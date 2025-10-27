#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

need_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }; }
need_debian() { command -v apt-get >/dev/null 2>&1 || { echo "Debian-based OS required"; exit 1; }; }
need_root; need_debian

# ---- Paths ----
APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUNTIME_DIR="/var/run/tunneld"
BLACKLIST_DIR="$CONFIG_DIR/blacklists"
DNSCRYPT_DIR="$CONFIG_DIR/dnscrypt"
mkdir -p "$APP_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BLACKLIST_DIR" "$DNSCRYPT_DIR"

# ---- State (persist across reruns) ----
UP_IFACE="${UP_IFACE:-}"
DOWN_IFACE="${DOWN_IFACE:-}"
GATEWAY="${GATEWAY:-10.0.0.1}"
DHCP_START="${DHCP_START:-10.0.0.2}"
DHCP_END="${DHCP_END:-10.0.0.100}"
DEVICE_ID="${DEVICE_ID:-$(cat /proc/sys/kernel/random/uuid)}"
TUNNELD_VERSION="${TUNNELD_VERSION:-}"

# ---- Intro ----
whiptail --title "Tunneld Installer" --msgbox \
"Tunneld is a portable, wireless-first programmable gateway.

This wizard will:
  1) Install dependencies
  2) Configure network (upstream/downstream, DHCP)
  3) Configure dnsmasq
  4) Install & configure dnscrypt-proxy (Mullvad only)
  5) Fetch blocklist
  6) Enable IP forwarding + NAT
  7) (Optional) Download a Tunneld release
  8) Enable & start services

Press OK to begin." 20 74

# ========== 1) Dependencies ==========
whiptail --title "Step 1/8: Dependencies" --msgbox "We will install: curl, ca-certificates, iptables, iptables-persistent, dnsmasq, dhcpcd5, unzip, whiptail." 10 74
apt-get update
apt-get install -y curl ca-certificates iptables iptables-persistent dnsmasq dhcpcd5 unzip whiptail

# Remove distro dnscrypt to avoid path/service clashes
if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
  systemctl stop dnscrypt-proxy || true
  systemctl disable dnscrypt-proxy || true
  apt-get purge -y dnscrypt-proxy || true
fi

# ========== 2) Network (UP/DOWN, DHCP) ==========
mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|zt|tun|wg)')
if [ ${#ifaces[@]} -eq 0 ]; then whiptail --msgbox "No interfaces found." 8 50; exit 1; fi

menu_items=(); for i in "${ifaces[@]}"; do menu_items+=("$i" ""); done
UP_IFACE=$(whiptail --title "Step 2/8: Upstream (Internet)" --menu "Select upstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1
menu_items=(); for i in "${ifaces[@]}"; do [ "$i" != "$UP_IFACE" ] && menu_items+=("$i" ""); done
DOWN_IFACE=$(whiptail --title "Step 2/8: Downstream (LAN)" --menu "Select downstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1

GATEWAY=$(whiptail --title "Gateway IP" --inputbox "Gateway IP (CIDR /24 assumed)" 10 60 "$GATEWAY" 3>&1 1>&2 2>&3) || exit 1
DHCP_START=$(whiptail --title "DHCP Start" --inputbox "Start address" 10 60 "$DHCP_START" 3>&1 1>&2 2>&3) || exit 1
DHCP_END=$(whiptail --title "DHCP End" --inputbox "End address" 10 60 "$DHCP_END" 3>&1 1>&2 2>&3) || exit 1

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
whiptail --title "Step 2/8" --msgbox "Network settings saved:\nUP: $UP_IFACE\nDOWN: $DOWN_IFACE\nGATEWAY: $GATEWAY\nDHCP: $DHCP_START → $DHCP_END" 12 60

# ========== 3) dnsmasq ==========
cat > "$CONFIG_DIR/dnsmasq.conf" <<EOF
domain=tunneld.lan
local=/tunneld.lan/
expand-hosts
port=5336
interface=$DOWN_IFACE
bind-interfaces
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,infinite
dhcp-option=option:router,$GATEWAY
dhcp-option=option:dns-server,$GATEWAY
dhcp-option=15,tunneld.lan
dhcp-option=119,tunneld.lan
no-resolv
server=127.0.0.1#5335
conf-file=$BLACKLIST_DIR/dnsmasq-system.blacklist
address=/tunneld.lan/$GATEWAY
address=/gateway.tunneld.lan/$GATEWAY
EOF
ln -sf "$CONFIG_DIR/dnsmasq.conf" /etc/dnsmasq.conf
whiptail --title "Step 3/8" --msgbox "dnsmasq configured to forward (5336 → 127.0.0.1:5335)." 9 70

# ========== 4) dnscrypt-proxy (Mullvad only) ==========
DNSCRYPT_VERSION="2.1.5"
uname_arch=$(uname -m)
case "$uname_arch" in
  x86_64)   rel_arch="amd64"; tar_dir="linux-x86_64" ;;
  aarch64|arm64) rel_arch="arm64"; tar_dir="linux-arm64" ;;
  armv7l|armhf)  rel_arch="armv7";  tar_dir="linux-arm" ;;
  armv6l)        rel_arch="armv6";  tar_dir="linux-arm" ;;
  *) whiptail --msgbox "Unsupported arch: $uname_arch" 8 50; exit 1;;
esac

tmpdir=$(mktemp -d)
pushd "$tmpdir" >/dev/null
curl -fL "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VERSION}/dnscrypt-proxy-linux_${rel_arch}-${DNSCRYPT_VERSION}.tar.gz" -o dnscrypt.tar.gz
tar -xzf dnscrypt.tar.gz
cd "${tar_dir}"

install -m 755 dnscrypt-proxy /usr/local/bin/dnscrypt-proxy
/usr/local/bin/dnscrypt-proxy -version >/dev/null || { whiptail --msgbox "dnscrypt-proxy failed to install"; exit 1; }

if [ ! -f "$DNSCRYPT_DIR/dnscrypt-proxy.toml" ]; then
  sed \
    -e "s|^#\?listen_addresses = .*|listen_addresses = ['127.0.0.1:5335']|g" \
    -e "s|^#\?max_clients = .*|max_clients = 250|g" \
    -e "s|^#\?server_names = .*|server_names = ['mullvad-doh']|g" \
    example-dnscrypt-proxy.toml > "$DNSCRYPT_DIR/dnscrypt-proxy.toml" || cp example-dnscrypt-proxy.toml "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
else
  sed -i "s|^#\?listen_addresses = .*|listen_addresses = ['127.0.0.1:5335']|g" "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
  sed -i "s|^#\?server_names = .*|server_names = ['mullvad-doh']|g" "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
fi

if ! grep -q "sources.*public-resolvers" "$DNSCRYPT_DIR/dnscrypt-proxy.toml"; then
  cat >> "$DNSCRYPT_DIR/dnscrypt-proxy.toml" <<'EOF'
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/etc/tunneld/dnscrypt/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
EOF
fi
popd >/dev/null
rm -rf "$tmpdir"

cat > /etc/systemd/system/dnscrypt-proxy.service <<EOF
[Unit]
Description=dnscrypt-proxy
After=network.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dnscrypt-proxy -config $DNSCRYPT_DIR/dnscrypt-proxy.toml
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

whiptail --title "Step 4/8" --msgbox "dnscrypt-proxy installed and locked to Mullvad DoH (server_names = ['mullvad-doh'])." 10 74

# ========== 5) Blocklist ==========
cat > "$APP_DIR/update_blacklist.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
BLACKLIST_DIR="/etc/tunneld/blacklists"
LOG_DIR="/var/log/tunneld"
mkdir -p "$BLACKLIST_DIR" "$LOG_DIR"
curl -fsSL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt -o "$BLACKLIST_DIR/dnsmasq-system.blacklist"
echo "Updated: $(date)" | tee -a "$LOG_DIR/blacklist.log"
systemctl is-active --quiet dnsmasq && systemctl reload dnsmasq || true
EOF
chmod +x "$APP_DIR/update_blacklist.sh"
"$APP_DIR/update_blacklist.sh" || true
whiptail --title "Step 5/8" --msgbox "Hagezi blocklist fetched and wired into dnsmasq." 8 70

# ========== 6) IP forwarding + NAT ==========
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

iptables -t nat -C POSTROUTING -o "$UP_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$UP_IFACE" -j MASQUERADE
iptables -C FORWARD -i "$DOWN_IFACE" -o "$UP_IFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$DOWN_IFACE" -o "$UP_IFACE" -j ACCEPT
iptables -C FORWARD -i "$UP_IFACE" -o "$DOWN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$UP_IFACE" -o "$DOWN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables-save > /etc/iptables/rules.v4
whiptail --title "Step 6/8" --msgbox "IP forwarding enabled and NAT rules saved." 8 60

# ========== 7) (Optional) Tunneld release ==========
if whiptail --title "Step 7/8: Tunneld Release" --yesno "Download and install a Tunneld release now?" 10 60; then
  uname_arch=$(uname -m)
  case "$uname_arch" in
    x86_64) rel_arch="amd64" ;;
    aarch64|arm64) rel_arch="arm64" ;;
    armv7l|armhf) rel_arch="armv7" ;;
    armv6l) rel_arch="armv6" ;;
    *) whiptail --msgbox "Unsupported arch: $uname_arch" 8 50; exit 1;;
  esac
  TUNNELD_VERSION=$(whiptail --inputbox "Enter version (e.g. 0.4.0) or leave empty for latest" 10 60 "$TUNNELD_VERSION" 3>&1 1>&2 2>&3) || true
  tmpdir=$(mktemp -d)
  if [ -n "${TUNNELD_VERSION:-}" ]; then
    url="https://github.com/toreanjoel/tunneld/releases/download/v${TUNNELD_VERSION}/tunneld-${TUNNELD_VERSION}-linux-${rel_arch}.tar.gz"
  else
    url="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-${rel_arch}.tar.gz"
  fi
  curl -fL "$url" -o "$tmpdir/tunneld.tar.gz"
  tar -xzf "$tmpdir/tunneld.tar.gz" -C "$APP_DIR"
  rm -rf "$tmpdir"
  whiptail --msgbox "Tunneld files placed in $APP_DIR" 8 50
else
  whiptail --msgbox "Skipping download. Ensure a valid release exists in $APP_DIR (bin/, erts-*/, lib/, releases/)." 10 70
fi

# ========== 8) Enable & start services ==========
[ -f "$DATA_DIR/auth.json" ] || echo '{}' > "$DATA_DIR/auth.json"
[ -f "$DATA_DIR/shares.json" ] || echo '[]' > "$DATA_DIR/shares.json"

SECRET_KEY_BASE=$(openssl rand -hex 64)
cat > /etc/systemd/system/tunneld.service <<EOF
[Unit]
Description=Tunneld
After=network-online.target dnscrypt-proxy.service
Wants=network-online.target

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

systemctl daemon-reload
systemctl enable dhcpcd dnsmasq dnscrypt-proxy tunneld
systemctl restart dhcpcd
systemctl restart dnscrypt-proxy
systemctl restart dnsmasq
systemctl restart tunneld

# ---- Outro ----
whiptail --title "Installation Complete" --msgbox \
"Tunneld installation complete.

App:    $APP_DIR
Config: $CONFIG_DIR
Logs:   $LOG_DIR
Data:   $DATA_DIR

Saved values:
  $CONFIG_DIR/interfaces.conf
  $CONFIG_DIR/dhcpcd.conf
  $CONFIG_DIR/dnsmasq.conf
  $DNSCRYPT_DIR/dnscrypt-proxy.toml

Access:
  http://$GATEWAY
  http://tunneld.lan
  http://gateway.tunneld.lan

Manage:
  systemctl status dnscrypt-proxy dnsmasq dhcpcd tunneld
  $APP_DIR/update_blacklist.sh

Done." 24 80
