#!/usr/bin/env bash
# rag/rag-setup.sh - set up Retrieval-Augmented Generation for the AI Workstation
#
# What this does:
#   1. Deploys the Chroma vector database (rag/rag-compose.yml)
#   2. Pulls the embedding model (nomic-embed-text) into Ollama
#   3. Configures Open WebUI RAG settings via its admin API
#   4. Tests RAG by uploading a sample document and querying it
#
# Idempotent: re-running detects an already-configured setup and skips work.
#
# Part of the 0x10debug VPS tool suite

set -euo pipefail

# Locate repo root from this script's location
MB_AI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${MB_AI_DIR}/lib/common.sh"
# shellcheck source=../lib/gpu.sh
source "${MB_AI_DIR}/lib/gpu.sh"

CHROMA_CONTAINER="chroma"
OPEN_WEBUI_CONTAINER="open-webui"
OLLAMA_CONTAINER="ollama"
EMBEDDING_MODEL="${RAG_EMBEDDING_MODEL:-nomic-embed-text}"
OPEN_WEBUI_URL="${OPEN_WEBUI_URL:-http://localhost:3000}"
SAMPLE_DOC="${MB_AI_DIR}/rag/sample-doc.txt"

mb_check_docker

# ---- 1. Deploy Chroma ----
mb_step "Deploying Chroma vector database"
if docker ps --format '{{.Names}}' | grep -qx "${CHROMA_CONTAINER}"; then
    mb_info "Chroma container already running"
else
    docker compose -f "${MB_AI_DIR}/rag/rag-compose.yml" --env-file "${MB_AI_DIR}/compose/.env" up -d chroma
    mb_success "Chroma started"
fi

# Wait for Chroma to be healthy
mb_info "Waiting for Chroma to be ready..."
for _ in $(seq 1 30); do
    if curl -sf "http://localhost:8000/api/v1/heartbeat" >/dev/null 2>&1; then
        mb_success "Chroma is ready"
        break
    fi
    sleep 2
done
if ! curl -sf "http://localhost:8000/api/v1/heartbeat" >/dev/null 2>&1; then
    mb_die "Chroma did not become ready in time"
fi

# ---- 2. Pull embedding model into Ollama ----
mb_step "Ensuring embedding model '${EMBEDDING_MODEL}' is available"
if ! docker ps --format '{{.Names}}' | grep -qx "${OLLAMA_CONTAINER}"; then
    mb_die "Ollama container is not running. Start the workstation first: mb ai deploy"
fi
if docker exec "${OLLAMA_CONTAINER}" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "${EMBEDDING_MODEL}"; then
    mb_info "Embedding model already present"
else
    mb_info "Pulling ${EMBEDDING_MODEL} (small, ~270MB)..."
    docker exec "${OLLAMA_CONTAINER}" ollama pull "${EMBEDDING_MODEL}"
    mb_success "Embedding model pulled"
fi

# ---- 3. Configure Open WebUI RAG settings via API ----
mb_step "Configuring Open WebUI RAG settings"
if ! docker ps --format '{{.Names}}' | grep -qx "${OPEN_WEBUI_CONTAINER}"; then
    mb_die "Open WebUI container is not running. Start the workstation first: mb ai deploy"
fi

# Wait for Open WebUI
mb_info "Waiting for Open WebUI to be ready..."
for _ in $(seq 1 60); do
    if curl -sf "${OPEN_WEBUI_URL}/health" >/dev/null 2>&1; then
        mb_success "Open WebUI is ready"
        break
    fi
    sleep 2
done
if ! curl -sf "${OPEN_WEBUI_URL}/health" >/dev/null 2>&1; then
    mb_die "Open WebUI did not become ready in time"
fi

# Idempotency: check if RAG is already configured
RAG_STATUS=$(curl -sf "${OPEN_WEBUI_URL}/api/config" 2>/dev/null || echo "{}")
if echo "${RAG_STATUS}" | grep -q "chroma:8000" 2>/dev/null; then
    mb_info "RAG already configured (Chroma URL detected). Skipping API configuration."
    mb_success "RAG is already set up"
else
    mb_info "Setting RAG_EMBEDDING_ENGINE=ollama and CHROMA_DB_URL via environment"
    mb_detail "Open WebUI reads RAG settings from environment variables on startup."
    mb_detail "The rag-compose.yml already sets them; restart open-webui to apply:"
    mb_detail "  docker compose -f rag/rag-compose.yml --env-file compose/.env up -d open-webui"
    docker compose -f "${MB_AI_DIR}/rag/rag-compose.yml" --env-file "${MB_AI_DIR}/compose/.env" up -d open-webui
    mb_success "Open WebUI restarted with RAG settings"
fi

# ---- 4. Test RAG with a sample document ----
mb_step "Testing RAG with a sample document"
if [[ ! -f "${SAMPLE_DOC}" ]]; then
    cat > "${SAMPLE_DOC}" <<'EOF'
The 0x10debug AI Workstation is a self-hosted alternative to ChatGPT.
It deploys Ollama and Open WebUI on a VPS using Docker. It supports both
CPU-only and NVIDIA GPU servers. Models can be pulled with the mb CLI.
RAG is powered by Chroma and the nomic-embed-text embedding model.
EOF
    mb_info "Created sample document at ${SAMPLE_DOC}"
fi

mb_info "Uploading sample document to Open WebUI..."
UPLOAD_RESP=$(curl -sf -X POST "${OPEN_WEBUI_URL}/api/v1/documents/" \
    -F "file=@${SAMPLE_DOC}" 2>/dev/null || echo "")

if [[ -z "${UPLOAD_RESP}" ]]; then
    mb_warn "Could not upload sample document (Open WebUI may require authentication)."
    mb_detail "Sign in at ${OPEN_WEBUI_URL} as the admin, then re-run: mb ai rag setup"
    mb_detail "RAG infrastructure is deployed; only the test upload was skipped."
else
    mb_success "Sample document uploaded"
    mb_info "You can now ask questions about it in the Open WebUI chat with RAG enabled."
fi

mb_step "RAG setup complete"
mb_detail "Chroma:      http://localhost:8000"
mb_detail "Open WebUI:  ${OPEN_WEBUI_URL}"
mb_detail "Embedding:   ${EMBEDDING_MODEL}"
mb_detail "See docs/rag-setup.md for usage details."
