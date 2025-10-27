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

# State (kept while navigating the wizard)
UP_IFACE="${UP_IFACE:-}"
DOWN_IFACE="${DOWN_IFACE:-}"
GATEWAY="${GATEWAY:-10.0.0.1}"
DHCP_START="${DHCP_START:-10.0.0.2}"
DHCP_END="${DHCP_END:-10.0.0.100}"
DEVICE_ID="${DEVICE_ID:-$(cat /proc/sys/kernel/random/uuid)}"
DOWNLOAD_TUNNELD="${DOWNLOAD_TUNNELD:-yes}"
TUNNELD_VERSION="${TUNNELD_VERSION:-}"

# ---- Intro ----
whiptail --title "Tunneld Installer" --msgbox \
"Tunneld is a portable, wireless-first programmable gateway.

This wizard will guide you through:
  • Dependencies
  • Network (upstream/downstream, DHCP)
  • dnsmasq + dnscrypt-proxy
  • NAT + IP forwarding
  • (Optional) Downloading a Tunneld release
  • Enabling services

You can revisit steps in any order." 18 72

# ---- Helpers ----
ensure_whiptail() { command -v whiptail >/dev/null 2>&1 || apt-get update && apt-get install -y whiptail; }
ensure_whiptail

gauge() {
  # $1 message, $2 percent
  { echo -e "XXX\n$2\n$1\nXXX"; } | whiptail --gauge "Working..." 7 60 0
}

save_interfaces_conf() {
  cat > "$CONFIG_DIR/interfaces.conf" <<EOF
UPSTREAM_INTERFACE=$UP_IFACE
DOWNSTREAM_INTERFACE=$DOWN_IFACE
GATEWAY_IP=$GATEWAY
DHCP_START=$DHCP_START
DHCP_END=$DHCP_END
DEVICE_ID=$DEVICE_ID
EOF
}

# ---- Steps ----
step_deps() {
  if whiptail --title "Dependencies" --yesno "Install/update required packages now?" 10 60; then
    gauge "Installing dependencies..." 10
    apt-get update
    apt-get install -y curl ca-certificates iptables iptables-persistent dnsmasq dhcpcd5 unzip
    gauge "Dependencies installed." 100
  fi
}

step_network() {
  mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|zt|tun|wg)')
  [ ${#ifaces[@]} -gt 0 ] || { whiptail --msgbox "No interfaces found." 8 50; return; }

  menu_items=(); for i in "${ifaces[@]}"; do menu_items+=("$i" ""); done
  UP_IFACE=$(whiptail --title "Upstream (Internet)" --menu "Select upstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return
  menu_items=(); for i in "${ifaces[@]}"; do [ "$i" != "$UP_IFACE" ] && menu_items+=("$i" ""); done
  DOWN_IFACE=$(whiptail --title "Downstream (LAN)" --menu "Select downstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || return

  GATEWAY=$(whiptail --title "Gateway IP" --inputbox "Gateway IP (CIDR /24 assumed)" 10 60 "$GATEWAY" 3>&1 1>&2 2>&3) || return
  DHCP_START=$(whiptail --title "DHCP Start" --inputbox "Start address" 10 60 "$DHCP_START" 3>&1 1>&2 2>&3) || return
  DHCP_END=$(whiptail --title "DHCP End" --inputbox "End address" 10 60 "$DHCP_END" 3>&1 1>&2 2>&3) || return

  save_interfaces_conf

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

  whiptail --title "Network" --msgbox "Network settings saved:\n\nUP: $UP_IFACE\nDOWN: $DOWN_IFACE\nGATEWAY: $GATEWAY\nDHCP: $DHCP_START → $DHCP_END" 12 60
}

step_dnsmasq() {
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
log-queries
log-facility=$LOG_DIR/dnsmasq.log
EOF
  ln -sf "$CONFIG_DIR/dnsmasq.conf" /etc/dnsmasq.conf
  whiptail --title "dnsmasq" --msgbox "dnsmasq configured. Upstream will be dnscrypt-proxy on 127.0.0.1:5335." 10 60
}

step_dnscrypt() {
  # remove distro dnscrypt to avoid path/service clashes
  if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
    systemctl stop dnscrypt-proxy || true
    systemctl disable dnscrypt-proxy || true
    apt-get purge -y dnscrypt-proxy || true
  fi

  DNSCRYPT_VERSION="2.1.5"
  uname_arch=$(uname -m)
  case "$uname_arch" in
    x86_64) rel_arch="amd64"; tar_dir="linux-x86_64" ;;
    aarch64|arm64) rel_arch="arm64"; tar_dir="linux-arm64" ;;
    armv7l|armhf) rel_arch="armv7"; tar_dir="linux-arm" ;;
    armv6l) rel_arch="armv6"; tar_dir="linux-arm" ;;
    *) whiptail --msgbox "Unsupported arch: $uname_arch" 8 50; return;;
  esac

  gauge "Downloading dnscrypt-proxy ${DNSCRYPT_VERSION}..." 20
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
      -e "s|^#\?server_names = .*|server_names = ['mullvad-doh', 'quad9-dnscrypt-ip4-filter-pri']|g" \
      example-dnscrypt-proxy.toml > "$DNSCRYPT_DIR/dnscrypt-proxy.toml" || cp example-dnscrypt-proxy.toml "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
    if ! grep -q "sources.*public-resolvers" "$DNSCRYPT_DIR/dnscrypt-proxy.toml"; then
      cat >> "$DNSCRYPT_DIR/dnscrypt-proxy.toml" <<'EOF'
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '/etc/tunneld/dnscrypt/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
EOF
    fi
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

  whiptail --title "dnscrypt-proxy" --msgbox "dnscrypt-proxy installed to /usr/local/bin and configured at:\n$DNSCRYPT_DIR/dnscrypt-proxy.toml" 12 70
}

step_blacklist() {
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
  whiptail --title "Blocklist" --msgbox "Hagezi blocklist fetched and wired into dnsmasq.\nScript: $APP_DIR/update_blacklist.sh" 10 70
}

step_nat() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

  iptables -t nat -C POSTROUTING -o "$UP_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$UP_IFACE" -j MASQUERADE
  iptables -C FORWARD -i "$DOWN_IFACE" -o "$UP_IFACE" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$DOWN_IFACE" -o "$UP_IFACE" -j ACCEPT
  iptables -C FORWARD -i "$UP_IFACE" -o "$DOWN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$UP_IFACE" -o "$DOWN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables-save > /etc/iptables/rules.v4

  whiptail --title "Routing" --msgbox "IP forwarding enabled and NAT rules saved." 8 60
}

step_tunneld_release() {
  if whiptail --title "Tunneld Release" --yesno "Download and install a Tunneld release now?" 10 60; then
    DOWNLOAD_TUNNELD="yes"
    uname_arch=$(uname -m)
    case "$uname_arch" in
      x86_64) rel_arch="amd64" ;;
      aarch64|arm64) rel_arch="arm64" ;;
      armv7l|armhf) rel_arch="armv7" ;;
      armv6l) rel_arch="armv6" ;;
      *) whiptail --msgbox "Unsupported arch: $uname_arch" 8 50; return;;
    esac
    TUNNELD_VERSION=$(whiptail --inputbox "Enter version (e.g. 0.4.0) or leave empty for latest" 10 60 "$TUNNELD_VERSION" 3>&1 1>&2 2>&3) || return
    tmpdir=$(mktemp -d)
    if [ -n "${TUNNELD_VERSION}" ]; then
      url="https://github.com/toreanjoel/tunneld/releases/download/v${TUNNELD_VERSION}/tunneld-${TUNNELD_VERSION}-linux-${rel_arch}.tar.gz"
    else
      url="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-${rel_arch}.tar.gz"
    fi
    gauge "Downloading Tunneld..." 40
    curl -fL "$url" -o "$tmpdir/tunneld.tar.gz"
    tar -xzf "$tmpdir/tunneld.tar.gz" -C "$APP_DIR"
    rm -rf "$tmpdir"
    whiptail --msgbox "Tunneld files placed in $APP_DIR" 8 50
  else
    DOWNLOAD_TUNNELD="no"
    whiptail --msgbox "Skip download. Ensure a valid release exists in $APP_DIR (bin/, erts-*/, lib/, releases/)." 10 70
  fi
}

step_services() {
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

  whiptail --title "Services" --msgbox "Services enabled and started.\n\nAccess:\n  http://$GATEWAY\n  http://tunneld.lan\n  http://gateway.tunneld.lan" 12 60
}

# ---- Wizard Main Menu ----
while true; do
  CHOICE=$(whiptail --title "Tunneld Setup Wizard" --menu "Select a step (you can run steps multiple times)" 22 76 10 \
    "1" "Install dependencies" \
    "2" "Configure network (UP/DOWN, DHCP)" \
    "3" "Configure dnsmasq" \
    "4" "Install & configure dnscrypt-proxy" \
    "5" "Fetch blocklist (Hagezi) & wire" \
    "6" "Enable IP forwarding + NAT" \
    "7" "Download Tunneld release (optional)" \
    "8" "Enable & start services" \
    "9" "Finish" 3>&1 1>&2 2>&3) || { echo "Cancelled"; exit 1; }

  case "$CHOICE" in
    1) step_deps ;;
    2) step_network ;;
    3) step_dnsmasq ;;
    4) step_dnscrypt ;;
    5) step_blacklist ;;
    6) step_nat ;;
    7) step_tunneld_release ;;
    8) step_services ;;
    9) break ;;
  esac
done

whiptail --title "Installation Complete" --msgbox \
"Tunneld installation wizard complete.

App:    $APP_DIR
Config: $CONFIG_DIR
Logs:   $LOG_DIR
Data:   $DATA_DIR

Saved values:
  $CONFIG_DIR/interfaces.conf
  $CONFIG_DIR/dhcpcd.conf
  $CONFIG_DIR/dnsmasq.conf
  $DNSCRYPT_DIR/dnscrypt-proxy.toml

Manage:
  systemctl status dnscrypt-proxy dnsmasq dhcpcd tunneld
  $APP_DIR/update_blacklist.sh

You can re-run this wizard anytime to update settings." 20 74
