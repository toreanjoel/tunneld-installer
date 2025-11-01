# Tunneld Installer

> **⚠️ Tunneld is in active development (Beta Phase).**
>
> Pre-release ARM builds are distributed for testing.
> Only one "beta" build is published at a time.
> The source code and tagged public releases will become available once the project is open sourced.
> For early access and feedback, contact @toreanjoel.

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

Update to the newest beta build later (without reinstalling full networking):

```bash
curl -fsSL https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/update.sh -o update.sh
chmod +x update.sh
sudo ./update.sh
```

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

## Beta Builds and Integrity

During the beta phase:

- The installer and updater pull a single ARM64 tarball from this repo:

  - `releases/tunneld-beta-linux-arm64.tar.gz`

- A matching checksum file is published alongside it:

  - `releases/checksums.txt`

The installer and updater will:

1. Download the beta tarball
2. Download the checksum file
3. Show (and try to verify) the expected SHA256
4. Extract the binary into `/opt/tunneld`

There is intentionally only one active beta build in `releases/` at a time.
When a new beta is published, it replaces the previous one.

When the project goes open source, this will switch to versioned, tagged releases (for example `v1.0.0`, `v1.1.0`) hosted in the main Tunneld repository. At that point, both install and update will pull those signed/tagged releases.

---

## What is Tunneld?

Tunneld is a self-hosted network gateway that provides:

- **Secure Service Exposure** – Share local services to the internet securely over the [OpenZiti](https://netfoundry.io/docs/openziti) overlay network using [Zrok](https://zrok.io/).

- **Zero Trust Networking** – Create private networks with fine-grained access control between trusted devices.

- **Built-in Network Services**:

  - DHCP and DNS management (isolated gateway network)
  - DNS encryption via dnscrypt-proxy ([Mullvad](https://mullvad.net/))
  - Tracker and ad blocking with blacklist enforcement
    ([Default Block List](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt))
    [Support the creator](https://github.com/hagezi/dns-blocklists)

- **Privacy-First** – No reliance on third-party platforms, full control over your infrastructure.

This is useful for developers, home-lab builders, and anyone who wants portable, policy-controlled network access without exposing their main network directly.

---

## What the Installer Does

The `install.sh` script performs a complete, guided setup:

### 1) Guided Configuration

- Detects available network interfaces.
- Prompts for:

  - Upstream (WAN/Wi-Fi) and downstream (LAN/AP) interfaces.
  - Gateway IP (default: `10.0.0.1`).
  - DHCP range (default: `10.0.0.2–10.0.0.100`).

### 2) Installs and Configures Dependencies

Installs:

- `dnsmasq` (DNS/DHCP server)
- `dhcpcd` (network configuration)
- `dnscrypt-proxy` (encrypted DNS using Mullvad DoH)
- `iptables`, `bc`, `unzip`, and required build/runtime packages
- [OpenZiti](https://openziti.io/) and [Zrok](https://zrok.io/)

Also removes any distro-provided `dnscrypt-proxy` to avoid conflicts and replaces it with a configured instance.

### 3) Configures System Services

- Creates configuration under `/etc/tunneld/`.
- Symlinks:

  - `/etc/dhcpcd.conf` → `/etc/tunneld/dhcpcd.conf`
  - `/etc/dnsmasq.conf` → `/etc/tunneld/dnsmasq.conf`

- Enables DHCP, DNS, and encrypted DNS forwarding.
- Fetches and wires in the [Hagezi blocklist](https://github.com/hagezi/dns-blocklists) for tracker/ad blocking.

### 4) Deploys and Enables Tunneld

- Optionally downloads the current Tunneld beta build for ARM64 from this repo’s `releases/` directory.
- Shows and attempts to verify checksum.
- Extracts into `/opt/tunneld`.
- Writes and enables a `tunneld.service` systemd unit.
- Enables and/or restarts:

  - `tunneld.service`
  - `dnscrypt-proxy.service`
  - `dnsmasq.service`
  - `dhcpcd.service`

After this, the dashboard should be reachable.

---

## After Installation

1. Access the dashboard:

   ```
   http://10.0.0.1
   http://tunneld.lan
   http://gateway.tunneld.lan
   ```

2. Verify services:

   ```bash
   systemctl status tunneld dnscrypt-proxy dnsmasq dhcpcd
   ```

3. Expose services securely:

   - Use Zrok to share local services.
   - To self-host your controller, follow the Zrok self-hosting documentation.

---

## Updating Tunneld (beta builds)

To update just the Tunneld application binary without redoing network setup:

```bash
curl -fsSL https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/update.sh -o update.sh
chmod +x update.sh
sudo ./update.sh
```

What `update.sh` does:

1. Stops the `tunneld` service.
2. Downloads the current beta tarball (`tunneld-beta-linux-arm64.tar.gz`) and the published `checksums.txt`.
3. Shows and attempts to verify the checksum.
4. Extracts the new build into `/opt/tunneld`.
5. Restarts `tunneld`.

Your DHCP/DNS settings and network config are not touched.

When Tunneld transitions from beta to open source, `update.sh` will be updated to fetch signed, tagged releases from the main Tunneld repo instead of the single rotating beta build.

---

## Uninstallation

To completely remove Tunneld:

```bash
curl -fsSL https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/uninstall.sh -o uninstall.sh
chmod +x uninstall.sh
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
5. Remove all related systemd units.
6. Remove `/etc/dnsmasq.conf` and `/etc/dhcpcd.conf` if they are symlinks to Tunneld.
7. Restart `dnsmasq` and `dhcpcd` (best effort).

---

## Directory Layout

```text
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
| `dhcpcd.conf`                         | Gateway and interface config    |
| `dnsmasq.conf`                        | DNS/DHCP configuration          |
| `dnscrypt/dnscrypt-proxy.toml`        | Encrypted DNS resolver settings |
| `blacklists/dnsmasq-system.blacklist` | Ad/tracker block rules          |

---

## Support the Project and Its Creators

Tunneld builds on and integrates with several open-source projects.
If you find this useful, please consider supporting the creators:

- [Tunneld Project](https://github.com/toreanjoel/tunneld)
- [OpenZiti / NetFoundry](https://netfoundry.io/)
- [Zrok](https://zrok.io/)
- [Hagezi DNS Blocklists](https://github.com/hagezi/dns-blocklists)
- [dnscrypt-proxy](https://github.com/DNSCrypt/dnscrypt-proxy)
- [Mullvad](https://mullvad.net/)

Each of these plays a role in privacy, routing, DNS security, or controlled access.
