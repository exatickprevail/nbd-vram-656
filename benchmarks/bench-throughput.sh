#!/bin/bash
# bench-throughput.sh - VRAM swap vs NVMe: sequential throughput (dd, O_DIRECT)
# State: restores VRAM swap when done; stops service only if this script started it.

set -e
cd "$(dirname "$0")"

VRAM_DEV=$(cat /run/nbd-vram-dev 2>/dev/null || echo "/dev/nbd0")
BENCH_GiB=2
BENCH_COUNT=$(( BENCH_GiB * 256 ))   # 2 GiB at 4M blocks = 512 iterations

# Find a writable directory backed by the NVMe
find_nvme_dir() {
    for d in /home /opt /var/tmp /tmp; do
        [ -d "$d" ] || continue
        df "$d" 2>/dev/null | grep -q nvme && echo "$d" && return
    done
    echo "/tmp"   # fallback
}

NVME_DIR=$(find_nvme_dir)
NVME_FILE="$NVME_DIR/.nbd-vram-bench-tmp"
NVME_PART=$(df "$NVME_DIR" --output=source | tail -1)

# Simulated typing with realistic delay (matches demo.sh)
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

# Run dd, show live progress, and return the final speed string
# Sets global LAST_SPEED after each call
dd_bench() {
    local tmpout
    tmpout=$(mktemp)
    # 2>&1 merges dd's stderr into the pipe so tee shows it live
    eval "$@" 2>&1 | tee "$tmpout"
    LAST_SPEED=$(grep -oP '[\d.]+ [MG]B/s' "$tmpout" | tail -1)
    rm -f "$tmpout"
}

SERVICE_WAS_RUNNING=0

cleanup() {
    rm -f "$NVME_FILE"
    # Restore VRAM swap if we left it off
    if ! swapon --show --noheadings | awk '{print $1}' | grep -qxF "$VRAM_DEV"; then
        mkswap "$VRAM_DEV" > /dev/null 2>&1 || true
        swapon "$VRAM_DEV" -p "${VRAM_PRIO:-1500}" 2>/dev/null || true
    fi
    # Stop service if we started it
    [ "$SERVICE_WAS_RUNNING" = "0" ] && systemctl stop vram-swap-nbd 2>/dev/null || true
}
trap cleanup EXIT

clear
sleep 1

echo "# VRAM swap vs NVMe — ${BENCH_GiB} GiB sequential benchmark (O_DIRECT)"
sleep 1

# ── 1/2  NVMe (no service needed) ───────────────────────────────
echo ""
echo "# ── 1/2  NVMe  ($NVME_PART) ──"
sleep 0.5

echo ""
type_cmd "dd if=/dev/zero of=$NVME_FILE bs=4M count=$BENCH_COUNT oflag=direct conv=fdatasync status=progress"
dd_bench "dd if=/dev/zero of=$NVME_FILE bs=4M count=$BENCH_COUNT oflag=direct conv=fdatasync status=progress"
NVME_WRITE="$LAST_SPEED"
sleep 0.5

echo ""
type_cmd "dd if=$NVME_FILE of=/dev/null bs=4M count=$BENCH_COUNT iflag=direct status=progress"
dd_bench "dd if=$NVME_FILE of=/dev/null bs=4M count=$BENCH_COUNT iflag=direct status=progress"
NVME_READ="$LAST_SPEED"
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
type_cmd "dd if=/dev/zero of=$VRAM_DEV bs=4M count=$BENCH_COUNT oflag=direct status=progress"
dd_bench "dd if=/dev/zero of=$VRAM_DEV bs=4M count=$BENCH_COUNT oflag=direct status=progress"
VRAM_WRITE="$LAST_SPEED"
sleep 0.5

echo ""
type_cmd "dd if=$VRAM_DEV of=/dev/null bs=4M count=$BENCH_COUNT iflag=direct status=progress"
dd_bench "dd if=$VRAM_DEV of=/dev/null bs=4M count=$BENCH_COUNT iflag=direct status=progress"
VRAM_READ="$LAST_SPEED"
sleep 0.5

echo ""
type_cmd "mkswap $VRAM_DEV && swapon $VRAM_DEV -p $VRAM_PRIO"
mkswap "$VRAM_DEV" > /dev/null
swapon "$VRAM_DEV" -p "$VRAM_PRIO"
sleep 1.5

# ── results ──────────────────────────────────────────────────────
echo ""
echo "# ── results ──────────────────────────────────"
sleep 0.5
printf "  %-14s  write: %-12s  read: %s\n" "NVMe ($NVME_PART)" "$NVME_WRITE" "$NVME_READ"
printf "  %-14s  write: %-12s  read: %s\n" "VRAM ($VRAM_DEV)" "$VRAM_WRITE" "$VRAM_READ"
sleep 1.5

echo ""
echo "# swap restored:"
run "swapon --show"
sleep 5
