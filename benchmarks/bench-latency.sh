#!/bin/bash
# bench-latency.sh - VRAM swap vs NVMe: per-operation latency (ioping, 4K reads)
# NVMe test runs first (no service needed), then VRAM swap is started for the VRAM test.
# State: restores VRAM swap when done; stops service only if this script started it.

set -e
cd "$(dirname "$0")"

VRAM_DEV=$(cat /run/nbd-vram-dev 2>/dev/null || echo "/dev/nbd0")
IOPING_COUNT=20

find_nvme_dir() {
    for d in /home /opt /var/tmp /tmp; do
        [ -d "$d" ] || continue
        df "$d" 2>/dev/null | grep -q nvme && echo "$d" && return
    done
    echo "/tmp"
}

NVME_DIR=$(find_nvme_dir)
NVME_FILE="$NVME_DIR/.nbd-vram-ioping-tmp"
NVME_PART=$(df "$NVME_DIR" --output=source | tail -1)
SERVICE_WAS_RUNNING=0

type_cmd() {
    echo -n "$ "
    printf '%s' "$1" | pv -qL 40
    sleep 0.3
}

run() {
    type_cmd "$*"
    eval "$@"
    sleep 1
}

cleanup() {
    rm -f "$NVME_FILE"
    if ! swapon --show --noheadings | awk '{print $1}' | grep -qxF "$VRAM_DEV"; then
        mkswap "$VRAM_DEV" > /dev/null 2>&1 || true
        swapon "$VRAM_DEV" -p "${VRAM_PRIO:-1500}" 2>/dev/null || true
    fi
    [ "$SERVICE_WAS_RUNNING" = "0" ] && systemctl stop vram-swap-nbd 2>/dev/null || true
}
trap cleanup EXIT

clear
sleep 1

echo "# VRAM swap vs NVMe — per-operation latency (ioping)"
echo "# 4K sequential reads, $IOPING_COUNT requests each"
sleep 1

echo ""
if ! command -v ioping &>/dev/null; then
    run "apt-get install -y ioping"
fi

# ── 1/2  NVMe (no service needed) ───────────────────────────────
echo ""
echo "# ── 1/2  NVMe  ($NVME_PART) ──"
sleep 0.5

# 64 MiB file so ioping doesn't repeatedly hit the same sectors
dd if=/dev/zero of="$NVME_FILE" bs=4k count=16384 &>/dev/null

echo ""
type_cmd "ioping -c $IOPING_COUNT -D $NVME_FILE"
NVME_OUT=$(ioping -c "$IOPING_COUNT" -D "$NVME_FILE" 2>&1)
echo "$NVME_OUT"
NVME_LAT=$(echo "$NVME_OUT" | grep -oP 'min/avg/max/mdev\s*=\s*\K[^\n]+' | head -1)
rm -f "$NVME_FILE"
sleep 1.5

# ── 2/2  VRAM (start service now) ────────────────────────────────
echo ""
echo "# ── 2/2  VRAM — start service ──"
sleep 0.5
if systemctl is-active --quiet vram-swap-nbd; then
    SERVICE_WAS_RUNNING=1
else
    run "sudo systemctl start vram-swap-nbd"
fi
VRAM_DEV=$(cat /run/nbd-vram-dev 2>/dev/null || echo "/dev/nbd0")

VRAM_PRIO=$(swapon --show --noheadings | awk -v dev="$VRAM_DEV" '$1==dev{print $NF}')
VRAM_PRIO="${VRAM_PRIO:-1500}"

echo ""
type_cmd "swapoff $VRAM_DEV"
swapoff "$VRAM_DEV"
sleep 0.5

echo ""
type_cmd "ioping -c $IOPING_COUNT -D $VRAM_DEV"
VRAM_OUT=$(ioping -c "$IOPING_COUNT" -D "$VRAM_DEV" 2>&1)
echo "$VRAM_OUT"
VRAM_LAT=$(echo "$VRAM_OUT" | grep -oP 'min/avg/max/mdev\s*=\s*\K[^\n]+' | head -1)

echo ""
type_cmd "mkswap $VRAM_DEV && swapon $VRAM_DEV -p $VRAM_PRIO"
mkswap "$VRAM_DEV" > /dev/null
swapon "$VRAM_DEV" -p "$VRAM_PRIO"
sleep 1.5

# ── results ──────────────────────────────────────────────────────
echo ""
echo "# ── results (min/avg/max/mdev latency) ────────────"
sleep 0.5
printf "  NVMe (%s):  %s\n" "$NVME_PART" "$NVME_LAT"
printf "  VRAM (%s):  %s\n" "$VRAM_DEV" "$VRAM_LAT"
sleep 1.5

echo ""
echo "# swap restored:"
run "swapon --show"
sleep 5
