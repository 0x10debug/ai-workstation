# Model Selection Guide

How to choose the right Ollama models for your VPS, with an explanation of
quantization and memory sizing.

## The basic rule: memory, not disk

The most important constraint is **RAM** (CPU mode) or **VRAM** (GPU mode).
A model must fit entirely in memory for fast inference. Disk size only
matters for storage.

As a rule of thumb, the **runtime memory** needed is roughly **1.2–1.4× the
model file size**, because Ollama loads the weights plus context/KV cache.

| Model file size | Approx. runtime memory |
|-----------------|------------------------|
| 1 GB            | ~1.3 GB                |
| 2 GB            | ~2.6 GB                |
| 5 GB            | ~6.5 GB                |
| 9 GB            | ~12 GB                 |
| 20 GB           | ~26 GB                 |

Always leave headroom for the OS and Open WebUI (~500 MB).

## CPU vs GPU

- **CPU**: inference speed scales with RAM bandwidth and core count. Models
  up to ~8B (Q4) are usable on a 16 GB VPS, but expect 2–10 tokens/sec.
- **GPU**: a single NVIDIA GPU with 8 GB VRAM can run an 8B model at
  30–60 tokens/sec. 24 GB VRAM unlocks 32B models at good speed.

## Quantization explained

Ollama ships models in **GGUF** format with **quantization** — compressing
the original 16-bit floats to 4-bit (Q4_K_M by default) or similar. This
shrinks the model ~4× with a small quality loss.

- **Q4_K_M** (default): best size/quality balance — what `ollama pull` gives you.
- **Q5 / Q8**: higher quality, larger files, more memory. Use when you have
  RAM to spare and want maximum quality.
- **F16**: uncompressed; rarely needed on a VPS.

You usually don't need to pick a quantization manually — the default tag
(e.g. `llama3.1:8b`) is already Q4_K_M. Specialized tags like `:8b-q8_0`
exist for experimentation.

## Choosing by VPS size

Run `./mb ai model recommend` to get automatic suggestions based on detected
hardware. The table below summarizes the tiers:

| Resources | Recommended | Why |
|-----------|-------------|-----|
| 2 GB RAM / CPU | `qwen2.5:0.5b`, `llama3.2:1b` | Only tiny models fit; good for testing |
| 4 GB RAM / CPU | `phi3:mini`, `qwen2.5:1.5b` | Small but surprisingly capable |
| 8 GB RAM / CPU | `llama3.2:3b`, `qwen2.5:3b` | Balanced CPU experience |
| 16 GB RAM / CPU | `llama3.1:8b`, `qwen2.5:7b` | Best CPU quality at usable speed |
| 8 GB VRAM / GPU | `llama3.1:8b`, `qwen2.5:7b` | Fast GPU inference, great quality |
| 16 GB VRAM / GPU | `qwen2.5:14b`, `llama3.1:13b` | Higher quality, still fast |
| 24 GB+ VRAM / GPU | `qwen2.5:32b`, `llama3.1:70b` (Q4, 48GB) | Near-frontier quality |

## Specialized models

| Use case | Model | Notes |
|----------|-------|-------|
| Coding | `qwen2.5-coder:7b`, `deepseek-coder:6.7b` | Strong code generation |
| Multilingual | `qwen2.5:7b` | Excellent non-English |
| Embeddings (RAG) | `nomic-embed-text` | Small, fast, used by RAG setup |
| Lightweight chat | `phi3:mini` | Great quality per parameter |

## Workflow

1. **Start small**: pull a 1B–3B model to verify the stack works end-to-end.
2. **Benchmark**: time a few prompts to measure tokens/sec on your hardware.
3. **Scale up**: pull the largest model your memory comfortably supports.
4. **Rotate**: remove models you no longer use with `mb ai model remove`.

```bash
./mb ai model pull qwen2.5:0.5b   # verify the stack
./mb ai model recommend           # see what fits
./mb ai model pull llama3.1:8b    # your real model
./mb ai model remove qwen2.5:0.5b # clean up
```

See `models/model-list.md` for the full catalog and `models/recommended.yaml`
for the structured recommendations the CLI uses.
