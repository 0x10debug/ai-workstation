#!/usr/bin/env bash
# lib/gpu.sh - NVIDIA GPU detection helpers for the AI Workstation CLI (mb)
# Part of the 0x10debug VPS tool suite

set -euo pipefail

# mb_gpu_check -> returns 0 if an NVIDIA GPU is available, 1 otherwise
mb_gpu_check() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        return 1
    fi
    if ! nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
        return 1
    fi
    # Make sure there is at least one GPU reported
    [[ "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)" -gt 0 ]]
}

# mb_gpu_info -> prints GPU name, VRAM, and driver version
mb_gpu_info() {
    if ! mb_gpu_check; then
        echo "No NVIDIA GPU detected"
        return 1
    fi
    local name vram driver
    name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
    driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
    printf 'GPU:          %s\n' "${name}"
    printf 'VRAM (total): %s MB\n' "${vram}"
    printf 'Driver:       %s\n' "${driver}"
}

# mb_gpu_vram -> echoes total VRAM in GB (integer). Echoes 0 if no GPU.
mb_gpu_vram() {
    if ! mb_gpu_check; then
        echo 0
        return 0
    fi
    local mb
    mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1)
    echo $(( mb / 1024 ))
}
