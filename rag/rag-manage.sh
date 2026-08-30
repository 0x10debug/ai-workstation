#!/usr/bin/env bash
# rag/rag-manage.sh - RAG knowledge base management
#
# Subcommands:
#   setup                Deploy Chroma + configure Open WebUI RAG
#   ingest <path>        Ingest documents from a directory into Chroma
#   collections list     List all Chroma collections
#   collections info <n> Show details of a specific collection
#   collections delete <n>  Delete a collection (with confirmation)
#   query <collection> <text>  Query a collection for similar documents
#   backup <output>      Backup Chroma database to a tar file
#   restore <input>      Restore Chroma database from a tar file
#   status               Show RAG system status
#   models               Show available embedding models
#   models pull <name>   Pull a specific embedding model
#
# Part of the 0x10debug VPS tool suite

set -euo pipefail

MB_AI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${MB_AI_DIR}/lib/common.sh"

CHROMA_CONTAINER="chroma"
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"
OPEN_WEBUI_CONTAINER="open-webui"
CHROMA_URL="${CHROMA_URL:-http://localhost:8000}"
OPEN_WEBUI_URL="${OPEN_WEBUI_URL:-http://localhost:3000}"
EMBEDDING_MODEL="${RAG_EMBEDDING_MODEL:-nomic-embed-text}"

# Supported embedding models
SUPPORTED_EMBEDDING_MODELS=(
    "nomic-embed-text"
    "mxbai-embed-large"
    "snowflake-arctic-embed"
    "all-minilm"
    "bge-m3"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_rag_chroma_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CHROMA_CONTAINER"
}

_rag_ollama_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OLLAMA_CONTAINER"
}

_rag_wait_chroma() {
    mb_info "Waiting for Chroma to be ready..."
    for _ in $(seq 1 30); do
        if curl -sf "${CHROMA_URL}/api/v1/heartbeat" >/dev/null 2>&1; then
            mb_success "Chroma is ready"
            return 0
        fi
        sleep 2
    done
    mb_die "Chroma did not become ready in time"
}

_rag_wait_webui() {
    mb_info "Waiting for Open WebUI to be ready..."
    for _ in $(seq 1 60); do
        if curl -sf "${OPEN_WEBUI_URL}/health" >/dev/null 2>&1; then
            mb_success "Open WebUI is ready"
            return 0
        fi
        sleep 2
    done
    mb_die "Open WebUI did not become ready in time"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

rag_setup() {
    mb_check_docker
    mb_step "Setting up RAG (Retrieval-Augmented Generation)"

    # 1. Deploy Chroma
    mb_step "Deploying Chroma vector database"
    if _rag_chroma_running; then
        mb_info "Chroma container already running"
    else
        docker compose -f "${MB_AI_DIR}/rag/rag-compose.yml" \
            --env-file "${MB_AI_DIR}/compose/.env" up -d chroma
        mb_success "Chroma started"
    fi
    _rag_wait_chroma

    # 2. Pull embedding model
    mb_step "Ensuring embedding model '${EMBEDDING_MODEL}' is available"
    if ! _rag_ollama_running; then
        mb_die "Ollama container is not running. Start the workstation first: mb ai deploy"
    fi
    if docker exec "$OLLAMA_CONTAINER" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$EMBEDDING_MODEL"; then
        mb_info "Embedding model already present"
    else
        mb_info "Pulling ${EMBEDDING_MODEL} (small, ~270MB)..."
        docker exec "$OLLAMA_CONTAINER" ollama pull "$EMBEDDING_MODEL"
        mb_success "Embedding model pulled"
    fi

    # 3. Configure Open WebUI
    mb_step "Configuring Open WebUI RAG settings"
    if ! docker ps --format '{{.Names}}' | grep -qx "$OPEN_WEBUI_CONTAINER"; then
        mb_warn "Open WebUI container is not running."
        mb_detail "RAG infrastructure is deployed. Start Open WebUI to enable RAG in the UI."
        mb_detail "Open WebUI reads RAG settings from environment variables in rag-compose.yml."
    else
        _rag_wait_webui
        mb_info "Open WebUI reads RAG settings from environment variables on startup."
        mb_detail "If RAG settings were recently changed, restart Open WebUI:"
        mb_detail "  docker compose -f rag/rag-compose.yml restart open-webui"
    fi

    # 4. Create default collection
    mb_step "Creating default knowledge base collection"
    local collections
    collections=$(curl -sf "${CHROMA_URL}/api/v1/collections" 2>/dev/null || echo "[]")
    if echo "$collections" | grep -q "knowledge_base" 2>/dev/null; then
        mb_info "Default collection 'knowledge_base' already exists"
    else
        local create_resp
        create_resp=$(curl -sf -X POST "${CHROMA_URL}/api/v1/collections" \
            -H "Content-Type: application/json" \
            -d '{"name":"knowledge_base","metadata":{"description":"Default RAG knowledge base"}}' 2>/dev/null || echo "")
        if [[ -n "$create_resp" ]]; then
            mb_success "Default collection 'knowledge_base' created"
        else
            mb_warn "Could not create default collection (may require auth)"
        fi
    fi

    mb_step "RAG setup complete"
    mb_detail "Chroma:      ${CHROMA_URL}"
    mb_detail "Open WebUI:  ${OPEN_WEBUI_URL}"
    mb_detail "Embedding:   ${EMBEDDING_MODEL}"
    mb_detail "Ingest docs: mb ai rag ingest /path/to/documents"
    mb_detail "Collections: mb ai rag collections list"
}

# ---------------------------------------------------------------------------
# Ingest documents
# ---------------------------------------------------------------------------

rag_ingest() {
    local doc_path="${1:-}"
    [[ -z "$doc_path" ]] && mb_die "Usage: mb ai rag ingest <path>"
    [[ ! -d "$doc_path" ]] && mb_die "Path does not exist: $doc_path"

    _rag_chroma_running || mb_die "Chroma is not running. Run 'mb ai rag setup' first."
    _rag_ollama_running || mb_die "Ollama is not running."

    local collection="${2:-knowledge_base}"
    mb_step "Ingesting documents from: $doc_path"
    mb_info "Target collection: $collection"
    mb_info "Embedding model: $EMBEDDING_MODEL"

    # Supported file extensions
    local supported_exts="txt md markdown pdf docx doc html htm csv json yaml yml rst org"

    local file_count=0
    local success_count=0
    local fail_count=0

    # Find supported files
    local find_args=()
    for ext in $supported_exts; do
        find_args+=(-o -name "*.${ext}")
    done
    find_args=("${find_args[@]:1}")  # Remove first -o

    while IFS= read -r -d '' file; do
        file_count=$((file_count + 1))
        local basename
        basename=$(basename "$file")
        local ext="${basename##*.}"
        local size
        size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)

        mb_detail "[${file_count}] ${basename} ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"))"

        # Read file content
        local content=""
        case "$ext" in
            txt|md|markdown|rst|org|html|htm|csv|json|yaml|yml)
                content=$(cat "$file" 2>/dev/null || echo "")
                ;;
            pdf|docx|doc)
                mb_detail "  (binary format — requires Open WebUI for processing)"
                # For binary formats, we'd need to use Open WebUI's document API
                # or a tool like pandoc/tika. For now, skip with a note.
                fail_count=$((fail_count + 1))
                continue
                ;;
            *)
                fail_count=$((fail_count + 1))
                continue
                ;;
        esac

        if [[ -z "$content" ]]; then
            mb_warn "  Empty content, skipping"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Generate embedding via Ollama
        local embedding_resp
        embedding_resp=$(docker exec "$OLLAMA_CONTAINER" ollama embed "$EMBEDDING_MODEL" "$content" 2>/dev/null || echo "")

        if [[ -z "$embedding_resp" ]]; then
            mb_warn "  Failed to generate embedding"
            fail_count=$((fail_count + 1))
            continue
        fi

        # Extract embedding vector from JSON response
        local embedding_json
        embedding_json=$(echo "$embedding_resp" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    embeddings = data.get('embeddings', [])
    if embeddings:
        print(json.dumps(embeddings[0]))
    else:
        print(json.dumps(data.get('embedding', [])))
except:
    print('[]')
" 2>/dev/null || echo "[]")

        # Add to Chroma collection
        local doc_id
        doc_id=$(echo -n "${file}${file_count}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "doc_${file_count}")

        local add_resp
        add_resp=$(curl -sf -X POST "${CHROMA_URL}/api/v1/collections/${collection}/add" \
            -H "Content-Type: application/json" \
            -d "{
                \"ids\": [\"${doc_id}\"],
                \"embeddings\": [${embedding_json}],
                \"documents\": [$(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')],
                \"metadatas\": [{\"source\": \"${basename}\", \"path\": \"${file}\", \"size\": ${size}}]
            }" 2>/dev/null || echo "")

        if [[ -n "$add_resp" ]]; then
            success_count=$((success_count + 1))
        else
            mb_warn "  Failed to add to Chroma"
            fail_count=$((fail_count + 1))
        fi

    done < <(find "$doc_path" -type f "${find_args[@]}" -print0 2>/dev/null)

    mb_step "Ingestion complete"
    mb_detail "Files found:    ${file_count}"
    mb_detail "Successfully ingested: ${success_count}"
    mb_detail "Failed:         ${fail_count}"
    if [[ "$fail_count" -gt 0 ]]; then
        mb_detail "Binary formats (PDF, DOCX) require Open WebUI upload for processing."
    fi
}

# ---------------------------------------------------------------------------
# Collections management
# ---------------------------------------------------------------------------

rag_collections_list() {
    _rag_chroma_running || mb_die "Chroma is not running. Run 'mb ai rag setup' first."
    mb_step "Chroma collections"

    local collections
    collections=$(curl -sf "${CHROMA_URL}/api/v1/collections" 2>/dev/null || echo "[]")

    echo "$collections" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data:
    print('  No collections found')
    print('  Create one: mb ai rag ingest /path/to/docs <collection_name>')
else:
    print(f'{\"Name\":<30} {\"Documents\":>10} {\"Distance\":<15}')
    print(f'{\"----\":<30} {\"---------\":>10} {\"--------\":<15}')
    for c in data:
        name = c.get('name', 'unknown')
        count = c.get('metadata', {}).get('count', '?')
        distance = c.get('metadata', {}).get('hnsw:space', 'unknown')
        print(f'{name:<30} {count:>10} {distance:<15}')
" 2>/dev/null || mb_warn "Failed to parse collections"
}

rag_collections_info() {
    local name="${1:-}"
    [[ -z "$name" ]] && mb_die "Usage: mb ai rag collections info <name>"
    _rag_chroma_running || mb_die "Chroma is not running."

    mb_step "Collection: $name"

    local info
    info=$(curl -sf "${CHROMA_URL}/api/v1/collections/${name}" 2>/dev/null || echo "{}")

    echo "$info" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'  Name:     {data.get(\"name\", \"unknown\")}')
print(f'  ID:       {data.get(\"id\", \"unknown\")}')
meta = data.get('metadata', {})
print(f'  Distance: {meta.get(\"hnsw:space\", \"unknown\")}')
print(f'  Count:    {meta.get(\"count\", \"unknown\")}')
print(f'  Created:  {meta.get(\"created_at\", \"unknown\")}')
" 2>/dev/null || mb_warn "Failed to parse collection info"

    # Get sample documents
    mb_info "Sample documents:"
    local sample
    sample=$(curl -sf -X POST "${CHROMA_URL}/api/v1/collections/${name}/get" \
        -H "Content-Type: application/json" \
        -d '{"limit": 5}' 2>/dev/null || echo "{}")

    echo "$sample" | python3 -c "
import json, sys
data = json.load(sys.stdin)
docs = data.get('documents', [])
metas = data.get('metadatas', [])
for i, (doc, meta) in enumerate(zip(docs, metas)):
    source = meta.get('source', 'unknown') if meta else 'unknown'
    preview = doc[:100] + '...' if len(doc) > 100 else doc
    print(f'  [{i+1}] {source}: {preview}')
if not docs:
    print('  (empty collection)')
" 2>/dev/null || mb_warn "Failed to parse sample documents"
}

rag_collections_delete() {
    local name="${1:-}"
    [[ -z "$name" ]] && mb_die "Usage: mb ai rag collections delete <name>"
    _rag_chroma_running || mb_die "Chroma is not running."

    mb_warn "This will permanently delete collection '${name}' and all its documents."
    read -r -p "Type the collection name to confirm: " confirm
    [[ "$confirm" == "$name" ]] || mb_die "Confirmation does not match. Aborted."

    local resp
    resp=$(curl -sf -X DELETE "${CHROMA_URL}/api/v1/collections/${name}" 2>/dev/null || echo "")
    if [[ -n "$resp" ]]; then
        mb_success "Collection '${name}' deleted"
    else
        mb_die "Failed to delete collection '${name}'"
    fi
}

rag_query() {
    local collection="${1:-}"
    local query_text="${2:-}"
    [[ -z "$collection" ]] && mb_die "Usage: mb ai rag query <collection> <text>"
    [[ -z "$query_text" ]] && mb_die "Usage: mb ai rag query <collection> <text>"
    shift 2

    _rag_chroma_running || mb_die "Chroma is not running."
    _rag_ollama_running || mb_die "Ollama is not running."

    mb_step "Querying collection: $collection"
    mb_info "Query: $query_text"

    # Generate embedding for query
    local embedding_resp
    embedding_resp=$(docker exec "$OLLAMA_CONTAINER" ollama embed "$EMBEDDING_MODEL" "$query_text" 2>/dev/null || echo "")
    local embedding_json
    embedding_json=$(echo "$embedding_resp" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    embeddings = data.get('embeddings', [])
    if embeddings:
        print(json.dumps(embeddings[0]))
    else:
        print(json.dumps(data.get('embedding', [])))
except:
    print('[]')
" 2>/dev/null || echo "[]")

    local n_results="${RAG_TOP_K:-4}"
    local results
    results=$(curl -sf -X POST "${CHROMA_URL}/api/v1/collections/${collection}/query" \
        -H "Content-Type: application/json" \
        -d "{
            \"query_embeddings\": [${embedding_json}],
            \"n_results\": ${n_results}
        }" 2>/dev/null || echo "{}")

    echo "$results" | python3 -c "
import json, sys
data = json.load(sys.stdin)
docs = data.get('documents', [[]])
metas = data.get('metadatas', [[]])
dists = data.get('distances', [[]])

if not docs or not docs[0]:
    print('  No results found')
else:
    for i, (doc, meta, dist) in enumerate(zip(docs[0], metas[0], dists[0])):
        source = meta.get('source', 'unknown') if meta else 'unknown'
        print(f'  [{i+1}] {source} (distance: {dist:.4f})')
        preview = doc[:200] + '...' if len(doc) > 200 else doc
        print(f'      {preview}')
        print()
" 2>/dev/null || mb_warn "Failed to parse query results"
}

# ---------------------------------------------------------------------------
# Backup / Restore
# ---------------------------------------------------------------------------

rag_backup() {
    local output="${1:-}"
    [[ -z "$output" ]] && mb_die "Usage: mb ai rag backup <output.tar.gz>"
    _rag_chroma_running || mb_die "Chroma is not running."

    mb_step "Backing up Chroma database"
    mb_info "Output: $output"

    # Get the volume name
    local volume
    volume=$(docker inspect "$CHROMA_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/chroma/chroma"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

    if [[ -z "$volume" ]]; then
        # Fallback: use bind mount path
        local mount_path
        mount_path=$(docker inspect "$CHROMA_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/chroma/chroma"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || echo "")
        if [[ -n "$mount_path" ]]; then
            tar czf "$output" -C "$mount_path" . 2>/dev/null && mb_success "Backup complete: $output" || mb_die "Backup failed"
        else
            mb_die "Could not find Chroma data volume or mount path"
        fi
    else
        # Backup from Docker volume
        docker run --rm -v "${volume}:/data:ro" -v "$(cd "$(dirname "$output")" && pwd)/$(basename "$output"):/backup.tar.gz" \
            alpine tar czf /backup.tar.gz -C /data . 2>/dev/null && \
            mb_success "Backup complete: $output" || mb_die "Backup failed"
    fi

    local size
    size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
    mb_detail "Size: $(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")"
}

rag_restore() {
    local input="${1:-}"
    [[ -z "$input" ]] && mb_die "Usage: mb ai rag restore <input.tar.gz>"
    [[ ! -f "$input" ]] && mb_die "File not found: $input"
    _rag_chroma_running || mb_die "Chroma is not running."

    mb_warn "This will REPLACE all existing Chroma data."
    read -r -p "Type 'yes' to confirm: " confirm
    [[ "$confirm" == "yes" ]] || mb_die "Aborted."

    mb_step "Stopping Chroma for restore..."
    docker stop "$CHROMA_CONTAINER" 2>/dev/null || true

    local volume
    volume=$(docker inspect "$CHROMA_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/chroma/chroma"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

    if [[ -n "$volume" ]]; then
        mb_info "Restoring from: $input"
        docker run --rm -v "${volume}:/data" -v "$(cd "$(dirname "$input")" && pwd)/$(basename "$input"):/backup.tar.gz:ro" \
            alpine sh -c "rm -rf /data/* && tar xzf /backup.tar.gz -C /data" 2>/dev/null && \
            mb_success "Restore complete" || mb_die "Restore failed"
    else
        mb_die "Could not find Chroma data volume"
    fi

    mb_step "Starting Chroma..."
    docker start "$CHROMA_CONTAINER" 2>/dev/null || true
    _rag_wait_chroma
    mb_success "Chroma restored and running"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------

rag_status() {
    mb_check_docker
    mb_step "RAG system status"

    # Chroma
    if _rag_chroma_running; then
        mb_success "Chroma: running"
        mb_detail "URL: ${CHROMA_URL}"

        # Collections
        local collections
        collections=$(curl -sf "${CHROMA_URL}/api/v1/collections" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len(data))
except:
    print(0)
" 2>/dev/null || echo 0)
        mb_detail "Collections: ${collections}"
    else
        mb_warn "Chroma: not running"
        mb_detail "Start: mb ai rag setup"
    fi

    # Ollama
    if _rag_ollama_running; then
        mb_success "Ollama: running"
        # Check embedding model
        if docker exec "$OLLAMA_CONTAINER" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$EMBEDDING_MODEL"; then
            mb_detail "Embedding model: ${EMBEDDING_MODEL} (available)"
        else
            mb_warn "Embedding model: ${EMBEDDING_MODEL} (not pulled)"
            mb_detail "Pull: mb ai rag models pull ${EMBEDDING_MODEL}"
        fi
    else
        mb_warn "Ollama: not running"
    fi

    # Open WebUI
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$OPEN_WEBUI_CONTAINER"; then
        mb_success "Open WebUI: running"
        mb_detail "URL: ${OPEN_WEBUI_URL}"
    else
        mb_warn "Open WebUI: not running"
    fi

    # Disk usage
    local volume
    volume=$(docker inspect "$CHROMA_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/chroma/chroma"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")
    if [[ -n "$volume" ]]; then
        local vol_size
        vol_size=$(docker system df -v 2>/dev/null | grep "$volume" | awk '{print $3}' || echo "?")
        mb_detail "Chroma volume: ${volume} (${vol_size})"
    fi
}

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

rag_models_list() {
    mb_step "Supported embedding models"
    for model in "${SUPPORTED_EMBEDDING_MODELS[@]}"; do
        local status="not pulled"
        if _rag_ollama_running && docker exec "$OLLAMA_CONTAINER" ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$model"; then
            status="available"
        fi
        printf "  %-30s %s\n" "$model" "$status"
    done
    mb_detail "Pull a model: mb ai rag models pull <name>"
}

rag_models_pull() {
    local model="${1:-}"
    [[ -z "$model" ]] && mb_die "Usage: mb ai rag models pull <name>"
    _rag_ollama_running || mb_die "Ollama is not running."

    mb_step "Pulling embedding model: $model"
    docker exec "$OLLAMA_CONTAINER" ollama pull "$model"
    mb_success "Model pulled: $model"
    mb_detail "Set as default: export RAG_EMBEDDING_MODEL=${model}"
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

rag_main() {
    local sub="${1:-}"
    [[ $# -gt 0 ]] && shift || true

    case "$sub" in
        setup)               rag_setup "$@" ;;
        ingest)              rag_ingest "$@" ;;
        collections)
            local coll_sub="${1:-}"
            [[ $# -gt 0 ]] && shift || true
            case "$coll_sub" in
                list)   rag_collections_list "$@" ;;
                info)   rag_collections_info "$@" ;;
                delete) rag_collections_delete "$@" ;;
                *)      mb_die "Usage: mb ai rag collections <list|info|delete> [args]" ;;
            esac
            ;;
        query)    rag_query "$@" ;;
        backup)   rag_backup "$@" ;;
        restore)  rag_restore "$@" ;;
        status)   rag_status "$@" ;;
        models)
            local model_sub="${1:-}"
            [[ $# -gt 0 ]] && shift || true
            case "$model_sub" in
                list) rag_models_list "$@" ;;
                pull) rag_models_pull "$@" ;;
                *)    mb_die "Usage: mb ai rag models <list|pull> [args]" ;;
            esac
            ;;
        *) mb_die "Usage: mb ai rag <setup|ingest|collections|query|backup|restore|status|models>" ;;
    esac
}

rag_main "$@"
