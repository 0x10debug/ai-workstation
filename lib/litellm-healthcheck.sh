#!/usr/bin/env bash
# lib/litellm-healthcheck.sh - LiteLLM health & config checks for the mb CLI
# Part of the 0x10debug VPS tool suite
#
# Provides reusable functions used by `mb ai litellm health` and
# `mb ai litellm config-check`. All functions are safe to source under
# `set -euo pipefail`.

set -euo pipefail

# shellcheck source=common.sh
# (sourced by the mb CLI before this file)

LITELLM_CONTAINER="${LITELLM_CONTAINER:-litellm}"
LITELLM_HOST_PORT="${LITELLM_PORT:-4000}"

# Default placeholder values shipped in litellm.yml — if these are still in
# use, the deployment is insecure and we warn loudly.
LITELLM_DEFAULT_MASTER_KEY="sk-litellm-master-change-me"
LITELLM_DEFAULT_SALT_KEY="sk-litellm-salt-change-me"

# ---- Internal helpers ----

# _litellm_running -> 0 if the litellm container is up, 1 otherwise
_litellm_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LITELLM_CONTAINER}"
}

# _litellm_api_get <path> [extra curl args...] -> prints the JSON body of
# GET http://127.0.0.1:<port><path>. Uses the host port binding (127.0.0.1)
# so it works without `docker exec`.
_litellm_api_get() {
    local path="${1:-/health/liveness}"
    shift || true
    curl -fsS "http://127.0.0.1:${LITELLM_HOST_PORT}${path}" "$@" 2>/dev/null
}

# _litellm_env <var> -> prints the value of an env var set on the container
_litellm_env() {
    local var="$1"
    docker inspect "${LITELLM_CONTAINER}" \
        --format "{{range .Config.Env}}{{println .}}{{end}}" 2>/dev/null \
        | sed -n "s/^${var}=//p" | head -n1
}

# ---- Public functions ----

# litellm_healthcheck -> 0 if LiteLLM answers /health/liveness, 1 otherwise.
# Prints a one-line status. Verbose mode (arg `--verbose`) prints the raw
# response body.
litellm_healthcheck() {
    local verbose=0
    [[ "${1:-}" == "--verbose" ]] && verbose=1
    if ! _litellm_running; then
        mb_warn "LiteLLM container '${LITELLM_CONTAINER}' is not running"
        return 1
    fi
    local body
    if ! body=$(_litellm_api_get /health/liveness); then
        mb_warn "LiteLLM did not answer /health/liveness on 127.0.0.1:${LITELLM_HOST_PORT}"
        return 1
    fi
    if (( verbose == 1 )); then
        mb_success "LiteLLM healthy"
        mb_detail "response: ${body}"
    else
        mb_success "LiteLLM healthy"
    fi
    return 0
}

# litellm_list_models -> prints the configured models from /v1/models.
# Requires the master key (LiteLLM protects /v1/models). Returns 1 if the
# container is not running or the API is unreachable.
litellm_list_models() {
    if ! _litellm_running; then
        mb_warn "LiteLLM container '${LITELLM_CONTAINER}' is not running"
        return 1
    fi
    local master_key
    master_key=$(_litellm_env LITELLM_MASTER_KEY)
    if [[ -z "${master_key}" ]]; then
        mb_warn "Could not read LITELLM_MASTER_KEY from the container"
        return 1
    fi
    local body
    if ! body=$(_litellm_api_get /v1/models -H "Authorization: Bearer ${master_key}"); then
        mb_warn "LiteLLM did not answer /v1/models (is the master key correct?)"
        return 1
    fi
    mb_step "Configured LiteLLM models"
    # Extract model ids from the JSON response. LiteLLM returns:
    # {"data":[{"id":"llama3.2:3b",...},...]}
    printf '%s' "${body}" \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | sed 's/^/  /' || mb_warn "Could not parse model list"
}

# litellm_check_keys -> verifies the master key and salt key are set and not
# the insecure defaults. Returns 1 if defaults are still in use.
litellm_check_keys() {
    if ! _litellm_running; then
        mb_warn "LiteLLM container '${LITELLM_CONTAINER}' is not running"
        return 1
    fi
    local rc=0
    local master_key salt_key
    master_key=$(_litellm_env LITELLM_MASTER_KEY)
    salt_key=$(_litellm_env LITELLM_SALT_KEY)

    mb_step "API key configuration"
    if [[ -z "${master_key}" ]]; then
        mb_warn "LITELLM_MASTER_KEY is not set on the container"
        rc=1
    elif [[ "${master_key}" == "${LITELLM_DEFAULT_MASTER_KEY}" ]]; then
        mb_warn "LITELLM_MASTER_KEY is still the insecure default — generate a real key"
        mb_detail "  openssl rand -hex 32"
        rc=1
    else
        mb_success "LITELLM_MASTER_KEY is set (not the default)"
    fi

    if [[ -z "${salt_key}" ]]; then
        mb_warn "LITELLM_SALT_KEY is not set on the container"
        rc=1
    elif [[ "${salt_key}" == "${LITELLM_DEFAULT_SALT_KEY}" ]]; then
        mb_warn "LITELLM_SALT_KEY is still the insecure default — generate a real salt"
        mb_detail "  openssl rand -hex 32"
        rc=1
    else
        mb_success "LITELLM_SALT_KEY is set (not the default)"
    fi

    return "${rc}"
}

# litellm_check_budget -> reports the budget configuration from the
# container environment and the config file. Returns 0 always (advisory).
litellm_check_budget() {
    if ! _litellm_running; then
        mb_warn "LiteLLM container '${LITELLM_CONTAINER}' is not running"
        return 1
    fi
    mb_step "Budget configuration"
    local max_budget budget_duration
    max_budget=$(_litellm_env LITELLM_MAX_BUDGET)
    budget_duration=$(_litellm_env LITELLM_BUDGET_DURATION)
    if [[ -z "${max_budget}" ]]; then
        mb_detail "  max_budget: (not set — defaults to 0 / unlimited)"
    else
        mb_detail "  max_budget: ${max_budget}"
    fi
    if [[ -z "${budget_duration}" ]]; then
        mb_detail "  budget_duration: (not set — defaults to monthly)"
    else
        mb_detail "  budget_duration: ${budget_duration}"
    fi
    mb_info "Per-key budgets are managed via the /key/generate API"
    mb_detail "  curl -X POST http://127.0.0.1:${LITELLM_HOST_PORT}/key/generate ..."
    return 0
}

# litellm_check_all -> runs every check and returns 0 only if all pass.
# Used by `mb ai litellm health`.
litellm_check_all() {
    local rc=0
    litellm_healthcheck --verbose || rc=1
    echo
    litellm_list_models || rc=1
    echo
    litellm_check_keys || rc=1
    echo
    litellm_check_budget || rc=1
    return "${rc}"
}

# litellm_config_check -> validates the config file and key setup without
# requiring the container to be running. Used by `mb ai litellm config-check`.
litellm_check_config_file() {
    local config_file="${MB_COMPOSE_DIR}/litellm-config.yaml"
    local env_file
    env_file=$(mb_env_file)
    mb_step "LiteLLM config validation"

    if [[ ! -f "${config_file}" ]]; then
        mb_warn "Config file not found: ${config_file}"
        return 1
    fi
    mb_success "Config file present: ${config_file}"

    # Check for required top-level keys
    local has_model_list=0 has_router=0 has_general=0
    grep -qE '^model_list:' "${config_file}" && has_model_list=1
    grep -qE '^router_settings:' "${config_file}" && has_router=1
    grep -qE '^general_settings:' "${config_file}" && has_general=1

    if (( has_model_list == 0 )); then
        mb_warn "Missing 'model_list' section in config"
        return 1
    fi
    mb_success "model_list section found"

    if (( has_router == 0 )); then
        mb_detail "router_settings section not found (will use LiteLLM defaults)"
    else
        mb_success "router_settings section found"
    fi

    if (( has_general == 0 )); then
        mb_warn "Missing 'general_settings' section in config"
        return 1
    fi
    mb_success "general_settings section found"

    # Check env file for keys
    echo
    mb_step "Environment key check"
    local rc=0
    if [[ ! -f "${env_file}" ]]; then
        mb_warn "Env file not found: ${env_file}"
        mb_detail "Run 'mb ai deploy' or copy compose/.env.example to compose/.env"
        return 1
    fi

    if grep -q "^LITELLM_MASTER_KEY=${LITELLM_DEFAULT_MASTER_KEY}" "${env_file}" 2>/dev/null; then
        mb_warn "LITELLM_MASTER_KEY in ${env_file} is the insecure default"
        mb_detail "  Generate one: openssl rand -hex 32"
        rc=1
    elif grep -qE '^LITELLM_MASTER_KEY=.' "${env_file}" 2>/dev/null; then
        mb_success "LITELLM_MASTER_KEY is set in ${env_file}"
    else
        mb_warn "LITELLM_MASTER_KEY not found in ${env_file}"
        mb_detail "  Add: LITELLM_MASTER_KEY=sk-litellm-<openssl rand -hex 32>"
        rc=1
    fi

    if grep -q "^LITELLM_SALT_KEY=${LITELLM_DEFAULT_SALT_KEY}" "${env_file}" 2>/dev/null; then
        mb_warn "LITELLM_SALT_KEY in ${env_file} is the insecure default"
        mb_detail "  Generate one: openssl rand -hex 32"
        rc=1
    elif grep -qE '^LITELLM_SALT_KEY=.' "${env_file}" 2>/dev/null; then
        mb_success "LITELLM_SALT_KEY is set in ${env_file}"
    else
        mb_warn "LITELLM_SALT_KEY not found in ${env_file}"
        mb_detail "  Add: LITELLM_SALT_KEY=sk-litellm-<openssl rand -hex 32>"
        rc=1
    fi

    return "${rc}"
}
