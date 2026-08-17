# Ollama Model Catalog

A curated list of popular models available through Ollama for the AI Workstation.
Pull any of them with `mb ai model pull <model>`.

## Model comparison

| Model | Size | RAM/VRAM needed | Best for |
|-------|------|-----------------|----------|
| `qwen2.5:0.5b` | ~500MB | 1GB+ | Lightweight chat, testing, edge devices |
| `llama3.2:1b` | ~1.3GB | 2GB+ | Smallest Llama, basic conversations |
| `qwen2.5:1.5b` | ~1GB | 2GB+ | Fast and capable small model |
| `phi3:mini` | ~2.3GB | 4GB+ | Microsoft Phi-3, great quality per parameter |
| `llama3.2:3b` | ~2GB | 4GB+ | Balanced choice for CPU inference |
| `qwen2.5:3b` | ~2GB | 4GB+ | Strong reasoning in a small footprint |
| `gemma2:2b` | ~1.6GB | 4GB+ | Google Gemma 2, compact and efficient |
| `mistral:7b` | ~4.1GB | 8GB+ | Solid general-purpose 7B model |
| `qwen2.5:7b` | ~4.7GB | 8GB+ | Excellent multilingual, strong reasoning |
| `llama3.1:8b` | ~4.7GB | 8GB+ | Best all-around 8B, great CPU/GPU balance |
| `llama3.2:3b-instruct` | ~2GB | 4GB+ | Instruction-tuned Llama 3.2 |
| `qwen2.5:14b` | ~9GB | 12GB+ | Mid-size GPU, high quality |
| `llama3.1:13b` | ~7.4GB | 16GB+ | Llama 13B, more capable than 8B |
| `gemma2:9b` | ~5.4GB | 12GB+ | Google Gemma 2 9B, high quality |
| `codellama:7b` | ~3.8GB | 8GB+ | Code completion and generation |
| `codellama:13b` | ~7.4GB | 16GB+ | Larger code model, better reasoning |
| `deepseek-coder:6.7b` | ~4GB | 8GB+ | Strong code generation, multi-language |
| `deepseek-coder-v2:16b` | ~8.9GB | 16GB+ | Advanced code reasoning |
| `qwen2.5:32b` | ~20GB | 24GB+ | Large model, needs 24GB+ VRAM |
| `qwen2.5-coder:7b` | ~4.7GB | 8GB+ | Qwen coder, strong code + multilingual |
| `qwen2.5-coder:32b` | ~20GB | 24GB+ | Top-tier open code model |
| `llama3.1:70b` | ~40GB | 48GB+ (Q4) | Largest, near-frontier quality |
| `phi3:14b` | ~7.9GB | 16GB+ | Larger Phi-3 variant |

## Family overviews

### Llama 3.x
Meta's open-weight family. `llama3.1:8b` is the sweet spot for most VPS
deployments — excellent quality at a manageable size. `llama3.2` adds 1B/3B
variants ideal for CPU-only servers. The 70B model approaches frontier quality
but requires 48GB+ VRAM.

### Qwen 2.5
Alibaba's multilingual family. Outstanding non-English performance (Chinese,
Japanese, Korean, European languages). Available from 0.5B to 32B. The coder
variants (`qwen2.5-coder`) are among the best open code models available.

### Phi-3
Microsoft's small-model family. Punches well above its parameter count thanks
to training on high-quality synthetic data. `phi3:mini` (3.8B) is a great
choice for 4GB RAM servers that need better quality than the 1B models.

### Mistral
Mistral AI's 7B model. A reliable general-purpose model that predates the
Llama 3 / Qwen 2.5 generation but still performs well. Good fallback if you
want variety.

### Gemma 2
Google's open models. `gemma2:2b` is efficient for small servers; `gemma2:9b`
offers strong quality at a mid-range footprint.

### CodeLlama
Meta's code-specialized Llama derivatives. Good for completion, infilling,
and instruction-based code tasks. Use `deepseek-coder` or `qwen2.5-coder` for
better raw code quality.

### DeepSeek Coder
Specialized code models with strong multi-language support. `deepseek-coder-v2`
adds improved reasoning for complex programming tasks.

## Choosing a model

1. **Check your resources**: `mb ai gpu check` and `mb ai model recommend`
2. **Match size to RAM/VRAM**: model file size × 1.3 ≈ memory needed at runtime
3. **Start small**: pull a 1B–3B model first to verify the stack works
4. **Scale up**: once confirmed, pull the largest model your server supports

See `docs/model-selection.md` for a detailed guide on quantization and sizing.
