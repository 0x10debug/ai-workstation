# LiteLLM API Gateway Configuration

LiteLLM is a unified LLM API gateway that exposes an OpenAI-compatible
interface in front of multiple backends. In this workstation it sits between
your clients (apps, scripts, Open WebUI) and Ollama, giving you a single
endpoint (`http://localhost:4000/v1/*`) with model routing, virtual API keys,
budget control, and load balancing.

This document covers the LiteLLM compose files
(`compose/litellm.yml`, `compose/litellm-proxy.yml`), the routing config
(`compose/litellm-config.yaml`), and the health-check library
(`lib/litellm-healthcheck.sh`).

For the underlying Ollama production setup see
[`production-config.md`](production-config.md) first; LiteLLM depends on a
running Ollama service on the `mb-proxy` network.

## TL;DR

```bash
# 1. Deploy Ollama first (LiteLLM needs it as a backend)
mb ai ollama-prod deploy --cpu   # or --gpu

# 2. Deploy LiteLLM
mb ai litellm deploy

# 3. Verify
mb ai litellm health
mb ai litellm config-check

# Or deploy the full stack (Ollama + LiteLLM + Open WebUI) together
mb ai litellm deploy --full --cpu
```

## What LiteLLM gives you

Without LiteLLM, every client talks to Ollama directly. That works, but you
lose:

- **Unified API shape** — Ollama's OpenAI compatibility is good but not
  identical to the real OpenAI API. LiteLLM normalizes request/response
  shapes so any OpenAI SDK works without surprises.
- **Model routing** — map friendly names (`gpt-4o`, `claude-3-5-sonnet`) to
  local Ollama models, or mix local + cloud backends behind one endpoint.
- **Virtual API keys** — issue per-team or per-app keys with independent
  budgets, model whitelists, and rate limits. The master key can do
  everything; virtual keys are scoped down.
- **Budget control** — cap spend per key, per day/week/month. For local
  Ollama models the "cost" is synthetic, but it still enforces request
  quotas. For cloud backends it tracks real USD spend.
- **Load balancing** — round-robin or latency-based routing across multiple
  Ollama instances when you scale out.
- **Logging & observability** — every request is logged with model, tokens,
  latency, and key. Feed this into the monitor-stack for dashboards.

## Deployment

### Prerequisites

1. Docker + Docker Compose v2.
2. The `mb-proxy` external Docker network (created by `mb ai deploy` or
   manually: `docker network create mb-proxy`).
3. A running Ollama service on `mb-proxy` (from
   `compose/ollama-production.yml`). LiteLLM routes to
   `http://ollama:11434`.
4. Models preloaded into Ollama (`mb ai ollama-prod preload`), matching the
   `model_list` in `compose/litellm-config.yaml`.

### Step 1: Generate keys

LiteLLM needs a master key and a salt key. Generate both before first deploy:

```bash
openssl rand -hex 32   # -> LITELLM_MASTER_KEY
openssl rand -hex 32   # -> LITELLM_SALT_KEY
```

Add them to `compose/.env`:

```
LITELLM_MASTER_KEY=sk-litellm-<your-generated-key>
LITELLM_SALT_KEY=sk-litellm-<your-generated-salt>
```

### Step 2: Deploy

```bash
# LiteLLM only (assumes Ollama is already running)
mb ai litellm deploy

# Or the full joint stack (Ollama + LiteLLM + Open WebUI)
mb ai litellm deploy --full --cpu
mb ai litellm deploy --full --gpu
```

### Step 3: Verify

```bash
mb ai litellm health          # /health/liveness probe
mb ai litellm config-check    # validate config.yaml + keys + budget
```

### Manual deploy (without the CLI)

```bash
docker compose -f compose/litellm.yml --env-file compose/.env up -d
```

## Configuration reference

LiteLLM reads its routing config from `compose/litellm-config.yaml`, which is
mounted read-only at `/app/config.yaml` inside the container. The file has
four top-level sections:

### `model_list`

Each entry maps a **model name** (what clients put in the `model:` field) to
a backend deployment. For Ollama backends:

```yaml
model_list:
  - model_name: llama3.2:3b          # what the client requests
    litellm_params:
      model: ollama/llama3.2:3b       # provider prefix + Ollama tag
      api_base: http://ollama:11434   # Ollama on the mb-proxy network
```

The `ollama/` prefix tells LiteLLM to use its Ollama adapter. The `api_base`
points at the Ollama container over the Docker network (not the host port).

For external providers, set the provider prefix and an API key from the
environment:

```yaml
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
```

`os.environ/NAME` reads the variable at startup; set the actual key in
`compose/.env` so it never lands in the config file.

### `router_settings`

Controls backend selection when a `model_name` has multiple deployments
(load balancing). Single-deployment models always use the one entry.

| Strategy | Behavior | When to use |
|----------|----------|-------------|
| `simple-shuffle` | Random pick among deployments | Default; good enough for round-robin across equal hosts |
| `least-busy` | Fewest in-flight requests | When hosts have different speeds or load varies |
| `latency-based-routing` | Lowest average response latency | When you want the fastest host to absorb most traffic |
| `usage-based-routing` | By cost/token budget | When mixing local (free) and cloud (paid) backends |

### `litellm_settings`

Global LiteLLM behavior:

| Setting | Default | What it does |
|---------|---------|--------------|
| `drop_params` | `true` | Silently drop OpenAI-only params Ollama doesn't understand, instead of erroring. Keeps client compatibility high. |
| `max_budget` | `0` | Global USD budget across all keys. `0` = no cap. Set per-key budgets in `virtual_keys`. |
| `budget_duration` | `monthly` | Reset window for budgets: `daily`, `weekly`, or `monthly`. |
| `telemetry` | `false` | Anonymous usage telemetry. Off by default for privacy. |

### `general_settings`

Key management and database:

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
```

- **`master_key`** — read from the `LITELLM_MASTER_KEY` env var. Can call any
  model and create virtual keys.
- **`database_url`** — optional Postgres URL for persistent key/budget/usage
  storage. When unset, LiteLLM uses in-memory state (keys are lost on
  restart). For production with many virtual keys, add a Postgres service.

## Model routing strategies

### Single backend (default)

One `model_list` entry per model name. All requests go to that Ollama
instance. This is what the shipped config does.

### Round-robin (multiple Ollama instances)

List the same `model_name` twice with different `api_base` values:

```yaml
model_list:
  - model_name: llama3.2:3b
    litellm_params:
      model: ollama/llama3.2:3b
      api_base: http://ollama-1:11434

  - model_name: llama3.2:3b
    litellm_params:
      model: ollama/llama3.2:3b
      api_base: http://ollama-2:11434

router_settings:
  routing_strategy: simple-shuffle
```

LiteLLM alternates between the two. Use this when you run Ollama on multiple
GPUs or hosts and want to spread load.

### Weighted

Add a `weight` to each deployment (higher = more traffic):

```yaml
  - model_name: llama3.2:3b
    litellm_params:
      model: ollama/llama3.2:3b
      api_base: http://ollama-fast:11434
      weight: 3

  - model_name: llama3.2:3b
    litellm_params:
      model: ollama/llama3.2:3b
      api_base: http://ollama-slow:11434
      weight: 1
```

### Latency-based

```yaml
router_settings:
  routing_strategy: latency-based-routing
```

LiteLLM tracks rolling average latency per deployment and prefers the
fastest. Good when one host has a better GPU but you want the slower host as
overflow.

## API key management

### Master key

Set via `LITELLM_MASTER_KEY` in `compose/.env`. The master key:

- Can call any model in `model_list`.
- Can create, list, and revoke virtual keys via `/key/generate`,
  `/key/list`, `/key/delete`.
- Should be treated like a root password — store it in a secrets manager,
  never in git.

### Virtual keys

Create a scoped key with a budget using the master key:

```bash
curl -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "team-chat",
    "max_budget": 10.0,
    "budget_duration": "monthly",
    "models": ["llama3.2:3b", "qwen2.5:7b"]
  }'
```

The response includes the generated `key` (starts with `sk-`). This key can
only call the listed models and is capped at the budget. Distribute it to
apps or team members.

Check remaining budget:

```bash
curl http://127.0.0.1:4000/key/info \
  -H "Authorization: Bearer <virtual-key>"
```

Revoke a key:

```bash
curl -X POST http://127.0.0.1:4000/key/delete \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{"keys": ["sk-team-..."]}'
```

### Pre-declared keys

You can also pre-declare virtual keys in `general_settings.virtual_keys`
inside `litellm-config.yaml`. This is useful for reproducible deployments,
but the key value is generated by LiteLLM on first start (you read it back
from the API or logs). For most setups, creating keys at runtime is simpler.

## Integration with Ollama

LiteLLM talks to Ollama over the `mb-proxy` Docker network at
`http://ollama:11434`. This is the same address Open WebUI uses when
deployed without LiteLLM — no Ollama-side changes are needed.

Requirements:

1. Ollama must be running on `mb-proxy` (from `ollama-production.yml`).
2. The models in `litellm-config.yaml`'s `model_list` must be pulled into
   Ollama (`mb ai ollama-prod preload` or `mb ai model pull <tag>`).
3. The `api_base` in each `model_list` entry must match the Ollama container
   network address (`http://ollama:11434` for the CPU variant, or the
   `ollama` alias for the GPU variant — both resolve on `mb-proxy`).

LiteLLM translates OpenAI-shaped `/v1/chat/completions` and `/v1/embeddings`
requests into Ollama's native format, so clients that expect a strict
OpenAI API work without adaptation.

## Integration with Open WebUI

In the joint deployment (`compose/litellm-proxy.yml`), Open WebUI's
`OLLAMA_BASE_URL` is set to `http://litellm:4000` instead of
`http://ollama:11434`. This routes all chat traffic through LiteLLM, so:

- Interactive chat sessions are subject to the same key/budget rules as API
  calls.
- LiteLLM logs every chat request with model, tokens, and latency.
- You can swap the backend model (e.g. route `llama3.2:3b` to a cloud model
  for heavy workloads) without touching Open WebUI's config.

If you prefer Open WebUI to talk directly to Ollama (bypassing LiteLLM for
interactive use), deploy them separately with `ollama-production.yml` +
`open-webui.yml` and only use LiteLLM for programmatic API access.

## Integration with external APIs

LiteLLM supports 100+ providers. To add a cloud backend, uncomment the
relevant block in `litellm-config.yaml` and set the API key in
`compose/.env`:

```
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GEMINI_API_KEY=...
```

Then add the model to `model_list`:

```yaml
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY
```

Clients request `model: gpt-4o` and LiteLLM routes to OpenAI. Mix local and
cloud models behind the same endpoint — useful for cost optimization (cheap
local model for drafts, cloud model for final polish).

## Load balancing (multiple Ollama instances)

When a single Ollama host can't keep up, run multiple Ollama containers (or
hosts) and let LiteLLM balance across them:

1. Deploy a second Ollama instance with a different container name (e.g.
   `ollama-2`) on the `mb-proxy` network.
2. Add a second `model_list` entry for each model pointing at
   `http://ollama-2:11434`.
3. Set `router_settings.routing_strategy` to `simple-shuffle`
   (round-robin), `least-busy`, or `latency-based-routing`.

LiteLLM handles failover automatically: if a deployment stops responding,
it retries on the next one (configurable via `num_retries` and
`retry_after` in `litellm_settings`).

## Monitoring & logging

### Health checks

```bash
mb ai litellm health          # liveness probe
mb ai litellm config-check    # config + keys + budget validation
```

The health-check library (`lib/litellm-healthcheck.sh`) provides:

- `litellm_healthcheck` — probes `/health/liveness`.
- `litellm_list_models` — lists configured models via `/v1/models`.
- `litellm_check_keys` — verifies the master key is set and not the default.
- `litellm_check_budget` — reports budget configuration.

### Request logs

LiteLLM logs every request to stdout (captured by Docker's json-file driver
with rotation). Each log line includes the model, virtual key, token counts,
latency, and status. Tail them with:

```bash
docker logs -f litellm
```

### Monitor-stack integration

The LiteLLM health check is designed to be wrapped by a monitoring cron,
same as the Ollama check:

```bash
*/2 * * * *  /opt/ai-workstation/mb ai litellm health >/dev/null 2>&1 \
  && curl -fsS -X POST monitor-stack:9090/health/litellm -d status=up \
  || curl -fsS -X POST monitor-stack:9090/health/litellm -d status=down
```

LiteLLM also exposes a `/health/readiness` endpoint and Prometheus metrics
at `/metrics` (enable in `litellm_settings` if you use Prometheus).

## Security best practices

1. **Bind to 127.0.0.1** — LiteLLM's port 4000 is bound to loopback only, so
   it is unreachable from the public internet. All external access goes
   through the reverse proxy.
2. **Generate real keys** — never deploy with the default
   `sk-litellm-master-change-me`. Generate with `openssl rand -hex 32` and
   store in `compose/.env` (gitignored).
3. **Reverse-proxy authentication** — put LiteLLM behind Caddy/Traefik with
   TLS and auth (basic auth, forward-auth, or mTLS). The master key alone is
   not enough if the endpoint is internet-facing; defense in depth.
4. **Use virtual keys, not the master key** — distribute scoped virtual keys
   to apps and users. Keep the master key for administration only.
5. **Pinned image tag** — `ghcr.io/berriai/litellm:v1.52.0` is pinned. Bump
   deliberately after reviewing the upstream changelog.
6. **Log rotation** — `json-file` with `max-size: 10m` and `max-file: 3`
   prevents log-driven disk exhaustion.
7. **Network isolation** — LiteLLM lives on `mb-proxy` only. It has no ports
   published to other networks.
8. **Rotate keys** — periodically revoke and reissue virtual keys. LiteLLM
   supports key expiry (`expires` field on `/key/generate`).
9. **Audit model provenance** — only route to models from the official
   Ollama registry or trusted cloud providers. A malicious model is an
   arbitrary code execution vector on the inference engine.
10. **Keep the OS patched** — the container is only as secure as the host
    kernel.

## Files reference

| File | Purpose |
|------|---------|
| `compose/litellm.yml` | LiteLLM gateway service (pinned tag, loopback bind, healthcheck, log rotation) |
| `compose/litellm-config.yaml` | LiteLLM routing config (model_list, router settings, key/budget settings) |
| `compose/litellm-proxy.yml` | Joint Ollama + LiteLLM + Open WebUI deployment (full stack) |
| `lib/litellm-healthcheck.sh` | Reusable health/model/key/budget check functions |
| `docs/litellm-config.md` | This document |
