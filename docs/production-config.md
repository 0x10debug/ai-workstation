# Production Configuration

Hardening and tuning guide for running the AI Workstation (Ollama + Open
WebUI) in production on a VPS. This covers the production compose files
(`compose/ollama-production.yml`, `compose/open-webui.yml`), the preload
script (`scripts/preload-models.sh`), and the health-check library
(`lib/ollama-healthcheck.sh`).

For basic setup see [`deployment-guide.md`](deployment-guide.md) first; this
document assumes the stack is already running and focuses on production
concerns.

## TL;DR

```bash
# Deploy the hardened Ollama service (CPU)
mb ai ollama-prod deploy --cpu

# Or GPU
mb ai ollama-prod deploy --gpu

# Deploy Open WebUI
mb ai ollama-prod deploy --webui

# Preload default models
mb ai ollama-prod preload

# Full health check
mb ai ollama-prod health
```

## Ollama production parameters

The production compose file exposes four tunable environment variables. Set
them in `compose/.env` (not in the compose file) so the same image works
across environments.

| Variable | Default | What it controls |
|----------|---------|------------------|
| `OLLAMA_MAX_LOADED_MODELS` | `2` | Max models resident in memory at once. Lower on small hosts to avoid OOM. |
| `OLLAMA_NUM_PARALLEL` | `2` | Concurrent inference requests queued/served. Raise for throughput, at the cost of peak memory. |
| `OLLAMA_MAX_VRAM` | `0` | VRAM cap in bytes (`0` = use all). Set when sharing the GPU with other workloads. |
| `OLLAMA_KEEP_ALIVE` | `5m` | How long a model stays loaded after the last request. `5m`/`30m`/`2h`/`-1` (never unload)/`0` (immediate). |

### `OLLAMA_MAX_LOADED_MODELS`

Ollama keeps recently used models in memory so subsequent requests don't pay
the load cost. Each resident model consumes roughly its file size in RAM/VRAM.
On a 16 GB host running an 8B model (~4.7 GB), `2` is safe; on an 8 GB host
set it to `1` so a second model pull can't OOM the first.

### `OLLAMA_NUM_PARALLEL`

This is the number of requests Ollama will process at the same time. With
`OLLAMA_NUM_PARALLEL=1` requests serialize (lowest memory, highest latency
under load). With `2`–`4` throughput improves but each concurrent request
needs its own KV-cache allocation, so peak memory grows roughly linearly. For
a single-user workstation `1`–`2` is fine; for a team-shared API endpoint
start at `2` and watch memory.

### `OLLAMA_MAX_VRAM`

Bytes of VRAM Ollama may use. `0` means "use everything the driver reports".
Set an explicit cap when the GPU also drives a desktop, encoding workload, or
another container. Example: to cap at 20 GB on a 24 GB card:

```
OLLAMA_MAX_VRAM=21474836480
```

### `OLLAMA_KEEP_ALIVE`

Controls the unload delay after the last request. Trade-offs:

- **`5m` (default)** — good balance for interactive workloads; the model is
  still warm if you send another message a few minutes later.
- **`30m` / `2h`** — better for a busy shared API; worse for memory headroom.
- **`-1`** — never unload. Use only on a dedicated host with one model; the
  model occupies VRAM permanently until the container restarts.
- **`0`** — unload immediately after each response. Lowest memory, highest
  latency on the next request. Useful when memory is tight and requests are
  infrequent.

## GPU vs CPU deployment

The production stack uses a single pinned image (`ollama/ollama:0.3.14`) for
both modes. GPU access is gated behind the `gpu` compose profile so the same
file works on CPU-only hosts without requiring the NVIDIA Container Toolkit.

| Aspect | CPU (`--cpu`) | GPU (`--gpu`) |
|--------|---------------|---------------|
| Image | `ollama/ollama:0.3.14` | `ollama/ollama:0.3.14` |
| Device reservation | none | `nvidia`, `count: all`, `capabilities: [gpu]` |
| Prerequisite | Docker only | NVIDIA Container Toolkit + driver |
| Typical tokens/s (8B) | 5–15 | 40–80+ |
| Max practical model | ~13B (slow) | 70B (Q4) on 48 GB VRAM |
| Power / cost | higher per token | lower per token at scale |

Choose GPU when the VPS has an NVIDIA GPU and you need >15 tokens/s or models
larger than 13B. CPU is fine for light, interactive use of ≤8B models.

## Memory / VRAM planning

Runtime memory ≈ 1.3 × model file size (weights + KV cache + activation
buffers). Plan for the largest model you intend to load simultaneously:

| Model | File size | Runtime RAM/VRAM | Min host |
|-------|-----------|------------------|----------|
| `llama3.2:3b` | ~2 GB | ~2.6 GB | 4 GB |
| `qwen2.5:7b` | ~4.7 GB | ~6 GB | 8 GB |
| `llama3.1:8b` | ~4.7 GB | ~6 GB | 8 GB |
| `qwen2.5:14b` | ~9 GB | ~12 GB | 16 GB |
| `qwen2.5:32b` | ~20 GB | ~26 GB | 32 GB |
| `llama3.1:70b` (Q4) | ~40 GB | ~52 GB | 64 GB |

With `OLLAMA_MAX_LOADED_MODELS=2`, reserve **2 × the largest model's runtime
footprint** plus ~1 GB for the Ollama/Open WebUI overhead. If that exceeds
host RAM, lower `OLLAMA_MAX_LOADED_MODELS` to `1`.

Check actual usage at any time:

```bash
mb ai ollama-prod health      # includes VRAM + disk
```

## Concurrency tuning

1. **Single user, interactive** — `OLLAMA_NUM_PARALLEL=1`,
   `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_KEEP_ALIVE=5m`. Lowest memory,
   simplest reasoning about latency.
2. **Small team (2–5 people)** — `OLLAMA_NUM_PARALLEL=2`,
   `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KEEP_ALIVE=30m`. Keeps a hot model
   around and handles overlap without OOM on a 16 GB host.
3. **Shared API endpoint** — `OLLAMA_NUM_PARALLEL=4`,
   `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_KEEP_ALIVE=2h`. Requires 32 GB+ RAM
   or 24 GB+ VRAM. Monitor with `mb ai ollama-prod health` and the
   monitor-stack integration below.

Always load-test with realistic concurrent requests before trusting a
setting in production. OOM kills are silent and look like "container
restarted" in `docker ps`.

## Model keep-alive strategy

The right `OLLAMA_KEEP_ALIVE` depends on usage pattern, not just host size:

- **Bursty / unpredictable** (a user sends 5 messages, then nothing for an
  hour) — `5m`–`30m`. Long keep-alives waste memory during the idle gap.
- **Steady / shared** (team chat, API) — `2h` or `-1`. The model stays warm
  and per-request latency is dominated by inference, not loading.
- **Memory-constrained** — `0` or `1m`. Accept the load latency to keep
  headroom for the OS and Open WebUI.

## Reverse proxy integration

Both services bind to `127.0.0.1` only, so they are **not reachable from the
public internet directly**. Expose them through a reverse proxy from the
[network-toolkit](https://github.com/0x10debug/network-toolkit) (Caddy or
Traefik).

### Caddy (via mb-proxy)

Use `compose/Caddyfile.example` as the starting point. It terminates TLS,
applies security headers, and proxies to `open-webui:8080` over the shared
`mb-proxy` Docker network. Reload after editing:

```bash
caddy reload --config /etc/caddy/Caddyfile
```

### Traefik

Add labels to the Open WebUI service (in an overlay compose file or directly)
and let Traefik discover it via the `mb-proxy` network:

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.ai-webui.rule=Host(`ai.example.com`)
  - traefik.http.routers.ai-webui.tls.certresolver=letsencrypt
  - traefik.http.services.ai-webui.loadbalancer.server.port=8080
```

Keep the Ollama API (`:11434`) **behind** the reverse proxy and authenticate
it (see below) — never expose it unauthenticated, even on a trusted network.

## Authentication

Three layers, apply as many as your threat model requires:

1. **Open WebUI built-in auth** (`WEBUI_AUTH=true`, the default). The first
   registered user becomes admin. After provisioning, set
   `ENABLE_SIGNUP=false` in `compose/.env` and restart Open WebUI to lock
   out new sign-ups.
2. **Reverse-proxy auth** — basic auth, forward-auth (e.g. Authelia,
   oauth2-proxy), or mTLS at the Caddy/Traefik layer. This protects the
   entire site including the API path.
3. **API key for the OpenAI-compatible endpoint** — `mb ai api enable`
   generates a bearer token and wires the `/v1/` route in the Caddyfile.
   Required if you expose the API to other apps.

For a single-user homelab, layer 1 is enough. For anything internet-facing,
combine 1 + 2, and add 3 for programmatic access.

### mTLS (mutual TLS)

For the most restrictive setup, terminate mTLS at Caddy so only clients
presenting a trusted client certificate can connect:

```caddy
ai.example.com {
    tls /etc/caddy/cert.pem /etc/caddy/key.pem {
        client_auth {
            mode require_and_verify
            trusted_ca_cert_file /etc/caddy/ca.pem
        }
    }
    reverse_proxy open-webui:8080
}
```

Issue client certs from your own CA and distribute them to the machines that
need access.

## Monitoring integration (monitor-stack)

The Ollama health-check library (`lib/ollama-healthcheck.sh`) is designed to
be wrapped by a monitoring check. Recommended integration with the
0x10debug monitor-stack:

1. **Health probe** — cron a one-liner that calls `ollama_healthcheck` and
   posts the exit code to monitor-stack's push endpoint:

   ```bash
   */2 * * * *  /opt/ai-workstation/mb ai ollama-prod health >/dev/null 2>&1 \
     && curl -fsS -X POST monitor-stack:9090/health/ollama -d status=up \
     || curl -fsS -X POST monitor-stack:9090/health/ollama -d status=down
   ```

2. **Disk usage** — `ollama_check_disk` output can be parsed for the "Use%"
   column; alert when the models volume exceeds 80%.

3. **VRAM** — `ollama_check_vram` reports `memory.used`/`memory.total`; graph
   it to spot memory leaks or a model that won't unload.

4. **Container metrics** — the Docker provider in monitor-stack already
   scrapes `ollama` and `open-webui` containers via the `mb-proxy` network;
   no extra config needed beyond ensuring they're on that network (they are,
   by default).

## Backup strategy

Two volumes matter: the Ollama models and the Open WebUI data.

| Volume | Host path (legacy) / named volume (prod) | Contents | Backup frequency |
|--------|------------------------------------------|----------|------------------|
| Ollama models | `/data/ollama` or `ollama-models` | Model weights (large, mostly immutable) | Weekly + before model changes |
| Open WebUI data | `/data/open-webui` or `open-webui-data` | Users, chats, uploaded docs, RAG config | Daily |

### Models

Model weights are large and re-downloadable from Ollama's registry, so a
full backup is optional. What's worth backing up is the **list** of models
you keep installed — that's just `models/default-models.conf` plus any
per-host overrides. Restore = re-run `mb ai ollama-prod preload`.

If you want a real backup (e.g. air-gapped host, slow uplink), snapshot the
volume while the container is stopped:

```bash
docker compose -f compose/ollama-production.yml stop ollama
tar -C "$(docker volume inspect ollama-models -f '{{.Mountpoint}}')" \
    -czf /backup/ollama-models-$(date +%F).tgz .
docker compose -f compose/ollama-production.yml start ollama
```

### Open WebUI data

This is the irreplaceable part — chat history and user accounts. Back it up
daily. The data is a SQLite DB plus uploaded files; a cold copy while the
container is stopped is safest, or use `sqlite3 .backup` for a hot copy:

```bash
docker exec open-webui sqlite3 /app/backend/data/webui.db ".backup /data/webui.db.bak"
docker cp open-webui:/app/backend/data/webui.db.bak /backup/webui-$(date +%F).db
```

Uploads live under `/app/backend/data/uploads` — back that directory up too.

## Security best practices

1. **Bind to 127.0.0.1** — both production compose files bind their ports to
   the loopback interface. This is the single most important hardening step;
   it makes the services unreachable from the public internet regardless of
   firewall misconfiguration. All external access goes through the reverse
   proxy.
2. **Pinned image tags** — `ollama/ollama:0.3.14` and
   `ghcr.io/open-webui/open-webui:v0.4.8` are pinned. No floating `latest` or
   `main` tags in production. Bump tags deliberately after reviewing the
   upstream changelog.
3. **Network isolation** — both services live on the `mb-proxy` external
   network only. They have no port published to other networks, and Open
   WebUI talks to Ollama over the Docker network (`http://ollama:11434`),
   not via the host port.
4. **Reverse-proxy authentication** — see the Authentication section. Never
   expose Open WebUI or the Ollama API without auth.
5. **Log rotation** — both compose files set `json-file` with `max-size: 10m`
   and `max-file: 3` so logs can't fill the disk.
6. **Restart policy** — `unless-stopped` so the stack survives reboots but
   honors an explicit `docker compose stop`.
7. **Disable signup after provisioning** — set `ENABLE_SIGNUP=false` once
   your admin account exists.
8. **Keep the OS patched** — the container is only as secure as the host
   kernel. Apply Ubuntu/kernel updates on your normal cadence.
9. **Firewall** — even with loopback binding, run ufw/nftables to deny
   anything you don't explicitly allow. Defense in depth.
10. **Audit model provenance** — only pull models from the official Ollama
    registry or a trusted mirror. A malicious model file is an arbitrary
    code execution vector on the inference engine.

## Files reference

| File | Purpose |
|------|---------|
| `compose/ollama-production.yml` | Hardened Ollama service (pinned tag, loopback bind, healthcheck, log rotation, GPU profile) |
| `compose/open-webui.yml` | Hardened Open WebUI service (pinned tag, loopback bind, healthcheck, auth env) |
| `scripts/preload-models.sh` | Concurrent, idempotent model preloader with `--dry-run` |
| `models/default-models.conf` | Default model list consumed by the preloader |
| `lib/ollama-healthcheck.sh` | Reusable health/VRAM/disk/model-list functions |
| `docs/production-config.md` | This document |
