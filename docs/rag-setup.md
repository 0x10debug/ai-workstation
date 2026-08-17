# RAG Setup Guide

Retrieval-Augmented Generation (RAG) lets your AI answer questions based on
your own documents. The AI Workstation ships a RAG stack built on
**Chroma** (vector database) and **Open WebUI**'s built-in document tools,
using **Ollama** for embeddings.

## Architecture

```
User question
   |
Open WebUI  --embed query-->  nomic-embed-text (Ollama)
   |
   +--search vectors-->  Chroma  --return chunks-->  Open WebUI
   |
   +--prompt + chunks-->  chat model (Ollama)  --answer-->  User
```

## One-command setup

```bash
./mb ai rag setup
```

This script (`rag/rag-setup.sh`):

1. Deploys the **Chroma** vector database via `rag/rag-compose.yml`.
2. Pulls the **`nomic-embed-text`** embedding model into Ollama.
3. Restarts Open WebUI with RAG environment variables set:
   - `RAG_EMBEDDING_ENGINE=ollama`
   - `RAG_EMBEDDING_MODEL=nomic-embed-text`
   - `CHROMA_DB_URL=http://chroma:8000`
4. Tests the setup by uploading a sample document.

The script is **idempotent** — re-running it detects an already-configured
stack and skips redundant work.

## Prerequisites

- The AI Workstation is already deployed (`./mb ai deploy`).
- A chat model is pulled (e.g. `./mb ai model pull llama3.1:8b`).
- ~1 GB free disk for Chroma + the embedding model.

## Manual setup (advanced)

If you prefer to run the steps yourself:

```bash
# 1. Start Chroma + reconfigure Open WebUI
docker compose -f rag/rag-compose.yml --env-file compose/.env up -d

# 2. Pull the embedding model
docker exec ollama ollama pull nomic-embed-text

# 3. Verify Chroma
curl http://localhost:8000/api/v1/heartbeat
```

## Using RAG in Open WebUI

1. Sign in to Open WebUI as admin.
2. Go to **Workspace → Documents**.
3. Upload a document (PDF, TXT, Markdown, DOCX).
4. Start a new chat and toggle **RAG** on (or `#`-mention a document).
5. Ask a question about the document's content.

Open WebUI embeds the query with `nomic-embed-text`, retrieves the most
relevant chunks from Chroma, and sends them as context to the chat model.

## Tuning

Environment variables in `rag/rag-compose.yml` control behavior:

| Variable | Default | Purpose |
|----------|---------|---------|
| `RAG_EMBEDDING_ENGINE` | `ollama` | Use Ollama for embeddings |
| `RAG_EMBEDDING_MODEL` | `nomic-embed-text` | Embedding model tag |
| `CHROMA_DB_URL` | `http://chroma:8000` | Chroma endpoint |
| `RAG_DOCUMENT_MAX_CHARS` | `10000` | Max chars per chunk |
| `RAG_TOP_K` | `4` | Number of chunks retrieved |

After changing these, recreate the Open WebUI container:

```bash
docker compose -f rag/rag-compose.yml --env-file compose/.env up -d open-webui
```

## Using a different embedding model

Any Ollama embedding model works. Popular alternatives:

- `nomic-embed-text` (default, ~270 MB, 768 dims)
- `mxbai-embed-large` (~670 MB, 1024 dims, higher quality)
- `bge-m3` (~1.2 GB, multilingual)

```bash
docker exec ollama ollama pull mxbai-embed-large
# then set RAG_EMBEDDING_MODEL=mxbai-embed-large in rag/rag-compose.yml
```

> Note: changing the embedding model after documents are already indexed
> means you must re-upload them — existing vectors use the old dimensions.

## Troubleshooting

### Chroma not reachable

```bash
docker logs chroma
docker exec open-webui curl -s http://chroma:8000/api/v1/heartbeat
```

Both containers must be on `mb-proxy`. If not:

```bash
docker compose -f rag/rag-compose.yml --env-file compose/.env up -d
```

### RAG answers ignore documents

- Confirm the document is indexed in **Workspace → Documents**.
- Make sure RAG is toggled on in the chat (or `#`-mention the doc).
- Check that `RAG_EMBEDDING_ENGINE=ollama` is set (not `openai`).
- Verify the embedding model is pulled: `docker exec ollama ollama list`.

### Embedding model errors

The chat model and embedding model are different. `nomic-embed-text` is for
embeddings; `llama3.1:8b` is for chat. You need both pulled.
