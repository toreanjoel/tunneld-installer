# Tunneld Installer

Official installer script for [Tunneld](https://github.com/toreanjoel/tunneld) - a portable, wireless-first programable gateway for self-hosters, developers, and edge network builders.

## What is Tunneld?

Tunneld is a self-hosted network gateway that provides:

- **Secure Service Exposure** - Share local services to the internet securely over [OpenZiti](https://netfoundry.io/docs/openziti) overlay network using [Zrok](https://zrok.io/)
- **Zero Trust Networking** - Create private networks with fine-grained access control between trusted devices
- **Built-in Network Services**:
  - DHCP and DNS management (Isolated Network Gateway)
  - DNS Encryption via dnscrypt-proxy ([Mullvad](https://mullvad.net/))
  - Tracker and ad blocking with blacklist enforcement ([Default Block List](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt), [Support The Creator](https://github.com/hagezi/dns-blocklists))
- **Privacy-First** - No reliance on third-party platforms, full control over your infrastructure

Perfect for developers, home-lab enthusiasts, and anyone wanting to self-host without exposing their home network directly to the internet.

## What Does This Installer Do?

The installer script:

1. **Guides you through setup** with an interactive menu:
   - Select upstream (WAN/WiFi) and downstream (LAN/Ethernet) interfaces
   - Configure gateway IP and DHCP range

2. **Installs and configures dependencies**:
   - dnsmasq (DNS/DHCP server)
   - dhcpcd (Network configuration)
   - dnscrypt-proxy (Encrypted DNS)
   - OpenZiti & Zrok (Overlay networking)

3. **Sets up system services**:
   - Configures networking and IP forwarding
   - Creates systemd services
   - Downloads and installs the latest Tunneld release

## Installation

### Prerequisites

- Debian/Ubuntu-based Linux system (Raspberry Pi, Ubuntu Server, etc.)
- At least 2 network interfaces (one for WAN, one for LAN) - Make sure the firmware for the devices are installed before installing

### Quick Start

```bash
git clone https://github.com/toreanjoel/tunneld-installer
cd tunneld-installer
chmod +x install.sh
sudo ./install.sh
```

Follow the interactive prompts to complete installation.

## Post-Installation

After installation completes:

1. **Access the dashboard**:
   - `http://<gateway-ip>` (e.g., `http://10.0.0.1`)
   - `http://tunneld.lan`
   - `http://gateway.tunneld.lan`

2. **Connect to OpenZiti overlay**:
   - Tunneld uses OpenZiti/Zrok for secure service exposure
   - You can self-host your own controller: [Zrok Self-Hosting Guide](https://docs.zrok.io/docs/category/self-hosting/)
   - Or use the default Tunneld controller (if available)

## Uninstalling

To completely remove Tunneld:

```bash
sudo ./uninstall.sh
```

The uninstaller will:
- Stop all Tunneld services
- Remove all files and configurations
- Clean up systemd services
- Optionally revert network changes

## Directory Structure

### Production Mode
```
/opt/tunneld/              # Application files
/etc/tunneld/              # Configuration files
/var/log/tunneld/          # Log files
/var/lib/tunneld/          # Persistent data
```

## Configuration Files

Key configuration files (in `/etc/tunneld/`):

- `dhcpcd.conf` - Network interface configuration
- `dnsmasq.conf` - DNS/DHCP server settings
- `dnscrypt/dnscrypt-proxy.toml` - DNS encryption config
- `blacklists/dnsmasq-system.blacklist` - Ad/tracker blocking rules
- `interfaces.conf` - Network interface mappings

## Support the Project

Tunneld is free and open-source. If you find it useful:

- ⭐ **Star us on GitHub** - Helps others discover the project
- 💰 **Support via donations** - [TODO: Add donation link]
- 📢 **Spread the word** - Share with friends and community