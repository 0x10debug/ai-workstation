# Langfuse LLM Observability

Langfuse is an open-source LLM engineering platform — tracing, evaluation,
prompt management, and analytics for your LLM applications. In this
workstation it gives you visibility into every request that flows through
Ollama and LiteLLM: token usage, latency, cost, model comparison, and
per-trace inspection.

This document covers the Langfuse compose file
(`compose/langfuse.yml`), the CLI integration (`mb ai observability`), and
how to wire it into Ollama, LiteLLM, and Open WebUI.

For the underlying Ollama production setup see
[`production-config.md`](production-config.md); for the LiteLLM gateway see
[`litellm-config.md`](litellm-config.md).

## TL;DR

```bash
# 1. Deploy Ollama first (so traces have a backend to observe)
mb ai ollama-prod deploy --cpu   # or --gpu

# 2. Deploy Langfuse
mb ai observability deploy

# 3. Check it is healthy
mb ai observability status

# 4. Open the UI
open http://localhost:3001

# 5. Wire LiteLLM to send traces (see Integration section below)
#    Add LANGFUSE_* keys to compose/.env, then:
mb ai litellm deploy
```

## What Langfuse is and why LLM observability matters

When you run a self-hosted LLM stack you quickly hit questions that
traditional APM (Grafana, Prometheus) cannot answer well:

- **Which model is slowest?** Ollama serves many models; without per-request
  tracing you only see aggregate load, not which model or prompt shape is the
  bottleneck.
- **How many tokens did that conversation cost?** Token counts drive VRAM,
  context-window limits, and (for cloud backends) real money. Langfuse
  records prompt + completion tokens per request.
- **Why did the model produce a bad answer?** Langfuse stores the full
  prompt, completion, and metadata for every trace, so you can replay and
  debug a specific failure instead of guessing.
- **Are my prompts regressing?** Langfuse supports human + LLM-as-a-judge
  evaluation scores attached to traces, so you can compare prompt versions.
- **Who is spending the budget?** When LiteLLM issues virtual API keys,
  Langfuse attributes each trace to a user/session, giving you per-key
  cost and usage breakdowns.

Langfuse is the open-source equivalent of Datadog LLM Observability or
LangSmith — but self-hosted, so your prompts and completions never leave
your VPS.

## Architecture

```
                      ┌────────────────────────────────────────────┐
                      │              mb-proxy network               │
                      │                                            │
   clients ──────────►│  LiteLLM ──traces──► Langfuse ──► Postgres │
   (Open WebUI,       │     │                  │  (UI + API)        │
    scripts, apps)    │     ▼                  │                    │
                      │  Ollama                ▼                    │
                      │  (inference)        Redis (cache + jobs)    │
                      └────────────────────────────────────────────┘
                                   │
                          127.0.0.1 ports only
```

| Service        | Container        | Image                       | Port (loopback) | Role                              |
|----------------|------------------|-----------------------------|-----------------|-----------------------------------|
| Langfuse UI    | `langfuse`       | `langfuse/langfuse:2.0.0`   | 3001 → 3000     | Web UI + ingestion API            |
| PostgreSQL     | `langfuse-db`    | `postgres:16-alpine`        | 5432            | Traces, scores, users, prompts    |
| Redis          | `langfuse-redis` | `redis:7-alpine`            | 6379            | Caching + background-job queue    |

All three services join the shared `mb-proxy` Docker network, so LiteLLM
can post traces to `http://langfuse:3000` without crossing the host
network. Ollama is observed indirectly — Langfuse does not need to talk to
Ollama itself; it receives traces from the *caller* (LiteLLM or your app).

## Deployment

### Prerequisites

1. Docker + Docker Compose v2.
2. The `mb-proxy` Docker network exists (created by `mb ai deploy` or
   `mb ai ollama-prod deploy`; `mb ai observability deploy` creates it if
   missing).
3. Ollama is running (optional but recommended — without a backend there
   is nothing to observe).

### Deploy with the CLI

```bash
mb ai observability deploy
```

This runs `docker compose -f compose/langfuse.yml --env-file compose/.env
up -d`, creating the network if needed and pulling the pinned images.

### Deploy manually

```bash
docker compose -f compose/langfuse.yml --env-file compose/.env up -d
```

### Verify

```bash
mb ai observability status
# or
curl -fsS http://127.0.0.1:3001/api/public/health
```

The Langfuse UI is at `http://localhost:3001` (loopback only). On first
visit you create an admin account and an organization — see
[Configuration](#configuration) below.

## Configuration

### Environment variables

All Langfuse settings are read from `compose/.env`. Defaults are safe for
a local-only trial; **change every `*-change-me` value before exposing the
UI through a reverse proxy.**

| Variable                     | Default                     | Purpose                                              |
|------------------------------|-----------------------------|------------------------------------------------------|
| `LANGFUSE_PORT`              | `3001`                      | Host port for the Langfuse UI                        |
| `LANGFUSE_DB_PORT`           | `5432`                      | Host port for Postgres (loopback only)               |
| `LANGFUSE_REDIS_PORT`        | `6379`                      | Host port for Redis (loopback only)                  |
| `LANGFUSE_DB_USER`           | `langfuse`                  | Postgres user                                         |
| `LANGFUSE_DB_PASSWORD`       | `langfuse-change-me`        | Postgres password — **change this**                  |
| `LANGFUSE_DB_NAME`           | `langfuse`                  | Postgres database name                                |
| `LANGFUSE_NEXTAUTH_SECRET`   | `nextauth-secret-change-me` | JWT session-signing secret — **change this**         |
| `LANGFUSE_NEXTAUTH_URL`      | `http://localhost:3001`     | Public base URL of the UI (set to your domain)       |
| `LANGFUSE_SALT`              | `salt-change-me`            | Encryption salt for stored API keys — **change this**|
| `LANGFUSE_TELEMETRY_DISABLED`| `true`                      | Disable Langfuse telemetry (privacy)                 |
| `LANGFUSE_LOG_LEVEL`         | `info`                      | Log level: debug, info, warn, error                  |

Generate strong secrets with:

```bash
openssl rand -hex 32
```

### Auth setup (first run)

1. Open `http://localhost:3001` in your browser.
2. Create the admin account (email + password). This is stored in Postgres;
   there is no external auth provider required.
3. Create an organization and a project. The project is where traces land.
4. Inside the project, create **API keys** (public + secret). You will use
   these to configure LiteLLM and your applications.
5. After the admin account exists, set `ENABLE_SIGNUP=false` in
   `compose/.env` and redeploy to lock down new-user registration:

   ```bash
   # add to compose/.env
   LANGFUSE_DISABLE_SIGNUP=true
   mb ai observability deploy
   ```

### Reverse proxy (public access)

The UI is bound to `127.0.0.1:3001` only. To expose it publicly, put a
reverse proxy (Caddy/Traefik from `mb-proxy`) in front with authentication,
and set `LANGFUSE_NEXTAUTH_URL` to the public HTTPS URL so OAuth redirects
and email links resolve correctly.

## Integration

### Integration with LiteLLM (native)

LiteLLM has built-in Langfuse support — no SDK changes needed. Add the
following to `compose/.env` (values come from the Langfuse project's API
keys page):

```bash
# Langfuse tracing for LiteLLM
LANGFUSE_PUBLIC_KEY=pk-lf-xxxxxxxx
LANGFUSE_SECRET_KEY=sk-lf-xxxxxxxx
LANGFUSE_HOST=http://langfuse:3000
```

Then tell LiteLLM to use them by adding to `compose/litellm-config.yaml`
under `litellm_settings`:

```yaml
litellm_settings:
  callbacks: langfuse
```

Redeploy LiteLLM:

```bash
mb ai litellm deploy
```

Every request through LiteLLM now appears in Langfuse with model name,
tokens, latency, and the virtual key used. Because `LANGFUSE_HOST` points
at the internal service name `http://langfuse:3000`, traces never leave the
Docker network.

### Integration with Ollama (via OpenTelemetry / Langfuse SDK)

Ollama itself does not emit OpenTelemetry traces, so there are two options:

1. **Observe through LiteLLM (recommended).** Route Ollama traffic through
   LiteLLM and let LiteLLM send the traces (see above). This is the
   zero-code path and captures every Ollama call automatically.

2. **Instrument your application with the Langfuse SDK.** If you call
   Ollama directly (not through LiteLLM), wrap your calls with the
   Langfuse SDK in your language of choice:

   **Python (langfuse + ollama):**
   ```python
   from langfuse import Langfuse
   from langfuse.openai import openai  # drop-in OpenAI client that traces

   langfuse = Langfuse(
       public_key="pk-lf-xxxxxxxx",
       secret_key="sk-lf-xxxxxxxx",
       host="http://localhost:3001",
   )

   # Point the OpenAI-compatible client at Ollama
   client = openai.OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")

   resp = client.chat.completions.create(
       model="llama3.1:8b",
       messages=[{"role": "user", "content": "Hello"}],
   )
   # The langfuse.openai wrapper auto-captures the trace.
   ```

   **TypeScript:**
   ```typescript
   import { Langfuse } from "langfuse";
   import OpenAI from "openai";

   const langfuse = new Langfuse({
     publicKey: "pk-lf-xxxxxxxx",
     secretKey: "sk-lf-xxxxxxxx",
     baseUrl: "http://localhost:3001",
   });

   const trace = langfuse.trace({ name: "ollama-chat" });
   const generation = trace.generation({
     model: "llama3.1:8b",
     input: "Hello",
   });

   const client = new OpenAI({ baseURL: "http://localhost:11434/v1", apiKey: "ollama" });
   const resp = await client.chat.completions.create({
     model: "llama3.1:8b",
     messages: [{ role: "user", content: "Hello" }],
   });

   generation.end({ output: resp.choices[0].message.content });
   await langfuse.shutdownAsync();
   ```

   When running inside a container on the `mb-proxy` network, use
   `http://langfuse:3000` as the host instead of `localhost:3001`.

### Integration with Open WebUI

Open WebUI does not have native Langfuse tracing, but because it routes
through LiteLLM when deployed with `mb ai litellm deploy --full`, every
Open WebUI chat is automatically traced by the LiteLLM → Langfuse
integration above. No Open WebUI config changes are needed.

If you run Open WebUI against Ollama directly (not through LiteLLM), you
will not get traces unless you add a proxy layer. The simplest fix is to
point Open WebUI at LiteLLM instead:

1. Deploy LiteLLM with Langfuse callbacks (see above).
2. In Open WebUI admin settings, set the OpenAI API base URL to
   `http://litellm:4000/v1` and the API key to your LiteLLM virtual key.

## Key metrics to track

Langfuse organizes observability around **traces**. Each trace is one
end-to-end LLM call (or a nested span tree for multi-step pipelines).
Within a trace you get:

| Metric            | Where           | Why it matters                                          |
|-------------------|-----------------|---------------------------------------------------------|
| **Token usage**   | Per generation  | Drives VRAM, context limits, and cloud cost.            |
| **Latency**       | Per generation  | Time-to-first-token and total time. Spot slow models.   |
| **Cost**          | Per generation  | Synthetic for local Ollama; real USD for cloud backends.|
| **Model**         | Per generation  | Compare models side-by-side on the same prompts.        |
| **Error rate**    | Per trace       | Failed generations, timeouts, OOM.                      |
| **User / session**| Per trace       | Attribute usage to virtual keys or end users.           |
| **Scores**        | Per trace       | Human or LLM-as-a-judge evaluations for regression.     |

### Model comparison

The Langfuse dashboard lets you filter traces by model and compare
median latency, token distribution, and error rate across models. Use this
to decide whether `llama3.1:8b` is fast enough or whether you should keep
`qwen2.5:7b` loaded instead.

### Token usage over time

The usage chart aggregates prompt + completion tokens per day/week. Watch
for sudden spikes that indicate a runaway loop or a misconfigured
`OLLAMA_KEEP_ALIVE` keeping models resident too long.

## Dashboard setup and usage

1. **Traces view** — the default landing page. Lists recent traces with
   model, latency, tokens, and cost. Click any trace to see the full
   prompt, completion, and metadata.
2. **Sessions** — groups traces by session ID. Useful for following a
   single conversation or user across multiple turns.
3. **Dashboard** — aggregate charts: requests over time, token usage, cost,
   latency percentiles, error rate, top models, top users.
4. **Prompts** — versioned prompt templates. Define a prompt once, pin a
   version, and reference it from your app so prompt changes are tracked
   and rollbackable.
5. **Scores** — attach evaluation scores to traces (manual thumbs-up/down,
   or automated LLM-as-a-judge). Use scores to detect prompt regressions.
6. **API keys** — create per-project public/secret key pairs for your apps.

### Creating a custom dashboard

Langfuse v2 ships with a default dashboard. To add custom views, use the
**Analytics** tab to build queries (e.g. "error rate per model, last 7
days") and pin them to a dashboard.

## Alerting configuration

Langfuse v2 does not include a built-in alerting engine, but it exposes
all metrics through its API and the Postgres database. Two alerting
strategies:

1. **Prometheus + Grafana (recommended).** Export Langfuse metrics via a
   lightweight scraper that queries the Langfuse API or reads Postgres,
   then alert in Grafana. Alert on:
   - Error rate > 5% over 5 minutes.
   - p95 latency > 30s for any model.
   - Daily token usage > budget threshold.

2. **Langfuse webhooks (score-based).** Configure a webhook on score
   events so that a low LLM-as-a-judge score triggers a notification
   (Slack/Discord via `mb-notify`).

Example Grafana alert rule (PromQL, assuming a custom exporter):

```promql
# Error rate per model over 5 minutes
sum by (model) (rate(langfuse_requests_total{status="error"}[5m]))
  / sum by (model) (rate(langfuse_requests_total[5m]))
  > 0.05
```

## Backup and recovery

The Langfuse database (`langfuse-db`) holds all traces, scores, users, and
prompt definitions. Redis is ephemeral (cache + job queue) and does not
need backup.

### Backup with the CLI

```bash
# Backup to a compressed SQL file
mb ai observability backup ./langfuse-backup-$(date +%Y%m%d).sql.gz
```

This runs `pg_dump` inside the `langfuse-db` container and writes the
output to the path you specify on the host.

### Manual backup

```bash
docker exec langfuse-db pg_dump -U langfuse -d langfuse \
  | gzip > ./langfuse-backup.sql.gz
```

### Restore

```bash
# Stop Langfuse so no new writes conflict with the restore
mb ai observability stop

# Restore the database
gunzip -c ./langfuse-backup.sql.gz \
  | docker exec -i langfuse-db psql -U langfuse -d langfuse

# Bring the stack back up
mb ai observability deploy
```

### Scheduled backups

Add a cron job on the host to take nightly backups:

```cron
0 3 * * *  /usr/local/bin/mb ai observability backup /data/backups/langfuse-$(date +\%Y\%m\%d).sql.gz
```

Keep at least 7 days of backups and periodically verify a restore in a
throwaway container.

## Troubleshooting

### Langfuse container keeps restarting

Check the logs:

```bash
mb ai observability logs
# or
docker logs langfuse
```

Common causes:
- **`DATABASE_URL` is wrong.** Verify `LANGFUSE_DB_USER`,
  `LANGFUSE_DB_PASSWORD`, and `LANGFUSE_DB_NAME` in `compose/.env` match
  the Postgres service config.
- **Postgres not healthy yet.** Langfuse has `depends_on: service_healthy`
  so this should self-resolve, but on a cold start the first migration can
  take a while. Give it 60–90 seconds.
- **`NEXTAUTH_SECRET` or `SALT` is empty.** Langfuse refuses to start
  without them. Set both in `compose/.env`.

### Health check reports unhealthy

```bash
curl -fsS http://127.0.0.1:3001/api/public/health
```

If this returns 200 but `mb ai observability status` shows unhealthy, the
container's internal healthcheck may still be in its `start_period`. Wait
40 seconds and re-check.

### No traces appearing in the UI

1. Confirm LiteLLM is sending traces: check LiteLLM logs for Langfuse
   callback errors.
   ```bash
   docker logs litellm 2>&1 | grep -i langfuse
   ```
2. Confirm the API keys match. The `LANGFUSE_PUBLIC_KEY` /
   `LANGFUSE_SECRET_KEY` in `compose/.env` must come from the same
   Langfuse project you are viewing in the UI.
3. Confirm `LANGFUSE_HOST` is reachable from the LiteLLM container:
   ```bash
   docker exec litellm curl -fsS http://langfuse:3000/api/public/health
   ```

### Port 3001 is already in use

Change `LANGFUSE_PORT` in `compose/.env` to a free port and redeploy:

```bash
echo "LANGFUSE_PORT=3002" >> compose/.env
mb ai observability deploy
```

### Postgres port 5432 conflicts with an existing database

Set `LANGFUSE_DB_PORT` to a different host port (the internal container
port stays 5432; only the host binding moves):

```bash
echo "LANGFUSE_DB_PORT=5433" >> compose/.env
mb ai observability deploy
```

### Resetting to a clean state

To wipe all traces and start fresh (destructive — back up first):

```bash
mb ai observability stop
docker volume rm ai-workstation_langfuse-postgres ai-workstation_langfuse-redis
mb ai observability deploy
```

You will need to recreate the admin account and API keys.

## See also

- [`production-config.md`](production-config.md) — hardened Ollama setup
- [`litellm-config.md`](litellm-config.md) — LiteLLM gateway (sends traces)
- [`api-usage.md`](api-usage.md) — using the OpenAI-compatible API
- [`load-balancing.md`](load-balancing.md) — multi-instance Ollama

Part of the 0x10debug VPS tool suite.
