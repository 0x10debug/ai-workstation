# vLLM & SGLang — Alternative Inference Engines

Ollama is the default engine in this Workstation because it is simple,
cross-platform, and supports CPU mode. For **production high-throughput**
serving on NVIDIA GPUs, [vLLM](https://github.com/vllm-project/vllm) and
[SGLang](https://github.com/sgl-project/sglang) offer significantly higher
request concurrency and better GPU utilization. This guide covers when to
switch and how to deploy them with the same `mb` CLI workflow.

## Why consider alternatives to Ollama

Ollama is optimized for ease of use and single-user/local inference. It does
not implement advanced serving techniques that matter under load:

| Capability | Ollama | vLLM / SGLang |
|---|---|---|
| Continuous batching | Limited | Yes (core feature) |
| PagedAttention / KV-cache paging | No | Yes |
| Tensor parallelism (multi-GPU) | Automatic, basic | Explicit, tuned |
| Concurrent request throughput | Low–medium | High |
| GPU utilization under load | Moderate | Near-linear scaling |
| CPU mode | Yes | No (NVIDIA GPU required) |
| Ease of use / model management | Excellent | Good (more config) |

If your workload is **many concurrent requests** (a shared API, a product
feature, batch processing), vLLM or SGLang will deliver 3–10× the throughput
of Ollama on the same GPU. If your workload is **interactive single-user
chat**, Ollama is fine and simpler.

---

## vLLM

### What it is

vLLM is a high-throughput, memory-efficient inference engine for LLMs on
NVIDIA GPUs. Its two headline innovations:

- **PagedAttention** — manages the KV cache in fixed-size pages (like an OS
  virtual memory system), eliminating the fragmentation that wastes 60–80%
  of KV-cache memory in naive implementations. This lets vLLM serve far more
  concurrent sequences on the same VRAM.
- **Continuous batching** — new requests are inserted into the running batch
  at every iteration step, rather than waiting for the current batch to
  finish. This keeps the GPU saturated and slashes queue latency.

Additional features: tensor parallelism across multiple GPUs, quantization
(AWQ, GPTQ, FP8), and an **OpenAI-compatible API server** out of the box.

### When to use vLLM vs Ollama

| Use case | Recommended engine |
|---|---|
| Local dev / testing / CPU | Ollama |
| Interactive single-user chat | Ollama (simpler) or vLLM (faster) |
| Production API, 10+ concurrent users | **vLLM** |
| Need maximum VRAM efficiency | **vLLM** (PagedAttention) |
| Multi-GPU tensor parallelism | **vLLM** |
| CPU-only host | Ollama (vLLM has no CPU mode) |
| Apple Silicon | Ollama (vLLM requires NVIDIA GPU) |

### Installation

**pip** (for a host with CUDA and an NVIDIA driver):

```bash
pip install vllm
vllm serve <model-name> --port 8000
```

**Docker** (recommended — avoids driver/CUDA version matching headaches):

```bash
docker run --gpus all -p 127.0.0.1:8000:8000 \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    vllm/vllm-openai:0.6.0 \
    --model meta-llama/Meta-Llama-3.1-8B-Instruct
```

The `mb ai platform vllm deploy` wrapper uses the Docker compose template at
`compose/vllm.yml` and handles the network and env file for you.

### Docker compose template

See [`compose/vllm.yml`](../compose/vllm.yml). Highlights:

- Pinned image tag `vllm/vllm-openai:0.6.0` (no floating `latest`)
- API port bound to `127.0.0.1:8000` (loopback only — expose via reverse proxy)
- Healthcheck via `/health`
- Log rotation (10 MB × 3 files)
- Named volume for the Hugging Face model cache
- GPU reservation via the `nvidia` device driver
- All tunables exposed as environment variables

### Configuration

vLLM is configured through **command-line arguments** passed to the entrypoint
(and surfaced as environment variables in the compose template):

| Setting | Env var | Default | Notes |
|---|---|---|---|
| Model to load | `VLLM_MODEL` | `meta-llama/Meta-Llama-3.1-8B-Instruct` | Hugging Face model ID |
| GPU memory utilization | `VLLM_GPU_MEMORY_UTILIZATION` | `0.9` | Fraction of VRAM to use (0.0–1.0) |
| Max model length (context) | `VLLM_MAX_MODEL_LEN` | `8192` | Tokens; higher uses more KV cache |
| Tensor parallel size | `VLLM_TENSOR_PARALLEL_SIZE` | `1` | Number of GPUs to shard across |
| Max sequences in batch | `VLLM_MAX_NUM_SEQS` | `256` | Concurrent requests in flight |
| Quantization | `VLLM_QUANTIZATION` | (none) | `awq`, `gptq`, `fp8`, etc. |
| Served model name | `VLLM_SERVED_MODEL_NAME` | (same as model) | Name exposed in `/v1/models` |

Example override in `compose/.env`:

```bash
VLLM_MODEL=Qwen/Qwen2.5-14B-Instruct
VLLM_GPU_MEMORY_UTILIZATION=0.95
VLLM_MAX_MODEL_LEN=16384
VLLM_TENSOR_PARALLEL_SIZE=2   # 2-GPU tensor parallel
```

### API compatibility

vLLM ships an **OpenAI-compatible API**. Any client written for the OpenAI
Chat Completions API works unchanged:

```bash
curl http://127.0.0.1:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "meta-llama/Meta-Llama-3.1-8B-Instruct",
        "messages": [{"role":"user","content":"Hello"}]
    }'
```

This means **LiteLLM** can front vLLM exactly as it fronts Ollama — just
point `api_base` at `http://vllm:8000` and Open WebUI can use it as a model
backend. No client changes are needed.

### Performance tuning

- **Raise `VLLM_GPU_MEMORY_UTILIZATION`** toward 0.95 if the GPU is dedicated
  to vLLM; lower it to 0.7–0.8 when sharing the GPU with other containers.
- **Set `VLLM_MAX_MODEL_LEN`** to your real context need. Every unused token
  of KV cache still reserves page-table entries; oversized values waste VRAM
  and reduce max concurrency.
- **Use tensor parallelism** (`VLLM_TENSOR_PARALLEL_SIZE=N`) for models that
  do not fit on one GPU. All N GPUs must be identical.
- **Enable quantization** (`VLLM_QUANTIZATION=awq`/`fp8`) to fit larger models
  in less VRAM at a small quality cost.
- **Pre-download models** into the cache volume to avoid first-start delays:
  `huggingface-cli download <model-id>`.

### Limitations

- **No CPU mode.** vLLM requires an NVIDIA GPU with CUDA. There is no
  CPU-only fallback — use Ollama for CPU hosts.
- **No Apple Silicon / Metal support.** vLLM is CUDA-only.
- **Model format:** vLLM loads native Hugging Face safetensors (not GGUF).
  Quantized models must be in AWQ/GPTQ/FP8 format. You cannot point vLLM at
  an Ollama GGUF file directly.
- **Higher operational complexity** than Ollama: you manage the Hugging Face
  cache, choose quantization, and tune memory utilization.

---

## SGLang

### What it is

SGLang is a fast serving framework for LLMs with two distinguishing features:

- **RadixAttention** — caches the KV state of shared prompt prefixes in a
  radix tree, so repeated prefixes (system prompts, few-shot examples, RAG
  context) are computed once and reused across requests. This dramatically
  speeds up workloads with overlapping prompts.
- **Structured generation** — native support for JSON/regex-constrained
  output, so the model is guaranteed to emit valid JSON or match a schema.
  This is first-class in SGLang (via a backend argument), not a bolt-on.

It also features fast decoding, continuous batching, and tensor parallelism,
putting it in the same throughput class as vLLM.

### When to use SGLang

| Use case | Recommended engine |
|---|---|
| Structured output (JSON/schema-constrained) | **SGLang** (native, fastest) |
| Many requests sharing a long system prompt / RAG context | **SGLang** (RadixAttention reuses prefixes) |
| Complex multi-turn / agent prompting with repeated context | **SGLang** |
| General high-throughput serving | vLLM or SGLang (comparable) |
| Simplest setup / widest model compatibility | vLLM (slightly more mature ecosystem) |
| CPU / Apple Silicon | Ollama |

### Installation and Docker compose

**pip:**

```bash
pip install "sglang[all]"
python -m sglang.launch_server \
    --model-path meta-llama/Meta-Llama-3.1-8B-Instruct \
    --port 30000
```

**Docker** (via the `mb ai platform sglang deploy` wrapper and
`compose/sglang.yml`):

```bash
docker run --gpus all -p 127.0.0.1:30000:30000 \
    -v ~/.cache/huggingface:/root/.cache/huggingface \
    lmsysorg/sglang:latest \
    --model-path meta-llama/Meta-Llama-3.1-8B-Instruct
```

The compose template pins the image, binds the port to `127.0.0.1`, adds a
healthcheck, log rotation, a model-cache volume, and GPU reservations.

### Configuration and API

SGLang is configured via command-line flags (surfaced as env vars in the
compose template):

| Setting | Env var | Default | Notes |
|---|---|---|---|
| Model to load | `SGLANG_MODEL_PATH` | `meta-llama/Meta-Llama-3.1-8B-Instruct` | Hugging Face model ID |
| Host port | `SGLANG_PORT` | `30000` | Loopback-bound |
| Tensor parallel size | `SGLANG_TENSOR_PARALLEL_SIZE` | `1` | GPUs to shard across |
| Max running requests | `SGLANG_MAX_RUNNING_REQUESTS` | `256` | Concurrent requests |
| Context length | `SGLANG_CONTEXT_LENGTH` | `8192` | Max tokens |
| Quantization | `SGLANG_QUANTIZATION` | (none) | `fp8`, `awq`, etc. |

SGLang exposes an **OpenAI-compatible API** at `/v1/chat/completions`, so it
drops into the same LiteLLM/Open WebUI integration as vLLM and Ollama.

Structured generation example:

```bash
curl http://127.0.0.1:30000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "meta-llama/Meta-Llama-3.1-8B-Instruct",
        "messages": [{"role":"user","content":"List 3 fruits as JSON"}],
        "response_format": {"type": "json_schema",
            "json_schema": {"name":"fruits","schema":{
                "type":"object","properties":{"fruits":{"type":"array","items":{"type":"string"}}}
            }}}
    }'
```

### Performance comparison with vLLM and Ollama

Indicative throughput on a single A100 80 GB, 8B model, Q4/FP8, concurrent
requests with shared system prompt:

| Engine | Throughput (tok/s aggregate) | Latency (ms/tok, p50) | Notes |
|---|---|---|---|
| Ollama | ~1,500 | ~40 | No continuous batching; throughput plateaus |
| vLLM | ~6,000 | ~12 | PagedAttention saturates the GPU |
| SGLang | ~7,000 | ~10 | RadixAttention reuses the shared prefix |

Numbers vary with model, prompt overlap, and batch size. The key takeaways:

- **vLLM and SGLang both beat Ollama by 3–5×** under concurrent load.
- **SGLang pulls ahead of vLLM** when prompts share prefixes (RAG, agents,
  repeated system prompts) thanks to RadixAttention.
- For **single-stream** interactive use, the differences are small and
  Ollama's simplicity wins.

---

## Comparison table

| Feature | Ollama | vLLM | SGLang |
|---|---|---|---|
| Ease of use | Excellent | Good | Good |
| Continuous batching | Limited | Yes | Yes |
| PagedAttention | No | Yes | Yes (RadixAttention) |
| Prefix caching | No | Partial | Yes (RadixAttention, best-in-class) |
| Structured generation (JSON) | No | Partial | Yes (native) |
| Tensor parallelism | Basic (auto) | Yes (tuned) | Yes (tuned) |
| OpenAI-compatible API | Yes | Yes | Yes |
| CPU support | Yes | No | No |
| Apple Silicon / Metal | Yes | No | No |
| Model format | GGUF | HF safetensors / AWQ / GPTQ / FP8 | HF safetensors / AWQ / FP8 |
| GPU support | NVIDIA, AMD, Metal | NVIDIA only | NVIDIA only |
| Best for | Dev, local, CPU, Apple Silicon | Production throughput | Structured output, prefix-heavy workloads |
| Compose template | `compose/*.yml` | `compose/vllm.yml` | `compose/sglang.yml` |
| CLI command | `mb ai deploy` | `mb ai platform vllm deploy` | `mb ai platform sglang deploy` |

## Migration guide: Ollama to vLLM/SGLang

Switching engines is straightforward because all three expose an
OpenAI-compatible API. The main work is **model format**: Ollama uses GGUF,
while vLLM/SGLang use native Hugging Face safetensors (or AWQ/GPTQ/FP8).

1. **Identify the equivalent HF model.** Ollama's `llama3.1:8b` corresponds to
   `meta-llama/Meta-Llama-3.1-8B-Instruct` on Hugging Face. Check the model
   card for the exact repo ID.
2. **Handle gating.** Many HF models (Meta, Mistral) require accepting a
   license. Set `HF_TOKEN` in `compose/.env` so the engine can download them.
3. **Pre-download to the cache volume** to avoid a slow first start:
   ```bash
   huggingface-cli download meta-llama/Meta-Llama-3.1-8B-Instruct
   ```
4. **Deploy the new engine** alongside Ollama (different port):
   ```bash
   mb ai platform vllm deploy
   # or
   mb ai platform sglang deploy
   ```
5. **Point clients at the new endpoint.** Update LiteLLM's
   `litellm-config.yaml` `api_base` to `http://vllm:8000` or
   `http://sglang:30000`, or change Open WebUI's model backend URL.
6. **Verify**, then stop Ollama if no longer needed:
   ```bash
   mb ai platform vllm status
   docker stop ollama
   ```

Because the API is OpenAI-compatible, **no application code changes** are
required — only the base URL and model name differ.

## Hybrid setup: Ollama for dev, vLLM for production

A common and recommended pattern:

- **Local/Apple Silicon dev machine** → Ollama (CPU/Metal, GGUF models, easy
  `ollama pull`). Develop and test prompts, RAG pipelines, and agents.
- **Production GPU VPS** → vLLM or SGLang (NVIDIA GPU, continuous batching,
  high throughput). Same models in HF format, same OpenAI-compatible API.

LiteLLM makes this seamless: configure both an `ollama/*` model (pointing at
your local Ollama) and a `vllm/*` model (pointing at the production vLLM) in
`litellm-config.yaml`, then route by environment or by model name. Your
application talks only to LiteLLM and is unaware of the backend switch.

```bash
# Dev
mb ai deploy --cpu            # Ollama locally
mb ai litellm deploy          # LiteLLM in front

# Prod
mb ai ollama-prod deploy --gpu   # (optional) keep Ollama as fallback
mb ai platform vllm deploy       # vLLM for throughput
mb ai litellm deploy             # LiteLLM routes to vllm:8000
```

## Related

- [Apple Silicon Guide](apple-silicon.md) — running the stack on M-series Macs
- [LiteLLM Config](litellm-config.md) — unified API gateway in front of any engine
- [Model Selection](model-selection.md) — sizing and quantization
- [Load Balancing](load-balancing.md) — multi-instance Ollama clustering
- [Production Config](production-config.md) — hardening for production
