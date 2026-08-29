#!/usr/bin/env bash
# lib/ollama-healthcheck.sh - Ollama health & resource checks for the mb CLI
# Part of the 0x10debug VPS tool suite
#
# Provides reusable functions used by `mb ai ollama-prod health` and the
# production deployment flow. All functions are safe to source under
# `set -euo pipefail`.

set -euo pipefail

# shellcheck source=common.sh
# shellcheck source=gpu.sh
# (sourced by the mb CLI before this file)

OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"
OLLAMA_HOST_PORT="${OLLAMA_PORT:-11434}"

# ---- Internal helpers ----

# _ollama_running -> 0 if the ollama container is up, 1 otherwise
_ollama_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${OLLAMA_CONTAINER}"
}

# _ollama_api_get <path> -> prints the JSON body of GET http://localhost:<port><path>
# Uses the host port binding (127.0.0.1) so it works without `docker exec`.
_ollama_api_get() {
    local path="${1:-/api/version}"
    curl -fsS "http://127.0.0.1:${OLLAMA_HOST_PORT}${path}" 2>/dev/null
}

# ---- Public functions ----

# ollama_healthcheck -> 0 if Ollama answers /api/version, 1 otherwise.
# Prints a one-line status. Verbose mode (arg `--verbose`) prints the version.
ollama_healthcheck() {
    local verbose=0
    [[ "${1:-}" == "--verbose" ]] && verbose=1
    if ! _ollama_running; then
        mb_warn "Ollama container '${OLLAMA_CONTAINER}' is not running"
        return 1
    fi
    local body
    if ! body=$(_ollama_api_get /api/version); then
        mb_warn "Ollama did not answer /api/version on 127.0.0.1:${OLLAMA_HOST_PORT}"
        return 1
    fi
    if (( verbose == 1 )); then
        local version
        version=$(printf '%s' "${body}" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        mb_success "Ollama healthy (version ${version:-unknown})"
    else
        mb_success "Ollama healthy"
    fi
    return 0
}

# ollama_list_models -> prints the installed models (name + size + modified).
# Returns 1 if the container is not running.
ollama_list_models() {
    if ! _ollama_running; then
        mb_warn "Ollama container '${OLLAMA_CONTAINER}' is not running"
        return 1
    fi
    mb_step "Installed Ollama models"
    # `ollama list` prints a header row then one line per model.
    docker exec "${OLLAMA_CONTAINER}" ollama list 2>/dev/null || {
        mb_warn "Failed to list models (is ollama ready?)"
        return 1
    }
}

# ollama_check_vram -> prints GPU VRAM usage if an NVIDIA GPU is present in
# the container, otherwise reports CPU mode. Returns 0 always.
ollama_check_vram() {
    if ! _ollama_running; then
        mb_warn "Ollama container '${OLLAMA_CONTAINER}' is not running"
        return 1
    fi
    if ! docker exec "${OLLAMA_CONTAINER}" command -v nvidia-smi >/dev/null 2>&1; then
        mb_info "GPU: none (CPU mode — no nvidia-smi in container)"
        return 0
    fi
    mb_step "GPU VRAM usage (inside ${OLLAMA_CONTAINER})"
    docker exec "${OLLAMA_CONTAINER}" nvidia-smi \
        --query-gpu=index,name,memory.used,memory.total,utilization.gpu \
        --format=csv,noheader 2>/dev/null | sed 's/^/  /' \
        || mb_warn "nvidia-smi query failed"
}

# ollama_check_disk -> prints free/used space on the volume backing
# /root/.ollama inside the container. Returns 1 if unavailable.
ollama_check_disk() {
    if ! _ollama_running; then
        mb_warn "Ollama container '${OLLAMA_CONTAINER}' is not running"
        return 1
    fi
    mb_step "Model storage (/root/.ollama)"
    # `df` is present in the ollama image; fall back gracefully if not.
    if ! docker exec "${OLLAMA_CONTAINER}" df -h /root/.ollama 2>/dev/null | sed 's/^/  /'; then
        mb_warn "Could not query disk usage inside the container"
        return 1
    fi
}

# ollama_check_all -> runs every check and returns 0 only if all pass.
# Used by `mb ai ollama-prod health`.
ollama_check_all() {
    local rc=0
    ollama_healthcheck --verbose || rc=1
    echo
    ollama_list_models || rc=1
    echo
    ollama_check_vram || rc=1
    echo
    ollama_check_disk || rc=1
    return "${rc}"
}
