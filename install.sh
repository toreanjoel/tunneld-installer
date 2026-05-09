#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

need_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }; }
need_debian() { command -v apt-get >/dev/null 2>&1 || { echo "Debian-based OS required"; exit 1; }; }
need_root; need_debian

# Detect Real User for Permissions
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$(id -un)"
fi
REAL_GROUP="$(id -gn "$REAL_USER")"

APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUNTIME_DIR="/var/run/tunneld"
BACKUP_DIR="$DATA_DIR/backup"
BACKUP_FILE="$BACKUP_DIR/tunneld-backup.tar.gz"

mkdir -p "$APP_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$RUNTIME_DIR"

UP_IFACE="${UP_IFACE:-}"
DOWN_IFACE="${DOWN_IFACE:-}"
GATEWAY="${GATEWAY:-10.0.0.1}"
DHCP_START="${DHCP_START:-10.0.0.2}"
DHCP_END="${DHCP_END:-10.0.0.100}"
DEVICE_ID="${DEVICE_ID:-$(cat /proc/sys/kernel/random/uuid)}"
TUNNELD_VERSION="${TUNNELD_VERSION:-}"

whiptail --title "Tunneld Installer" --msgbox \
"Tunneld is a portable, wireless-first programmable gateway.

This wizard will:
  1) Install dependencies
  2) Configure network (upstream/downstream, DHCP)
  3) (Optional) Download a Tunneld pre-alpha release
  4) Enable & start services

If an existing installation is found, a backup will be created
before updating. If the new version fails to start, it will be
automatically rolled back to the previous version.

Important:
  - The Tunneld uninstaller will remove Tunneld itself, its configs,
    logs and systemd units.
  - It will NOT remove system packages installed as dependencies.

Press OK to begin." 26 80

whiptail --title "Step 1/4: Dependencies" --msgbox "We will install: Zrok2, OpenZiti, dnsmasq, dhcpcd, nginx, git, dkms, build-essential, libjson-c-dev, libwebsockets-dev, libssl-dev, iptables, iproute2, bc, unzip, iw, systemd-timesyncd, zram-tools, openssl, wireguard-tools" 10 74

systemctl unmask systemd-time-wait-sync.service 2>/dev/null || true
systemctl unmask dhcpcd.service 2>/dev/null || true
systemctl unmask dnsmasq.service 2>/dev/null || true

# Free wlan from other network managers; Tunneld owns the stack.
for svc in NetworkManager NetworkManager-wait-online iwd systemd-networkd wpa_supplicant.service; do
  systemctl disable --now "$svc" 2>/dev/null || true
  systemctl mask "$svc" 2>/dev/null || true
done

apt-get update
apt-get install dnsmasq dhcpcd nginx git dkms build-essential libjson-c-dev libwebsockets-dev libssl-dev iptables iproute2 bc unzip iw systemd-timesyncd zram-tools openssl wireguard-tools wpasupplicant rfkill -y

rfkill unblock wifi || true

# Verify WireGuard kernel module is available (built-in on kernel 5.6+, DKMS fallback)
if ! modprobe -n wireguard 2>/dev/null; then
  echo "WireGuard kernel module not found, installing wireguard-dkms..."
  apt-get install -y wireguard-dkms || whiptail --title "WireGuard Warning" --msgbox \
    "WireGuard kernel module not detected and DKMS install failed.\n\nMesh networking features may not work. Ensure your kernel is 5.6+ or\ninstall wireguard-dkms manually." 12 70
fi
timedatectl set-ntp true
systemctl enable --now systemd-timesyncd.service
systemctl enable --now systemd-time-wait-sync.service

# Configure Zram & Swappiness
cat > /etc/default/zramswap <<EOF
ALGO=lz4
PERCENTAGE=50
PRIORITY=100
EOF
if ! grep -q "vm.swappiness=150" /etc/sysctl.conf; then
  echo "vm.swappiness=150" >> /etc/sysctl.conf
fi
sysctl -p || true
systemctl restart zramswap || true

# Prepare nginx
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
rm -f /etc/nginx/sites-enabled/default
systemctl enable --now nginx

# Warn if zrok v1 is installed
if command -v zrok >/dev/null 2>&1 && ! command -v zrok2 >/dev/null 2>&1; then
  whiptail --title "Zrok v1 Detected" --msgbox \
"WARNING: zrok v1 is installed on this system.
Tunneld now requires zrok2 (v2). The old zrok v1
package will NOT be removed automatically.

After installation, you may remove v1 manually:
  sudo apt-get purge zrok zrok-agent

Config migration (~/.zrok → ~/.zrok2) is also
your responsibility if needed." 14 60
fi

# Install Zrok2
curl -sSf https://get.openziti.io/install.bash | sudo bash -s zrok2

mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|zt|tun|wg)')
if [ ${#ifaces[@]} -eq 0 ]; then whiptail --msgbox "No interfaces found." 8 50; exit 1; fi

menu_items=(); for i in "${ifaces[@]}"; do menu_items+=("$i" ""); done
UP_IFACE=$(whiptail --title "Step 2/4: Upstream (Internet)" --menu "Select upstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1
menu_items=(); for i in "${ifaces[@]}"; do [ "$i" != "$UP_IFACE" ] && menu_items+=("$i" ""); done
DOWN_IFACE=$(whiptail --title "Step 2/4: Downstream (LAN)" --menu "Select downstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1

GATEWAY=$(whiptail --title "Gateway IP" --inputbox "Gateway IP (CIDR /24 assumed)" 10 60 "$GATEWAY" 3>&1 1>&2 2>&3) || exit 1
DHCP_START=$(whiptail --title "DHCP Start" --inputbox "Start address" 10 60 "$DHCP_START" 3>&1 1>&2 2>&3) || exit 1
DHCP_END=$(whiptail --title "DHCP End" --inputbox "End address" 10 60 "$DHCP_END" 3>&1 1>&2 2>&3) || exit 1
WIFI_COUNTRY=$(whiptail --title "Wi-Fi Country / Regulatory Domain" --inputbox "Enter the 2-letter country code (example: US, ZA, DE, UK)." 12 72 "" 3>&1 1>&2 2>&3) || exit 1

if [ -n "$UP_IFACE" ]; then
  if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    cat > /etc/wpa_supplicant/wpa_supplicant.conf <<EOF
country=$WIFI_COUNTRY
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
EOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
  fi

  ln -sf /etc/wpa_supplicant/wpa_supplicant.conf \
         "/etc/wpa_supplicant/wpa_supplicant-${UP_IFACE}.conf"

  systemctl unmask "wpa_supplicant@${UP_IFACE}.service" 2>/dev/null || true
  systemctl enable --now "wpa_supplicant@${UP_IFACE}.service"
fi

cat > "$CONFIG_DIR/interfaces.conf" <<EOF
UPSTREAM_INTERFACE=$UP_IFACE
DOWNSTREAM_INTERFACE=$DOWN_IFACE
GATEWAY_IP=$GATEWAY
DHCP_START=$DHCP_START
DHCP_END=$DHCP_END
DEVICE_ID=$DEVICE_ID
EOF

cat > "$CONFIG_DIR/dhcpcd.conf" <<EOF
interface $DOWN_IFACE
static ip_address=${GATEWAY}/24
nohook wpa_supplicant
metric 250

interface $UP_IFACE
nohook wpa_supplicant
metric 100
EOF
ln -sf "$CONFIG_DIR/dhcpcd.conf" /etc/dhcpcd.conf
whiptail --title "Step 2/4" --msgbox "Network settings saved." 8 60

cat > "$CONFIG_DIR/dnsmasq.conf" <<EOF
port=5336
interface=$DOWN_IFACE
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,infinite
dhcp-option=option:router,$GATEWAY
dhcp-option=option:dns-server,$GATEWAY
no-resolv
EOF
ln -sf "$CONFIG_DIR/dnsmasq.conf" /etc/dnsmasq.conf

# Create extra dnsmasq resource config
mkdir -p /etc/dnsmasq.d
touch /etc/dnsmasq.d/tunneld_resources.conf
chown "$REAL_USER:$REAL_GROUP" /etc/dnsmasq.d/tunneld_resources.conf

# Default DNS server — managed by the Tunneld app at runtime
echo "server=1.1.1.1" > /etc/dnsmasq.d/tunneld_dns.conf

# --- Backup existing installation ---
if [ -d "$APP_DIR/bin" ] && [ -x "$APP_DIR/bin/tunneld" ]; then
  mkdir -p "$BACKUP_DIR"
  rm -f "$BACKUP_FILE"
  if tar -czf "$BACKUP_FILE" -C /opt tunneld 2>/dev/null; then
    whiptail --title "Backup" --msgbox "Existing Tunneld installation backed up.\n\nBackup: $BACKUP_FILE" 10 60
  else
    rm -f "$BACKUP_FILE"
    whiptail --title "Backup Failed" --msgbox "Could not back up existing installation.\n\nIf the update fails, manual recovery will be needed." 10 60
  fi
fi

if whiptail --title "Step 3/4: Tunneld Release" --yesno "Download and install pre-alpha build?" 10 60; then
  tmpdir=$(mktemp -d)
  beta_url="https://raw.githubusercontent.com/toreanjoel/tunneld-installer/refs/heads/main/releases/tunneld-pre-alpha.tar.gz"
  sums_url="https://raw.githubusercontent.com/toreanjoel/tunneld-installer/refs/heads/main/releases/checksums.txt"

  curl -fL "$beta_url" -o "$tmpdir/tunneld-pre-alpha.tar.gz"
  curl -fsSL "$sums_url" -o "$tmpdir/checksums.txt"

  # Verify checksum
  if [ -f "$tmpdir/checksums.txt" ]; then
    EXPECTED_SHA=$(awk '{print $1}' "$tmpdir/checksums.txt")
    ACTUAL_SHA=$(sha256sum "$tmpdir/tunneld-pre-alpha.tar.gz" | awk '{print $1}')
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
      rm -rf "$tmpdir"
      whiptail --title "Checksum Failed" --msgbox \
"Download checksum verification failed.

Expected: $EXPECTED_SHA
Actual:   $ACTUAL_SHA

The download may be corrupted. Please try again or
report this issue at:
https://github.com/toreanjoel/tunneld-installer/issues" 14 70
      exit 1
    fi
  fi

  tar -xzf "$tmpdir/tunneld-pre-alpha.tar.gz" -C "$APP_DIR"
  rm -rf "$tmpdir"
  whiptail --msgbox "Tunneld files installed." 8 60
else
  whiptail --msgbox "Skipping download." 8 60
fi

SECRET_KEY_BASE=$(openssl rand -hex 64)
cat > /etc/systemd/system/tunneld.service <<EOF
[Unit]
Description=Tunneld
After=network-online.target dhcpcd.service wpa_supplicant@${UP_IFACE}.service
Wants=network-online.target dhcpcd.service wpa_supplicant@${UP_IFACE}.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=PHX_SERVER=true
Environment=PORT=80
Environment=SECRET_KEY_BASE=$SECRET_KEY_BASE
Environment=WIFI_INTERFACE=$UP_IFACE
Environment=LAN_INTERFACE=$DOWN_IFACE
Environment=GATEWAY=$GATEWAY
Environment=TUNNELD_DATA=$DATA_DIR
Environment=WIFI_COUNTRY=$WIFI_COUNTRY
Environment=DEVICE_ID=$DEVICE_ID
Environment=DNS_CLUSTER_QUERY=
Environment="ERL_FLAGS=-os_mon system_memory_high_watermark 0.15"
ExecStart=$APP_DIR/bin/tunneld start
ExecStop=$APP_DIR/bin/tunneld stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dhcpcd dnsmasq nginx tunneld zramswap
systemctl restart nginx
systemctl restart dhcpcd
systemctl restart dnsmasq
systemctl restart zramswap
systemctl restart tunneld

# --- Verify tunneld service started ---
VERIFY_TIMEOUT=60
VERIFY_INTERVAL=5
ELAPSED=0
SERVICE_OK=false

while [ $ELAPSED -lt $VERIFY_TIMEOUT ]; do
  if systemctl is-active --quiet tunneld 2>/dev/null; then
    SERVICE_OK=true
    break
  fi
  sleep $VERIFY_INTERVAL
  ELAPSED=$((ELAPSED + VERIFY_INTERVAL))
done

if [ "$SERVICE_OK" = true ]; then
  # Clean up backup on success
  rm -f "$BACKUP_FILE"

  whiptail --title "Installation Complete" --msgbox \
"Tunneld installation complete.

App:    $APP_DIR
Config: $CONFIG_DIR
Data:   $DATA_DIR

Access:
  http://$GATEWAY

Services verified.
Done." 24 80
else
  # Service failed to start
  JOURNAL_OUTPUT=$(journalctl -u tunneld --no-pager -n 20 2>/dev/null || echo "Unable to retrieve logs.")

  if [ -f "$BACKUP_FILE" ]; then
    # Rollback to previous version
    systemctl stop tunneld 2>/dev/null || true
    rm -rf "$APP_DIR"
    tar -xzf "$BACKUP_FILE" -C /opt
    systemctl restart tunneld

    # Verify rollback
    ROLLBACK_OK=false
    ELAPSED=0
    while [ $ELAPSED -lt $VERIFY_TIMEOUT ]; do
      if systemctl is-active --quiet tunneld 2>/dev/null; then
        ROLLBACK_OK=true
        break
      fi
      sleep $VERIFY_INTERVAL
      ELAPSED=$((ELAPSED + VERIFY_INTERVAL))
    done

    if [ "$ROLLBACK_OK" = true ]; then
      whiptail --title "Update Rolled Back" --msgbox \
"The new version failed to start and was rolled back
to your previous installation.

Service logs:
$JOURNAL_OUTPUT

Your previous version is running. Please report this
issue at:
https://github.com/toreanjoel/tunneld-installer/issues" 24 80
    else
      whiptail --title "Rollback Failed" --msgbox \
"CRITICAL: The new version failed to start, and the
rollback also failed.

Service logs:
$JOURNAL_OUTPUT

Your device may be inaccessible. To recover:
  1. SSH into the device
  2. Check: journalctl -u tunneld
  3. Reinstall: sudo ./install.sh

Report this issue at:
https://github.com/toreanjoel/tunneld-installer/issues" 24 80
    fi
  else
    # No backup available (first install)
    whiptail --title "Service Failed" --msgbox \
"The Tunneld service failed to start.

Service logs:
$JOURNAL_OUTPUT

Since this is a new installation, no rollback is
available. To troubleshoot:
  1. Check: journalctl -u tunneld
  2. Reinstall: sudo ./install.sh
  3. Report at:
     https://github.com/toreanjoel/tunneld-installer/issues" 24 80
  fi
fi