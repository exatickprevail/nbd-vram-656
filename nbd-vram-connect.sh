#!/bin/bash
# nbd-vram-connect.sh - find a free nbd device, connect, activate swap
# Called by vram-swap-nbd.service ExecStartPost after nbd-vram signals ready.
set -e

modprobe nbd max_part=0 2>/dev/null || true

# Find first free /dev/nbdN by checking kernel's pid file for each device
NBD_DEV=""
for dev in /dev/nbd{0..15}; do
    [ -b "$dev" ] || continue
    pid=$(cat "/sys/block/$(basename "$dev")/pid" 2>/dev/null || true)
    if [ -z "$pid" ]; then
        NBD_DEV="$dev"
        break
    fi
done

if [ -z "$NBD_DEV" ]; then
    echo "nbd-vram-connect: no free nbd device found (nbd0-nbd15 all in use)" >&2
    exit 1
fi

echo "nbd-vram-connect: using $NBD_DEV"
nbd-client -unix /run/nbd-vram.sock "$NBD_DEV"
mkswap "$NBD_DEV"
swapon "$NBD_DEV" -p "${VRAM_SWAP_PRIORITY:-1500}"

# Save device name so disconnect script knows what to clean up
echo "$NBD_DEV" > /run/nbd-vram-dev
echo "nbd-vram-connect: swap active on $NBD_DEV"
