#!/usr/bin/env bash
# lib/model.sh - Ollama model management helpers for the AI Workstation CLI (mb)
# Part of the 0x10debug VPS tool suite

set -euo pipefail

# shellcheck source=common.sh
# shellcheck source=gpu.sh
# (sourced by the mb CLI before this file)

OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"

# mb_ollama_exec <args...> -> runs `ollama <args>` inside the container
mb_ollama_exec() {
    docker exec "${OLLAMA_CONTAINER}" ollama "$@"
}

# mb_model_list -> lists installed models via `ollama list`
mb_model_list() {
    if ! docker ps --format '{{.Names}}' | grep -qx "${OLLAMA_CONTAINER}"; then
        mb_warn "Ollama container '${OLLAMA_CONTAINER}' is not running."
        mb_info "Start the workstation first: mb ai deploy"
        return 1
    fi
    mb_step "Installed Ollama models"
    mb_ollama_exec list
}

# mb_model_pull <model> -> pulls a model
mb_model_pull() {
    local model="${1:-}"
    [[ -n "${model}" ]] || mb_die "Usage: mb ai model pull <model>"
    if ! docker ps --format '{{.Names}}' | grep -qx "${OLLAMA_CONTAINER}"; then
        mb_die "Ollama container '${OLLAMA_CONTAINER}' is not running. Start with: mb ai deploy"
    fi
    mb_step "Pulling model: ${model}"
    mb_info "This may take a while depending on model size and bandwidth..."
    mb_ollama_exec pull "${model}"
    mb_success "Pulled ${model}"
}

# mb_model_remove <model> -> removes a model
mb_model_remove() {
    local model="${1:-}"
    [[ -n "${model}" ]] || mb_die "Usage: mb ai model remove <model>"
    if ! docker ps --format '{{.Names}}' | grep -qx "${OLLAMA_CONTAINER}"; then
        mb_die "Ollama container '${OLLAMA_CONTAINER}' is not running. Start with: mb ai deploy"
    fi
    mb_step "Removing model: ${model}"
    mb_ollama_exec rm "${model}"
    mb_success "Removed ${model}"
}

# mb_model_recommend -> detects RAM/VRAM, reads recommended.yaml, shows recommendations
mb_model_recommend() {
    local ram_gb vram_gb
    ram_gb=$(mb_detect_ram_gb)
    if mb_gpu_check; then
        vram_gb=$(mb_gpu_vram)
    else
        vram_gb=0
    fi

    mb_step "Detected hardware"
    if (( vram_gb > 0 )); then
        mb_detail "RAM:  ${ram_gb} GB"
        mb_detail "VRAM: ${vram_gb} GB (NVIDIA GPU)"
    else
        mb_detail "RAM:  ${ram_gb} GB"
        mb_detail "VRAM: none (CPU-only)"
    fi

    # Pick a profile based on resources
    local profile=""
    if (( vram_gb >= 24 )); then
        profile="24GB+ VRAM / GPU"
    elif (( vram_gb >= 16 )); then
        profile="16GB VRAM / GPU"
    elif (( vram_gb >= 8 )); then
        profile="8GB VRAM / GPU"
    elif (( ram_gb >= 16 )); then
        profile="16GB RAM / CPU"
    elif (( ram_gb >= 8 )); then
        profile="8GB RAM / CPU"
    elif (( ram_gb >= 4 )); then
        profile="4GB RAM / CPU"
    else
        profile="2GB RAM / CPU"
    fi

    mb_step "Recommended models for profile: ${profile}"
    echo

    # Parse recommended.yaml with awk (no yq dependency) for the matching profile block.
    # Each profile block is a list item under `recommendations:` and contains
    # `  - name: ...` / `    size: ...` / `    description: ...` entries.
    local yaml="${MB_MODELS_DIR}/recommended.yaml"
    [[ -f "${yaml}" ]] || mb_die "recommended.yaml not found at ${yaml}"

    # Use python3 if available for robust YAML parsing; fall back to awk.
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${yaml}" "${profile}" <<'PY'
import sys, yaml
path, profile = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = yaml.safe_load(f)
found = False
for entry in data.get("recommendations", []):
    if entry.get("profile") == profile:
        found = True
        for m in entry.get("models", []):
            print(f"  {m['name']:<22} {m.get('size',''):<10} {m.get('description','')}")
if not found:
    print("  (no matching profile)")
PY
        return 0
    fi

    # Fallback: awk-based extraction
    awk -v want="${profile}" '
        /^[[:space:]]*- profile:/ {
            gsub(/^[[:space:]]*- profile:[[:space:]]*"?/, "")
            gsub(/"?[[:space:]]*$/, "")
            in_block = ($0 == want)
            next
        }
        in_block && /^[[:space:]]*- name:/ {
            gsub(/^[[:space:]]*- name:[[:space:]]*/, "")
            name = $0
            getline
            gsub(/^[[:space:]]*size:[[:space:]]*/, "")
            size = $0
            getline
            gsub(/^[[:space:]]*description:[[:space:]]*"?/, "")
            gsub(/"?[[:space:]]*$/, "")
            desc = $0
            printf "  %-22s %-10s %s\n", name, size, desc
        }
    ' "${yaml}"
}
