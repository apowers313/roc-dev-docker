# syntax=docker/dockerfile:1.7
#
# roc-dev on Ubuntu 24.04 (noble).
#
# Build side by side with the 22.04 image:
#   make build-noble        # -> apowers313/roc-dev:3.0.0-noble
#   make shell-noble        # interactive shell, real ~/dev mounted
#
# Differences from ./Dockerfile are marked "NOBLE:" where the change was
# forced by 24.04, and "BP:" where it is a Dockerfile best-practice cleanup.

######################
# BUILD ARGUMENTS
######################
# BP: every third-party version is pinned here instead of floating, so a
# rebuild is reproducible and an upgrade is a one-line diff.
ARG UBUNTU_VERSION=24.04
# NOBLE: memgraph 2.8.0 has no ubuntu-24.04 build (404). 2.22.1 is the last
# 2.x line; 3.6.0 exists but is a major version jump — see README notes.
ARG MEMGRAPH_VERSION=2.22.1
# NOBLE: CUDA 12.0 (525.60.13) predates noble. 12.4 is the first release with
# 24.04 support; 12.8 matches current torch/cu128 wheels.
ARG CUDA_APT_PACKAGE=cuda-toolkit-12-8
ARG NODE_MAJOR=22
ARG PNPM_VERSION=10.0.0
ARG SONAR_SCANNER_VERSION=7.0.2.4839
ARG DEV_USER=apowers
# NOBLE: must match the host uid that owns /home/apowers/dev (1000).
ARG DEV_UID=1000

######################
# MEMGRAPH LAB STAGE
######################
# BP: pinned instead of :latest so the Lab version can't drift under you.
# NOTE: memgraph-platform is deprecated upstream; latest is memgraph 2.14.1 +
# lab 2.11.1. It pairs with the 2.x server line, not 3.x.
FROM memgraph/memgraph-platform:2.14.1-memgraph2.14.1-lab2.11.1 AS mg-lab

######################
# MAIN IMAGE
######################
FROM ubuntu:${UBUNTU_VERSION}

LABEL org.opencontainers.image.title="roc-dev" \
      org.opencontainers.image.description="Ubuntu 24.04 dev environment: CUDA, Memgraph, code-server, JupyterLab, Marimo" \
      org.opencontainers.image.source="https://github.com/apowers313/roc-dev-docker"

# BP: ARG, not ENV — keeps DEBIAN_FRONTEND out of the final image, where it
# would silently break interactive apt for anyone shelled in. (The original
# `RUN unset DEBIAN_FRONTEND` was a no-op: unset in a subshell can't clear ENV.)
ARG DEBIAN_FRONTEND=noninteractive
ARG DEV_USER
ARG DEV_UID
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# BP: keep apt's downloads in a BuildKit cache mount. Rebuilds — including
# `make fresh` (--no-cache) — reuse the .debs instead of re-downloading GBs.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
 && echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
 && printf '#!/bin/sh\nexit 0\n' > /usr/sbin/policy-rc.d \
 && chmod 0755 /usr/sbin/policy-rc.d

######################
# SETUP UBUNTU
######################

# BP: one layer for the base system instead of five. Cheaper to build, and a
# single apt resolution can't leave half-satisfied dependencies behind.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
apt-get update
# Make REAL Ubuntu
apt-get install -y ubuntu-server
# NOBLE: unminimize moved out of the image (/usr/local/sbin/unminimize) into
# its own package at /usr/bin/unminimize.
apt-get install -y unminimize
# NOTE: subshell with pipefail off. unminimize exits before `yes` does, so the
# pipeline returns 141 (SIGPIPE) under `set -o pipefail` even on success.
( set +o pipefail; yes | /usr/bin/unminimize )
# Basic tools.
# BP: man-db by name. `man` is a virtual package with several providers on
# noble; apt still resolves it to man-db today, but which provider wins is not
# something to leave to apt's scoring.
apt-get install -y \
    ca-certificates curl wget git gnupg software-properties-common \
    net-tools sudo man-db locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
EOF

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Setup user
RUN <<'EOF'
set -euxo pipefail
# NOBLE: the 24.04 base image ships a default `ubuntu` account already holding
# uid 1000. Left in place, ${DEV_USER} lands on 1001 and every file in the
# bind-mounted /home/${DEV_USER} (owned by host uid 1000) becomes foreign.
userdel -r ubuntu 2>/dev/null || true
useradd -m -s /bin/bash -u "${DEV_UID}" -U "${DEV_USER}"
# BP: drop-in file instead of appending to /etc/sudoers, and fix the original's
# case typo ("ALL:All"), which made the runas spec silently narrower.
echo "${DEV_USER} ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/${DEV_USER}
chmod 0440 /etc/sudoers.d/${DEV_USER}
# BP: /home/${DEV_USER} is masked by the dev-vol bind mount at runtime, so a
# per-user .gitconfig written here would never be seen. Write it system-wide.
git config --system user.email "apowers@ato.ms"
git config --system user.name "Adam Powers"
EOF

WORKDIR /home/${DEV_USER}

######################
# PYTHON
######################
# NOBLE: the system python3 is 3.12, not 3.10. The bind-mounted home carries
# ~11 GB of `pip install --user` packages under ~/.local/lib/python3.10 plus a
# dozen venvs whose pyvenv.cfg says `home = /usr/bin` + 3.10 — so python3.10
# is installed explicitly here to keep all of that resolvable. deadsnakes
# publishes 3.10/3.11/3.13 for noble (3.12 comes from the Ubuntu archive).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update
apt-get install -y \
    python3.10 python3.10-dev python3.10-venv python3.10-distutils \
    python3.11 python3.11-dev python3.11-venv python3.11-distutils \
    python3.12 python3.12-dev python3.12-venv \
    python3.13 python3.13-dev python3.13-venv \
    python3-pip
EOF

# NOTE: deliberately no `ensurepip` for the extra interpreters. Every
# Debian-patched python puts /usr/lib/python3/dist-packages on sys.path, so
# `python3.10 -m ensurepip --upgrade` reaches into the SYSTEM 3.12's packages
# and replaces its setuptools — which breaks _distutils_hack and then breaks
# 3.13's bootstrap. uv installs into a named interpreter without that
# collision, so uv is the install path for every non-system interpreter here.
# For ad-hoc installs use: uv pip install --system --python python3.10 <pkg>
# (the mounted home also carries its own ~/.local/bin/pip3.10).
ENV UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
RUN curl -LsSf --retry 5 --retry-delay 2 --retry-all-errors https://astral.sh/uv/install.sh \
  | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

######################
# INSTALL CUDA
######################
# NOBLE: replaces the 12.0 .run installer. The runfile for 12.0 has no 24.04
# support and trips over noble's gcc 13 / glibc 2.39. The apt repo resolves
# dependencies properly, is cached, and cuda-toolkit-* pulls NO driver packages
# (the driver comes from the host via nvidia-container-toolkit).
ARG CUDA_APT_PACKAGE
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
cd /tmp
repo=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64
curl -fsSLO --retry 5 --retry-delay 2 --retry-all-errors "${repo}/cuda-keyring_1.1-1_all.deb"
dpkg -i cuda-keyring_1.1-1_all.deb
rm -f cuda-keyring_1.1-1_all.deb
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "${repo}/cuda-ubuntu2404.pin" -o /etc/apt/preferences.d/cuda-repository-pin-600
apt-get update
apt-get install -y "${CUDA_APT_PACKAGE}"
EOF

ENV CUDA_HOME="/usr/local/cuda"
# BP: no ${LD_LIBRARY_PATH} prefix — it is unset in the base image, and the
# original left a leading ":" in the value, which makes the loader search the
# current working directory.
ENV LD_LIBRARY_PATH="/usr/local/cuda/lib64:/usr/local/cuda/extras/CUPTI/lib64"

######################
# INSTALL MEMGRAPH
######################
ARG MEMGRAPH_VERSION
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
cd /tmp
apt-get update
# BP: apt-get install ./file.deb resolves dependencies; `dpkg -i` just fails on
# the first missing one.
curl -fsSLO --retry 5 --retry-delay 2 --retry-all-errors "https://download.memgraph.com/memgraph/v${MEMGRAPH_VERSION}/ubuntu-24.04/memgraph_${MEMGRAPH_VERSION}-1_amd64.deb"
apt-get install -y "./memgraph_${MEMGRAPH_VERSION}-1_amd64.deb"
rm -f "memgraph_${MEMGRAPH_VERSION}-1_amd64.deb"
# BP: distro packages instead of `pip install` into the system interpreter,
# which 24.04 refuses outright (PEP 668 "externally-managed-environment").
apt-get install -y libssl-dev python3-networkx python3-numpy python3-scipy
EOF
EXPOSE 7687

# Memgraph Lab (copied from the platform image, as before)
COPY --from=mg-lab /lab /lab
EXPOSE 3000
EXPOSE 7444

# Memgraph test data
COPY got.cypherl /tmp/got.cypherl
COPY loaddata.sh /tmp/loaddata.sh

######################
# PROGRAMMING LANGUAGES
######################

# node.js
# NOBLE/BP: the old `setup_18.x` line is gone — it is now an EOL deprecation
# stub, and it was redundant anyway since setup_22.x ran right after it.
ARG NODE_MAJOR
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs
EOF

# Rust
# BP: installed to /usr/local instead of ~/.cargo. Anything written to
# /home/${DEV_USER} during the build is invisible at runtime — the dev-vol bind
# mount covers it. (That is why the original's rust, uv, poetry, pnpm and
# .jupyter config effectively came from the host home, not the image.)
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo
RUN <<'EOF'
set -euxo pipefail
curl --proto '=https' --tlsv1.2 -sSf --retry 5 --retry-delay 2 --retry-all-errors https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --default-toolchain stable
/usr/local/cargo/bin/cargo install typos-cli
# world-writable so the dev user can `cargo install` / update the registry
chmod -R a+w "${RUSTUP_HOME}" "${CARGO_HOME}"
EOF

######################
# SERVICES
######################

# OpenSSH server
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
apt-get update
apt-get install -y openssh-server
# SSH login fix. Otherwise user is kicked off after login
sed -i 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' /etc/pam.d/sshd
mkdir -p /run/sshd
ssh-keygen -A
# BP: the original's two `ex` substitutions on sshd_config are dropped. They
# fail the build outright if the pattern ever moves, and they are unnecessary:
# supervisord already passes -o ListenAddress=0.0.0.0, and the commented
# HostKey lines are the defaults. `update-rc.d ssh defaults` is also gone —
# nothing reads sysvinit here, supervisord runs sshd -D directly.
EOF
EXPOSE 22

# VS Code
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
apt-get update
# NOBLE: verified hard failure on noble — "E: Package 'netcat' has no
# installation candidate". Nothing in main or universe provides it.
apt-get install -y jq libatomic1 nano netcat-openbsd
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://code-server.dev/install.sh | sh
EOF
EXPOSE 8004

# JupyterLab
# NOBLE/BP: an isolated venv rather than `pip3 install` into the system python
# (PEP 668). The symlinks keep supervisord's plain `jupyter lab` working.
RUN <<'EOF'
set -euxo pipefail
python3.12 -m venv /opt/venv/jupyter
/opt/venv/jupyter/bin/pip install --no-cache-dir --upgrade pip
/opt/venv/jupyter/bin/pip install --no-cache-dir jupyterlab notebook
for f in /opt/venv/jupyter/bin/jupyter*; do ln -sf "$f" /usr/local/bin/; done
EOF
# BP: /etc/jupyter is a system config dir Jupyter always reads. The original
# put this in ~/.jupyter, which the bind mount hides.
COPY jupyter_lab_config.py /etc/jupyter/jupyter_lab_config.py
EXPOSE 8002

# Marimo
# NOTE: installed into the system 3.13 (not a venv) on purpose — supervisord
# invokes it as `python3.13 /usr/local/bin/marimo`, which only resolves if
# marimo is importable by that interpreter.
RUN uv pip install --system --break-system-packages --python /usr/bin/python3.13 marimo
EXPOSE 8003

# http index of running services
COPY index.html /var/run/indexserver/index.html
EXPOSE 80

######################
# EXTRA TOOLS
######################

# Nethack Learning Environment dependencies + cmake from Kitware
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
apt-get update
apt-get install -y build-essential autoconf libtool pkg-config flex bison libbz2-dev
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://apt.kitware.com/keys/kitware-archive-latest.asc \
  | gpg --dearmor -o /etc/apt/trusted.gpg.d/kitware.gpg
chmod 0644 /etc/apt/trusted.gpg.d/kitware.gpg
# NOBLE: jammy -> noble
apt-add-repository -y 'deb https://apt.kitware.com/ubuntu/ noble main'
apt-get update
apt-get install -y kitware-archive-keyring cmake
EOF

# Extra tools
# The last four (git-lfs, tilix + X11 helpers) were found installed BY HAND in
# the live 22.04 container -- they existed only in that container's writable
# layer, not in ./Dockerfile, so they would have been lost on migration.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked <<'EOF'
set -euxo pipefail
apt-get update
# BP: fortune-mod by name (`fortune` is a virtual package with ~10 providers;
# apt does resolve it, but pick deliberately) plus the fortunes data package.
apt-get install -y \
    graphviz inetutils-telnet inetutils-ping fortune-mod fortunes-min \
    rsync bsdmainutils lsof dnsutils unzip \
    clang clangd \
    libvulkan1 mesa-vulkan-drivers \
    imagemagick \
    gh \
    openjdk-17-jre-headless \
    supervisor \
    git-lfs \
    tilix x11-utils x11-xserver-utils
git lfs install --system
EOF

# poetry / hatch / pnpm
# BP: all four relocated out of $HOME for the bind-mount reason above.
ENV PNPM_HOME=/usr/local/pnpm
ARG PNPM_VERSION
RUN <<'EOF'
set -euxo pipefail
# uv is installed with the interpreters above
# poetry
curl -sSL --retry 5 --retry-delay 2 --retry-all-errors https://install.python-poetry.org | POETRY_HOME=/opt/poetry python3 -
ln -sf /opt/poetry/bin/poetry /usr/local/bin/poetry
# BP: hatch is actually installed now. The original downloaded
# hatch-universal.pkg (a macOS installer) into \$HOME and never ran it.
uv tool install hatch
# pnpm
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors https://get.pnpm.io/install.sh | env PNPM_VERSION="${PNPM_VERSION}" SHELL=/bin/bash sh -
chmod -R a+w "${PNPM_HOME}"
EOF

# npm globals
# BP: `mmdc` is not mermaid-cli — it is an unrelated stub package. The real
# CLI is @mermaid-js/mermaid-cli. If mmdc reports missing shared libraries at
# runtime, add puppeteer's chromium deps (libnss3, libatk-bridge2.0-0, libcups2,
# libdrm2, libgbm1, libxkbcommon0, libxcomposite1, libxdamage1, libasound2t64).
RUN npm install -g @mermaid-js/mermaid-cli @anthropic-ai/claude-code

# SonarQube scanner
ARG SONAR_SCANNER_VERSION
RUN <<'EOF'
set -euxo pipefail
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}-linux-x64.zip" -o /tmp/sonar-scanner.zip
unzip -q /tmp/sonar-scanner.zip -d /opt
mv "/opt/sonar-scanner-${SONAR_SCANNER_VERSION}-linux-x64" /opt/sonar-scanner
rm -f /tmp/sonar-scanner.zip
EOF
# Use system Java instead of bundled JRE
ENV SONAR_SCANNER_OPTS="-Dsonar.scanner.javaExePath=/usr/bin/java"

######################
# PATH
######################
# BP: one authoritative PATH. ~/.local/bin stays first to match the current
# image (the mounted home's tools win), then the image-side tool dirs.
ENV PATH="/home/${DEV_USER}/.local/bin:/usr/local/cargo/bin:${PNPM_HOME}:/opt/sonar-scanner/bin:/usr/local/cuda/bin:${PATH}"

######################
# EXTRA PORTS
######################

# for development purposes
EXPOSE 8000-9999

######################
# SUPERVISORD
######################
RUN mkdir -p /var/log/supervisord
COPY supervisord.base.conf /usr/local/etc/supervisord.base.conf
COPY supervisord.conf /usr/local/etc/supervisord.conf
EXPOSE 8001

######################
# MOUNT COMPATIBILITY HELPERS
######################
# The bind-mounted home was populated under 22.04, where /usr/bin/python3 was
# 3.10. Scripts in ~/.local/bin (jupyter, poetry, ...) carry a literal
# `#!/usr/bin/python3` shebang but their packages live in
# ~/.local/lib/python3.10 — on noble that shebang resolves to 3.12 and they
# fail with ModuleNotFoundError. fix-home-shebangs repoints them at 3.10.
COPY fix-home-shebangs /usr/local/bin/fix-home-shebangs
COPY check-env /usr/local/bin/check-env
RUN chmod 0755 /usr/local/bin/fix-home-shebangs /usr/local/bin/check-env

COPY root_bashrc /root/.bashrc

# Run Server
USER ${DEV_USER}
CMD ["sudo", "-E", "supervisord", "-c", "/usr/local/etc/supervisord.conf"]
