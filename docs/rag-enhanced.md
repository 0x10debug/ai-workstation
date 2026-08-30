# RAG Knowledge Base Enhancement

This document describes the enhanced RAG (Retrieval-Augmented Generation)
system with Chroma vector database, document ingestion, collection management,
and backup/restore capabilities.

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Documents  │────→│   Ollama     │────→│    Chroma     │
│  (txt, md,  │     │  (embeddings)│     │  (vector DB)  │
│   pdf, ...) │     │              │     │               │
└─────────────┘     └──────────────┘     └───────┬───────┘
                                                 │
                    ┌──────────────┐             │
                    │  Open WebUI  │←────────────┘
                    │  (chat + RAG)│
                    └──────────────┘
```

1. Documents are ingested and split into chunks
2. Each chunk is embedded using an Ollama embedding model
3. Embeddings are stored in Chroma vector database
4. When a user asks a question, the query is embedded and matched against
   the vector database to find relevant chunks
5. Relevant chunks are added to the LLM prompt as context

## Quick Start

```bash
# 1. Set up RAG infrastructure (Chroma + embedding model)
mb ai rag setup

# 2. Ingest documents
mb ai rag ingest ./my-documents

# 3. Query the knowledge base
mb ai rag query knowledge_base "what is this project about?"

# 4. Check status
mb ai rag status
```

## Commands

### Setup

```bash
mb ai rag setup
```

Deploys Chroma vector database, pulls the embedding model (`nomic-embed-text`
by default), configures Open WebUI RAG settings, and creates a default
`knowledge_base` collection.

### Ingest Documents

```bash
# Ingest all supported files from a directory
mb ai rag ingest /path/to/documents

# Ingest into a specific collection
mb ai rag ingest /path/to/documents my_collection
```

Supported file formats:
- **Text**: `.txt`, `.md`, `.markdown`, `.rst`, `.org`
- **Web**: `.html`, `.htm`
- **Data**: `.csv`, `.json`, `.yaml`, `.yml`
- **Binary** (requires Open WebUI upload): `.pdf`, `.docx`, `.doc`

The ingestion process:
1. Reads each file
2. Generates an embedding vector via Ollama
3. Stores the document + embedding + metadata in Chroma

### Collections Management

```bash
# List all collections
mb ai rag collections list

# Show details of a specific collection
mb ai rag collections info knowledge_base

# Delete a collection (with confirmation)
mb ai rag collections delete old_collection
```

### Query

```bash
# Query a collection for similar documents
mb ai rag query knowledge_base "how to configure TLS?"

# Results show top-K matching documents with distance scores
```

The `RAG_TOP_K` environment variable controls how many results to return
(default: 4).

### Backup & Restore

```bash
# Backup Chroma database
mb ai rag backup ./chroma-backup-$(date +%Y%m%d).tar.gz

# Restore from backup (replaces all existing data)
mb ai rag restore ./chroma-backup-20260823.tar.gz
```

Backup creates a tar.gz of the entire Chroma data volume. Restore stops
Chroma, replaces the data, and restarts.

### Status

```bash
mb ai rag status
```

Shows the status of all RAG components:
- Chroma (running/stopped, URL, collection count)
- Ollama (running/stopped, embedding model availability)
- Open WebUI (running/stopped, URL)
- Chroma disk usage

### Embedding Models

```bash
# List supported embedding models
mb ai rag models list

# Pull a specific model
mb ai rag models pull mxbai-embed-large
```

Supported embedding models:

| Model | Size | Dimensions | Best for |
|---|---|---|---|
| `nomic-embed-text` | ~270MB | 768 | General purpose, English |
| `mxbai-embed-large` | ~670MB | 1024 | High accuracy, multilingual |
| `snowflake-arctic-embed` | ~670MB | 1024 | Enterprise, long documents |
| `all-minilm` | ~120MB | 384 | Fast, lightweight, English |
| `bge-m3` | ~1.2GB | 1024 | Multilingual, long context |

To change the default embedding model:
```bash
export RAG_EMBEDDING_MODEL=mxbai-embed-large
mb ai rag setup  # Re-run setup with new model
```

**Note**: Changing the embedding model after ingesting documents requires
re-ingesting all documents, as embeddings from different models are not
compatible.

## Configuration

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `RAG_EMBEDDING_MODEL` | `nomic-embed-text` | Ollama embedding model |
| `RAG_TOP_K` | `4` | Number of results to return per query |
| `CHROMA_PORT` | `8000` | Chroma API port |
| `CHROMA_URL` | `http://localhost:8000` | Chroma API URL |
| `OPEN_WEBUI_URL` | `http://localhost:3000` | Open WebUI URL |
| `CHROMA_AUTH_TOKEN` | (empty) | Chroma authentication token |
| `CHROMA_AUTH_METHOD` | (empty) | Chroma auth method |

### Chroma Authentication

For production deployments, enable Chroma authentication:

```bash
# In compose/.env
CHROMA_AUTH_TOKEN=your-secret-token
CHROMA_AUTH_METHOD=token
CHROMA_AUTH_PROVIDER=chromadb.auth.token_authn.TokenAuthenticationServerProvider

# Restart Chroma
docker compose -f rag/rag-compose.yml --env-file compose/.env restart chroma
```

## Integration with Open WebUI

Open WebUI reads RAG settings from environment variables. The key settings
are configured in the Open WebUI container environment:

| Setting | Value | Description |
|---|---|---|
| `RAG_EMBEDDING_ENGINE` | `ollama` | Use Ollama for embeddings |
| `RAG_EMBEDDING_MODEL` | `nomic-embed-text` | Embedding model name |
| `CHROMA_DB_URL` | `http://chroma:8000` | Chroma URL (Docker network) |
| `RAG_DOCUMENT_MAX_CHARS` | `10000` | Max chars per document chunk |
| `RAG_TOP_K` | `4` | Top-K results per query |

After changing these settings, restart Open WebUI:
```bash
docker compose -f compose/ollama-production.yml restart open-webui
```

## Best Practices

### Document Preparation

- **Clean text**: Remove boilerplate, navigation, and irrelevant content
- **Chunk size**: Aim for 500-1000 characters per chunk for optimal retrieval
- **Metadata**: Include source, date, and category in document metadata
- **Deduplication**: Avoid ingesting duplicate content

### Collection Design

- **One collection per knowledge domain**: e.g., `api-docs`, `faq`, `runbooks`
- **Don't mix languages in one collection**: Use language-specific embedding models
- **Version collections**: When documents change significantly, create a new
  collection and delete the old one after verification

### Performance

- **Embedding model size**: Smaller models (all-minilm) are faster but less accurate
- **Batch ingestion**: Ingest documents in batches to avoid overwhelming Ollama
- **Chroma memory**: Monitor Chroma memory usage; large collections may need
  more RAM
- **Regular backups**: Schedule backups with cron:
  ```bash
  # Daily backup at 3 AM
  0 3 * * * /path/to/mb ai rag backup /backups/chroma-$(date +\%Y\%m\%d).tar.gz
  ```

## Troubleshooting

| Issue | Cause | Solution |
|---|---|---|
| "Chroma is not running" | Chroma container stopped | `mb ai rag setup` or `docker start chroma` |
| "Embedding model not pulled" | Model not in Ollama | `mb ai rag models pull nomic-embed-text` |
| Ingestion fails for PDFs | Binary format not supported in CLI | Upload PDFs via Open WebUI web interface |
| Query returns no results | Empty collection or wrong model | Check `mb ai rag collections info <name>` |
| Distance scores are high | Poor embedding match | Try a different embedding model or improve document quality |
| Chroma OOM | Collection too large for RAM | Increase container memory limit or use smaller model |

## Related

- [Load balancing](load-balancing.md) — multi-instance Ollama for higher throughput
- [LiteLLM config](litellm-config.md) — API gateway with rate limiting
- [Model selection](model-selection.md) — choosing the right LLM for your hardware
