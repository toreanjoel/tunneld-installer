#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit 1
fi

# Confirm uninstall
if ! whiptail --title "Uninstall Tunneld" --yesno "Are you sure you want to completely remove Tunneld?\n\nThis will:\n- Stop all Tunneld services\n- Remove all files and configurations\n- Remove systemd services\n- Delete logs and data\n\nThis action CANNOT be undone!" 16 70; then
  echo "Uninstall cancelled."
  exit 0
fi

echo "Stopping Tunneld services..."

# Stop and disable services
systemctl stop tunneld 2>/dev/null || true
systemctl disable tunneld 2>/dev/null || true

# Stop system services that may have been modified
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop dhcpcd 2>/dev/null || true

echo "Removing systemd service files..."

# Remove systemd services
rm -f /etc/systemd/system/tunneld.service
systemctl daemon-reload

echo "Removing configuration files..."

# Remove configurations
rm -f /etc/dhcpcd.conf
rm -rf /etc/tunneld

echo "Removing application files..."

# Remove application directory
rm -rf /opt/tunneld

echo "Removing data and logs..."

# Remove data and logs
rm -rf /var/lib/tunneld
rm -rf /var/log/tunneld
rm -rf /var/run/tunneld

echo "Reverting IP forwarding..."

# Remove IP forwarding setting from sysctl.conf if it was added by installer
sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf 2>/dev/null || true

# Note: Not disabling IP forwarding in case other services need it
# Note: Not flushing iptables - the application manages those at runtime

# Final confirmation
whiptail --title "Uninstall Complete" --msgbox "Tunneld has been completely removed from your system.

Removed:
- Application files (/opt/tunneld)
- Configuration (/etc/tunneld)
- Logs (/var/log/tunneld)
- Data (/var/lib/tunneld)
- Systemd services

You may want to:
- Restore your original dhcpcd.conf if you had one
- Reconfigure dnsmasq if needed
- Review your network settings

Thank you for trying Tunneld!" 18 70

echo "Tunneld uninstall complete."