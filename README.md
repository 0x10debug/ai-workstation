# Self-Hosted AI on VPS - Ollama + Open WebUI in One Command

Deploy your own private AI workstation on a VPS with **Ollama** and **Open WebUI** packaged in Docker. Run a self-hosted ChatGPT alternative on any CPU-only or NVIDIA GPU server, expose it through a Caddy reverse proxy with automatic HTTPS, and use the built-in OpenAI-compatible API from your own apps. Perfect for homelab, privacy, and full control over your models and data — no cloud bills, no rate limits, no vendor lock-in.

Part of the [0x10debug](https://github.com/0x10debug) VPS tool suite.

## Features

- **One-command deploy** — `./mb ai deploy` boots Ollama + Open WebUI
- **Production hardening** — pinned tags, loopback port binding, healthchecks, log rotation, GPU profile
- **CPU and GPU** — auto-detects NVIDIA GPUs; same image, auto-acceleration
- **Self-hosted ChatGPT** — Open WebUI gives a polished chat interface
- **OpenAI-compatible API** — drop-in base URL for Cursor, Continue, LangChain
- **LiteLLM gateway** — unified API proxy with model routing, virtual keys, and budget control
- **Reverse proxy ready** — Caddyfile with security headers + optional auth
- **RAG support** — Chroma vector DB + document Q&A in one command
- **Model management** — pull, list, remove, and get recommendations by VPS size
- **Zero cloud lock-in** — your models, your data, on `/data/`

## Quick Start

### CPU server

```bash
git clone https://github.com/0x10debug/ai-workstation.git
cd ai-workstation
./mb ai deploy --cpu
./mb ai model pull llama3.1:8b
```

Open `http://<vps-ip>:3000` and create the admin account.

### GPU server

```bash
git clone https://github.com/0x10debug/ai-workstation.git
cd ai-workstation
./mb ai deploy --gpu
./mb ai model pull qwen2.5:7b
```

> Requires the [NVIDIA Container Toolkit](docs/deployment-guide.md#install-nvidia-container-toolkit-gpu-only).

### Interactive (auto-detects GPU)

```bash
./mb ai deploy
```

## Usage

```bash
./mb ai deploy [--cpu|--gpu]   # deploy the stack
./mb ai status                  # containers, GPU usage, model count
./mb ai model list              # list installed models
./mb ai model pull <model>      # pull a model
./mb ai model remove <model>    # remove a model
./mb ai model recommend         # recommendations for your VPS
./mb ai api enable              # enable OpenAI-compatible API + key
./mb ai api disable             # disable the API
./mb ai gpu check               # check NVIDIA GPU availability
./mb ai update                  # pull latest images and recreate
./mb ai rag setup               # set up RAG (Chroma + Open WebUI)
./mb ai ollama-prod deploy --cpu   # deploy hardened Ollama (CPU)
./mb ai ollama-prod deploy --gpu   # deploy hardened Ollama (GPU)
./mb ai ollama-prod deploy --webui # deploy hardened Open WebUI
./mb ai ollama-prod preload        # preload default models (idempotent)
./mb ai ollama-prod preload --model llama3.2:3b --dry-run
./mb ai ollama-prod health         # API + models + VRAM + disk check
./mb ai litellm deploy             # deploy LiteLLM API gateway (needs Ollama)
./mb ai litellm deploy --full --gpu  # deploy Ollama + LiteLLM + Open WebUI
./mb ai litellm health             # liveness + models + keys + budget check
./mb ai litellm config-check       # validate config + env keys
./mb ai help                    # full help
```

### Production deployment

The `ollama-prod` command uses hardened compose files with pinned image tags,
loopback-only port binding, healthchecks, and log rotation. See
[`docs/production-config.md`](docs/production-config.md) for the full tuning,
backup, and security guide.

```bash
./mb ai ollama-prod deploy --gpu      # Ollama (pinned tag, 127.0.0.1 bind)
./mb ai ollama-prod deploy --webui    # Open WebUI (pinned tag, 127.0.0.1 bind)
./mb ai ollama-prod preload           # pulls llama3.2:3b, qwen2.5:7b, nomic-embed-text
./mb ai ollama-prod health            # verify the stack
```

### LiteLLM API gateway

LiteLLM adds a unified, OpenAI-compatible API gateway in front of Ollama.
It gives you model routing, virtual API keys with per-key budgets, load
balancing across multiple Ollama instances, and the ability to mix local
and cloud models (OpenAI, Anthropic, Gemini) behind one endpoint.

```bash
./mb ai litellm deploy               # deploy LiteLLM (needs running Ollama)
./mb ai litellm deploy --full --gpu  # deploy Ollama + LiteLLM + Open WebUI
./mb ai litellm health               # liveness + models + keys + budget
./mb ai litellm config-check         # validate config + env keys
```

Generate keys before first deploy:

```bash
openssl rand -hex 32   # -> LITELLM_MASTER_KEY in compose/.env
openssl rand -hex 32   # -> LITELLM_SALT_KEY in compose/.env
```

See [`docs/litellm-config.md`](docs/litellm-config.md) for routing
strategies, virtual key management, external provider integration, and
security best practices.

## Model Recommendations

Run `./mb ai model recommend` for automatic suggestions. Summary:

| VPS Profile | Recommended Models | Size |
|-------------|--------------------|------|
| 2 GB RAM / CPU | `qwen2.5:0.5b`, `llama3.2:1b` | ~0.5–1.3 GB |
| 4 GB RAM / CPU | `phi3:mini`, `qwen2.5:1.5b` | ~1–2.3 GB |
| 8 GB RAM / CPU | `llama3.2:3b`, `qwen2.5:3b` | ~2 GB |
| 16 GB RAM / CPU | `llama3.1:8b`, `qwen2.5:7b` | ~4.7 GB |
| 8 GB VRAM / GPU | `llama3.1:8b`, `qwen2.5:7b` | ~4.7 GB |
| 16 GB VRAM / GPU | `qwen2.5:14b`, `llama3.1:13b` | ~7–9 GB |
| 24 GB+ VRAM / GPU | `qwen2.5:32b`, `llama3.1:70b` | ~20–40 GB |

See [`models/model-list.md`](models/model-list.md) for the full catalog and
[`docs/model-selection.md`](docs/model-selection.md) for the sizing guide.

## FAQ

**Do I need a GPU?**
No. CPU-only works fine for models up to ~8B. A GPU makes inference
significantly faster and unlocks larger models, but it's optional.

**How much RAM do I need?**
2 GB minimum to run the stack with a tiny model. 8 GB for a usable 3B model,
16 GB for an 8B model. Runtime memory ≈ 1.3× the model file size.

**Is my data private?**
Yes. Everything runs on your VPS. Model weights, chat history, and uploaded
documents live in `/data/ollama` and `/data/open-webui` — nothing leaves
your server except the initial model download from Ollama's registry.

**Can I use this instead of the OpenAI API?**
Yes. Run `./mb ai api enable`, then point any OpenAI-compatible client at
`https://<your-domain>/v1` with the generated API key. See
[`docs/api-usage.md`](docs/api-usage.md).

**How do I get HTTPS?**
Use the included `compose/Caddyfile.example` with a Caddy instance (e.g.
[mb-proxy](https://github.com/0x10debug/mb-proxy)). Caddy issues Let's
Encrypt certificates automatically. See
[`docs/remote-access.md`](docs/remote-access.md).

**Can I do document Q&A (RAG)?**
Yes. `./mb ai rag setup` deploys Chroma and configures Open WebUI for
retrieval-augmented generation. See [`docs/rag-setup.md`](docs/rag-setup.md).

**What is LiteLLM for?**
LiteLLM is an API gateway that sits in front of Ollama and exposes a
strict OpenAI-compatible endpoint. It adds virtual API keys with per-key
budgets, model routing (mix local + cloud models), and load balancing
across multiple Ollama instances. Deploy it with `./mb ai litellm deploy`.
See [`docs/litellm-config.md`](docs/litellm-config.md).

## Documentation

- [Deployment Guide](docs/deployment-guide.md) — CPU & GPU setup, prerequisites, troubleshooting
- [Production Config](docs/production-config.md) — hardening, tuning, backup, security for production
- [LiteLLM Config](docs/litellm-config.md) — API gateway, model routing, virtual keys, budget control
- [Model Selection](docs/model-selection.md) — choosing models, quantization explained
- [Remote Access](docs/remote-access.md) — Caddy reverse proxy, HTTPS, basic auth
- [API Usage](docs/api-usage.md) — OpenAI-compatible API, curl & SDK examples
- [RAG Setup](docs/rag-setup.md) — document Q&A with Chroma

## Related repositories

- [0x10debug/vps-bootstrap](https://github.com/0x10debug/vps-bootstrap) — base VPS provisioning
- [0x10debug/network-toolkit](https://github.com/0x10debug/network-toolkit) — networking utilities
- [0x10debug/compose-recipes](https://github.com/0x10debug/compose-recipes) — Docker Compose collection

## License

[MIT](LICENSE) — Copyright (c) 2026 0x10debug
