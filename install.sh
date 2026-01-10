#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

need_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }; }
need_debian() { command -v apt-get >/dev/null 2>&1 || { echo "Debian-based OS required"; exit 1; }; }
need_root; need_debian

APP_DIR="/opt/tunneld"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
DATA_DIR="/var/lib/tunneld"
RUNTIME_DIR="/var/run/tunneld"
BLACKLIST_DIR="$CONFIG_DIR/blacklists"
DNSCRYPT_DIR="$CONFIG_DIR/dnscrypt"
mkdir -p "$APP_DIR" "$CONFIG_DIR" "$LOG_DIR" "$DATA_DIR" "$RUNTIME_DIR" "$BLACKLIST_DIR" "$DNSCRYPT_DIR"

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
  3) Configure dnsmasq
  4) Install & configure dnscrypt-proxy (Mullvad only)
  5) Fetch blocklist
  6) (Optional) Download a Tunneld pre-alpha release
  7) Enable & start services

Important:
  - The Tunneld uninstaller will remove Tunneld itself, its configs,
    logs and systemd units.
  - It will NOT remove system packages installed as dependencies
    (e.g. dnsmasq, dhcpcd, nginx, iptables, fake-hwclock, etc.).
  - You can always remove those manually later with apt if you want
    a completely clean system.

Press OK to begin." 24 80

whiptail --title "Step 1/7: Dependencies" --msgbox "We will install: Zrok, OpenZiti, dnsmasq, dhcpcd, nginx, git, dkms, build-essential, libjson-c-dev, libwebsockets-dev, libssl-dev, iptables, iproute2, bc, unzip, iw, systemd-timesyncd, fake-hwclock" 10 74
apt-get update
apt-get install dnsmasq dhcpcd nginx git dkms build-essential libjson-c-dev libwebsockets-dev libssl-dev iptables iproute2 bc unzip iw systemd-timesyncd fake-hwclock -y
timedatectl set-ntp true
systemctl enable --now systemd-timesyncd.service
systemctl enable --now fake-hwclock.service
systemctl enable --now systemd-time-wait-sync.service

# Prepare nginx for tunneld gateway routing (app will manage server/upstream blocks)
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
rm -f /etc/nginx/sites-enabled/default
systemctl enable --now nginx

curl -sSf https://get.openziti.io/install.bash | sudo bash -s zrok

if dpkg -s dnscrypt-proxy >/dev/null 2>&1; then
  systemctl stop dnscrypt-proxy || true
  systemctl disable dnscrypt-proxy || true
  apt-get purge -y dnscrypt-proxy || true
fi

mapfile -t ifaces < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth|zt|tun|wg)')
if [ ${#ifaces[@]} -eq 0 ]; then whiptail --msgbox "No interfaces found." 8 50; exit 1; fi

menu_items=(); for i in "${ifaces[@]}"; do menu_items+=("$i" ""); done
UP_IFACE=$(whiptail --title "Step 2/7: Upstream (Internet)" --menu "Select upstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1
menu_items=(); for i in "${ifaces[@]}"; do [ "$i" != "$UP_IFACE" ] && menu_items+=("$i" ""); done
DOWN_IFACE=$(whiptail --title "Step 2/7: Downstream (LAN)" --menu "Select downstream interface" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3) || exit 1

GATEWAY=$(whiptail --title "Gateway IP" --inputbox "Gateway IP (CIDR /24 assumed)" 10 60 "$GATEWAY" 3>&1 1>&2 2>&3) || exit 1
DHCP_START=$(whiptail --title "DHCP Start" --inputbox "Start address" 10 60 "$DHCP_START" 3>&1 1>&2 2>&3) || exit 1
DHCP_END=$(whiptail --title "DHCP End" --inputbox "End address" 10 60 "$DHCP_END" 3>&1 1>&2 2>&3) || exit 1
WIFI_COUNTRY=$(whiptail --title "Wi-Fi Country / Regulatory Domain" --inputbox "Enter the 2-letter country code for this device's wireless regulatory domain (example: US, ZA, DE, UK). This controls which Wi-Fi channels are allowed." 12 72 "" 3>&1 1>&2 2>&3) || exit 1

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
whiptail --title "Step 2/7" --msgbox "Network settings saved:\nUP: $UP_IFACE\nDOWN: $DOWN_IFACE\nGATEWAY: $GATEWAY\nDHCP: $DHCP_START → $DHCP_END" 12 60

cat > "$CONFIG_DIR/dnsmasq.conf" <<EOF
port=5336
interface=$DOWN_IFACE
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,infinite
dhcp-option=option:router,$GATEWAY
dhcp-option=option:dns-server,$GATEWAY
no-resolv
server=127.0.0.1#5335
conf-file=$BLACKLIST_DIR/dnsmasq-system.blacklist
EOF
ln -sf "$CONFIG_DIR/dnsmasq.conf" /etc/dnsmasq.conf
whiptail --title "Step 3/7" --msgbox "dnsmasq configured to forward (5336 → 127.0.0.1:5335)." 9 70

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
    -e "s|^#\?listen_addresses = .*|listen_addresses = ['127.0.0.1:53', '127.0.0.1:5335']|g" \
    -e "s|^#\?max_clients = .*|max_clients = 250|g" \
    -e "s|^#\?server_names = .*|server_names = ['mullvad-doh']|g" \
    example-dnscrypt-proxy.toml > "$DNSCRYPT_DIR/dnscrypt-proxy.toml" || cp example-dnscrypt-proxy.toml "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
else
  sed -i "s|^#\?listen_addresses = .*|listen_addresses = ['127.0.0.1:53', '127.0.0.1:5335']|g" "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
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
After=network-online.target dhcpcd.service
Wants=network-online.target dhcpcd.service

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

whiptail --title "Step 4/7" --msgbox "dnscrypt-proxy installed and locked to Mullvad DoH (server_names = ['mullvad-doh'])." 10 74

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
whiptail --title "Step 5/7" --msgbox "Hagezi blocklist fetched and wired into dnsmasq." 8 70

if whiptail --title "Step 6/7: Tunneld Pre-Alpha Release" --yesno \
"Download and install the current Tunneld pre-alpha build now?

This is an early pre-release build intended for testing.
Config and networking will be managed by this box.
" 14 70; then

  tmpdir=$(mktemp -d)
  beta_url="https://raw.githubusercontent.com/toreanjoel/tunneld-installer/refs/heads/main/releases/tunneld-pre-alpha.tar.gz"
  sums_url="https://raw.githubusercontent.com/toreanjoel/tunneld-installer/refs/heads/main/releases/checksums.txt"

  curl -fL "$beta_url" -o "$tmpdir/tunneld-pre-alpha.tar.gz"
  curl -fsSL "$sums_url" -o "$tmpdir/checksums.txt" || true

  echo "Expected checksum for tunneld-pre-alpha.tar.gz:"
  grep "tunneld-pre-alpha.tar.gz" "$tmpdir/checksums.txt" || echo "No checksum found."

  if grep -q "tunneld-pre-alpha.tar.gz" "$tmpdir/checksums.txt" 2>/dev/null; then
    (
      cd "$tmpdir"
      if sha256sum --status -c checksums.txt 2>/dev/null; then
        echo "Checksum verified."
      else
        echo "WARNING: checksum did not verify. Proceeding anyway."
      fi
    )
  else
    echo "Skipping checksum verification."
  fi

  tar -xzf "$tmpdir/tunneld-pre-alpha.tar.gz" -C "$APP_DIR"
  rm -rf "$tmpdir"

  whiptail --msgbox \
"Tunneld pre-alpha files placed in:
  $APP_DIR

This is an unsigned pre-alpha build, not a final tagged release.
" 14 70
else
  whiptail --msgbox \
"Skipping Tunneld download.

Make sure a valid Tunneld release exists in:
  $APP_DIR

Expected structure:
  bin/
  erts-*/
  lib/
  releases/
" 16 70
fi

SECRET_KEY_BASE=$(openssl rand -hex 64)
cat > /etc/systemd/system/tunneld.service <<EOF
[Unit]
Description=Tunneld
After=network-online.target dhcpcd.service dnscrypt-proxy.service
Wants=network-online.target dhcpcd.service dnscrypt-proxy.service

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

tee /etc/resolv.conf > /dev/null <<EOF
nameserver 127.0.0.1
EOF

systemctl daemon-reload
systemctl enable dhcpcd dnsmasq dnscrypt-proxy nginx tunneld
systemctl restart nginx
systemctl restart dhcpcd
systemctl restart dnscrypt-proxy
systemctl restart dnsmasq
systemctl restart tunneld

whiptail --title "Installation Complete" --msgbox \
"Tunneld installation complete.

App:    $APP_DIR
Config: $CONFIG_DIR
Data:   $DATA_DIR

Access:
  http://$GATEWAY

Verify services running:
  systemctl status nginx dnscrypt-proxy dnsmasq dhcpcd tunneld

OpenZiti/Zrok:
  To expose services, connect to your device to Tunneld OpenZiti controller through the dashboard to get started.
  Aim to use the self-host guide: https://docs.zrok.io/docs/category/self-hosting/ to get started with your own in time.

Done." 24 80
