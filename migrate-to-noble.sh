#!/usr/bin/env bash
#
# dev-env operations. NOT RUN AUTOMATICALLY - every phase needs an explicit
# argument.
#
# HISTORICAL NOTE: the 24.04 migration is COMPLETE as of 2026-10-03. Ubuntu
# 24.04 is now the default (./Dockerfile + compose.yml), and 22.04 is the
# rollback (./Dockerfile.jammy + compose.jammy.yml). The `cutover` phase is
# kept for reference but is a no-op now; `verify`, `rollback` and `nogpu`
# remain useful. Everyday commands live in the Makefile: make start / stop /
# check / rollback / verify / nogpu.
#
#   ./migrate-to-noble.sh preflight   # read-only. changes nothing. run this first.
#   ./migrate-to-noble.sh shebangs    # OPTIONAL: rewrite 136 ~/.local/bin shebangs
#   ./migrate-to-noble.sh cutover     # STOPS dev-env, fixes driver, starts noble
#   ./migrate-to-noble.sh verify      # check a running dev-env
#   ./migrate-to-noble.sh nogpu       # EMERGENCY: start 22.04 with no GPU
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

NOBLE=apowers313/roc-dev:3.0.0
OLD=apowers313/roc-dev:2.0.0
# noble is the default now, so it needs no override; 22.04 is the override.
COMPOSE="docker compose --env-file .env"
COMPOSE_OLD="docker compose -f compose.yml -f compose.jammy.yml --env-file .env"

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
    if [ "${1:-}" != "--yes" ]; then
        read -rp "   continue? [y/N] " a 2>/dev/null \
            || { echo "   re-run as: $0 shebangs --yes"; return 1; }
        [ "${a,,}" = "y" ] || { echo "aborted"; return 1; }
    fi
    docker run --rm -v /home/apowers/dev:/home/apowers "$NOBLE" fix-home-shebangs --apply
}

# Bring dev-env back on the OLD 22.04 image. Used when the cutover cannot
# proceed, so a failure never leaves the host with no dev environment.
restore_old() {
    echo
    echo ">> RESTORING dev-env on the 22.04 image so you are not left without one"
    sudo ./setup-network.sh || true
    if ! $COMPOSE_OLD up -d --no-build dev-env; then
        echo "   !! restore FAILED - almost certainly the driver mismatch, since"
        echo "      compose.yml reserves a GPU and nvidia-container-cli refuses."
        echo "      You now have NO dev environment. Pick one:"
        echo "        ./fix-nvidia-driver.sh reboot        # fixes the driver properly"
        echo "        ./migrate-to-noble.sh nogpu          # start 22.04 WITHOUT a GPU"
        return 1
    fi
    echo ">> dev-env is back on 22.04."
    echo "   NOTE: if the nvidia modules were unloaded but not reloaded, this"
    echo "   container has NO GPU. Reboot to get a consistent driver stack."
}

cutover() {
    echo ">> NOTE: the migration is already done - 24.04 is the default."
    echo ">> This phase is kept for reference. To (re)start dev-env on the"
    echo ">> default image, just use: make start"
    echo
    echo ">> Checks the nvidia driver, then stops dev-env and brings it back"
    echo ">> up on $NOBLE."
    echo ">> Nothing is stopped until a GPU container is proven to start, and"
    echo ">> if the noble container fails, dev-env is restored on 22.04."
    if [ "${1:-}" = "--yes" ]; then
        echo ">> (--yes given, proceeding without prompting)"
    else
        read -rp "   Type CUTOVER to continue: " a 2>/dev/null \
            || { echo "   no interactive input available - re-run as: $0 cutover --yes"; return 1; }
        [ "$a" = "CUTOVER" ] || { echo "aborted"; return 1; }
    fi

    # Driver health is checked BEFORE anything is stopped. A mismatch blocks
    # BOTH the cutover and the rollback (compose.yml reserves a GPU), so
    # stopping dev-env first would leave no dev environment at all - which is
    # exactly what happened on the first attempt.
    loaded=$(sed -n 's/.*Kernel Module *\([0-9.]*\).*/\1/p' /proc/driver/nvidia/version)
    userspace=$(ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*.*.* 2>/dev/null \
        | sed 's/.*so\.//' | head -1)
    echo ">> nvidia: loaded module=$loaded  userspace=$userspace"
    if [ -z "$loaded" ]; then
        echo "   !! no nvidia module loaded at all. Reboot first."
        return 1
    fi
    if [ "$loaded" = "$userspace" ]; then
        echo ">> driver is consistent - no module work needed"
        skip_reload=1
    else
        echo "   !! DRIVER MISMATCH, and nothing has been stopped yet."
        echo "      A new GPU container cannot start until this is fixed, so"
        echo "      stopping dev-env now would leave you with NO dev environment."
        echo "      Fix it first:  ./fix-nvidia-driver.sh reboot --yes"
        echo "      (Only after a reboot fails to help is a module reload worth"
        echo "       trying - a stuck refcount will not clear by retrying.)"
        return 1
    fi

    echo ">> verifying a GPU container can start BEFORE touching dev-env"
    # --privileged matters: /etc/nvidia-container-runtime/config.toml has
    # no-cgroups = true, so nvidia-container-cli does not grant device access
    # via cgroups. compose.yml sets privileged: true, which is why dev-env
    # works. Without it this check fails with "NVML: Unknown Error" even when
    # the driver is perfectly healthy - a false alarm, not a real problem.
    if ! docker run --rm --gpus all --privileged "$NOBLE" nvidia-smi \
            --query-gpu=name,driver_version --format=csv,noheader; then
        echo "   !! a GPU container still cannot start. Nothing has been stopped."
        echo "      Reboot, or run without a GPU: ./migrate-to-noble.sh nogpu"
        return 1
    fi

    echo ">> stopping dev-env"
    $COMPOSE_OLD down

    echo ">> setting up the macvlan loopback"
    sudo ./setup-network.sh

    echo ">> starting dev-env on the noble image (no --build: use what was tested)"
    if ! $COMPOSE up -d --no-build dev-env; then
        echo "   !! noble container failed to start."
        $COMPOSE down || true
        restore_old
        return 1
    fi

    echo ">> waiting for supervisord to bring the services up"
    sleep 20
    verify
}

verify() {
    echo "== supervisord process states =="
    # supervisorctl needs [rpcinterface:supervisor]; containers built before
    # that was added fall back to scraping the web UI, which always works.
    docker exec dev-env supervisorctl -s http://localhost:8001 status 2>/dev/null \
        || docker exec dev-env bash -c "curl -s http://localhost:8001/ \
             | grep -oE 'status(Running|Error|Stopped)[^<]*</span>[^<]*<[^>]*>[a-z]+' \
             | sed 's/<[^>]*>/ /g'" 2>/dev/null \
        || echo "   (could not read supervisord state)"
    echo "== non-empty service error logs =="
    docker exec dev-env bash -c 'for f in /var/log/*.error.log; do \
        s=$(stat -c%s "$f"); [ "$s" -gt 0 ] && echo "   $(basename $f) ${s}b"; done; true' 2>/dev/null
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
    if [ "${1:-}" != "--yes" ]; then
        read -rp "   continue? [y/N] " a 2>/dev/null \
            || { echo "   re-run as: $0 rollback --yes"; return 1; }
        [ "${a,,}" = "y" ] || { echo "aborted"; return 1; }
    fi
    $COMPOSE down
    sudo ./setup-network.sh
    $COMPOSE_OLD up -d --no-build dev-env
    echo ">> NOTE: anything recompiled inside noble links glibc 2.39 and will not"
    echo ">> run on 22.04 (glibc 2.35). Rebuild those in the old container."
    echo ">> The shebang rewrite is backward compatible - leave it as is."
}

# Emergency: start dev-env with the GPU reservation stripped out, so a broken
# host driver does not leave you without a dev environment. No CUDA, but
# everything else (code-server, jupyter, memgraph, shells) works.
nogpu() {
    echo ">> starting dev-env on 22.04 with NO GPU (driver is mismatched)"
    sudo ./setup-network.sh || true
    docker compose -f compose.yml -f compose.nogpu.yml --env-file .env \
        up -d --no-build dev-env
    echo ">> up without a GPU. After fixing the driver, return to normal with:"
    echo "     docker compose --env-file .env up -d --force-recreate --no-build dev-env"
}

case "${1:-}" in
    preflight) preflight ;;
    nogpu)     nogpu ;;
    shebangs)  shebangs "${2:-}" ;;
    cutover)   cutover "${2:-}" ;;
    verify)    verify ;;
    rollback)  rollback "${2:-}" ;;
    *) sed -n '3,20p' "$0"; exit 1 ;;
esac
