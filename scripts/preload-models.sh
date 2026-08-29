#!/usr/bin/env bash
# scripts/preload-models.sh - preload Ollama models after the service is up
#
# Reads a model list from --config <file> or --model <tag> (repeatable) and
# pulls each one into the running Ollama container with bounded concurrency.
# Idempotent: models already present are skipped.
#
# Usage:
#   scripts/preload-models.sh                          # use models/default-models.conf
#   scripts/preload-models.sh --config my-models.conf
#   scripts/preload-models.sh --model llama3.2:3b --model qwen2.5:7b
#   scripts/preload-models.sh --dry-run                # print what would happen
#   scripts/preload-models.sh --concurrency 1          # serial pulls
#
# Config file format (one model per line, # comments and blank lines ignored):
#   llama3.2:3b
#   qwen2.5:7b
#   nomic-embed-text
#
# Part of the 0x10debug VPS tool suite

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MB_AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${MB_AI_DIR}/lib/common.sh"

OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"
DEFAULT_CONFIG="${MB_AI_DIR}/models/default-models.conf"
DEFAULT_CONCURRENCY=2

# ---- Defaults & arg parsing ----
models=()
config_file=""
dry_run=0
concurrency="${DEFAULT_CONCURRENCY}"

usage() {
    cat <<'USAGE'
Usage: preload-models.sh [options]

Options:
  --model <tag>         Model to pull (repeatable; overrides --config)
  --config <path>       Model list file (one tag per line; # = comment)
  --concurrency <n>     Max parallel pulls (default: 2)
  --dry-run             Print actions without pulling
  -h, --help            Show this help

If neither --model nor --config is given, models/default-models.conf is used.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)        models+=("$2"); shift 2 ;;
        --config)       config_file="$2"; shift 2 ;;
        --concurrency)  concurrency="$2"; shift 2 ;;
        --dry-run)      dry_run=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              mb_die "Unknown option: $1 (see --help)" ;;
    esac
done

# Validate concurrency is a positive integer
[[ "${concurrency}" =~ ^[1-9][0-9]*$ ]] || mb_die "--concurrency must be a positive integer, got '${concurrency}'"

# ---- Resolve the model list ----
resolve_models() {
    local file=""
    if [[ ${#models[@]} -gt 0 ]]; then
        # --model overrides --config entirely
        printf '%s\n' "${models[@]}"
        return 0
    fi
    if [[ -n "${config_file}" ]]; then
        file="${config_file}"
    else
        file="${DEFAULT_CONFIG}"
    fi
    [[ -f "${file}" ]] || mb_die "Model config not found: ${file}"
    # Strip comments (# ...) and blank lines
    grep -vE '^\s*(#|$)' "${file}" | sed 's/[[:space:]]*$//' | grep -v '^$' || true
}

mapfile -t MODEL_LIST < <(resolve_models)
if [[ ${#MODEL_LIST[@]} -eq 0 ]]; then
    mb_warn "No models to preload (config is empty)."
    exit 0
fi

mb_step "Preloading ${#MODEL_LIST[@]} model(s) into Ollama"
mb_detail "Container:    ${OLLAMA_CONTAINER}"
mb_detail "Concurrency:  ${concurrency}"
mb_detail "Dry-run:      $([[ ${dry_run} -eq 1 ]] && echo yes || echo no)"
echo

# ---- Preflight: container running? ----
if [[ ${dry_run} -eq 0 ]]; then
    mb_check_docker
    if ! docker ps --format '{{.Names}}' | grep -qx "${OLLAMA_CONTAINER}"; then
        mb_die "Ollama container '${OLLAMA_CONTAINER}' is not running. Start it first: mb ai ollama-prod deploy"
    fi
fi

# ---- Helpers ----

# model_is_present <tag> -> returns 0 if the model is already installed
model_is_present() {
    local tag="$1"
    docker exec "${OLLAMA_CONTAINER}" ollama list 2>/dev/null \
        | awk 'NR>1 {print $1}' \
        | grep -qx "${tag}"
}

# pull_one <tag> -> pulls a single model, streaming progress
pull_one() {
    local tag="$1"
    if [[ ${dry_run} -eq 1 ]]; then
        printf '%s[DRY]%s would pull %s\n' "${MB_C_YELLOW}" "${MB_C_RESET}" "${tag}"
        return 0
    fi
    if model_is_present "${tag}"; then
        printf '%s[SKIP]%s %s already present\n' "${MB_C_GRAY}" "${MB_C_RESET}" "${tag}"
        return 0
    fi
    printf '%s[PULL]%s %s\n' "${MB_C_CYAN}" "${MB_C_RESET}" "${tag}"
    if docker exec "${OLLAMA_CONTAINER}" ollama pull "${tag}" >/dev/null 2>&1; then
        printf '%s[OK]%s  %s\n' "${MB_C_GREEN}" "${MB_C_RESET}" "${tag}"
        return 0
    else
        printf '%s[ERR]%s %s (pull failed)\n' "${MB_C_RED}" "${MB_C_RESET}" "${tag}" >&2
        return 1
    fi
}

# ---- Bounded-concurrency pull ----
# We use a simple job-control loop: dispatch up to ${concurrency} background
# jobs, wait for a slot to free, repeat. Failures are collected and reported
# at the end so one bad model does not abort the whole run.

declare -a pids=()
declare -a tags_in_flight=()
failed_tags=()
started=0
total=${#MODEL_LIST[@]}

for tag in "${MODEL_LIST[@]}"; do
    # Wait for a free slot if at capacity
    while [[ ${#pids[@]} -ge ${concurrency} ]]; do
        # Poll children; remove finished ones
        new_pids=()
        new_tags=()
        for i in "${!pids[@]}"; do
            if kill -0 "${pids[$i]}" 2>/dev/null; then
                new_pids+=("${pids[$i]}")
                new_tags+=("${tags_in_flight[$i]}")
            else
                wait "${pids[$i]}" || failed_tags+=("${tags_in_flight[$i]}")
            fi
        done
        pids=("${new_pids[@]}")
        tags_in_flight=("${new_tags[@]}")
        [[ ${#pids[@]} -ge ${concurrency} ]] && sleep 1
    done

    started=$((started + 1))
    mb_detail "[$started/$total] dispatching ${tag}"
    pull_one "${tag}" &
    pids+=("$!")
    tags_in_flight+=("${tag}")
done

# Drain remaining jobs
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || failed_tags+=("${tags_in_flight[$i]}")
done

# ---- Summary ----
echo
succeeded=$(( total - ${#failed_tags[@]} ))
if [[ ${#failed_tags[@]} -eq 0 ]]; then
    mb_success "Preloaded ${succeeded}/${total} model(s)"
else
    mb_warn "Preloaded ${succeeded}/${total} model(s); ${#failed_tags[@]} failed:"
    for t in "${failed_tags[@]}"; do
        mb_detail "  failed: ${t}"
    done
    exit 1
fi
