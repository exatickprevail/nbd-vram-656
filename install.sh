#!/bin/bash
# install.sh - Install nbd-vram VRAM swap (CUDA + NBD, no kernel module needed)
# Run once as root. Survives kernel/driver updates automatically.
#
# Architecture:
#   nbd-vram daemon  - allocates VRAM via CUDA, serves NBD protocol on Unix socket
#   nbd kernel module (built-in) + nbd-client - exposes /dev/nbd0 as a block device
#   systemd service  - manages startup, mkswap, swapon/swapoff lifecycle
#
# Why not the vram_swap kernel module?
#   nvidia_p2p_get_pages_persistent is gated on GeForce/consumer GPUs. The P2P
#   API only works on Quadro/datacenter SKUs. This NBD approach works on any
#   CUDA-capable GPU with no NVIDIA kernel symbols or P2P dependency.

set -e
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== nbd-vram installer ==="
echo "Source: $SRC_DIR"

# Stop any running test instance so it doesn't hold VRAM during install
if pgrep -x nbd-vram &>/dev/null; then
    echo "[pre] stopping running nbd-vram instance..."
    bash "$SRC_DIR/nbd-vram-disconnect.sh" 2>/dev/null || true
    pkill -x nbd-vram 2>/dev/null || true
    sleep 1
fi

# Install config if not already present (no-clobber - preserves user edits on reinstall)
if [ ! -f /etc/nbd-vram.conf ]; then
    install -m 644 "$SRC_DIR/nbd-vram.conf" /etc/nbd-vram.conf

    echo ""
    printf "Enable power-aware management? Auto-disable VRAM swap on battery/low power [y/N]: "
    read -r PM_REPLY || PM_REPLY=""
    if [ "$PM_REPLY" = "y" ] || [ "$PM_REPLY" = "Y" ]; then
        sed -i 's/VRAM_POWER_MANAGEMENT=0/VRAM_POWER_MANAGEMENT=1/' /etc/nbd-vram.conf
        printf "Disable when unplugged from AC? [Y/n]: "
        read -r BAT_REPLY || BAT_REPLY=""
        if [ "$BAT_REPLY" = "n" ] || [ "$BAT_REPLY" = "N" ]; then
            sed -i 's/VRAM_DISABLE_ON_BATTERY=1/VRAM_DISABLE_ON_BATTERY=0/' /etc/nbd-vram.conf
            printf "Disable below battery %% (0 = never) [20]: "
            read -r THRESH || THRESH=""
            THRESH=${THRESH:-20}
            sed -i "s/VRAM_BATTERY_THRESHOLD=20/VRAM_BATTERY_THRESHOLD=${THRESH}/" /etc/nbd-vram.conf
        fi
        echo "Power management enabled. Edit /etc/nbd-vram.conf to change settings later."
    else
        echo "Power management left disabled. Edit /etc/nbd-vram.conf to enable later."
    fi
    echo ""
fi

# Ensure nbd-client is installed
echo "[1/4] Checking dependencies..."
if ! command -v nbd-client &>/dev/null; then
    echo "      installing nbd-client..."
    apt-get install -y nbd-client
fi
echo "      OK"

# Build the daemon
echo "[2/4] Building nbd-vram daemon..."
gcc -O2 -Wall -o "$SRC_DIR/nbd-vram" "$SRC_DIR/nbd-vram.c" -ldl
echo "      OK"

# Install binary and service
echo "[3/4] Installing binaries and systemd unit..."
install -m 755 "$SRC_DIR/nbd-vram"                          /usr/local/bin/nbd-vram
install -m 755 "$SRC_DIR/nbd-vram-connect.sh"               /usr/local/bin/nbd-vram-connect.sh
install -m 755 "$SRC_DIR/nbd-vram-disconnect.sh"            /usr/local/bin/nbd-vram-disconnect.sh
install -m 644 "$SRC_DIR/systemd/vram-swap-nbd.service"          /etc/systemd/system/
install -m 755 "$SRC_DIR/nbd-vram-power-check.sh"               /usr/local/bin/nbd-vram-power-check.sh
install -m 644 "$SRC_DIR/systemd/nbd-vram-power-check.service"  /etc/systemd/system/
install -m 644 "$SRC_DIR/systemd/nbd-vram-battery-watch.service" /etc/systemd/system/
install -m 644 "$SRC_DIR/systemd/nbd-vram-battery-watch.timer"  /etc/systemd/system/
mkdir -p /etc/udev/rules.d
install -m 644 "$SRC_DIR/udev/99-nbd-vram-power.rules"          /etc/udev/rules.d/

# Disable old P2P-based services if present
systemctl disable --now vram-setup.service  2>/dev/null || true
systemctl disable --now vram-swapon.service 2>/dev/null || true
systemctl disable --now vram-swap2.service  2>/dev/null || true
echo "      OK"

# Enable and start
echo "[4/4] Enabling vram-swap-nbd.service..."
systemctl daemon-reload
systemctl enable vram-swap-nbd.service
systemctl enable --now nbd-vram-battery-watch.timer
udevadm control --reload-rules
echo "      OK"

echo ""
echo "=== Installation complete ==="
echo ""
echo "To activate NOW (without rebooting):"
echo "  sudo systemctl start vram-swap-nbd.service"
echo ""
echo "To check status:"
echo "  systemctl status vram-swap-nbd"
echo "  swapon --show"
echo "  journalctl -u vram-swap-nbd -n 20"
echo ""
echo "To uninstall:"
echo "  sudo bash uninstall.sh"
