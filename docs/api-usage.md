# API Usage Guide

The AI Workstation exposes an **OpenAI-compatible API** through Ollama, so
you can use it as a drop-in replacement for the OpenAI API in any app that
lets you configure a base URL.

## Enabling the API

By default the `/v1/` route in the Caddyfile is commented out. Enable it:

```bash
./mb ai api enable
```

This:

1. Uncomments the `/v1/` route in `compose/Caddyfile`.
2. Generates an `API_KEY` in `compose/.env` (if not already set).
3. Prints instructions to reload Caddy.

Reload Caddy to apply:

```bash
sudo caddy reload --config /etc/caddy/Caddyfile
```

Disable it later with `./mb ai api disable`.

> If you're not using Caddy, you can hit Ollama directly at
> `http://<vps-ip>:11434`. The examples below assume the Caddy-secured
> endpoint at `https://ai.example.com`.

## Authentication

All API requests must include the API key as a Bearer token:

```
Authorization: Bearer <API_KEY>
```

Read the key from `compose/.env`:

```bash
grep '^API_KEY=' compose/.env | cut -d= -f2
```

## Endpoints

Ollama's OpenAI-compatible layer mirrors the OpenAI REST API:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/chat/completions` | POST | Chat completions (main one) |
| `/v1/completions` | POST | Text completions |
| `/v1/embeddings` | POST | Embeddings |
| `/v1/models` | GET | List available models |

## Examples

### List models

```bash
curl https://ai.example.com/v1/models \
  -H "Authorization: Bearer $API_KEY"
```

### Chat completion

```bash
curl https://ai.example.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1:8b",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user", "content": "Explain quantization in one sentence."}
    ],
    "temperature": 0.7
  }'
```

### Streaming

Add `"stream": true` and read the Server-Sent Events stream:

```bash
curl -N https://ai.example.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5:7b",
    "messages": [{"role":"user","content":"Write a haiku about VPS."}],
    "stream": true
  }'
```

### Embeddings (for custom RAG)

```bash
curl https://ai.example.com/v1/embeddings \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nomic-embed-text",
    "input": "Self-hosted AI on a VPS."
  }'
```

### Python (openai SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://ai.example.com/v1",
    api_key="YOUR_API_KEY",
)

resp = client.chat.completions.create(
    model="llama3.1:8b",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

### Node.js (openai SDK)

```js
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "https://ai.example.com/v1",
  apiKey: process.env.AI_API_KEY,
});

const resp = await client.chat.completions.create({
  model: "qwen2.5:7b",
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(resp.choices[0].message.content);
```

## Integrating with apps

| App | Setting |
|-----|---------|
| **Cursor** | Settings → Models → OpenAI API Key + Override base URL → `https://ai.example.com/v1` |
| **Continue** (VS Code) | config.json: `"apiBase": "https://ai.example.com/v1"`, `"apiKey": "..."` |
| **LangChain** | `ChatOpenAI(base_url="https://ai.example.com/v1", api_key="...")` |
| **LobeChat** | Settings → LLM → OpenAI → API proxy: `https://ai.example.com/v1` |
| **AnythingLLM** | LLM provider → OpenAI → Base URL: `https://ai.example.com/v1` |

## Notes & limits

- **Models must be pulled first**: `./mb ai model pull <model>`. The API only
  serves models already present in Ollama.
- **Concurrency**: Ollama serializes requests per model by default. For
  higher concurrency, set `OLLAMA_NUM_PARALLEL` in the compose environment.
- **No billing**: it's your own server — no rate limits beyond your hardware.
- **API key**: keep `API_KEY` secret. Rotate it by editing `compose/.env`
  and reloading Caddy.
