# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Docker-based development environment ("dev-env") running Ubuntu 22.04 with multiple services managed by supervisord. The container gets its own IP on the local network via macvlan networking and requires an NVIDIA GPU for CUDA workloads.

## Common Commands

All commands use `sudo docker` (defined as `DOCKER` in Makefile):

- `make start` - Build and start the container (also runs `setup-network.sh` for macvlan loopback)
- `make stop` - Stop the container (`docker compose down`)
- `make restart` - Stop then start
- `make build` - Build the image only
- `make fresh` - Build with `--no-cache`
- `make test-run` - Run container interactively with port mappings (no compose, no macvlan)
- `make logs` - View compose logs
- `make shell` - Run an interactive bash shell in a new container
- `make publish` - Tag and push to ghcr.io

## Architecture

### Container Image (Dockerfile)
Multi-stage build pulling Memgraph Lab from `memgraph/memgraph-platform`. The main image installs:
- **Languages**: Python 3.11/3.12/3.13, Rust, Node.js 22
- **CUDA**: 12.0 toolkit (installed from NVIDIA .run file, not apt)
- **Database**: Memgraph 2.8.0 + Memgraph Lab (copied from first stage)
- **Services**: code-server (VS Code), JupyterLab, Marimo, OpenSSH, supervisord
- **Tools**: uv, poetry, pnpm, cmake, clang, Claude Code, gh CLI

### Supervisord (process manager)
- `supervisord.base.conf` - Core services: VS Code (:8004), Jupyter (:8002), Marimo (:8003), SSHD (:22), index page (:80), supervisord web UI (:8001)
- `supervisord.conf` - Includes base config and adds: Memgraph (:7687), Memgraph Lab (:3000), data loader

### Networking (compose.yml + setup-network.sh)
Uses macvlan driver to give the container a real IP on the LAN (`DEV_IP` from `.env`). The `setup-network.sh` script creates a loopback macvlan interface so the host can communicate with the container.

### Configuration (.env)
Contains network settings (subnet, gateway, IP range, interface), container IP, MAC address, passwords, and tokens. Listed in `.gitignore` but present on disk.

### GPU
The compose.yml reserves 1 NVIDIA GPU via the `deploy.resources.reservations.devices` block. NVIDIA drivers must be loaded on the host and nvidia-container-toolkit must be installed for the container to start.

## Key Details

- Container hostname: `dev.ato.ms`
- Container user: `apowers` (has passwordless sudo)
- Home directory `/home/apowers` is bind-mounted from host `/home/apowers/dev`
- SSL certs mounted from `/home/apowers/atoms-cert` to `/home/apowers/ssl`
- Image tagged as both `apowers313/roc-dev` and `ghcr.io/apowers313/roc-dev`, current version 2.0.0
