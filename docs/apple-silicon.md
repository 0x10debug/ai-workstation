# Apple Silicon Deployment Guide

How to run the AI Workstation on Apple Silicon (M1/M2/M3/M4) Macs, where
unified memory and the Metal framework change the rules compared to a
discrete-NVIDIA-GPU VPS.

## Why Apple Silicon for AI

Apple Silicon ships with **unified memory**: the CPU and GPU share a single
pool of high-bandwidth RAM. For LLM inference this has three practical
consequences:

1. **No VRAM wall.** On a discrete GPU you are limited by VRAM (8/16/24 GB).
   On Apple Silicon the GPU can address almost all of system memory, so a
   64 GB Mac can keep a ~40 GB model resident — something that would need a
   pair of 24 GB GPUs on the NVIDIA side.
2. **MLX framework.** Apple's open-source [MLX](https://github.com/ml-explore/mlx)
   library is built specifically for unified memory. It avoids copies between
   CPU and GPU buffers, which is the dominant cost on traditional
   discrete-GPU setups.
3. **Energy efficiency.** Apple Silicon draws 20–60 W under load versus
   250–450 W for a single data-center GPU. For always-on personal inference
   this matters a lot on the electricity bill and on fan noise.

## Apple Silicon vs NVIDIA GPU for LLM inference

| Dimension | Apple Silicon (M-series) | NVIDIA GPU (A100/H100/RTX) |
|---|---|---|
| Memory model | Unified (shared CPU+GPU) | Discrete VRAM + system RAM |
| Max model size | Up to ~80% of unified memory | Bounded by VRAM (or tensor parallel) |
| Memory bandwidth | 100–800 GB/s (M1→M4 Ultra) | 1,500–3,350 GB/s (H100) |
| Peak tokens/sec (8B Q4) | 30–80 tok/s | 80–200 tok/s |
| Peak tokens/sec (70B Q4) | 5–15 tok/s (M-Max/Ultra) | 15–40 tok/s (multi-GPU) |
| Frameworks | Metal, MLX, Ollama (Metal) | CUDA, vLLM, SGLang, Ollama |
| Power draw | 20–60 W | 250–450 W per GPU |
| Cost (entry) | ~$700 (Mac mini 16 GB) | ~$1,500 (GPU + host) |
| Best for | Personal/dev, large single models | Production throughput, batching |

The short version: **Apple Silicon wins on memory capacity per dollar and
energy efficiency; NVIDIA wins on raw bandwidth and throughput.** A Mac
Studio with 128 GB can run a 70B model that would need 3–4× 24 GB GPUs, but
each token will be slower than on a multi-GPU server.

## Ollama on Apple Silicon

Ollama has native Apple Silicon support and is the easiest path to a working
stack. It compiles to an arm64 binary and uses Apple's **Metal framework**
for GPU acceleration — no CUDA, no NVIDIA Container Toolkit needed.

### Metal detection

Ollama auto-detects the Metal-capable GPU at startup. Verify it is active:

```bash
# Run inside the Ollama container (or the native binary)
ollama ps          # shows the GPU label, e.g. "Apple M3 Max"
OLLAMA_DEBUG=1 ollama serve 2>&1 | grep -i metal
# expect: "Metal GPU ... detected" / "ggml_metal_init ..."
```

If Ollama falls back to CPU, see [Troubleshooting](#troubleshooting) below.

### Native vs Docker

On a Mac you have two options:

| Option | Pros | Cons |
|---|---|---|
| **Native binary** (`brew install ollama`) | Best Metal performance, no virtualization overhead, full unified memory | Separate from the Dockerized Open WebUI; connect over the host network |
| **Docker (arm64 image)** | Same compose workflow as the VPS guide | Docker Desktop on Mac runs in a VM; GPU/Metal access is limited and memory is capped by the VM allocation |

For maximum performance on Apple Silicon, run **Ollama natively** and point
Open WebUI (still in Docker) at `http://host.docker.internal:11434`. Use the
Docker path only when you want parity with the VPS deployment for testing.

## MLX framework integration

[MLX](https://github.com/ml-explore/mlx) is Apple's array library for ML on
Apple Silicon. It is the foundation for Apple's first-party LLM work
([mlx-lm](https://github.com/ml-explore/mlx-lm)) and is increasingly used by
other inference engines.

When to reach for MLX directly instead of Ollama:

- You want the **highest single-stream throughput** on Apple Silicon (MLX
  avoids the GGUF conversion overhead and uses native float16/int4).
- You need **fine-grained control** over quantization, KV cache, or LoRA
  adapters.
- You are doing **research/prototyping** and want PyTorch-like ergonomics.

Quick start with `mlx-lm`:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install mlx-lm

# Run a chat model (downloads an MLX-optimized checkpoint)
mlx_lm.generate \
    --model mlx-community/Mistral-7B-Instruct-v0.3-4bit \
    --prompt "Explain unified memory in one sentence."

# Serve an OpenAI-compatible API on http://127.0.0.1:8080
mlx_lm.server \
    --model mlx-community/Mistral-7B-Instruct-v0.3-4bit \
    --host 127.0.0.1 --port 8080
```

The `mlx-community` Hugging Face org publishes 4-bit and 8-bit MLX
checkpoints of most popular models. Open WebUI can point at the
`mlx_lm.server` endpoint just like it points at Ollama.

## Memory bandwidth considerations

Inference speed is **memory-bandwidth bound**: each generated token requires
reading the entire model weight file once. Unified memory bandwidth is the
single most important number on Apple Silicon.

| Chip | Unified memory bandwidth | Practical 8B Q4 tok/s |
|---|---|---|
| M1 | 68 GB/s | ~25 |
| M1 Pro / M2 | 200 GB/s | ~45 |
| M2 Pro / M3 | 150–250 GB/s | ~40 |
| M2 Max / M3 Max | 400 GB/s | ~70 |
| M2 Ultra / M3 Ultra | 800 GB/s | ~110 |
| M4 Max | 546 GB/s | ~90 |

Compare with H100 at ~3,350 GB/s — the GPU reads the same 4 GB 8B model ~6×
faster per token. Unified memory's advantage is **capacity**, not bandwidth.

## Model size recommendations by memory

Because the GPU can use most of unified memory, the sizing rule is simpler
than on a discrete GPU: **keep the model file under ~70% of total unified
memory**, leaving room for the OS, KV cache, and Open WebUI.

| Unified memory | Largest recommended model (Q4) | Example models |
|---|---|---|
| 8 GB | ~4 GB | `llama3.2:3b`, `qwen2.5:3b`, `phi3:mini` |
| 16 GB | ~9 GB | `llama3.1:8b`, `qwen2.5:7b`, `qwen2.5-coder:7b` |
| 32 GB | ~20 GB | `qwen2.5:14b`, `llama3.1:13b`, `command-r` |
| 64 GB | ~40 GB | `qwen2.5:32b`, `llama3.1:70b` (Q3, ~35 GB) |
| 128 GB | ~85 GB | `llama3.1:70b` (Q4), `qwen2.5:72b` (Q4), Mixtral 8×7B |

Use `mb ai model recommend` (or `ollama ps` after a pull) to check actual
runtime memory against your available headroom.

## Performance benchmarks and expectations

Indicative numbers on Apple Silicon with Ollama (Metal), single stream,
Q4_K_M quantization:

| Model | M2 Pro 16 GB | M3 Max 64 GB | M2 Ultra 128 GB |
|---|---|---|---|
| llama3.2:3b | ~50 tok/s | ~70 tok/s | ~110 tok/s |
| llama3.1:8b | ~30 tok/s | ~65 tok/s | ~95 tok/s |
| qwen2.5:14b | (too big) | ~35 tok/s | ~55 tok/s |
| qwen2.5:32b | (too big) | ~12 tok/s | ~25 tok/s |
| llama3.1:70b (Q4) | (too big) | (too big) | ~8 tok/s |

These are single-user, single-prompt figures. Concurrent requests share the
same bandwidth and will scale sub-linearly — Apple Silicon is not designed
for the high-throughput batching that vLLM/SGLang provide on NVIDIA GPUs.

## Docker on Apple Silicon

Docker Desktop on Mac runs Linux containers inside a lightweight VM. Two
things to know for the AI Workstation:

1. **Use arm64 images.** The `ollama/ollama` and
   `ghcr.io/open-webui/open-webui` images publish multi-arch manifests with
   arm64 builds, so `docker compose up` works out of the box on Apple
   Silicon. Docker will pull the arm64 variant automatically.
2. **Rosetta 2 caveat.** If an image is amd64-only, Docker Desktop can
   emulate it via Rosetta 2, but LLM inference under emulation is
   **extremely slow** (no Metal, no native NEON) and should be avoided.
   Always confirm the image is arm64-native:
   ```bash
   docker image inspect ollama/ollama:latest \
       --format '{{.Architecture}}'   # expect "arm64"
   ```

Docker Desktop also caps the VM's memory (default ~half of host RAM). For
large models, either raise the Docker Desktop memory limit, or run Ollama
natively (recommended) and only containerize Open WebUI.

## Open WebUI on Apple Silicon

Open WebUI runs unchanged on Apple Silicon via its arm64 image. The only
configuration difference is the Ollama base URL when Ollama runs natively:

```bash
# Ollama native, Open WebUI in Docker
docker run -d --name open-webui \
    -p 3000:8080 \
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
    -v open-webui-data:/app/backend/data \
    ghcr.io/open-webui/open-webui:main
```

`host.docker.internal` resolves to the Mac host from inside Docker Desktop's
VM, so the containerized Web UI can reach the natively-running Ollama.

If you run both in Docker, the standard `OLLAMA_BASE_URL=http://ollama:11434`
on the shared `mb-proxy` network applies unchanged — but remember the Docker
VM memory cap limits the model size Ollama can load.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Ollama reports CPU, not Metal | Running under Docker Desktop VM (no Metal passthrough) | Run Ollama natively (`brew install ollama`), or accept CPU mode in Docker |
| `ggml_metal_init: failed` | Metal framework unavailable / outdated macOS | Update to macOS 13.5+ (Ventura) or later; ensure Ollama is the arm64 binary |
| Inference much slower than benchmark | Rosetta 2 emulating an amd64 image | Re-pull the arm64 image; verify with `docker image inspect ... --format '{{.Architecture}}'` |
| High memory pressure / swap | Model + KV cache exceeds available unified memory | Drop to a smaller quantization (Q4→Q3) or a smaller model; close other apps |
| `host.docker.internal` not resolving | Old Docker Desktop or non-Desktop runtime | Add `--add-host=host.docker.internal:host-gateway` to the `docker run` |
| Open WebUI cannot reach Ollama | Ollama bound to `127.0.0.1` only | Start native Ollama with `OLLAMA_HOST=0.0.0.0:11434 ollama serve`, or use the Docker network alias |
| Kernel panic / GPU timeout on huge model | Single request exhausting unified memory | Use `OLLAMA_MAX_VRAM` to cap usage, or stream with a smaller context window |

## When to use Apple Silicon vs cloud GPU

| Situation | Recommendation |
|---|---|
| Personal/dev inference, <5 concurrent users | **Apple Silicon** — lower cost, lower power, large models fit in unified memory |
| Privacy-sensitive data that cannot leave the device | **Apple Silicon** — fully local, no network egress |
| Production API serving many concurrent requests | **Cloud GPU (NVIDIA) + vLLM/SGLang** — batching and throughput |
| Need the absolute fastest single-token latency | **Cloud GPU** — higher memory bandwidth |
| Want to run a 70B+ model cheaply | **Apple Silicon (64–128 GB)** — far cheaper than 3–4× 24 GB GPUs |
| Batch offline processing of large corpora | **Cloud GPU** — throughput-bound, batching matters |

A common hybrid: develop and test locally on a Mac, then deploy the same
Ollama models (or switch to vLLM/SGLang for throughput) on a GPU VPS for
production. See [vLLM & SGLang alternative engines](vllm-alternative.md)
for the production side.

## Related

- [Model Selection](model-selection.md) — sizing rules and quantization
- [Deployment Guide](deployment-guide.md) — VPS CPU/GPU setup
- [vLLM & SGLang](vllm-alternative.md) — alternative high-throughput engines
- [Production Config](production-config.md) — hardening for production VPS
