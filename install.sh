#!/bin/bash

set -e

INSTALL_DIR="$(pwd)"
SYSTEMD_DIR="$INSTALL_DIR/etc/systemd/system"
ETC_DIR="$INSTALL_DIR/etc"
LOG_DIR="$INSTALL_DIR/logs"
BLACKLIST_DIR="$INSTALL_DIR/blacklists"
DNSCRYPT_DIR="$INSTALL_DIR/dnscrypt"

mkdir -p "$SYSTEMD_DIR" "$ETC_DIR" "$LOG_DIR" "$BLACKLIST_DIR" "$DNSCRYPT_DIR"

cancel_check() {
  if [ $? -ne 0 ]; then
    echo "Cancelled. Exiting..."
    exit 1
  fi
}

# 0. Welcome Message
whiptail --title "Welcome to Tunneld Installer" --msgbox "Welcome to Tunneld - a portable, wireless-first gateway for self-hosters, developers, and edge network builders.

Tunneld makes it easy to:
- Expose local services to the internet securely using Cloudflare tunnels.
- Share compute, storage, or applications between trusted devices.
- Create Zero Trust-like environments with fine-grained access control.

Built-in capabilities include:
- DHCP and DNS management (Isolated Network Gateway)
- DNS Encryption (dnscrypt)
- Tracker and ad blocking via blacklist enforcement

Ideal for those who want orchestration, portability, and privacy without relying on third-party platforms while connected to public upstream networks.

Press OK to begin." 24 75

# 0.5 Pull Tunneld Release
if whiptail --title "Download Tunneld Release" --yesno "Download and extract the latest Tunneld release from the official repo?" 10 60; then
  git clone https://github.com/[TODO].git "$INSTALL_DIR/tunneld"
  whiptail --title "Tunneld Cloned" --msgbox "Tunneld release pulled into $INSTALL_DIR/tunneld" 8 60
else
  whiptail --title "Release Skipped" --msgbox "Skipping download. You must place the release manually in $INSTALL_DIR/tunneld" 8 60
fi

# 1. Locale Setup
if whiptail --title "Locale Setup" --yesno "Would you like to configure system locales now?\n\nThis ensures the wireless system uses the correct regional settings (e.g. channel availability for WiFi)." 12 70; then
  sudo dpkg-reconfigure locales || echo "Locale configuration failed. Please check your environment manually."
  sudo locale-gen || echo "Locale generation failed."
  whiptail --title "Locale Configured" --msgbox "Locale configuration completed or skipped by user." 8 50
else
  whiptail --title "Locale Skipped" --msgbox "Locale setup was skipped. This may affect WiFi compatibility." 8 50
fi

# 2. Update System
if whiptail --title "System Update" --yesno "Run 'sudo apt-get update && sudo apt-get upgrade -y'?\n\nThis ensures your system has the latest package versions and security updates." 12 70; then
  if sudo apt-get update && sudo apt-get upgrade -y; then
    whiptail --title "Update Complete" --msgbox "System packages updated successfully." 8 50
  else
    whiptail --title "Update Error" --msgbox "There was an error updating your system. You may continue but some operations may fail." 10 60
  fi
else
  whiptail --title "Update Skipped" --msgbox "System update skipped by user. Proceeding with existing package state." 8 50
fi

# 3. Install Dependencies
if whiptail --title "Install Dependencies" --yesno "Install required dependencies (dnsmasq, dhcpcd, build-essential, git, etc)?" 10 60; then
  sudo apt-get install -y dnsmasq dhcpcd5 git build-essential libjson-c-dev
  whiptail --title "Dependencies Installed" --msgbox "All required packages have been installed." 8 50
else
  whiptail --title "Dependencies Skipped" --msgbox "You chose not to install dependencies. Ensure they are available for Tunneld to function." 10 60
fi

# 4. Select Interfaces
interfaces=( $(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo') )

menu_items=()
for i in "${interfaces[@]}"; do menu_items+=("$i" ""); done
up_iface=$(whiptail --title "Upstream Interface (Internet)" --menu "Select the interface that connects to the internet (WiFi):" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
cancel_check

menu_items=()
for i in "${interfaces[@]}"; do [ "$i" != "$up_iface" ] && menu_items+=("$i" "") ; done
selected=$(whiptail --title "Downstream Interfaces (LAN)" --menu "Select interface(s) to share internet with (Ethernet):" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
cancel_check
down_iface="$selected"

# 5. Network Settings
gateway=$(whiptail --title "Gateway IP Address" --inputbox "Enter the gateway IP address (e.g. 10.0.0.1):" 10 60 "10.0.0.1" 3>&1 1>&2 2>&3)
dhcp_start=$(whiptail --title "DHCP Range Start" --inputbox "Start of DHCP range (e.g. 10.0.0.2):" 10 60 "10.0.0.2" 3>&1 1>&2 2>&3)
dhcp_end=$(whiptail --title "DHCP Range End" --inputbox "End of DHCP range (e.g. 10.0.0.100):" 10 60 "10.0.0.100" 3>&1 1>&2 2>&3)

# 6. cloudflared Installer
deb_url=$(whiptail --title "Cloudflared Download URL" --inputbox "Paste the .deb URL for cloudflared from Cloudflare (arm64 or amd64):" 10 70 3>&1 1>&2 2>&3)
curl -L "$deb_url" -o cloudflared.deb || echo "Download failed. Please download manually."
sudo dpkg -i cloudflared.deb || true

# 7. dhcpcd.conf
cat <<EOF > "$ETC_DIR/dhcpcd.conf"
interface $down_iface
static ip_address=${gateway}/24
nohook wpa_supplicant
metric 250

interface $up_iface
nohook wpa_supplicant
metric 100
EOF

# 8. dnsmasq.conf
cat <<EOF > "$ETC_DIR/dnsmasq.conf"
port=5336
interface=$down_iface
dhcp-range=${dhcp_start},${dhcp_end},255.255.255.0,infinite
dhcp-option=option:router,$gateway
dhcp-option=option:dns-server,$gateway
no-resolv
server=127.0.0.1#5335
conf-file=$BLACKLIST_DIR/dnsmasq-system.blacklist
address=/tunneld.local/$gateway
EOF

# 9. Blacklist Script
cat <<EOF > "$INSTALL_DIR/generate_blacklist.sh"
#!/bin/bash
curl -sSL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt -o "$BLACKLIST_DIR/dnsmasq-system.blacklist"
echo "Blacklist updated."
EOF
chmod +x "$INSTALL_DIR/generate_blacklist.sh"

# Run the blacklist generation script
"$INSTALL_DIR/generate_blacklist.sh"

# 10. Cloudflare Service
cf_domain=$(whiptail --title "Tunnel Domain" --inputbox "Enter a public Cloudflare hosted domain. (e.g. example.com):" 10 60 3>&1 1>&2 2>&3)
cf_zone_id=$(whiptail --title "Cloudflare Zone ID" --inputbox "Enter your Cloudflare Zone ID:" 10 60 3>&1 1>&2 2>&3)
cf_api_key=$(whiptail --title "Cloudflare API Token" --inputbox "Enter the API token with DNS edit permissions:" 10 60 3>&1 1>&2 2>&3)

cat <<EOF > "$SYSTEMD_DIR/tunneld.service"
[Unit]
Description=Tunneld Service
After=network.target

[Service]
User=root
WorkingDirectory=$INSTALL_DIR/tunneld
ExecStart=$INSTALL_DIR/tunneld/tunneld_binary
Restart=always
RestartSec=5
Environment=LANG=en_US.UTF-8
Environment=MIX_ENV=prod
Environment=PHX_SERVER=true
Environment=SECRET_KEY_BASE=$(openssl rand -hex 64)
Environment=TUNNEL_ORIGIN_CERT=$INSTALL_DIR/.cloudflared/cert.pem
Environment=CF_API_KEY=$cf_api_key
Environment=CF_ZONE_ID=$cf_zone_id
Environment=CF_DOMAIN=$cf_domain
Environment=WIFI_INTERFACE=$up_iface
Environment=LAN_INTERFACE=$down_iface
Environment=GATEWAY=$gateway
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=tunneld

[Install]
WantedBy=multi-user.target
EOF

# 11. Final Notes
sudo systemctl enable dhcpcd && sudo systemctl start dhcpcd
sudo systemctl enable dnsmasq && sudo systemctl start dnsmasq
sudo systemctl enable "$SYSTEMD_DIR/tunneld.service" && sudo systemctl start tunneld

whiptail --title "Installation Complete" --msgbox "Tunneld installation complete.

Gateway IP: $gateway
Access Dashboard: http://$gateway or http://tunneld.lan

Default login credentials:
This will be request on first login

Thank you for installing Tunneld." 20 75
