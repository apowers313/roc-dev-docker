#!/usr/bin/env bash
#
# NOT RUN AUTOMATICALLY. Requires an explicit argument.
#
# Problem: the nvidia kernel module loaded at boot (2026-08-27) is 580.173.02,
# but userspace NVML is now 580.178.04. Any NEW GPU container fails with:
#   nvidia-container-cli: initialization error: nvml error: driver/library
#   version mismatch
# The already-running dev-env keeps its GPU only until it stops.
#
# Both fixes below are safe w.r.t. Secure Boot:
#   - kernel 5.15.0-191 is installed and pending; its Canonical-signed
#     nvidia-580 module is 580.178.04 (matches userspace exactly)
#   - DKMS has 580.178.04 built for kernels 190 and 191, signed with the
#     "hal Secure Boot Module Signature key", which IS enrolled
#
# Usage:
#   ./fix-nvidia-driver.sh reload    # ~2 min, only dev-env stops, no reboot
#   ./fix-nvidia-driver.sh reboot    # stops ALL containers; picks up kernel 191
#   ./fix-nvidia-driver.sh verify    # read-only: check whether GPU works now
set -euo pipefail

verify() {
    echo "== host nvidia-smi =="
    nvidia-smi || echo "  (still mismatched)"
    echo "== loaded module vs userspace =="
    cat /proc/driver/nvidia/version
    ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*[0-9]
    echo "== GPU inside the noble image =="
    docker run --rm --gpus all apowers313/roc-dev:3.0.0-noble bash -c '
        nvidia-smi | head -12
        nvcc --version | tail -2 | head -1
        python3.10 -c "import torch; print(\"torch\", torch.__version__, \"cuda:\", torch.cuda.is_available())" 2>/dev/null \
          || echo "(torch not installed for 3.10)"
    '
}

case "${1:-}" in
  reload)
    echo ">> stopping dev-env (the only container holding the GPU)"
    sudo docker stop dev-env
    echo ">> unloading nvidia modules"
    sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
    echo ">> reloading (modprobe picks the signed DKMS 580.178.04)"
    sudo modprobe nvidia
    sudo nvidia-smi
    echo ">> restarting dev-env"
    cd "$(dirname "$0")" && make start
    verify
    ;;
  reboot)
    echo ">> This stops EVERY container: observability stack, sonarqube, dev-env."
    read -rp "   Type REBOOT to continue: " ans
    [ "$ans" = "REBOOT" ] || { echo "aborted"; exit 1; }
    sudo systemctl reboot
    ;;
  verify)
    verify
    ;;
  *)
    echo "usage: $0 {reload|reboot|verify}"
    echo "  reload  - fix without rebooting (stops dev-env only)"
    echo "  reboot  - full reboot, also applies pending kernel 5.15.0-191"
    echo "  verify  - read-only check, changes nothing"
    exit 1
    ;;
esac
