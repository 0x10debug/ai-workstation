# Remote Access Guide

How to expose your AI Workstation securely over the internet using a Caddy
reverse proxy with HTTPS and optional authentication.

## Architecture

```
Internet --HTTPS--> Caddy (mb-proxy) --+--> open-webui:8080  (chat UI)
                                       +--> ollama:11434     (API, optional)
```

Caddy terminates TLS (automatic Let's Encrypt certificates) and forwards
traffic to the containers on the `mb-proxy` Docker network. The direct host
ports (`3000`, `11434`) can be kept firewalled off so all traffic goes
through Caddy.

## Prerequisites

- A domain name (or subdomain) with an **A record** pointing at your VPS IP.
- Caddy running on the VPS. The easiest path is
  [mb-proxy](https://github.com/0x10debug/mb-proxy), which manages Caddy and
  the `mb-proxy` Docker network this repo expects.
- Ports `80` and `443` open on the VPS firewall.

## 1. Set your domain

```bash
cp compose/.env.example compose/.env
# Set the domain:
sed -i 's/^AI_DOMAIN=$/AI_DOMAIN=ai.example.com/' compose/.env
```

## 2. Install the Caddyfile

This repo ships `compose/Caddyfile.example`. Copy it into your Caddy config
location and reload:

```bash
# If using mb-proxy:
sudo cp compose/Caddyfile.example /etc/caddy/conf.d/ai-workstation.caddy
# Substitute the domain from .env:
sudo sed -i 's|{\$AI_DOMAIN}|ai.example.com|' /etc/caddy/conf.d/ai-workstation.caddy
sudo caddy reload --config /etc/caddy/Caddyfile
```

Visit `https://ai.example.com` — you should see the Open WebUI login page
with a valid Let's Encrypt certificate.

## 3. (Recommended) Add basic auth

Caddy can require a username/password before reaching Open WebUI. This adds
a layer of protection on top of Open WebUI's own accounts.

Generate a hash:

```bash
caddy hash-password
# enter a password, copy the printed hash
```

Edit the Caddyfile and uncomment the `basicauth` block:

```caddyfile
basicauth {
    admin <hashed-password>
}
```

Reload Caddy:

```bash
sudo caddy reload --config /etc/caddy/Caddyfile
```

## 4. (Optional) Lock down direct ports

Once Caddy is serving traffic, close the direct host ports so the stack is
only reachable via HTTPS:

```bash
sudo ufw deny 3000
sudo ufw deny 11434
# keep 80/443 open
```

> The containers still talk to each other over the `mb-proxy` Docker network,
> so internal communication is unaffected.

## 5. (Optional) Expose the OpenAI-compatible API

To use the Ollama API from external apps (Cursor, Continue, custom scripts),
enable the `/v1/` route:

```bash
./mb ai api enable
```

This uncomments the `/v1/` block in the Caddyfile and generates an
`API_KEY` in `compose/.env`. Reload Caddy, then test:

```bash
curl https://ai.example.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.1:8b","messages":[{"role":"user","content":"hi"}]}'
```

See `docs/api-usage.md` for full API usage.

## Security checklist

- [ ] Domain points at VPS; HTTPS works (valid padlock).
- [ ] Direct ports `3000`/`11434` are firewalled (if using Caddy).
- [ ] Open WebUI admin account has a strong password.
- [ ] (Optional) Caddy `basicauth` enabled.
- [ ] (Optional) API route protected with `API_KEY`.
- [ ] Only trusted users have Open WebUI accounts.

## Troubleshooting

### Certificate not issued

Caddy needs ports 80/443 reachable from the internet for the ACME HTTP-01
challenge. Check `sudo ufw status` and your cloud provider's security group.

### 502 Bad Gateway

The target container isn't running or isn't on `mb-proxy`. Verify:

```bash
docker network inspect mb-proxy | grep -A3 Containers
docker ps --filter name=open-webui
```

### Basic auth loop / can't log in

Re-check the hash was pasted exactly as printed by `caddy hash-password`,
including the `$` characters. Reload Caddy after editing.
