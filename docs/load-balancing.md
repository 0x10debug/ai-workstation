# Load Balancing & Multi-Instance Clustering

This document describes how to deploy multiple Ollama instances behind a load
balancer for higher throughput, fault tolerance, and horizontal scaling.

## Architecture

```
                    ┌─────────────┐
   Client/API ──→   │   HAProxy   │  :11434 (127.0.0.1)
                    │  (leastconn)│
                    └──────┬──────┘
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ Ollama-1 │ │ Ollama-2 │ │ Ollama-3 │
        │  :11434  │ │  :11434  │ │  :11434  │
        │  (active)│ │  (active)│ │ (backup) │
        └──────────┘ └──────────┘ └──────────┘
```

Each Ollama instance has its own model volume. The HAProxy load balancer
distributes requests using the `leastconn` strategy (fewest active connections).

## When to Use Clustering

| Scenario | Single Instance | Cluster |
|---|---|---|
| 1-5 concurrent users | ✅ Sufficient | Not needed |
| 5-20 concurrent users | ⚠️ May queue | ✅ Recommended |
| 20+ concurrent users | ❌ Will bottleneck | ✅ Required |
| High availability | ❌ Single point of failure | ✅ Failover |
| Multiple model types | ⚠️ Model swapping overhead | ✅ Dedicated models per instance |

## Deployment

### Via mb CLI (recommended)

```bash
# Deploy 2-instance CPU cluster
mb ai cluster deploy --cpu --size 2

# Deploy 3-instance GPU cluster
mb ai cluster deploy --gpu --size 3

# Check cluster status
mb ai cluster status

# Sync models across all instances
mb ai cluster sync-models

# Stop cluster
mb ai cluster stop
```

### Manual deployment

```bash
# Create the mb-proxy network if it doesn't exist
docker network create mb-proxy 2>/dev/null || true

# CPU, 3 instances
docker compose -f compose/ollama-cluster.yml --profile cpu \
    --env-file compose/.env up -d

# GPU, 2 instances (remove ollama-3 service first)
docker compose -f compose/ollama-cluster.yml --profile gpu \
    --env-file compose/.env up -d
```

## Load Balancing Strategy

The default strategy is **leastconn** — each new request goes to the instance
with the fewest active connections. This is optimal for LLM inference because:

1. **Inference time varies** — different prompts take different time to process
2. **No session state** — Ollama is stateless (model loading aside)
3. **Fair distribution** — prevents one instance from being overwhelmed

### Alternative strategies

| Strategy | When to use |
|---|---|
| `leastconn` (default) | General purpose, variable request times |
| `roundrobin` | Equal-capability instances, uniform request times |
| `source` | Sticky sessions (same client → same instance) |

To change the strategy, edit `compose/haproxy-cluster.cfg`:

```haproxy
backend ollama_instances
    balance roundrobin  # or source
```

## Health Checks

HAProxy checks each instance every 5 seconds via `GET /api/version`:
- **3 consecutive failures** → instance marked down
- **2 consecutive successes** → instance marked back up
- **All instances down** → returns 503 Service Unavailable

## HAProxy Stats

Access the HAProxy stats dashboard at `http://localhost:8404` (bound to
127.0.0.1, so only accessible locally or via SSH tunnel):

```bash
ssh -L 8404:localhost:8404 user@your-vps
# Then open http://localhost:8404 in your browser
```

The dashboard shows:
- Active connections per instance
- Up/down status
- Request rates
- Error counts

## Model Synchronization

Each Ollama instance has its own model volume. After pulling a model on one
instance, sync it to all others:

```bash
# Sync all models from instance 1 to instances 2 and 3
mb ai cluster sync-models

# Or manually:
docker exec ollama-1 ollama list  # See what's on instance 1
docker exec ollama-2 ollama pull llama3.1:8b  # Pull on instance 2
docker exec ollama-3 ollama pull llama3.1:8b  # Pull on instance 3
```

For production, consider:
- Using a shared NFS volume for models (all instances read from same storage)
- Pre-loading models during deployment via `mb ai ollama-prod preload`
- Setting `OLLAMA_KEEP_ALIVE=-1` to prevent model unloading

## Resource Planning

### CPU clusters

| Instances | Recommended RAM | Use case |
|---|---|---|
| 2 | 16GB+ | Small team (5-10 users) |
| 3 | 24GB+ | Medium team (10-20 users) |
| 4+ | 32GB+ | Large team (20+ users) |

Each instance runs one model at a time. With 8GB per instance, you can run
7B parameter models (Q4_K_M quantization ≈ 4.5GB).

### GPU clusters

| Instances | GPU per instance | Use case |
|---|---|---|
| 2 | 1 GPU each | High throughput, model parallelism |
| 3+ | 1 GPU each | Maximum throughput, high availability |

For multi-GPU single-model inference, use a single Ollama instance with
multiple GPUs (Ollama handles this automatically).

## Integration with LiteLLM

For a unified API gateway in front of the cluster, deploy LiteLLM:

```bash
# Deploy cluster first
mb ai cluster deploy --gpu --size 3

# Then deploy LiteLLM pointing to the HAProxy
mb ai litellm deploy
```

LiteLLM config should point to the HAProxy endpoint:

```yaml
# litellm-config.yaml
model_list:
  - model_name: ollama-cluster
    litellm_params:
      model: ollama/llama3.1
      api_base: http://ollama-haproxy:11434
```

## Troubleshooting

| Issue | Cause | Solution |
|---|---|---|
| 503 Service Unavailable | All instances down | Check `docker logs ollama-1`, verify healthcheck |
| Uneven load distribution | Different model sizes per instance | Sync models with `mb ai cluster sync-models` |
| High latency on first request | Model not loaded | Preload models or set `OLLAMA_KEEP_ALIVE=-1` |
| OOM on one instance | Model too large for allocated memory | Reduce `OLLAMA_CLUSTER_MEMORY_LIMIT` or use smaller model |
| HAProxy config error | Syntax error in cfg | Run `docker exec ollama-haproxy haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg` |

## Related

- [Ollama production deployment](production-config.md) — single-instance hardened setup
- [LiteLLM API gateway](litellm-config.md) — unified API with rate limiting and budgets
- [RAG setup](rag-setup.md) — retrieval-augmented generation
- [Model selection](model-selection.md) — choosing the right model for your hardware
