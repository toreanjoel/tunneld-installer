#!/bin/bash

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root or with sudo"
  exit 1
fi

# System Requirements Check
echo "Checking system requirements..."

# Check for Debian-based system
if ! command -v apt-get &> /dev/null; then
  whiptail --title "Unsupported OS" --msgbox "ERROR: This installer only supports Debian-based systems (Debian, Ubuntu, Raspberry Pi OS, etc.)\n\nYour system does not appear to be Debian-based (apt-get not found).\n\nInstallation cannot continue." 12 70
  exit 1
fi

# Check architecture
ARCH=$(uname -m)
case $ARCH in
  aarch64|arm64|armv7l|armhf|armv6l)
    echo "Detected ARM architecture: $ARCH"
    ;;
  *)
    whiptail --title "Unsupported Architecture" --msgbox "ERROR: This installer only supports ARM-based systems.\n\nDetected architecture: $ARCH\n\nSupported architectures:\n- ARM64 (aarch64)\n- ARMv7 (armv7l/armhf)\n- ARMv6 (armv6l)\n\nInstallation cannot continue." 14 70
    exit 1
    ;;
esac

DEVICE_ID=$(cat /proc/sys/kernel/random/uuid)

# Directory structure
APP_DIR="/opt/tunneld"
BIN_DIR="$APP_DIR/bin"
LIB_DIR="$APP_DIR/lib"
CONFIG_DIR="/etc/tunneld"
LOG_DIR="/var/log/tunneld"
RUNTIME_DIR="/var/run/tunneld"
DATA_DIR="/var/lib/tunneld"
BLACKLIST_DIR="$CONFIG_DIR/blacklists"
DNSCRYPT_DIR="$CONFIG_DIR/dnscrypt"

# Create all necessary directories
mkdir -p "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR" "$LOG_DIR" "$RUNTIME_DIR" \
         "$DATA_DIR" "$BLACKLIST_DIR" "$DNSCRYPT_DIR"

cancel_check() {
  if [ $? -ne 0 ]; then
    echo "Cancelled. Exiting..."
    exit 1
  fi
}

# 0. Welcome Message
whiptail --title "Welcome to Tunneld Installer" --msgbox "Welcome to Tunneld - a portable, wireless-first gateway for self-hosters, developers, and edge network builders.

Tunneld makes it easy to:
- Expose local services to the internet securely over OpenZiti overlay network using Zrok
- Share compute, storage, or applications between trusted devices
- Create Zero Trust-like environments with fine-grained access control

Built-in capabilities include:
- DHCP and DNS management (Isolated Network Gateway)
- DNS Encryption (dnscrypt-proxy)
- Tracker and ad blocking via blacklist enforcement

Ideal for those who want orchestration, portability, and privacy without relying on third-party platforms.

Press OK to begin." 24 75

# 0.1 Support Message
whiptail --title "Support Tunneld" --msgbox "Thank You for Using Tunneld!

Tunneld is free and open-source, built with passion by someone who believes in privacy and self-hosting.

If you find Tunneld useful, please consider:

Star us on GitHub - It helps others discover the project
Support via donations - Helps maintain and improve Tunneld
Spread the word - Tell your friends and community
Report bugs & suggest features - Your feedback matters

Every bit of support helps keep this project alive and growing!

GitHub: https://github.com/toreanjoel/tunneld
Donate: [TODO - Add donation link]

Press OK to continue with installation." 22 75

# 1. Pull Tunneld Release
if whiptail --title "Download Tunneld Release" --yesno "Download and install the latest Tunneld release?" 10 60; then
  TEMP_DIR=$(mktemp -d)
  
  # Download the latest release binary
  echo "Downloading latest Tunneld release..."
  RELEASE_URL="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-arm64.tar.gz"
  
  # Detect architecture and download appropriate binary
  ARCH=$(uname -m)
  case $ARCH in
    x86_64)
      RELEASE_URL="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-amd64.tar.gz"
      ;;
    aarch64|arm64)
      RELEASE_URL="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-arm64.tar.gz"
      ;;
    armv7l|armhf)
      RELEASE_URL="https://github.com/toreanjoel/tunneld/releases/latest/download/tunneld-linux-armv7.tar.gz"
      ;;
    *)
      whiptail --title "Unsupported Architecture" --msgbox "Architecture $ARCH is not supported.\nPlease build from source: https://github.com/toreanjoel/tunneld" 10 60
      exit 1
      ;;
  esac
  
  # Download and extract
  if curl -L "$RELEASE_URL" -o "$TEMP_DIR/tunneld.tar.gz"; then
    tar -xzf "$TEMP_DIR/tunneld.tar.gz" -C "$TEMP_DIR"
    
    # Copy binary
    if [ -f "$TEMP_DIR/tunneld_binary" ]; then
      cp "$TEMP_DIR/tunneld_binary" "$BIN_DIR/"
      chmod +x "$BIN_DIR/tunneld_binary"
    fi
    
    # Copy any additional files (libs, assets, etc)
    if [ -d "$TEMP_DIR/lib" ]; then
      cp -r "$TEMP_DIR/lib/"* "$LIB_DIR/"
    fi
    
    rm -rf "$TEMP_DIR"
    whiptail --title "Tunneld Installed" --msgbox "Tunneld installed to $APP_DIR" 8 60
  else
    whiptail --title "Download Failed" --msgbox "Failed to download Tunneld release.\n\nPlease check your internet connection or install manually.\n\nSee: https://github.com/toreanjoel/tunneld/releases" 12 60
    exit 1
  fi
else
  whiptail --title "Release Skipped" --msgbox "Skipping download. You must place binaries manually in $BIN_DIR\n\nDownload from: https://github.com/toreanjoel/tunneld/releases" 10 70
fi

# 2. Locale Setup
if whiptail --title "Locale Setup" --yesno "Would you like to configure system locales now?\n\nThis ensures the wireless system uses the correct regional settings (e.g. channel availability for WiFi)." 12 70; then
  dpkg-reconfigure locales || echo "Locale configuration failed. Please check your environment manually."
  locale-gen || echo "Locale generation failed."
  whiptail --title "Locale Configured" --msgbox "Locale configuration completed or skipped by user." 8 50
else
  whiptail --title "Locale Skipped" --msgbox "Locale setup was skipped. This may affect WiFi compatibility." 8 50
fi

# 3. Update System
if whiptail --title "System Update" --yesno "Run 'apt-get update && apt-get upgrade -y'?\n\nThis ensures your system has the latest package versions and security updates." 12 70; then
  if apt-get update && apt-get upgrade -y; then
    whiptail --title "Update Complete" --msgbox "System packages updated successfully." 8 50
  else
    whiptail --title "Update Error" --msgbox "There was an error updating your system. You may continue but some operations may fail." 10 60
  fi
else
  whiptail --title "Update Skipped" --msgbox "System update skipped by user. Proceeding with existing package state." 8 50
fi

# 4. Install Dependencies
if whiptail --title "Install Dependencies" --yesno "Install required dependencies (dnsmasq, dhcpcd, dnscrypt-proxy, etc)?" 10 60; then
  apt-get install -y dnsmasq dhcpcd5 git dkms build-essential \
    libjson-c-dev libwebsockets-dev libssl-dev iptables bc unzip \
    dnscrypt-proxy
  
  # Install OpenZiti and Zrok
  curl -sSf https://get.openziti.io/install.bash | bash -s -y zrok
  
  whiptail --title "Dependencies Installed" --msgbox "All required packages have been installed." 8 50
else
  whiptail --title "Dependencies Skipped" --msgbox "You chose not to install dependencies. Ensure they are available for Tunneld to function." 10 60
fi

# 5. Select Interfaces
interfaces=( $(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo') )

menu_items=()
for i in "${interfaces[@]}"; do menu_items+=("$i" ""); done
up_iface=$(whiptail --title "Upstream Interface (Internet)" --menu "Select the interface that connects to the internet (WiFi/WAN):" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
cancel_check

menu_items=()
for i in "${interfaces[@]}"; do [ "$i" != "$up_iface" ] && menu_items+=("$i" "") ; done
selected=$(whiptail --title "Downstream Interfaces (LAN)" --menu "Select interface(s) to share internet with (Ethernet/LAN):" 20 60 10 "${menu_items[@]}" 3>&1 1>&2 2>&3)
cancel_check
down_iface="$selected"

# 6. Network Settings
gateway=$(whiptail --title "Gateway IP Address" --inputbox "Enter the gateway IP address (e.g. 10.0.0.1):" 10 60 "10.0.0.1" 3>&1 1>&2 2>&3)
dhcp_start=$(whiptail --title "DHCP Range Start" --inputbox "Start of DHCP range (e.g. 10.0.0.2):" 10 60 "10.0.0.2" 3>&1 1>&2 2>&3)
dhcp_end=$(whiptail --title "DHCP Range End" --inputbox "End of DHCP range (e.g. 10.0.0.100):" 10 60 "10.0.0.100" 3>&1 1>&2 2>&3)

# 7. Store interface config for reference
cat <<EOF > "$CONFIG_DIR/interfaces.conf"
UPSTREAM_INTERFACE=$up_iface
DOWNSTREAM_INTERFACE=$down_iface
GATEWAY_IP=$gateway
DHCP_START=$dhcp_start
DHCP_END=$dhcp_end
DEVICE_ID=$DEVICE_ID
EOF

# 8. dhcpcd.conf
cat <<EOF > "$CONFIG_DIR/dhcpcd.conf"
# Tunneld DHCPCD Configuration
interface $down_iface
static ip_address=${gateway}/24
nohook wpa_supplicant
metric 250

interface $up_iface
nohook wpa_supplicant
metric 100
EOF

# Symlink to system location
ln -sf "$CONFIG_DIR/dhcpcd.conf" /etc/dhcpcd.conf

# 9. dnsmasq.conf
cat <<EOF > "$CONFIG_DIR/dnsmasq.conf"
# Tunneld DNSMasq Configuration
domain=tunneld.lan
local=/tunneld.lan/
expand-hosts

# Listen on custom port (dnscrypt-proxy uses 53)
port=5336
interface=$down_iface
bind-interfaces

# DHCP Configuration
dhcp-range=${dhcp_start},${dhcp_end},255.255.255.0,infinite
dhcp-option=option:router,$gateway
dhcp-option=option:dns-server,$gateway
dhcp-option=15,tunneld.lan
dhcp-option=119,tunneld.lan

# DNS Configuration
no-resolv
# Forward to dnscrypt-proxy on port 5335
server=127.0.0.1#5335

# Blacklist enforcement
conf-file=$BLACKLIST_DIR/dnsmasq-system.blacklist

# Local DNS entries
address=/tunneld.lan/$gateway
address=/gateway.tunneld.lan/$gateway

# Logging
log-queries
log-facility=$LOG_DIR/dnsmasq.log
EOF

# 10. DNSCrypt-Proxy Configuration
cat <<EOF > "$DNSCRYPT_DIR/dnscrypt-proxy.toml"
# Tunneld DNSCrypt-Proxy Configuration
listen_addresses = ['127.0.0.1:5335']
max_clients = 250

# Privacy-focused DNS servers
server_names = ['mullvad-doh', 'quad9-dnscrypt-ip4-filter-pri']

# DNSCrypt sources
[sources]
  [sources.'public-resolvers']
  urls = ['https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md', 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md']
  cache_file = '$DNSCRYPT_DIR/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
EOF

# 11. Blacklist Update Script
cat <<EOF > "$BIN_DIR/update_blacklist.sh"
#!/bin/bash
# Tunneld Blacklist Update Script
curl -sSL https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt \
  -o "$BLACKLIST_DIR/dnsmasq-system.blacklist"
echo "Blacklist updated at \$(date)" | tee -a "$LOG_DIR/blacklist.log"

# Reload dnsmasq to apply changes if running
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
  systemctl reload dnsmasq
fi
EOF
chmod +x "$BIN_DIR/update_blacklist.sh"

# Run initial blacklist generation
"$BIN_DIR/update_blacklist.sh"

# 12. Create systemd service for Tunneld
cat <<EOF > "/etc/systemd/system/tunneld.service"
[Unit]
Description=Tunneld Service - OpenZiti Gateway
After=network-online.target
Wants=network-online.target
Before=dnsmasq.service

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$BIN_DIR/tunneld_binary
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/tunneld.log
StandardError=append:$LOG_DIR/tunneld-error.log

# Environment variables
Environment=LANG=en_US.UTF-8
Environment=SECRET_KEY_BASE=$(openssl rand -hex 64)
Environment=WIFI_INTERFACE=$up_iface
Environment=LAN_INTERFACE=$down_iface
Environment=GATEWAY=$gateway
Environment=DEVICE_ID=$DEVICE_ID
Environment=HOSTNAME=tunneld.lan
Environment=CONFIG_DIR=$CONFIG_DIR
Environment=DATA_DIR=$DATA_DIR
Environment=LOG_DIR=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF

# 13. IP Forwarding setup
cat <<EOF > "$BIN_DIR/setup_routing.sh"
#!/bin/bash
# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -w net.ipv4.ip_forward=1

# Make it persistent
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
EOF
chmod +x "$BIN_DIR/setup_routing.sh"

# Run routing setup
"$BIN_DIR/setup_routing.sh"

# 14. Enable and start services
systemctl daemon-reload
systemctl enable dhcpcd && systemctl restart dhcpcd
systemctl enable dnsmasq && systemctl restart dnsmasq
systemctl enable tunneld && systemctl start tunneld

# 15. Final Notes
whiptail --title "Installation Complete" --msgbox "Tunneld installation complete!

Installation Paths:
- Application: $APP_DIR
- Configuration: $CONFIG_DIR
- Logs: $LOG_DIR
- Data: $DATA_DIR

Network Configuration:
- Gateway IP: $gateway
- Upstream Interface: $up_iface
- Downstream Interface: $down_iface
- DHCP Range: $dhcp_start - $dhcp_end

Access Dashboard:
- http://$gateway
- http://tunneld.lan

OpenZiti/Zrok:
To expose services, connect to your device to Tunneld OpenZiti controller through the dashboard to get started.
Aim to use the self-host guide: https://docs.zrok.io/docs/category/self-hosting/ to get started with your own in time.

Device ID: $DEVICE_ID

Thank you for installing Tunneld!" 28 80