# VPS 自托管 AI — 一条命令部署 Ollama + Open WebUI

在你的 VPS 上部署私有 AI 工作站，使用 **Ollama** 和 **Open WebUI**，全部打包在 Docker 中。在纯 CPU 或 NVIDIA GPU 服务器上运行自托管的 ChatGPT 替代方案，通过 Caddy 反向代理暴露并自动获取 HTTPS 证书，使用内置的 OpenAI 兼容 API 接入你自己的应用。非常适合 homelab、隐私需求和完全掌控自己的模型与数据——没有云账单、没有速率限制、没有厂商锁定。

属于 [0x10debug](https://github.com/0x10debug) VPS 工具套件的一部分。

## 特性

- **一条命令部署** —— `./mb ai deploy` 启动 Ollama + Open WebUI
- **生产级加固** —— 固定镜像 tag、端口仅绑定 127.0.0.1、健康检查、日志轮转、GPU profile
- **CPU 与 GPU** —— 自动检测 NVIDIA GPU；同一镜像，自动加速
- **自托管 ChatGPT** —— Open WebUI 提供精致的聊天界面
- **OpenAI 兼容 API** —— 可直接作为 Cursor、Continue、LangChain 的 base URL
- **反向代理就绪** —— Caddyfile 自带安全头 + 可选认证
- **RAG 支持** —— Chroma 向量数据库 + 文档问答，一条命令搞定
- **模型管理** —— 拉取、列出、删除模型，并按 VPS 配置给出推荐
- **零云锁定** —— 你的模型、你的数据，全部存放在 `/data/`

## 快速开始

### CPU 服务器

```bash
git clone https://github.com/0x10debug/ai-workstation.git
cd ai-workstation
./mb ai deploy --cpu
./mb ai model pull llama3.1:8b
```

浏览器打开 `http://<vps-ip>:3000`，创建管理员账号。

### GPU 服务器

```bash
git clone https://github.com/0x10debug/ai-workstation.git
cd ai-workstation
./mb ai deploy --gpu
./mb ai model pull qwen2.5:7b
```

> 需要先安装 [NVIDIA Container Toolkit](docs/deployment-guide.md#install-nvidia-container-toolkit-gpu-only)。

### 交互式（自动检测 GPU）

```bash
./mb ai deploy
```

## 用法

```bash
./mb ai deploy [--cpu|--gpu]   # 部署整套服务
./mb ai status                  # 容器状态、GPU 使用、模型数量
./mb ai model list              # 列出已安装模型
./mb ai model pull <model>      # 拉取模型
./mb ai model remove <model>    # 删除模型
./mb ai model recommend         # 按 VPS 配置推荐模型
./mb ai api enable              # 启用 OpenAI 兼容 API + 密钥
./mb ai api disable             # 禁用 API
./mb ai gpu check               # 检测 NVIDIA GPU
./mb ai update                  # 拉取最新镜像并重建
./mb ai rag setup               # 部署 RAG（Chroma + Open WebUI）
./mb ai ollama-prod deploy --cpu   # 部署加固版 Ollama（CPU）
./mb ai ollama-prod deploy --gpu   # 部署加固版 Ollama（GPU）
./mb ai ollama-prod deploy --webui # 部署加固版 Open WebUI
./mb ai ollama-prod preload        # 预加载默认模型（幂等）
./mb ai ollama-prod preload --model llama3.2:3b --dry-run
./mb ai ollama-prod health         # API + 模型 + 显存 + 磁盘健康检查
./mb ai help                    # 完整帮助
```

### 生产级部署

`ollama-prod` 命令使用加固 compose 文件：固定镜像 tag、端口仅绑定 127.0.0.1、
健康检查、日志轮转。完整调优、备份与安全指南见
[`docs/production-config.md`](docs/production-config.md)。

```bash
./mb ai ollama-prod deploy --gpu      # Ollama（固定 tag，仅监听 127.0.0.1）
./mb ai ollama-prod deploy --webui    # Open WebUI（固定 tag，仅监听 127.0.0.1）
./mb ai ollama-prod preload           # 拉取 llama3.2:3b、qwen2.5:7b、nomic-embed-text
./mb ai ollama-prod health            # 验证整套服务
```

## 模型推荐

运行 `./mb ai model recommend` 自动获取建议。概览：

| VPS 配置 | 推荐模型 | 大小 |
|----------|----------|------|
| 2 GB 内存 / CPU | `qwen2.5:0.5b`、`llama3.2:1b` | ~0.5–1.3 GB |
| 4 GB 内存 / CPU | `phi3:mini`、`qwen2.5:1.5b` | ~1–2.3 GB |
| 8 GB 内存 / CPU | `llama3.2:3b`、`qwen2.5:3b` | ~2 GB |
| 16 GB 内存 / CPU | `llama3.1:8b`、`qwen2.5:7b` | ~4.7 GB |
| 8 GB 显存 / GPU | `llama3.1:8b`、`qwen2.5:7b` | ~4.7 GB |
| 16 GB 显存 / GPU | `qwen2.5:14b`、`llama3.1:13b` | ~7–9 GB |
| 24 GB+ 显存 / GPU | `qwen2.5:32b`、`llama3.1:70b` | ~20–40 GB |

完整目录见 [`models/model-list.md`](models/model-list.md)，选型指南见
[`docs/model-selection.md`](docs/model-selection.md)。

## 常见问题

**必须有 GPU 吗？**
不需要。纯 CPU 可以很好地运行 ~8B 以内的模型。GPU 会显著加速推理并
解锁更大模型，但它是可选的。

**需要多少内存？**
最低 2 GB 可运行整套服务和一个小模型。8 GB 可用 3B 模型，16 GB 可用
8B 模型。运行时内存 ≈ 模型文件大小的 1.3 倍。

**数据是私有的吗？**
是的，全部运行在你的 VPS 上。模型权重、聊天记录、上传文档存放在
`/data/ollama` 和 `/data/open-webui`——除了从 Ollama 仓库初始下载模型
外，没有任何数据离开你的服务器。

**能替代 OpenAI API 吗？**
可以。运行 `./mb ai api enable`，把任何 OpenAI 兼容客户端指向
`https://<your-domain>/v1` 并使用生成的 API 密钥。详见
[`docs/api-usage.md`](docs/api-usage.md)。

**如何启用 HTTPS？**
使用仓库自带的 `compose/Caddyfile.example` 配合一个 Caddy 实例（例如
[mb-proxy](https://github.com/0x10debug/mb-proxy)）。Caddy 会自动签发
Let's Encrypt 证书。详见 [`docs/remote-access.md`](docs/remote-access.md)。

**能做文档问答（RAG）吗？**
可以。`./mb ai rag setup` 会部署 Chroma 并配置 Open WebUI 的检索增强
生成。详见 [`docs/rag-setup.md`](docs/rag-setup.md)。

## 文档

- [部署指南](docs/deployment-guide.md) —— CPU 与 GPU 安装、前置条件、故障排查
- [生产级配置](docs/production-config.md) —— 加固、调优、备份、生产安全
- [模型选型](docs/model-selection.md) —— 如何选模型、量化原理说明
- [远程访问](docs/remote-access.md) —— Caddy 反向代理、HTTPS、basic auth
- [API 用法](docs/api-usage.md) —— OpenAI 兼容 API、curl 与 SDK 示例
- [RAG 配置](docs/rag-setup.md) —— 基于 Chroma 的文档问答

## 相关仓库

- [0x10debug/vps-bootstrap](https://github.com/0x10debug/vps-bootstrap) —— VPS 基础初始化
- [0x10debug/network-toolkit](https://github.com/0x10debug/network-toolkit) —— 网络工具集
- [0x10debug/compose-recipes](https://github.com/0x10debug/compose-recipes) —— Docker Compose 合集

## 许可证

[MIT](LICENSE) — Copyright (c) 2026 0x10debug
