#!/bin/bash
# bench-iops.sh - VRAM swap vs NVMe: 4K random IOPS (fio, libaio, iodepth=32)
# NVMe test runs first (no service needed), then VRAM swap is started for the VRAM test.
# State: restores VRAM swap when done; stops service only if this script started it.

set -e
cd "$(dirname "$0")"

VRAM_DEV=$(cat /run/nbd-vram-dev 2>/dev/null || echo "/dev/nbd0")
FIO_SIZE=512m
FIO_RUNTIME=20
FIO_IODEPTH=32

find_nvme_dir() {
    for d in /home /opt /var/tmp /tmp; do
        [ -d "$d" ] || continue
        df "$d" 2>/dev/null | grep -q nvme && echo "$d" && return
    done
    echo "/tmp"
}

NVME_DIR=$(find_nvme_dir)
NVME_FILE="$NVME_DIR/.nbd-vram-fio-tmp"
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

FIO_TMP=$(mktemp)

# Run fio, show live output, capture for parsing
fio_bench() {
    eval "$@" 2>&1 | tee "$FIO_TMP"
}

parse_iops() {
    grep -oP "${1}:.*?IOPS=\K[\d.]+[k]?" "$FIO_TMP" | head -1
}

parse_bw() {
    grep -oP "${1}:.*?BW=\K[^ ,)]+" "$FIO_TMP" | head -1
}

cleanup() {
    rm -f "$NVME_FILE" "$FIO_TMP"
    if ! swapon --show --noheadings | awk '{print $1}' | grep -qxF "$VRAM_DEV"; then
        mkswap "$VRAM_DEV" > /dev/null 2>&1 || true
        swapon "$VRAM_DEV" -p "${VRAM_PRIO:-1500}" 2>/dev/null || true
    fi
    [ "$SERVICE_WAS_RUNNING" = "0" ] && systemctl stop vram-swap-nbd 2>/dev/null || true
}
trap cleanup EXIT

clear
sleep 1

echo "# VRAM swap vs NVMe — 4K random I/O (fio)"
echo "# 4K blocks mirror real swap page size; $FIO_SIZE working set, ${FIO_RUNTIME}s runs"
sleep 1

echo ""
if ! command -v fio &>/dev/null; then
    run "apt-get install -y fio"
fi

# ── 1/2  NVMe (no service needed) ───────────────────────────────
echo ""
echo "# ── 1/2  NVMe  ($NVME_PART) ──"
sleep 0.5

echo ""
type_cmd "fio --name=nvme-rand --filename=$NVME_FILE --ioengine=libaio --direct=1 --rw=randrw --bs=4k --size=$FIO_SIZE --numjobs=1 --iodepth=$FIO_IODEPTH --runtime=$FIO_RUNTIME --time_based --group_reporting"
fio_bench "fio --name=nvme-rand --filename=$NVME_FILE --ioengine=libaio --direct=1 --rw=randrw --bs=4k --size=$FIO_SIZE --numjobs=1 --iodepth=$FIO_IODEPTH --runtime=$FIO_RUNTIME --time_based --group_reporting"
NVME_READ_IOPS=$(parse_iops read)
NVME_WRITE_IOPS=$(parse_iops write)
NVME_READ_BW=$(parse_bw read)
NVME_WRITE_BW=$(parse_bw write)
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
type_cmd "fio --name=vram-rand --filename=$VRAM_DEV --ioengine=libaio --direct=1 --rw=randrw --bs=4k --size=$FIO_SIZE --numjobs=1 --iodepth=$FIO_IODEPTH --runtime=$FIO_RUNTIME --time_based --group_reporting"
fio_bench "fio --name=vram-rand --filename=$VRAM_DEV --ioengine=libaio --direct=1 --rw=randrw --bs=4k --size=$FIO_SIZE --numjobs=1 --iodepth=$FIO_IODEPTH --runtime=$FIO_RUNTIME --time_based --group_reporting"
VRAM_READ_IOPS=$(parse_iops read)
VRAM_WRITE_IOPS=$(parse_iops write)
VRAM_READ_BW=$(parse_bw read)
VRAM_WRITE_BW=$(parse_bw write)

echo ""
type_cmd "mkswap $VRAM_DEV && swapon $VRAM_DEV -p $VRAM_PRIO"
mkswap "$VRAM_DEV" > /dev/null
swapon "$VRAM_DEV" -p "$VRAM_PRIO"
sleep 1.5

# ── results ──────────────────────────────────────────────────────
echo ""
echo "# ── results (4K randrw, iodepth=$FIO_IODEPTH, libaio) ──────────────"
sleep 0.5
printf "  %-14s  read: %-10s %-12s  write: %-10s %s\n" \
    "NVMe" "${NVME_READ_IOPS} IOPS" "$NVME_READ_BW" "${NVME_WRITE_IOPS} IOPS" "$NVME_WRITE_BW"
printf "  %-14s  read: %-10s %-12s  write: %-10s %s\n" \
    "VRAM" "${VRAM_READ_IOPS} IOPS" "$VRAM_READ_BW" "${VRAM_WRITE_IOPS} IOPS" "$VRAM_WRITE_BW"
sleep 1.5

echo ""
echo "# swap restored:"
run "swapon --show"
sleep 5
