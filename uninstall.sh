#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

need_root() { [ "$EUID" -eq 0 ] || { echo "Please run as root (sudo)"; exit 1; }; }
need_root

APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUN_DIR="/var/run/tunneld"
DNSCRYPT_BIN="/usr/local/bin/dnscrypt-proxy"

whiptail --title "Uninstall Tunneld (Pre-Alpha)" --yesno \
"Completely remove Tunneld and its pre-alpha files?

This will:
  1) Stop and disable Tunneld + dnscrypt-proxy
  2) Remove app/config/data/logs
  3) Remove systemd units (tunneld, dnscrypt-proxy, zrok-*)
  4) Remove dnsmasq/dhcpcd symlinks (if pointing to Tunneld)
  5) Remove /usr/local/bin/dnscrypt-proxy

Important:
  - This uninstaller NEVER removes system packages installed via apt
    (e.g. dnsmasq, dhcpcd, iptables, fake-hwclock, etc.).
  - If you no longer need those packages, please remove them manually
    with apt (e.g. 'sudo apt-get purge dnsmasq dhcpcd').

This cannot be undone." 24 80

if [ $? -ne 0 ]; then
  echo "Uninstall cancelled."
  exit 0
fi

echo "Stopping services..."
systemctl stop tunneld 2>/dev/null || true
systemctl disable tunneld 2>/dev/null || true

systemctl stop dnscrypt-proxy 2>/dev/null || true
systemctl disable dnscrypt-proxy 2>/dev/null || true

if ls /etc/systemd/system/zrok-*.service >/dev/null 2>&1 || \
   ls /etc/systemd/system/zrok-access-*.service >/dev/null 2>&1; then
  for u in /etc/systemd/system/zrok-*.service /etc/systemd/system/zrok-access-*.service; do
    [ -e "$u" ] || continue
    bn=$(basename "$u")
    systemctl stop "$bn" 2>/dev/null || true
    systemctl disable "$bn" 2>/dev/null || true
  done
fi

echo "Removing systemd unit files..."
rm -f /etc/systemd/system/tunneld.service
rm -f /etc/systemd/system/dnscrypt-proxy.service
rm -f /etc/systemd/system/zrok-*.service /etc/systemd/system/zrok-access-*.service
systemctl daemon-reload || true

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

systemctl restart dhcpcd 2>/dev/null || true
systemctl restart dnsmasq 2>/dev/null || true

if [ -x "$DNSCRYPT_BIN" ]; then
  rm -f "$DNSCRYPT_BIN"
  echo "Removed $DNSCRYPT_BIN"
fi

echo "Removing Tunneld directories..."
rm -rf "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"

systemctl daemon-reload || true

whiptail --title "Uninstall Complete" --msgbox \
"Tunneld (pre-alpha) has been removed.

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

Note:
  - System packages installed as dependencies (dnsmasq, dhcpcd, iptables,
    fake-hwclock, etc.) were NOT removed.
  - The Tunneld uninstaller never removes OS packages.
    If you want to remove them, use e.g.:
      sudo apt-get purge dnsmasq dhcpcd iptables fake-hwclock

Base services (dhcpcd, dnsmasq) were restarted.
" 24 84

echo "Tunneld uninstall complete."
