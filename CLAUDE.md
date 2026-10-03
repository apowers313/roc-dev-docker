# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Docker-based development environment ("dev-env") running Ubuntu 24.04 with multiple services managed by supervisord. The container gets its own IP on the local network via macvlan networking and requires an NVIDIA GPU for CUDA workloads.

## Common Commands

All commands use `sudo docker` (defined as `DOCKER` in Makefile):

- `make start` - Build and start the container (also runs `setup-network.sh` for macvlan loopback)
- `make stop` - Stop the container (`docker compose down`)
- `make restart` - Stop then start
- `make build` - Build the image only
- `make fresh` - Build with `--no-cache`
- `make check` - Smoke test the image against the real `~/dev` (`check-env`); starts no services
- `make verify` - supervisord states + in-container checks + port sweep against a running dev-env
- `make test-run` - Run container interactively with port mappings (no compose, no macvlan)
- `make logs` - View compose logs
- `make shell` - Run an interactive bash shell in a new container
- `make publish` - Tag and push to ghcr.io
- `make build-jammy` / `make rollback` - Build / switch to the previous 22.04 image
- `make nogpu` - Start without a GPU reservation (for when the host driver is broken)

## Architecture

### Container Image (Dockerfile)
Ubuntu 24.04. Multi-stage build pulling Memgraph Lab from `memgraph/memgraph-platform`
(pinned). Third-party versions are `ARG`s at the top of the file. The main image installs:
- **Languages**: Python 3.10/3.11/3.12/3.13 (3.12 is the system python; 3.10/3.11/3.13 from
  the deadsnakes PPA), Rust, Node.js 22
- **CUDA**: 12.8 toolkit, installed from NVIDIA's `ubuntu2404` apt repo (not a .run file)
- **Database**: Memgraph 2.22.1 + Memgraph Lab (copied from first stage)
- **Services**: code-server (VS Code), JupyterLab, Marimo, OpenSSH, supervisord
- **Tools**: uv, poetry, hatch, pnpm, cmake, clang, git-lfs, tilix, Claude Code, gh CLI

**Why python3.10 is installed:** the bind-mounted home carries ~11 GB of
`pip install --user` packages under `~/.local/lib/python3.10` plus a dozen venvs
pinned to 3.10. On 24.04 the system python is 3.12, so 3.10 is installed explicitly
to keep all of that resolvable.

**Do not run `ensurepip` for the extra interpreters.** Every Debian-patched python
shares `/usr/lib/python3/dist-packages`, so `python3.10 -m ensurepip --upgrade`
replaces the *system 3.12's* setuptools and breaks `_distutils_hack`. Use
`uv pip install --system --python python3.X <pkg>` instead.

**PEP 668:** 24.04 refuses `pip install` into the system interpreter. JupyterLab lives
in a venv at `/opt/venv/jupyter` (symlinked into `/usr/local/bin`); marimo is installed
with uv into the system 3.13 because supervisord invokes it as
`python3.13 /usr/local/bin/marimo`.

**Anything installed into `/home/apowers` at build time is invisible at runtime** - the
`dev-vol` bind mount covers it. Rust, uv, poetry, pnpm and hatch therefore install to
`/usr/local` and `/opt`, and the Jupyter config goes to `/etc/jupyter`.

### Rollback (Dockerfile.jammy)
`Dockerfile.jammy` is the previous Ubuntu 22.04 build, kept for rollback. See
`RECOVERY.md`. Note it lacks `git-lfs` and `tilix`, which were originally installed
by hand in the running container rather than in the Dockerfile.

### Supervisord (process manager)
- `supervisord.base.conf` - Core services: VS Code (:8004), Jupyter (:8002), Marimo (:8003), SSHD (:22), index page (:80), supervisord web UI (:8001)
- `supervisord.conf` - Includes base config and adds: Memgraph (:7687), Memgraph Lab (:3000), data loader

### Networking (compose.yml + setup-network.sh)
Uses macvlan driver to give the container a real IP on the LAN (`DEV_IP` from `.env`). The `setup-network.sh` script creates a loopback macvlan interface so the host can communicate with the container.

### Configuration (.env)
Contains network settings (subnet, gateway, IP range, interface), container IP, MAC address, passwords, and tokens. Listed in `.gitignore` but present on disk.

### GPU
The compose.yml reserves 1 NVIDIA GPU via the `deploy.resources.reservations.devices` block. NVIDIA drivers must be loaded on the host and nvidia-container-toolkit must be installed for the container to start.

**`--privileged` is required for GPU access.** `/etc/nvidia-container-runtime/config.toml`
sets `no-cgroups = true`, so `nvidia-container-cli` does not grant device access through
cgroups. compose.yml sets `privileged: true`, which is why dev-env works. A bare
`docker run --gpus all ...` test fails with `Failed to initialize NVML: Unknown Error`
even on a healthy driver - add `--privileged`.

**Driver mismatch:** if the nvidia packages are upgraded without a reboot, the loaded
kernel module and userspace NVML disagree and no new GPU container can start - including
a rollback, since compose.yml reserves a GPU. Use `./fix-nvidia-driver.sh verify` to
check and `./fix-nvidia-driver.sh reboot --yes` to fix; `make nogpu` gets a working
container meanwhile.

## Diagnostics and Incident Capture

### Why this exists
On 2026-10-03, `dev-env` restarted unexpectedly and lost all in-memory session state
(code-server and Jupyter keep sessions in memory). The cause was never found, because
essentially no evidence survived: supervisord's log jumped straight from running to a
fresh start with **no shutdown message**, the service logs lived inside the container,
and nothing had recorded the resource trend leading up to it. Memory, disk, GPU faults
(no Xid), daemon-level events and PID exhaustion were all ruled out. The instrumentation
below exists so a recurrence is diagnosable.

### dev-env-watchdog.sh
A systemd service on the **host** (not in the container). Install and inspect:

    ./dev-env-watchdog.sh install --yes   # installs + enables the systemd unit
    ./dev-env-watchdog.sh status          # sampler state + event-watcher health
    ./dev-env-watchdog.sh incidents       # most recent incident, with the run-up
    ./dev-env-watchdog.sh test            # exercise the capture path without a crash
    ./dev-env-watchdog.sh sample          # print one sample line

It has two independent halves:

1. **Sampler** - every 10s appends one greppable line to
   `/home/apowers/dev-env-diag/samples.log` (rotated, ~7 days): cgroup
   `pids.current`/`pids.events`, `memory.current`/`memory.events` (including
   `oom_kill`), CPU usage and throttling, host load, host available memory,
   self-tracked high-water marks, and **GPU state** (utilization, memory used/total,
   temperature, and per-process GPU memory). **This run-up is the one thing that
   cannot be reconstructed after the fact.**

   GPU metrics are sampled continuously, not just at death, because this box is used
   for CUDA/WebGPU work and a GPU-adjacent problem leaves no trace in the cgroup or
   host numbers. Note that a GPU *fault* (hang, reset) would also appear as an `Xid`
   in the kernel log - `journalctl -k | grep -E "Xid|NVRM"`. The absence of any Xid
   is what ruled out a GPU fault for the 2026-10-03 restart.
2. **Event watcher** - tails `docker events` for `die`/`oom`/`kill` and writes
   `/home/apowers/dev-env-diag/incidents/<stamp>-<action>/` containing: `summary.txt`
   (exit code, `OOMKilled`, timings, restart count), 2000 lines of container stdout,
   **every supervisord service log copied out of the stopped container**, the last 200
   resource samples, host state, dmesg, a filtered journal, the container's own systemd
   scope journal, and nvidia-smi. `incidents/LATEST` symlinks the newest.

Notes for anyone maintaining this:
- It runs as **root** so dmesg and the full journal are readable; output stays readable
  by `apowers`.
- `systemctl is-active` only proves the **sampler** is alive. The event watcher is the
  half that catches the crash, so `status` checks it separately and warns loudly if it
  died. The stream is wrapped in a reconnect loop for the same reason.
- `docker cp` of the whole `/var/log` **fails** on a dangling systemd symlink
  (`README -> ../../usr/share/doc/systemd/README.logs`), so logs are copied file by
  file. The container is stopped at `die` time, so `docker exec` is not an option.
- Kernel 5.15 has no `pids.peak`/`memory.peak` (added in 5.19+), so peaks are tracked
  in `$DIAG_DIR/peaks.*`.
- Values read from cgroup files **must be trimmed**; an untrimmed `"101 "` silently
  fails numeric comparisons.

### Log persistence
Supervisord and every service write to `/var/log/supervisord/`, which compose
bind-mounts from `/home/apowers/dev/logs/supervisord`. Logs therefore survive container
**recreation** (`compose down/up`), not just a restart, and are visible inside the
container as `~/logs/supervisord`. Container stdout (`docker logs`) is capped at
100 MB x 5 and is still lost on recreate - only the watchdog copies it somewhere durable.

### Resource limits as attribution
`compose.yml` sets `mem_limit: 84g`, `memswap_limit: 92g`, `pids_limit: 100000` - sized
to nearly the whole machine, because this container is the purpose of the server (host
has 93.9 GiB; the other ~16 containers use ~5.6 GiB combined). The point is **not** to
constrain the dev work. An unlimited container gets its processes killed by the host
(`earlyoom` runs here, and it logs only to the journal) with no record of which container
was responsible. With a limit, pressure is attributed: `.State.OOMKilled` flips to true
and the cgroup `oom_kill` counter increments, both of which the watchdog captures.
Observed task concurrency is ~101, so the pids ceiling only stops a genuine fork bomb.

### The remaining gap: who sent the signal
Nothing above records *which process* sent a kill. If an unexplained restart recurs,
switch on an audit rule (needs auditd) while hunting it:

    sudo auditctl -a always,exit -F arch=b64 -S kill -F a1=9 -k sigkill
    sudo ausearch -k sigkill -ts recent

It logs the sending pid/uid/comm for every SIGKILL. Noisy on a busy dev box, so it is
not enabled by default.

### Normal load is high - do not mistake it for a fault
This is a development machine and routinely runs ~7 cores saturated with process
creation rates around 400/second during builds and multi-agent workflows. High CPU,
high process-creation rate, and bursts of outbound API/DNS traffic are **expected** and
are not evidence of a problem. Note also that PID *numbers* grow monotonically, so a
large PID is cumulative churn, not concurrency - check `pids.current` instead.

## Key Details

- Container hostname: `dev.ato.ms`
- Container user: `apowers` (has passwordless sudo)
- Home directory `/home/apowers` is bind-mounted from host `/home/apowers/dev`
- SSL certs mounted from `/home/apowers/atoms-cert` to `/home/apowers/ssl`
- Image tagged as both `apowers313/roc-dev` and `ghcr.io/apowers313/roc-dev`, current version 3.0.0
- Scripts: `check-env` (smoke test, baked into the image), `fix-nvidia-driver.sh`,
  `fix-home-shebangs`, `migrate-to-noble.sh` (historical; `verify`/`rollback`/`nogpu` phases)
- Scripts in the mounted `~/.local/bin` carry `#!/usr/bin/python3` shebangs with their
  packages in python3.10, so they fail on 24.04. Deliberately unfixed - no service depends
  on them. Use `python3.10 ~/.local/bin/<tool>`, or `./fix-home-shebangs --apply`.
