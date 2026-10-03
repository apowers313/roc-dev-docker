#!/usr/bin/env bash
# Commits the Ubuntu 24.04 migration work plus the pending sonar-scanner edit,
# directly on master, unsigned (this repo has no commit signing configured).
# Run:  ./do-commit.sh
set -euo pipefail
cd "$(dirname "$0")"

git add -A
echo "=== staged ==="
git diff --cached --stat
echo

git commit -F - <<'MSG'
feat: add Ubuntu 24.04 (noble) image alongside 22.04

Adds a side-by-side 24.04 build so the dev-env can be migrated off 22.04
without disturbing the running container. The existing Dockerfile and
compose.yml are untouched; rollback is dropping one -f flag.

Dockerfile.noble - 24.04 build. Changes forced by noble:
  - base image ships a default `ubuntu` user holding uid 1000, which would
    push apowers to 1001 and orphan the bind-mounted home (host uid 1000)
  - unminimize moved to its own package at /usr/bin/unminimize
  - `netcat` has no installation candidate; use netcat-openbsd
  - `man` and `fortune` are virtual with several providers; name man-db and
    fortune-mod/fortunes-min directly
  - memgraph 2.8.0 has no ubuntu-24.04 build (404) -> 2.22.1
  - CUDA 12.0 runfile predates noble -> cuda-toolkit-12-8 from the apt repo
  - kitware cmake repo: jammy -> noble
  - PEP 668 blocks pip into the system interpreter; jupyter gets a venv and
    marimo is installed with uv
  - no ensurepip for the deadsnakes interpreters: they share
    /usr/lib/python3/dist-packages, so `python3.10 -m ensurepip --upgrade`
    replaces the system 3.12's setuptools and breaks _distutils_hack

  Also fixes pre-existing problems carried over from Dockerfile:
  - rust/uv/poetry/pnpm/hatch/jupyter config were installed into
    /home/apowers, which the dev-vol bind mount hides at runtime; they now
    go to /usr/local, /opt and /etc
  - hatch was downloaded as a macOS .pkg and never installed
  - `npm i -g mmdc` is not mermaid-cli (-> @mermaid-js/mermaid-cli)
  - LD_LIBRARY_PATH had a leading ":", making the loader search the cwd
  - DEBIAN_FRONTEND was ENV (leaked into the final image); the paired
    `RUN unset` was a no-op
  - ~80 RUN layers collapsed to ~12, third-party versions pinned as ARGs,
    apt cache mounts, and retries on every network fetch

  git-lfs, tilix, x11-utils and x11-xserver-utils were found installed by
  hand in the live container, existing only in its writable layer; they are
  captured here so the migration does not drop them.

supervisord.base.conf - jupyter now runs /usr/local/bin/jupyter by absolute
path. ~/.local/bin is first on PATH and the mounted home's jupyter launcher
has a `#!/usr/bin/python3` shebang whose packages live in python3.10, so it
fails on noble where python3 is 3.12. The absolute path works on both.

compose.noble.yml  - override selecting the noble image, so compose.yml and
                     the rollback path stay as they are
migrate-to-noble.sh - phased runbook: preflight / shebangs / cutover /
                     verify / rollback, each behind an explicit argument
fix-nvidia-driver.sh - the host's loaded nvidia module (580.173.02) and
                     userspace NVML (580.178.04) disagree, so no new
                     container can get a GPU; reload or reboot
fix-home-shebangs   - optional: repoint the 136 unused ~/.local/bin
                     launchers at python3.10 (reversible, .pre310 backups)
check-env           - smoke test; currently 30 pass, 1 fail (the host
                     driver), 4 known-and-accepted
.dockerignore       - keeps .git and .env out of the build context

Dockerfile: adds openjdk-17 and the SonarQube scanner (pending edit that
predates this work).

Verified: image builds; memgraph 2.22.1 loads got.cypherl and queries back
2680 nodes; Memgraph Lab, code-server, marimo-via-3.13 and supervisord all
start; all four interpreters present and the mounted home's 3.10 venvs and
11 GB user site-packages resolve. CUDA is unverified end-to-end: the host
driver mismatch blocks GPU attach for any new container.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG

echo
echo "=== result ==="
git --no-pager log -1 --stat
