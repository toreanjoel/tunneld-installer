# Tunneld Installer

> **⚠️ Tunneld is currently in active development.**
>
> The binary release will be made available on the [Tunneld repository](https://github.com/toreanjoel/tunneld) once the project is open-sourced.
>
> For early access to test builds or to participate in pre-release evaluations, please contact [Torean Joel](https://github.com/toreanjoel) directly.

---

Official installer script for [Tunneld](https://github.com/toreanjoel/tunneld) — a portable, wireless-first programmable gateway for self-hosters, developers, and edge network builders.

---

## Quick Remote Install

Install Tunneld directly without cloning the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

## What is Tunneld?

Tunneld is a self-hosted network gateway that provides:

- **Secure Service Exposure** – Share local services to the internet securely over the [OpenZiti](https://netfoundry.io/docs/openziti) overlay network using [Zrok](https://zrok.io/).

- **Zero Trust Networking** – Create private networks with fine-grained access control between trusted devices.

- **Built-in Network Services**:

  - DHCP and DNS management (Isolated Network Gateway)
  - DNS Encryption via dnscrypt-proxy ([Mullvad](https://mullvad.net/))
  - Tracker and ad blocking with blacklist enforcement ([Default Block List](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt))
    [Support the creator](https://github.com/hagezi/dns-blocklists)

- **Privacy-First** – No reliance on third-party platforms, full control over your infrastructure.

Perfect for developers, home-lab enthusiasts, and anyone wanting to self-host without exposing their home network directly to the internet.

---

## What the Installer Does

The `install.sh` script performs a complete, guided setup:

### 1) Guided Configuration

- Detects available network interfaces.
- Prompts for:

  - Upstream (WAN/Wi-Fi) and downstream (LAN/Ethernet) interfaces.
  - Gateway IP (default: `10.0.0.1`).
  - DHCP range (default: `10.0.0.2–10.0.0.100`).

### 2) Installs and Configures Dependencies

Installs:

- `dnsmasq` (DNS/DHCP server)
- `dhcpcd` (network configuration)
- `dnscrypt-proxy` (encrypted DNS)
- `iptables`, `bc`, `unzip`, and build dependencies
- [OpenZiti](https://openziti.io/) and [Zrok](https://zrok.io/)

### 3) Configures System Services

- Creates configuration files under `/etc/tunneld/`.

- Links configuration files:

  - `/etc/dhcpcd.conf` → `/etc/tunneld/dhcpcd.conf`
  - `/etc/dnsmasq.conf` → `/etc/tunneld/dnsmasq.conf`

- Enables DHCP, DNS, and encrypted DNS forwarding.

- Fetches and applies the [Hagezi blocklist](https://github.com/hagezi/dns-blocklists).

### 4) Deploys and Enables Tunneld

- Optionally downloads the latest Tunneld release from GitHub.

- Registers systemd services:

  - `tunneld.service`
  - `dnscrypt-proxy.service`
  - `dnsmasq.service`
  - `dhcpcd.service`

- Starts all services automatically and launches the dashboard.

---

## Installation

### Prerequisites

- Debian/Ubuntu-based Linux system (e.g., Raspberry Pi OS, Ubuntu Server)
- Two network interfaces (one WAN, one LAN)
- Ensure drivers and firmware for both interfaces are installed

### Quick Start

```bash
git clone https://github.com/toreanjoel/tunneld-installer
cd tunneld-installer
chmod +x install.sh
sudo ./install.sh
```

Follow the interactive prompts to complete installation.

---

## After Installation

Once setup completes:

1. **Access the dashboard:**

   ```
   http://10.0.0.1
   http://tunneld.lan
   http://gateway.tunneld.lan
   ```

2. **Verify services:**

   ```bash
   systemctl status tunneld dnscrypt-proxy dnsmasq dhcpcd
   ```

3. **Expose services securely:**

   - Use Zrok to share local services.
   - To self-host your controller, follow the [Zrok Self-Hosting Guide](https://docs.zrok.io/docs/category/self-hosting/).

---

## Uninstallation

To completely remove Tunneld:

```bash
sudo ./uninstall.sh
```

The uninstaller will:

1. Stop and disable `tunneld` and `dnscrypt-proxy`.

2. Stop and disable any `zrok-*` services.

3. Remove:

   - `/opt/tunneld`
   - `/etc/tunneld`
   - `/var/lib/tunneld`
   - `/var/log/tunneld`
   - `/var/run/tunneld`

4. Remove `/usr/local/bin/dnscrypt-proxy`.

5. Remove all related systemd units (`tunneld.service`, `dnscrypt-proxy.service`, `zrok-*`).

6. Remove `/etc/dnsmasq.conf` and `/etc/dhcpcd.conf` if they are symlinks to Tunneld.

7. Restart `dnsmasq` and `dhcpcd` (best effort).

---

## Directory Layout

```
/opt/tunneld/              Application binaries and releases
/etc/tunneld/              Configuration files
/var/log/tunneld/          Log files
/var/lib/tunneld/          Persistent data (auth.json, shares.json, etc.)
/var/run/tunneld/          Runtime data and temporary files
```

---

## Key Configuration Files

All configuration files are stored in `/etc/tunneld/`.

| File                                  | Purpose                         |
| ------------------------------------- | ------------------------------- |
| `interfaces.conf`                     | Network interface mappings      |
| `dhcpcd.conf`                         | Network interface configuration |
| `dnsmasq.conf`                        | DNS/DHCP configuration          |
| `dnscrypt/dnscrypt-proxy.toml`        | DNS encryption settings         |
| `blacklists/dnsmasq-system.blacklist` | Ad and tracker blocking rules   |

---

## Support the Project and Its Creators

Tunneld integrates with several incredible open-source tools and services. If you find this project useful, please consider supporting the creators who make it possible:

- [Tunneld Project](https://github.com/toreanjoel/tunneld)
- [OpenZiti / NetFoundry](https://netfoundry.io/)
- [Zrok](https://zrok.io/)
- [Hagezi DNS Blocklists](https://github.com/hagezi/dns-blocklists)
- [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy)
- [Mullvad](https://mullvad.net/)

Each plays a crucial role in providing the privacy, performance, and flexibility that Tunneld builds upon.

---

Tunneld is free and open-source.

- Star the project on GitHub: [github.com/toreanjoel/tunneld](https://github.com/toreanjoel/tunneld)
- Share it with your community and support the open-source ecosystem.
