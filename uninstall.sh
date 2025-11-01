#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- Prerequisites ---
need_root() { [ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)"; exit 1; }; }
need_root

# Paths
APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUN_DIR="/var/run/tunneld"
DNSCRYPT_BIN="/usr/local/bin/dnscrypt-proxy"

# Intro
whiptail --title "Uninstall Tunneld" --yesno \
"Completely remove Tunneld?

This will:
  1) Stop and disable Tunneld + dnscrypt-proxy
  2) Remove app/config/data/logs
  3) Remove systemd units (tunneld, dnscrypt-proxy, zrok-*)
  4) Remove dnsmasq/dhcpcd symlinks (if pointing to Tunneld)
  5) Remove /usr/local/bin/dnscrypt-proxy

This cannot be undone." 20 76

if [ $? -ne 0 ]; then
  echo "Uninstall cancelled."
  exit 0
fi

# 1) Stop and disable services
echo "Stopping services..."
systemctl stop tunneld 2>/dev/null || true
systemctl disable tunneld 2>/dev/null || true

systemctl stop dnscrypt-proxy 2>/dev/null || true
systemctl disable dnscrypt-proxy 2>/dev/null || true

# Stop zrok share units if any
if ls /etc/systemd/system/zrok-*.service >/dev/null 2>&1 || \
   ls /etc/systemd/system/zrok-access-*.service >/dev/null 2>&1; then
  for u in /etc/systemd/system/zrok-*.service /etc/systemd/system/zrok-access-*.service; do
    [ -e "$u" ] || continue
    bn=$(basename "$u")
    systemctl stop "$bn" 2>/dev/null || true
    systemctl disable "$bn" 2>/dev/null || true
  done
fi

# 2) Remove systemd unit files
echo "Removing systemd unit files..."
rm -f /etc/systemd/system/tunneld.service
rm -f /etc/systemd/system/dnscrypt-proxy.service
rm -f /etc/systemd/system/zrok-*.service /etc/systemd/system/zrok-access-*.service
systemctl daemon-reload || true

# 3) Restore system configs if symlinked
echo "Restoring system configs..."
if [ -L /etc/dhcpcd.conf ]; then
  target=$(readlink -f /etc/dhcpcd.conf || true)
  if [[ "$target" == "$CONFIG_DIR/dhcpcd.conf" ]]; then
    rm -f /etc/dhcpcd.conf
    echo "Removed symlink /etc/dhcpcd.conf"
  fi
fi

if [ -L /etc/dnsmasq.conf ]; then
  target=$(readlink -f /etc/dnsmasq.conf || true)
  if [[ "$target" == "$CONFIG_DIR/dnsmasq.conf" ]]; then
    rm -f /etc/dnsmasq.conf
    echo "Removed symlink /etc/dnsmasq.conf"
  fi
fi

# Restart base services (best effort)
systemctl restart dhcpcd 2>/dev/null || true
systemctl restart dnsmasq 2>/dev/null || true

# 4) Remove dnscrypt binary (installed manually)
if [ -x "$DNSCRYPT_BIN" ]; then
  rm -f "$DNSCRYPT_BIN"
  echo "Removed $DNSCRYPT_BIN"
fi

# 5) Remove app/config/data/logs
echo "Removing Tunneld directories..."
rm -rf "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"

# Finalize
systemctl daemon-reload || true

# Outro
whiptail --title "Uninstall Complete" --msgbox \
"Tunneld has been removed.

Removed:
  - $APP_DIR
  - $CONFIG_DIR
  - $DATA_DIR
  - $LOG_DIR
  - $RUN_DIR
  - /usr/local/bin/dnscrypt-proxy
  - systemd units (tunneld, dnscrypt-proxy, zrok-* / zrok-access-*)

Left untouched unless they pointed to Tunneld:
  - /etc/dnsmasq.conf
  - /etc/dhcpcd.conf

Base services (dhcpcd, dnsmasq) were restarted.
" 20 78

echo "Tunneld uninstall complete."
