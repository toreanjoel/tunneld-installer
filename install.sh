#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then echo "Run as root (sudo)"; exit 1; fi
if ! command -v apt-get >/dev/null 2>&1; then echo "Debian-based OS required"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive

# --- PREREQS ---
apt-get update
apt-get install -y whiptail curl ca-certificates iptables iptables-persistent dnsmasq dhcpcd5 unzip

# Remove distro dnscrypt to avoid path/service clashes if it exists
if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
  systemctl stop dnscrypt-proxy || true
  systemctl disable dnscrypt-proxy || true
  apt-get purge -y dnscrypt-proxy || true
fi

# --- INTRO ---
whiptail --title "Welcome to Tunneld Installer" --msgbox \
"Tunneld is a portable, wireless-first programmable gateway.

It provides:
 • Secure service exposure via OpenZiti (Zrok)
 • DNS/DHCP management (dnsmasq + dhcpcd)
 • Encrypted DNS (dnscrypt-proxy, Mullvad)
 • Tracker/ad blocking (Hagezi blocklist)

Press OK to begin." 20 70

# --- PATHS & BASE ---
APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUNTIME_DIR="/var/run/tunneld"
BLACKLIST_DIR="$CONFIG_DIR/blacklists"
DNSCRYPT_DIR="$CONFIG_DIR/dnscrypt"
DEVICE_ID="${DEVICE_ID:-$(cat /proc/sys/kernel/random/uuid)}"

mkdir -p "$APP_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BLACKLIST_DIR" "$DNSCRYPT_DIR"

# --- INTERFACES & RANGES ---
mapfile -t interfaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|zt|tun|wg)')

if [ ${#interfaces[@]} -eq 0 ]; then echo "No interfaces found"; exit 1; fi

menu_items=(); for i in "${interfaces[@]}"; do menu_items+=("$i" ""); done
up_iface=$(whiptail --title "Upstream (Internet)" --menu "Select upstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1
menu_items=(); for i in "${interfaces[@]}"; do [ "$i" != "$up_iface" ] && menu_items+=("$i" ""); done
down_iface=$(whiptail --title "Downstream (LAN)" --menu "Select downstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1

gateway=$(whiptail --title "Gateway IP" --inputbox "Gateway IP (e.g. 10.0.0.1)" 10 60 "10.0.0.1" 3>&1 1>&2 2>&3) || exit 1
dhcp_start=$(whiptail --title "DHCP Start" --inputbox "DHCP start (e.g. 10.0.0.2)" 10 60 "10.0.0.2" 3>&1 1>&2 2>&3) || exit 1
dhcp_end=$(whiptail --title "DHCP End" --inputbox "DHCP end (e.g. 10.0.0.100)" 10 60 "10.0.0.100" 3>&1 1>&2 2>&3) || exit 1

# --- SAVE CORE CONFIG (PERSIST WHAT YOU CHOSE) ---
cat > "$CONFIG_DIR/interfaces.conf" <<EOF
UPSTREAM_INTERFACE=$up_iface
DOWNSTREAM_INTERFACE=$down_iface
GATEWAY_IP=$gateway
DHCP_START=$dhcp_start
DHCP_END=$dhcp_end
DEVICE_ID=$DEVICE_ID
EOF

# --- DHCPCD ---
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

# --- DNSMASQ (5336 -> 5335) ---
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

# --- DNSCRYPT-PROXY: MANUAL INSTALL (v2.1.5) ---
DNSCRYPT_VERSION="2.1.5"
uname_arch=$(uname -m)
case "$uname_arch" in
  x86_64) rel_arch="amd64"; tar_dir="linux-x86_64" ;;
  aarch64|arm64) rel_arch="arm64"; tar_dir="linux-arm64" ;;
  armv7l|armhf) rel_arch="armv7"; tar_dir="linux-arm" ;;
  armv6l) rel_arch="armv6"; tar_dir="linux-arm" ;;
  *) whiptail --title "Unsupported Arch" --msgbox "Unsupported arch: $uname_arch" 10 60; exit 1 ;;
esac

tmpdir=$(mktemp -d)
pushd "$tmpdir" >/dev/null
curl -fL "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${DNSCRYPT_VERSION}/dnscrypt-proxy-linux_${rel_arch}-${DNSCRYPT_VERSION}.tar.gz" -o dnscrypt.tar.gz
tar -xzf dnscrypt.tar.gz
cd "${tar_dir}"

install -m 755 dnscrypt-proxy /usr/local/bin/dnscrypt-proxy
if ! /usr/local/bin/dnscrypt-proxy -version >/dev/null 2>&1; then
  echo "dnscrypt-proxy failed to install"; exit 1
fi

# Config lives under /etc/tunneld/dnscrypt; preserve if already exists
if [ ! -f "$DNSCRYPT_DIR/dnscrypt-proxy.toml" ]; then
  # Use the example as a base, tweak ports and sources cache path
  sed \
    -e "s|^#\?listen_addresses = .*|listen_addresses = ['127.0.0.1:5335']|g" \
    -e "s|^#\?max_clients = .*|max_clients = 250|g" \
    -e "s|^#\?server_names = .*|server_names = ['mullvad-doh', 'quad9-dnscrypt-ip4-filter-pri']|g" \
    example-dnscrypt-proxy.toml > "$DNSCRYPT_DIR/dnscrypt-proxy.toml" || cp example-dnscrypt-proxy.toml "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
fi

# Ensure sources section with cache path under /etc/tunneld/dnscrypt
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

# --- DNSCRYPT SYSTEMD (points to /usr/local/bin + your config) ---
cat > /etc/systemd/system/dnscrypt-proxy.service <<EOF
[Unit]
Description=dnscrypt-proxy
After=network.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/dnscrypt-proxy -config $DNSCRYPT_DIR/dnscrypt-proxy.toml
Restart=always
RestartSec=5
# Hardening (optional but sane)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

# --- BLACKLIST FETCHER ---
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

# --- TUNNELD SERVICE (keeps your chosen values via env + saved files) ---
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

# --- OPTIONAL: DOWNLOAD TUNNELD RELEASE ---
if whiptail --title "Download Tunneld" --yesno "Download and install a Tunneld release?" 10 60; then
  uname_arch=$(uname -m)
  case "$uname_arch" in
    x86_64) rel_arch="amd64" ;;
    aarch64|arm64) rel_arch="arm64" ;;
    armv7l|armhf) rel_arch="armv7" ;;
    armv6l) rel_arch="armv6" ;;
    *) whiptail --title "Unsupported Arch" --msgbox "Unsupported arch: $uname_arch" 10 60; exit 1 ;;
  esac
  ver_input=$(whiptail --title "Version" --inputbox "Enter version (e.g. 0.4.0) or leave empty for latest" 10 60 "" 3>&1 1>&2 2>&3) || exit 1
  tmpdir=$(mktemp -d)
  if [ -n "$ver_input" ]; then
    url="https://github.com/toreanjoel/tunneld/releases/download/v${ver_input}/tunneld-${ver_input}-linux-${rel_arch}.tar.gz"
  else
    url="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-${rel_arch}.tar.gz"
  fi
  echo "Fetching $url"
  curl -fL "$url" -o "$tmpdir/tunneld.tar.gz"
  tar -xzf "$tmpdir/tunneld.tar.gz" -C "$APP_DIR"
  rm -rf "$tmpdir"
else
  whiptail --title "Manual Placement" --msgbox "Place your built release in $APP_DIR (must contain bin/, erts-*/, lib/, releases/)" 10 70
fi

# --- IP FORWARDING & NAT ---
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

iptables -t nat -C POSTROUTING -o "$up_iface" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$up_iface" -j MASQUERADE
iptables -C FORWARD -i "$down_iface" -o "$up_iface" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$down_iface" -o "$up_iface" -j ACCEPT
iptables -C FORWARD -i "$up_iface" -o "$down_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$up_iface" -o "$down_iface" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Save rules for reboot
iptables-save > /etc/iptables/rules.v4

# --- ENABLE & START ---
systemctl daemon-reload
systemctl enable dhcpcd dnsmasq dnscrypt-proxy tunneld
systemctl restart dhcpcd
systemctl restart dnscrypt-proxy
systemctl restart dnsmasq
systemctl restart tunneld

# --- OUTRO ---
whiptail --title "Installation Complete" --msgbox \
"Tunneld installation completed successfully.

App:    $APP_DIR
Config: $CONFIG_DIR
Logs:   $LOG_DIR
Data:   $DATA_DIR

Access:
 • http://$gateway
 • http://tunneld.lan
 • http://gateway.tunneld.lan

Manage:
  systemctl status dnscrypt-proxy dnsmasq dhcpcd tunneld
  $APP_DIR/update_blacklist.sh

Your chosen values are saved in:
  $CONFIG_DIR/interfaces.conf
  $CONFIG_DIR/dhcpcd.conf
  $CONFIG_DIR/dnsmasq.conf
  $DNSCRYPT_DIR/dnscrypt-proxy.toml

Keep building, stay private." 25 78
