#!/usr/bin/env bash
#
# dev-env watchdog: records what the container was doing before it died.
#
# Why this exists: on 2026-10-03 dev-env restarted and the only evidence left
# behind was "supervisord started" with no shutdown message. Everything that
# would have explained it - the pre-death resource trend, the service logs, the
# process list - either lived inside the container (lost on recreate) or was
# never recorded at all. This fixes that.
#
# Two jobs:
#   1. SAMPLER      - every SAMPLE_INTERVAL seconds, append a line of cgroup +
#                     host + container state to a rolling log. This is the
#                     run-up you will want and cannot reconstruct afterwards.
#   2. EVENT WATCH  - tail `docker events`; on die/oom/kill, immediately write a
#                     timestamped incident report AND copy the container's own
#                     logs out to the host before they can be lost.
#
# Install as a systemd service (survives reboots):
#   ./dev-env-watchdog.sh install --yes
# Or run in the foreground to try it:
#   ./dev-env-watchdog.sh run
# Inspect what it has collected:
#   ./dev-env-watchdog.sh status
#   ./dev-env-watchdog.sh incidents

set -uo pipefail

CONTAINER=${CONTAINER:-dev-env}
DIAG_DIR=${DIAG_DIR:-/home/apowers/dev-env-diag}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-10}
# How much sampler history to keep (10s samples: 8640 = ~24h per file)
SAMPLE_ROTATE_LINES=${SAMPLE_ROTATE_LINES:-8640}
SAMPLE_KEEP_FILES=${SAMPLE_KEEP_FILES:-7}
SAMPLE_LOG="$DIAG_DIR/samples.log"
# Host side of the container's /var/log/supervisord bind mount (compose.yml).
HOST_LOG_DIR=${HOST_LOG_DIR:-/home/apowers/dev/logs/supervisord}
UNIT=/etc/systemd/system/dev-env-watchdog.service

mkdir -p "$DIAG_DIR/incidents" 2>/dev/null || true

cgroup_base() {
    local cid
    cid=$(docker inspect "$CONTAINER" --format '{{.Id}}' 2>/dev/null) || return 1
    for b in "/sys/fs/cgroup/system.slice/docker-$cid.scope" "/sys/fs/cgroup/docker/$cid"; do
        [ -d "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}

# Trailing whitespace matters: an untrimmed "101 " fails the ^[0-9]+$ test in
# track_peak and silently disables peak tracking.
read_or_dash() {
    [ -r "$1" ] || { echo "-"; return 0; }
    tr '\n' ' ' < "$1" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# Rolling high-water mark, since this kernel exposes no *.peak files.
track_peak() {
    local key val f old
    key="$1"
    val="$2"
    f="$DIAG_DIR/peaks.$key"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then echo "-"; return 0; fi
    old=0
    if [ -r "$f" ]; then
        old=$(cat "$f" 2>/dev/null)
        [[ "$old" =~ ^[0-9]+$ ]] || old=0
    fi
    if [ "$val" -gt "$old" ]; then
        echo "$val" > "$f" 2>/dev/null
        echo "$val"
    else
        echo "$old"
    fi
}

# One sample line. Deliberately single-line and greppable so you can chart it.
sample_once() {
    local ts base pids_cur pids_peak pids_ev mem_cur mem_peak mem_ev cpu_stat
    ts=$(date -Is)
    base=$(cgroup_base) || { echo "$ts container=absent"; return; }

    pids_cur=$(read_or_dash "$base/pids.current")
    pids_ev=$(read_or_dash "$base/pids.events")
    mem_cur=$(read_or_dash "$base/memory.current")
    # kernel 5.15 has no pids.peak / memory.peak (added in 5.19+/6.x), so the
    # high-water marks are tracked here instead, in $DIAG_DIR/peaks.
    pids_peak=$(track_peak pids "$pids_cur")
    mem_peak=$(track_peak mem "$mem_cur")
    mem_ev=$(read_or_dash "$base/memory.events")
    cpu_stat=$(grep -E "^(usage_usec|nr_throttled|throttled_usec)" "$base/cpu.stat" 2>/dev/null | tr '\n' ' ')

    # GPU trend matters here: this box is used for CUDA/WebGPU work, and a
    # GPU-adjacent problem leaves no trace in the cgroup or host numbers.
    # Captured per-sample (not just at death) so there is a run-up to read.
    local gpu
    gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    [ -n "$gpu" ] || gpu="unavailable"
    local gpu_procs
    gpu_procs=$(nvidia-smi --query-compute-apps=pid,used_memory \
            --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | paste -sd';' -)

    printf '%s pids_current=%s pids_peak=%s pids_events="%s" mem_current=%s mem_peak=%s mem_events="%s" cpu="%s" host_load="%s" host_mem_avail_kb=%s gpu_util_memused_memtotal_temp="%s" gpu_procs="%s"\n' \
        "$ts" "$pids_cur" "$pids_peak" "$pids_ev" "$mem_cur" "$mem_peak" "$mem_ev" \
        "$cpu_stat" "$(cut -d' ' -f1-3 /proc/loadavg)" \
        "$(awk '/MemAvailable/{print $2}' /proc/meminfo)" \
        "$gpu" "${gpu_procs:-none}"
}

rotate_samples() {
    local lines
    lines=$(wc -l < "$SAMPLE_LOG" 2>/dev/null || echo 0)
    [ "$lines" -lt "$SAMPLE_ROTATE_LINES" ] && return 0
    local i
    for ((i=SAMPLE_KEEP_FILES-1; i>=1; i--)); do
        [ -f "$SAMPLE_LOG.$i" ] && mv "$SAMPLE_LOG.$i" "$SAMPLE_LOG.$((i+1))"
    done
    mv "$SAMPLE_LOG" "$SAMPLE_LOG.1"
    rm -f "$SAMPLE_LOG.$((SAMPLE_KEEP_FILES+1))"
}

# Called on a die/oom/kill event. Order matters: grab the volatile things first.
capture_incident() {
    local action="$1"
    local stamp dir
    stamp=$(date +%Y%m%d-%H%M%S)
    dir="$DIAG_DIR/incidents/$stamp-$action"
    mkdir -p "$dir"

    # 1. Container logs, FIRST - these vanish if the container is recreated.
    docker logs "$CONTAINER" --timestamps --tail 2000 > "$dir/container-stdout.log" 2>&1

    # 2. The container's own service logs. Also lost on recreate. The container
    #    is stopped at this point, so `docker cp` (not exec) is the only option -
    #    and cp of the whole /var/log dir fails on a dangling symlink shipped by
    #    systemd, so each file is copied individually.
    mkdir -p "$dir/container-var-log"
    # Primary source: the HOST-side bind mount of /var/log/supervisord. This
    # always works - it cannot race the container going away, and it survives
    # the container being removed entirely (compose down).
    #
    # Learned the hard way: the first live test of this code recovered ZERO
    # logs, because `compose down` removed the container before `docker cp`
    # could read from it. Never rely on the container still existing here.
    if [ -d "$HOST_LOG_DIR" ]; then
        cp -a "$HOST_LOG_DIR/." "$dir/container-var-log/" 2>/dev/null
    fi
    # Fallback for a container built before the log volume existed, or for any
    # log outside /var/log/supervisord. Best-effort: the container may be gone.
    for svc in supervisord vscode jupyter marimo memgraph memgraphlab \
               memgraphdata sshd indexserver; do
        for ext in log error.log; do
            [ -f "$dir/container-var-log/$svc.$ext" ] && continue
            docker cp "$CONTAINER:/var/log/$svc.$ext" \
                "$dir/container-var-log/$svc.$ext" 2>/dev/null
        done
    done
    if [ -z "$(ls -A "$dir/container-var-log" 2>/dev/null)" ]; then
        echo "no service logs recovered: host dir $HOST_LOG_DIR missing/empty and the container was already gone" \
            > "$dir/container-var-log.EMPTY"
    fi

    # 3. Why docker thinks it died.
    docker inspect "$CONTAINER" > "$dir/inspect.json" 2>&1
    docker inspect "$CONTAINER" --format 'Action:       '"$action"'
Status:       {{.State.Status}}
ExitCode:     {{.State.ExitCode}}
OOMKilled:    {{.State.OOMKilled}}
Error:        {{.State.Error}}
StartedAt:    {{.State.StartedAt}}
FinishedAt:   {{.State.FinishedAt}}
RestartCount: {{.RestartCount}}
Image:        {{.Config.Image}}' > "$dir/summary.txt" 2>&1

    # 4. The run-up: the sampler lines leading to the death. This is the part
    #    that is impossible to reconstruct after the fact.
    tail -200 "$SAMPLE_LOG" > "$dir/samples-before-death.log" 2>/dev/null

    # 5. Host side.
    { echo "### free"; free -h
      echo; echo "### loadavg"; cat /proc/loadavg
      echo; echo "### df"; df -h / /var /home
      echo; echo "### host process count"; ls -d /proc/[0-9]* | wc -l
      echo; echo "### top 15 by RSS (host-wide)"
      ps -eo pid,user,rss,pcpu,comm --sort=-rss 2>/dev/null | head -16
    } > "$dir/host-state.txt" 2>&1

    # 6. Kernel + OOM killers. earlyoom is userspace and logs ONLY to the
    #    journal, so it must be captured here or it is invisible later.
    dmesg -T 2>/dev/null | tail -100 > "$dir/dmesg.log" 2>&1 \
        || echo "dmesg needs root; add CAP or run watchdog as root" > "$dir/dmesg.log"
    cid=$(docker inspect "$CONTAINER" --format '{{.Id}}' 2>/dev/null)
    journalctl --since "15 min ago" --no-pager 2>/dev/null \
        | grep -vE "otelcol|netbox|grafana|prometheus|ModemManager" \
        | grep -iE "earlyoom|Out of memory|oom-kill|killed process|Xid|NVRM|\
sigkill|Deactivated successfully|Consumed .* CPU time|shim|${cid:-__none__}|\
\b$CONTAINER\b" \
        | tail -300 > "$dir/journal.log" 2>&1
    # the container's own systemd scope, in full - this is where "Deactivated
    # successfully" and the CPU-time accounting show up
    [ -n "$cid" ] && journalctl --since "15 min ago" --no-pager 2>/dev/null \
        | grep -F "docker-$cid.scope" > "$dir/journal-scope.log" 2>&1

    # 7. GPU - a wedged GPU can take processes with it.
    nvidia-smi > "$dir/nvidia-smi.txt" 2>&1
    cat /proc/driver/nvidia/version > "$dir/nvidia-driver.txt" 2>&1

    ln -sfn "$dir" "$DIAG_DIR/incidents/LATEST"
    logger -t dev-env-watchdog "captured $action incident to $dir"
    echo "[$(date -Is)] $action -> $dir" >> "$DIAG_DIR/incidents.index"
}

run() {
    logger -t dev-env-watchdog "starting (container=$CONTAINER diag=$DIAG_DIR interval=${SAMPLE_INTERVAL}s)"

    # Event watcher in the background; sampler in the foreground.
    #
    # The stream is wrapped in a reconnect loop on purpose. If `docker events`
    # exits (daemon restart, socket blip) the inner `while read` ends, and
    # without this the service would still look "active" from the sampler while
    # having NO incident capture - the worst possible failure for this tool.
    (
        while true; do
            # --since 0s so a watchdog restart does not replay old events
            docker events --since 0s \
                --filter "container=$CONTAINER" \
                --filter 'event=die' --filter 'event=oom' --filter 'event=kill' \
                --format '{{.Action}}' 2>/dev/null |
            while read -r action; do
                [ -n "$action" ] || continue
                # A single stop emits `kill` then `die` seconds apart. Capturing
                # both just duplicates ~1 MB of evidence, so collapse them.
                now=$(date +%s)
                last=0
                [ -r "$DIAG_DIR/.last-capture" ] && last=$(cat "$DIAG_DIR/.last-capture" 2>/dev/null)
                [[ "$last" =~ ^[0-9]+$ ]] || last=0
                if [ $((now - last)) -lt 20 ]; then
                    logger -t dev-env-watchdog "skipping duplicate $action within 20s"
                    continue
                fi
                echo "$now" > "$DIAG_DIR/.last-capture"
                capture_incident "$action"
            done
            logger -t dev-env-watchdog "docker events stream ended; reconnecting in 5s"
            echo "$(date -Is) WARN docker events stream ended; reconnecting" \
                >> "$DIAG_DIR/watchdog.log"
            sleep 5
        done
    ) &
    local watcher=$!
    trap 'kill $watcher 2>/dev/null; exit 0' TERM INT

    while true; do
        sample_once >> "$SAMPLE_LOG"
        rotate_samples
        sleep "$SAMPLE_INTERVAL"
    done
}

install_unit() {
    local self
    self=$(readlink -f "$0")
    cat > /tmp/dev-env-watchdog.service <<UNITEOF
[Unit]
Description=dev-env container watchdog (resource sampler + incident capture)
After=docker.service
Requires=docker.service

[Service]
Type=simple
# root so dmesg and the full journal are readable
User=root
Environment=CONTAINER=$CONTAINER
Environment=DIAG_DIR=$DIAG_DIR
Environment=SAMPLE_INTERVAL=$SAMPLE_INTERVAL
Environment=HOST_LOG_DIR=$HOST_LOG_DIR
ExecStart=$self run
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
UNITEOF
    echo "Unit written to /tmp/dev-env-watchdog.service"
    if [ "${1:-}" != "--yes" ]; then
        echo
        echo "Re-run as '$0 install --yes' to install it, or do it by hand:"
        echo "  sudo cp /tmp/dev-env-watchdog.service $UNIT"
        echo "  sudo systemctl daemon-reload"
        echo "  sudo systemctl enable --now dev-env-watchdog"
        return 0
    fi
    echo ">> installing"
    sudo cp /tmp/dev-env-watchdog.service "$UNIT" || return 1
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable --now dev-env-watchdog || return 1
    echo
    systemctl status dev-env-watchdog --no-pager 2>&1 | head -12
    echo
    echo ">> waiting for the first samples"
    sleep 12
    status
}

status() {
    echo "=== service ==="
    systemctl is-active dev-env-watchdog 2>/dev/null || echo "not installed"
    # The unit being active only proves the sampler loop is alive. Check the
    # event watcher separately - it is the half that catches the crash.
    if pgrep -f "docker events --since 0s --filter container=$CONTAINER" >/dev/null 2>&1; then
        echo "event watcher: running"
    else
        echo "event watcher: NOT RUNNING - incidents would not be captured"
    fi
    if [ -s "$DIAG_DIR/watchdog.log" ]; then
        echo "watchdog warnings:"; tail -3 "$DIAG_DIR/watchdog.log" | sed 's/^/  /'
    fi
    echo
    echo "=== sampler ==="
    if [ -f "$SAMPLE_LOG" ]; then
        echo "  $SAMPLE_LOG ($(wc -l < "$SAMPLE_LOG") samples, $(du -h "$SAMPLE_LOG" | cut -f1))"
        echo "  latest:"
        tail -3 "$SAMPLE_LOG" | sed 's/^/    /'
    else
        echo "  no samples yet"
    fi
    echo
    echo "=== incidents ==="
    if [ -s "$DIAG_DIR/incidents.index" ]; then
        tail -10 "$DIAG_DIR/incidents.index" | sed 's/^/  /'
    else
        echo "  none recorded"
    fi
}

incidents() {
    local latest="$DIAG_DIR/incidents/LATEST"
    [ -e "$latest" ] || { echo "no incidents recorded"; return 1; }
    echo "=== $(readlink -f "$latest") ==="
    cat "$latest/summary.txt" 2>/dev/null
    echo
    echo "=== resource trend before death (last 10 samples) ==="
    tail -10 "$latest/samples-before-death.log" 2>/dev/null | sed 's/^/  /'
    echo
    echo "=== files ==="
    ls -la "$latest" | tail -n +2 | awk '{print "  "$9, $5"b"}'
}

case "${1:-}" in
    run)       run ;;
    install)   install_unit "${2:-}" ;;
    status)    status ;;
    incidents) incidents ;;
    sample)    sample_once ;;
    test)      capture_incident "manual-test"; incidents ;;
    *)
        sed -n '3,25p' "$0"
        echo
        echo "usage: $0 {run|install|status|incidents|sample|test}"
        exit 1
        ;;
esac
