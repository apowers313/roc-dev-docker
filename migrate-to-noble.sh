#!/usr/bin/env bash
#
# Migrate dev-env from the Ubuntu 22.04 image to apowers313/roc-dev:3.0.0-noble.
# NOT RUN AUTOMATICALLY - every phase needs an explicit argument.
#
#   ./migrate-to-noble.sh preflight   # read-only. changes nothing. run this first.
#   ./migrate-to-noble.sh shebangs    # OPTIONAL: rewrite 136 ~/.local/bin shebangs
#   ./migrate-to-noble.sh cutover     # STOPS dev-env, fixes driver, starts noble
#   ./migrate-to-noble.sh verify      # check a running dev-env
#   ./migrate-to-noble.sh rollback    # back to the 22.04 image
#
# Ordering that matters:
#   1. dev-env must STOP before the nvidia modules can be reloaded, and it
#      cannot get a GPU back until they are - so the driver fix belongs inside
#      the cutover window, not before or after it.
#   2. The `shebangs` phase is OPTIONAL - those launchers are unused, and
#      JupyterLab now runs the image's own /usr/local/bin/jupyter instead.
set -euo pipefail
cd "$(dirname "$0")"

NOBLE=apowers313/roc-dev:3.0.0-noble
OLD=apowers313/roc-dev:latest
COMPOSE="docker compose -f compose.yml -f compose.noble.yml --env-file .env"
COMPOSE_OLD="docker compose -f compose.yml --env-file .env"

preflight() {
    echo "== 1. the tested image is present =="
    docker image inspect "$NOBLE" --format '{{.RepoTags}} {{.Created}}' || {
        echo "   MISSING - run: make build-noble"; return 1; }

    echo; echo "== 2. rollback image is still present (do NOT prune this) =="
    docker image inspect "$OLD" --format '{{.RepoTags}} {{.Created}}' \
        || echo "   WARNING: no 22.04 image to roll back to"

    echo; echo "== 3. disk =="
    df -h /var/lib/docker | tail -1

    echo; echo "== 4. nvidia driver (must be consistent before a new container gets a GPU) =="
    loaded=$(sed -n 's/.*Kernel Module *\([0-9.]*\).*/\1/p' /proc/driver/nvidia/version)
    # match only the fully-versioned soname (X.Y.Z), not libnvidia-ml.so.1
    userspace=$(ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*.*.* 2>/dev/null \
        | sed 's/.*so\.//' | head -1)
    echo "   loaded module: $loaded"
    echo "   userspace:     $userspace"
    if [ "$loaded" = "$userspace" ]; then echo "   OK - matched"
    else echo "   MISMATCH - cutover will reload the modules (see fix-nvidia-driver.sh)"; fi

    echo; echo "== 5. container drift: anything hand-installed in the live container =="
    echo "   (these changes live in the container, NOT in ~/dev, and are LOST on cutover)"
    # `docker diff` walks the whole container layer and can take many minutes
    # on this container, so it is bounded and treated as advisory.
    if timeout 120 docker diff dev-env > /tmp/dev-env-drift.txt 2>/dev/null; then
        grep -E "^A (/usr|/opt|/etc|/srv)" /tmp/dev-env-drift.txt \
            | grep -vE "/usr/lib/node_modules/.+/" | head -20 \
            || echo "   (no additions under /usr, /opt, /etc, /srv)"
        echo "   full list: /tmp/dev-env-drift.txt ($(wc -l < /tmp/dev-env-drift.txt) entries)"
    else
        echo "   SKIPPED - docker diff did not finish in 120s on this container."
        echo "   Advisory only. Check by hand what matters to you, e.g.:"
        echo "     docker exec dev-env bash -c 'ls -t /var/lib/dpkg/info/*.list | head -20'"
    fi

    echo; echo "== 6. memgraph: nothing to preserve =="
    echo "   supervisord's loaddata program reloads got.cypherl on every boot, so"
    echo "   the DB is disposable by design. No dump needed."

    echo; echo "== 7. ~/.local/bin shebangs: INTENTIONALLY NOT FIXED =="
    echo "   Those 136 launchers are unused. JupyterLab no longer depends on them:"
    echo "   supervisord.base.conf now calls /usr/local/bin/jupyter (the image s own"
    echo "   copy, working on both 22.04 and 24.04). If you return to those tools,"
    echo "   run ./fix-home-shebangs --apply, or call them as:"
    echo "     python3.10 ~/.local/bin/<tool>"
    echo "   Verifying the image jupyter instead:"
    echo -n "     jupyter lab "
    docker run --rm -v /home/apowers/dev:/home/apowers "$NOBLE" \
        /usr/local/bin/jupyter lab --version 2>&1 | tail -1
}

shebangs() {
    echo ">> rewriting #!/usr/bin/python3 -> #!/usr/bin/python3.10 in ~/.local/bin"
    echo ">> backups kept as *.pre310; safe on BOTH the 22.04 and 24.04 images"
    read -rp "   continue? [y/N] " a; [ "${a,,}" = "y" ] || { echo "aborted"; return 1; }
    docker run --rm -v /home/apowers/dev:/home/apowers "$NOBLE" fix-home-shebangs --apply
}

cutover() {
    echo ">> This stops dev-env (5+ weeks up), reloads the nvidia modules,"
    echo ">> and brings it back on $NOBLE."
    read -rp "   Type CUTOVER to continue: " a; [ "$a" = "CUTOVER" ] || { echo "aborted"; return 1; }

    echo ">> stopping dev-env"
    $COMPOSE_OLD down

    echo ">> reloading nvidia modules (nothing holds the GPU now)"
    if sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia; then
        sudo modprobe nvidia && sudo nvidia-smi | head -10
    else
        echo "   rmmod failed - something still holds the GPU. Options:"
        echo "     sudo fuser -v /dev/nvidia*     # find it"
        echo "     ./fix-nvidia-driver.sh reboot  # or just reboot"
        return 1
    fi

    echo ">> setting up the macvlan loopback"
    sudo ./setup-network.sh

    echo ">> starting dev-env on the noble image (no --build: use what was tested)"
    $COMPOSE up -d --no-build dev-env

    sleep 15
    verify
}

verify() {
    echo "== supervisord process states =="
    docker exec dev-env supervisorctl -s http://localhost:8001 status 2>/dev/null \
        || docker exec dev-env bash -c 'ls /var/log/*.error.log' 2>/dev/null
    echo; echo "== smoke test inside the running container =="
    docker exec dev-env check-env || true
    echo; echo "== ports from the host =="
    ip=$(grep -E "^DEV_IP=" .env | cut -d= -f2)
    for p in 80 22 3000 7687 8001 8002 8003 8004; do
        timeout 3 bash -c "</dev/tcp/$ip/$p" 2>/dev/null \
            && echo "   open   $ip:$p" || echo "   CLOSED $ip:$p"
    done
}

rollback() {
    echo ">> returning dev-env to the 22.04 image"
    read -rp "   continue? [y/N] " a; [ "${a,,}" = "y" ] || { echo "aborted"; return 1; }
    $COMPOSE down
    sudo ./setup-network.sh
    $COMPOSE_OLD up -d --no-build dev-env
    echo ">> NOTE: anything recompiled inside noble links glibc 2.39 and will not"
    echo ">> run on 22.04 (glibc 2.35). Rebuild those in the old container."
    echo ">> The shebang rewrite is backward compatible - leave it as is."
}

case "${1:-}" in
    preflight) preflight ;;
    shebangs)  shebangs ;;
    cutover)   cutover ;;
    verify)    verify ;;
    rollback)  rollback ;;
    *) sed -n '3,20p' "$0"; exit 1 ;;
esac
