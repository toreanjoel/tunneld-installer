#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then echo "Please run as root (sudo)"; exit 1; fi

if ! whiptail --title "Uninstall Tunneld" --yesno "Completely remove Tunneld?\n\nThis will stop services and delete:\n- /opt/tunneld\n- /etc/tunneld\n- /var/lib/tunneld\n- /var/log/tunneld\n- systemd units (tunneld and zrok units)\n\nThis cannot be undone." 16 72; then
  echo "Uninstall cancelled."
  exit 0
fi

APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUN_DIR="/var/run/tunneld"
BLACKLIST_DIR="$CONFIG_DIR/blacklists"
DNSCRYPT_DIR="$CONFIG_DIR/dnscrypt"

echo "Stopping services..."
systemctl stop tunneld 2>/dev/null || true
systemctl disable tunneld 2>/dev/null || true

# Stop/disable any zrok units created by Tunneld
if ls /etc/systemd/system/zrok-*.service >/dev/null 2>&1 || ls /etc/systemd/system/zrok-access-*.service >/dev/null 2>&1; then
  for u in /etc/systemd/system/zrok-*.service /etc/systemd/system/zrok-access-*.service; do
    [ -e "$u" ] || continue
    bn=$(basename "$u")
    systemctl stop "$bn" 2>/dev/null || true
    systemctl disable "$bn" 2>/dev/null || true
  done
fi

echo "Removing systemd unit files..."
rm -f /etc/systemd/system/tunneld.service
# Remove zrok units we just disabled
rm -f /etc/systemd/system/zrok-*.service /etc/systemd/system/zrok-access-*.service
systemctl daemon-reload

# Restore dnscrypt-proxy to packaged defaults if we overrode it
if [ -f /etc/systemd/system/dnscrypt-proxy.service.d/override.conf ]; then
  rm -f /etc/systemd/system/dnscrypt-proxy.service.d/override.conf
  rmdir /etc/systemd/system/dnscrypt-proxy.service.d 2>/dev/null || true
  systemctl daemon-reload
  systemctl restart dnscrypt-proxy 2>/dev/null || true
fi

# Only remove dnsmasq.conf if it's pointing to our config
if [ -L /etc/dnsmasq.conf ]; then
  target=$(readlink -f /etc/dnsmasq.conf || true)
  if [[ "$target" == "$CONFIG_DIR/dnsmasq.conf" ]]; then
    rm -f /etc/dnsmasq.conf
    # Package default may be empty; restart to re-read defaults
    systemctl restart dnsmasq 2>/dev/null || true
  fi
fi

# Only remove dhcpcd.conf if it's pointing to our config
if [ -L /etc/dhcpcd.conf ]; then
  target=$(readlink -f /etc/dhcpcd.conf || true)
  if [[ "$target" == "$CONFIG_DIR/dhcpcd.conf" ]]; then
    rm -f /etc/dhcpcd.conf
    systemctl restart dhcpcd 2>/dev/null || true
  fi
fi

echo "Removing application/config/data/logs..."
rm -rf "$APP_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"

echo "Cleaning sysctl IP forwarding line..."
sed -i '/^net\.ipv4\.ip_forward=1$/d' /etc/sysctl.conf 2>/dev/null || true
# Do not toggle live ip_forward as other services may rely on it

echo "Finalizing..."
systemctl daemon-reload

whiptail --title "Uninstall Complete" --msgbox "Tunneld has been removed.

Removed:
- $APP_DIR
- $CONFIG_DIR
- $DATA_DIR
- $LOG_DIR
- systemd units (tunneld, zrok-* / zrok-access-* if present)

Left untouched unless they pointed to Tunneld:
- /etc/dnsmasq.conf
- /etc/dhcpcd.conf

dnscrypt-proxy override removed and service restarted (if present).
" 18 76

echo "Tunneld uninstall complete."
