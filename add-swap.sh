#!/usr/bin/env bash
#
# Increase swap available to dev-env.
#
#   ./add-swap.sh            # show the current picture, change nothing
#   ./add-swap.sh 32G        # add a 32 GiB swap file and raise the container's
#                            # swap allowance to the new host total
#
# Why a NEW file on /var rather than growing /swap.img:
#   /       98 GiB total, ~74 GiB free  <- /swap.img lives here; a large swap
#                                          file would eat the root filesystem
#   /var   3.6 TiB total, ~2.8 TiB free <- plenty of room, same NVMe class
# Both are ext4, so a swap file is fine on either.
#
# The container's swap limit cannot exceed the host's total swap, which is why
# host swap has to grow first. compose.yml's memswap_limit is memory + swap,
# so it is recomputed here and also applied live via `docker update` so no
# container restart is needed.
set -euo pipefail
cd "$(dirname "$0")"

SWAPFILE=${SWAPFILE:-/var/swap2.img}
MEM_LIMIT_GIB=84          # must match mem_limit in compose.yml
CONTAINER=dev-env

human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1"; }

show() {
    echo "=== host swap ==="
    swapon --show 2>/dev/null | sed 's/^/  /' || echo "  none"
    free -h | awk '/Swap:/{print "  total="$2"  used="$3"  free="$4}'
    echo
    echo "=== vm.swappiness ==="
    local sw; sw=$(cat /proc/sys/vm/swappiness)
    echo "  $sw"
    if [ "$sw" -le 10 ]; then
        echo "  NOTE: at swappiness=$sw the kernel avoids swapping almost entirely."
        echo "  More swap is then emergency headroom only - it will not change"
        echo "  day-to-day behaviour. Raising swappiness is a separate decision."
    fi
    echo
    echo "=== dev-env ==="
    local cid b
    cid=$(docker inspect "$CONTAINER" --format '{{.Id}}' 2>/dev/null) || { echo "  not running"; return 0; }
    for c in /sys/fs/cgroup/system.slice/docker-$cid.scope /sys/fs/cgroup/docker/$cid; do
        [ -d "$c" ] && b=$c && break
    done
    [ -n "${b:-}" ] || { echo "  cgroup not found"; return 0; }
    echo "  memory.max          $(human "$(cat $b/memory.max)")"
    echo "  memory.swap.max     $(human "$(cat $b/memory.swap.max)")"
    echo "  memory.swap.current $(human "$(cat $b/memory.swap.current)")"
    awk '/^anon /{printf "  anon (real)         %.1f GiB\n", $2/1073741824}' "$b/memory.stat"
    echo "  memory.events       $(tr '\n' ' ' < $b/memory.events)"
    echo
    echo "  Read this before adding swap: if anon is far below memory.max,"
    echo "  swap.current is 0 and memory.events are all 0, then swap is NOT"
    echo "  currently a constraint. Adding it is insurance, not a fix."
}

add() {
    local size="$1"
    local bytes
    bytes=$(numfmt --from=iec "${size}" 2>/dev/null) || {
        echo "bad size '$size' - use e.g. 16G, 32G, 64G"; exit 1; }

    if [ -e "$SWAPFILE" ]; then
        echo "!! $SWAPFILE already exists. Remove it first:"
        echo "     sudo swapoff $SWAPFILE && sudo rm $SWAPFILE"
        echo "   and delete its line from /etc/fstab."
        exit 1
    fi

    local avail_kb avail_bytes
    avail_kb=$(df -k --output=avail "$(dirname "$SWAPFILE")" | tail -1 | tr -d ' ')
    avail_bytes=$((avail_kb * 1024))
    if [ "$bytes" -gt $((avail_bytes - 10737418240)) ]; then
        echo "!! $size would leave under 10 GiB free on $(dirname "$SWAPFILE")"
        echo "   available: $(human "$avail_bytes")"
        exit 1
    fi

    echo ">> creating $SWAPFILE ($size)"
    sudo fallocate -l "$bytes" "$SWAPFILE" 2>/dev/null \
        || sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((bytes / 1048576)) status=progress
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"

    if ! grep -qF "$SWAPFILE" /etc/fstab; then
        echo ">> adding to /etc/fstab so it survives reboot"
        echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi

    # Recompute the container's allowance from the ACTUAL host swap total, so
    # this stays correct whatever size was chosen.
    local swap_total_bytes swap_total_gib new_memswap_gib
    swap_total_bytes=$(free -b | awk '/Swap:/{print $2}')
    swap_total_gib=$((swap_total_bytes / 1073741824))
    new_memswap_gib=$((MEM_LIMIT_GIB + swap_total_gib))

    echo
    echo ">> host swap total is now ${swap_total_gib} GiB"
    echo ">> setting dev-env memswap_limit to ${new_memswap_gib}g (${MEM_LIMIT_GIB}g memory + ${swap_total_gib}g swap)"

    # Persist for future `make start`
    if grep -q "memswap_limit:" compose.yml; then
        sed -i "s/^\( *memswap_limit:\).*/\1 ${new_memswap_gib}g/" compose.yml
        echo "   compose.yml updated: $(grep 'memswap_limit:' compose.yml | tr -d ' ')"
    else
        echo "   !! memswap_limit not found in compose.yml - add it by hand"
    fi

    # Apply live so no restart is needed. Docker requires --memory alongside
    # --memory-swap.
    if sudo docker update --memory "${MEM_LIMIT_GIB}g" \
            --memory-swap "${new_memswap_gib}g" "$CONTAINER" >/dev/null 2>&1; then
        echo "   applied live to the running container (no restart needed)"
    else
        echo "   could not apply live; it will take effect on the next 'make start'"
    fi

    echo
    show
}

case "${1:-}" in
    "")  show ;;
    *)   add "$1" ;;
esac
