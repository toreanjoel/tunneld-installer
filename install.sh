#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi
if ! command -v apt-get >/dev/null 2>&1; then echo "Debian-based OS required"; exit 1; fi

APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUNTIME_DIR="/var/run/tunneld"
BLACKLIST_DIR="$CONFIG_DIR/blacklists"
DNSCRYPT_DIR="$CONFIG_DIR/dnscrypt"
DEVICE_ID=$(cat /proc/sys/kernel/random/uuid)

mkdir -p "$APP_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BLACKLIST_DIR" "$DNSCRYPT_DIR"

# Select interfaces
interfaces=( $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$') )
if [ ${#interfaces[@]} -eq 0 ]; then echo "No interfaces found"; exit 1; fi

menu_items=(); for i in "${interfaces[@]}"; do menu_items+=("$i" ""); done
up_iface=$(whiptail --title "Upstream (Internet)" --menu "Select upstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1
menu_items=(); for i in "${interfaces[@]}"; do [ "$i" != "$up_iface" ] && menu_items+=("$i" ""); done
down_iface=$(whiptail --title "Downstream (LAN)" --menu "Select downstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1

gateway=$(whiptail --title "Gateway IP" --inputbox "Gateway IP (e.g. 10.0.0.1)" 10 60 "10.0.0.1" 3>&1 1>&2 2>&3) || exit 1
dhcp_start=$(whiptail --title "DHCP Start" --inputbox "DHCP start (e.g. 10.0.0.2)" 10 60 "10.0.0.2" 3>&1 1>&2 2>&3) || exit 1
dhcp_end=$(whiptail --title "DHCP End" --inputbox "DHCP end (e.g. 10.0.0.100)" 10 60 "10.0.0.100" 3>&1 1>&2 2>&3) || exit 1

# Optional: install deps
if whiptail --title "Dependencies" --yesno "Install dnsmasq, dhcpcd5, dnscrypt-proxy, iptables, curl, unzip?" 10 60; then
  apt-get update
  apt-get install -y dnsmasq dhcpcd5 dnscrypt-proxy iptables curl unzip
fi

# Detect arch (for release asset name)
uname_arch=$(uname -m)
case "$uname_arch" in
  x86_64) rel_arch="amd64" ;;
  aarch64|arm64) rel_arch="arm64" ;;
  armv7l|armhf) rel_arch="armv7" ;;
  armv6l) rel_arch="armv6" ;;
  *) whiptail --title "Unsupported Arch" --msgbox "Unsupported arch: $uname_arch" 10 60; exit 1 ;;
esac

# Download release (optional)
if whiptail --title "Download Tunneld" --yesno "Download and install a Tunneld release?" 10 60; then
  ver_input=$(whiptail --title "Version" --inputbox "Enter version (e.g. 0.4.0) or leave empty for latest" 10 60 "" 3>&1 1>&2 2>&3) || exit 1
  tmpdir=$(mktemp -d)
  if [ -n "$ver_input" ]; then
    url="https://github.com/toreanjoel/tunneld/releases/download/v${ver_input}/tunneld-${ver_input}-linux-${rel_arch}.tar.gz"
  else
    url="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-${rel_arch}.tar.gz"
  fi
  echo "Fetching $url"
  curl -fL "$url" -o "$tmpdir/tunneld.tar.gz"

  # Extract Elixir release tarball directly into /opt/tunneld
  tar -xzf "$tmpdir/tunneld.tar.gz" -C "$APP_DIR"
  rm -rf "$tmpdir"
else
  whiptail --title "Manual Placement" --msgbox "Place your built release contents in $APP_DIR (it must contain bin/, erts-*/, lib/, releases/)" 10 70
fi

# Seed data files if missing
[ -f "$DATA_DIR/auth.json" ] || echo '{}' > "$DATA_DIR/auth.json"
[ -f "$DATA_DIR/shares.json" ] || echo '[]' > "$DATA_DIR/shares.json"

# Persist chosen interfaces/config for reference
cat > "$CONFIG_DIR/interfaces.conf" <<EOF
UPSTREAM_INTERFACE=$up_iface
DOWNSTREAM_INTERFACE=$down_iface
GATEWAY_IP=$gateway
DHCP_START=$dhcp_start
DHCP_END=$dhcp_end
DEVICE_ID=$DEVICE_ID
EOF

# dhcpcd
cat > "$CONFIG_DIR/dhcpcd.conf" <<EOF
interface $down_iface
static ip_address=${gateway}/24
nohook wpa_supplicant
metric 250

interface $up_iface
nohook wpa_supplicant
metric 100
EOF
ln -sf "$CONFIG_DIR/dhcpcd.conf" /etc/dhcpcd.conf

# dnsmasq
cat > "$CONFIG_DIR/dnsmasq.conf" <<EOF
domain=tunneld.lan
local=/tunneld.lan/
expand-hosts
port=5336
interface=$down_iface
bind-interfaces
dhcp-range=${dhcp_start},${dhcp_end},255.255.255.0,infinite
dhcp-option=option:router,$gateway
dhcp-option=option:dns-server,$gateway
dhcp-option=15,tunneld.lan
dhcp-option=119,tunneld.lan
no-resolv
server=127.0.0.1#5335
conf-file=$BLACKLIST_DIR/dnsmasq-system.blacklist
address=/tunneld.lan/$gateway
address=/gateway.tunneld.lan/$gateway
log-queries
log-facility=$LOG_DIR/dnsmasq.log
EOF
ln -sf "$CONFIG_DIR/dnsmasq.conf" /etc/dnsmasq.conf

# dnscrypt-proxy
cat > "$DNSCRYPT_DIR/dnscrypt-proxy.toml" <<'EOF'
listen_addresses = ['127.0.0.1:5335']
max_clients = 250
server_names = ['mullvad-doh', 'quad9-dnscrypt-ip4-filter-pri']
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/etc/tunneld/dnscrypt/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
EOF
install -d -m 755 /etc/systemd/system/dnscrypt-proxy.service.d
cat > /etc/systemd/system/dnscrypt-proxy.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/dnscrypt-proxy -config $DNSCRYPT_DIR/dnscrypt-proxy.toml
EOF

# blacklist updater
cat > "$APP_DIR/update_blacklist.sh" <<EOF
#!/bin/bash
set -euo pipefail
mkdir -p "$BLACKLIST_DIR" "$LOG_DIR"
curl -fsSL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt -o "$BLACKLIST_DIR/dnsmasq-system.blacklist"
echo "Updated: \$(date)" | tee -a "$LOG_DIR/blacklist.log"
systemctl is-active --quiet dnsmasq && systemctl reload dnsmasq || true
EOF
chmod +x "$APP_DIR/update_blacklist.sh"

# systemd service (Elixir release)
SECRET_KEY_BASE=$(openssl rand -hex 64)
cat > /etc/systemd/system/tunneld.service <<EOF
[Unit]
Description=Tunneld
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment=PHX_SERVER=true
Environment=PORT=80
Environment=SECRET_KEY_BASE=$SECRET_KEY_BASE
Environment=WIFI_INTERFACE=$up_iface
Environment=LAN_INTERFACE=$down_iface
Environment=GATEWAY=$gateway
Environment=TUNNELD_DATA=$DATA_DIR
Environment=MULLVAD_INTERFACE=
Environment=DNS_CLUSTER_QUERY=
ExecStart=$APP_DIR/bin/tunneld start
ExecStop=$APP_DIR/bin/tunneld stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# enable + start
systemctl daemon-reload
systemctl enable dhcpcd dnsmasq dnscrypt-proxy
systemctl restart dhcpcd dnsmasq dnscrypt-proxy
systemctl enable tunneld
systemctl restart tunneld

echo "Installed:
- App:    $APP_DIR
- Config: $CONFIG_DIR
- Logs:   $LOG_DIR
- Data:   $DATA_DIR

Interfaces:
- Upstream:   $up_iface
- Downstream: $down_iface
Gateway: $gateway

Check:   systemctl status tunneld
Open:    http://$gateway
"
