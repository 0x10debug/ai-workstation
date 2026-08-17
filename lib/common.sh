#!/usr/bin/env bash
# lib/common.sh - shared helpers for the AI Workstation CLI (mb)
# Part of the 0x10debug VPS tool suite

set -euo pipefail

# ---- Version & paths ----
MB_AI_VERSION="1.0.0"
MB_AI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MB_COMPOSE_DIR="${MB_AI_DIR}/compose"
MB_MODELS_DIR="${MB_AI_DIR}/models"
MB_RAG_DIR="${MB_AI_DIR}/rag"
MB_DOCS_DIR="${MB_AI_DIR}/docs"
MB_DEPLOY_DIR="/opt/mb-ai"

# ---- Colors (disabled when not a TTY) ----
if [[ -t 1 ]]; then
    MB_C_RESET=$'\033[0m'
    MB_C_BOLD=$'\033[1m'
    MB_C_RED=$'\033[31m'
    MB_C_GREEN=$'\033[32m'
    MB_C_YELLOW=$'\033[33m'
    MB_C_BLUE=$'\033[34m'
    MB_C_CYAN=$'\033[36m'
    MB_C_GRAY=$'\033[90m'
else
    MB_C_RESET=""
    MB_C_BOLD=""
    MB_C_RED=""
    MB_C_GREEN=""
    MB_C_YELLOW=""
    MB_C_BLUE=""
    MB_C_CYAN=""
    MB_C_GRAY=""
fi

# ---- Logging ----
mb_step()   { printf '%s==>%s %s%s%s\n' "${MB_C_BOLD}${MB_C_BLUE}" "${MB_C_RESET}" "${MB_C_BOLD}" "$*" "${MB_C_RESET}"; }
mb_info()   { printf '%s[i]%s %s\n' "${MB_C_CYAN}" "${MB_C_RESET}" "$*"; }
mb_detail() { printf '%s    %s%s%s\n' "${MB_C_GRAY}" "$*" "${MB_C_RESET}"; }
mb_success(){ printf '%s[OK]%s %s\n' "${MB_C_GREEN}" "${MB_C_RESET}" "$*"; }
mb_warn()   { printf '%s[!]%s %s\n' "${MB_C_YELLOW}" "${MB_C_RESET}" "$*" >&2; }
mb_error()  { printf '%s[ERR]%s %s\n' "${MB_C_RED}" "${MB_C_RESET}" "$*" >&2; }
mb_die()    { mb_error "$*"; exit 1; }

# ---- Interactive helpers ----
# mb_ask "question?" -> echoes y/n, returns 0 on yes
mb_ask() {
    local prompt="$1"
    local reply
    read -r -p "${MB_C_BOLD}?${MB_C_RESET} ${prompt} [y/N] " reply
    reply="${reply:-n}"
    case "${reply,,}" in
        y|yes) echo "y"; return 0 ;;
        *)     echo "n"; return 1 ;;
    esac
}

# mb_ask_value "prompt" "default" -> echoes the value (default if empty)
mb_ask_value() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    if [[ -n "${default}" ]]; then
        read -r -p "${MB_C_BOLD}?${MB_C_RESET} ${prompt} [${default}]: " reply
        echo "${reply:-${default}}"
    else
        read -r -p "${MB_C_BOLD}?${MB_C_RESET} ${prompt}: " reply
        echo "${reply}"
    fi
}

# ---- Checks ----
# mb_check_command <cmd...> -> dies if any command is missing
mb_check_command() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        mb_die "Missing required command(s): ${missing[*]}"
    fi
}

# mb_check_docker -> dies if docker / docker compose are unavailable
mb_check_docker() {
    mb_check_command docker
    if ! docker compose version >/dev/null 2>&1; then
        mb_die "Docker Compose v2 is required (plugin not found). Install it and retry."
    fi
}

# ---- Misc helpers ----
# mb_compose_file -> echoes the compose file path based on GPU presence flag
#   arg1: "gpu" or "cpu"
mb_compose_file() {
    local mode="${1:-cpu}"
    case "${mode}" in
        gpu) echo "${MB_COMPOSE_DIR}/compose.gpu.yml" ;;
        *)   echo "${MB_COMPOSE_DIR}/compose.cpu.yml" ;;
    esac
}

# mb_env_file -> echoes the .env path used by compose
mb_env_file() {
    echo "${MB_COMPOSE_DIR}/.env"
}

# mb_detect_ram_gb -> echoes total system RAM in GB (integer)
mb_detect_ram_gb() {
    if [[ -r /proc/meminfo ]]; then
        local kb
        kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        echo $(( kb / 1024 / 1024 ))
    else
        # macOS / fallback
        if command -v sysctl >/dev/null 2>&1; then
            local bytes
            bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
            echo $(( bytes / 1024 / 1024 / 1024 ))
        else
            echo 0
        fi
    fi
}
