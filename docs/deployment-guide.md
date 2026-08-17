# Deployment Guide

Complete instructions for deploying the AI Workstation (Ollama + Open WebUI)
on a VPS, for both CPU-only and NVIDIA GPU servers.

## Prerequisites

- A VPS running **Ubuntu 22.04 / 24.04** (or any modern Linux)
- **Docker Engine** 24+ and **Docker Compose v2**
- At least **2 GB RAM** (CPU mode) — 8 GB+ recommended for usable models
- **20 GB+ disk** for the stack and a few small models
- (GPU mode) an **NVIDIA GPU** with the **NVIDIA Container Toolkit** installed
- (Optional) a domain name pointing at your VPS for HTTPS via Caddy

### Install Docker (if needed)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
# log out and back in for the group change to take effect
```

### Install NVIDIA Container Toolkit (GPU only)

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify the GPU is visible to Docker:

```bash
docker run --rm --gpus all nvidia/cuda:12.2.2-base-ubuntu22.04 nvidia-smi
```

## CPU deployment

### One command

```bash
./mb ai deploy --cpu
```

The CLI will:

1. Generate `compose/.env` from `compose/.env.example`
2. Ask for your domain (optional — used by the Caddy reverse proxy)
3. Create the `mb-proxy` Docker network if missing
4. Create `/data/ollama` and `/data/open-webui`
5. Pull images and start the containers

### Manual

```bash
cp compose/.env.example compose/.env
# edit compose/.env and set AI_DOMAIN if you have a domain
docker network create mb-proxy 2>/dev/null || true
sudo mkdir -p /data/ollama /data/open-webui
docker compose -f compose/compose.cpu.yml --env-file compose/.env up -d
```

## GPU deployment

### One command

```bash
./mb ai deploy --gpu
```

If `nvidia-smi` is present, the interactive `mb ai deploy` (no flag) will
auto-detect the GPU and offer the GPU version.

### Manual

```bash
cp compose/.env.example compose/.env
docker network create mb-proxy 2>/dev/null || true
sudo mkdir -p /data/ollama /data/open-webui
docker compose -f compose/compose.gpu.yml --env-file compose/.env up -d
```

The GPU compose file reserves all NVIDIA GPUs for the `ollama` container via
`deploy.resources.reservations.devices`. The `ollama/ollama:latest` image
auto-detects the GPU at runtime — no separate image tag is needed.

## Verifying the deployment

```bash
# Container status
docker ps --filter name=ollama --filter name=open-webui

# Ollama health
curl http://localhost:11434/api/tags

# Open WebUI
curl http://localhost:3000/health
```

Open `http://<your-vps-ip>:3000` in a browser and create the first admin
account (the first registered user becomes admin).

Pull your first model:

```bash
./mb ai model pull llama3.1:8b
```

## Updating

```bash
./mb ai update
```

This pulls the latest images and recreates the containers. Your data in
`/data/ollama` and `/data/open-webui` is preserved.

## Troubleshooting

### `docker compose` not found

You need Compose v2 (the `docker compose` subcommand, not the old
`docker-compose` standalone binary). Reinstall Docker via `get.docker.com`.

### Ollama container exits immediately

- **GPU mode, no toolkit**: install the NVIDIA Container Toolkit and run
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
- **Out of memory**: check `dmesg | grep -i oom`. Use a smaller model or add swap.

### Open WebUI can't reach Ollama

Both containers must be on the same `mb-proxy` network. Verify:

```bash
docker network inspect mb-proxy | grep -A2 Containers
```

If either is missing, recreate with `docker compose ... up -d`.

### Port already in use

Change `OLLAMA_PORT` or `OPEN_WEBUI_PORT` in `compose/.env` and redeploy.

### Models download slowly / fail

Ollama pulls from the public registry. On a slow link, pull a smaller model
first (`qwen2.5:0.5b`) to confirm connectivity, then pull the larger one.
Retries are safe — `ollama pull` resumes partial downloads.

### GPU not used even in GPU mode

Confirm the device reservation worked:

```bash
docker exec ollama nvidia-smi
```

If `nvidia-smi` is missing inside the container, the NVIDIA Container Toolkit
is not configured correctly. Re-run the toolkit install steps above.

### Caddy / HTTPS not working

This repo provides `compose/Caddyfile.example`. It expects an external Caddy
instance (e.g. from [mb-proxy](https://github.com/0x10debug/mb-proxy)) to
serve it. Copy the Caddyfile into your Caddy config and reload. See
`docs/remote-access.md` for the full walkthrough.
