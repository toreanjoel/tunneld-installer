# Tunneld Installer

This repository provides the official installer script for [Tunneld](https://github.com/toreanjoel/sentinel), a self-hosted networking gateway and tunneling system designed for developers and home-lab enthusiasts.

## What is Tunneld?

Tunneld is a portable network gateway that allows:
- Exposing self-hosted services to the public internet securely using Cloudflare tunnels.
- Sharing compute resources and services with trusted devices on the network.
- Hosting applications without a VPS, all from a local devices on the tunneld network (artifacts).

## What does this installer do?

This script:
- Guides you through selecting upstream/downstream interfaces.
- Sets up networking configuration and service files.
- Installs dependencies like dnsmasq and cloudflared.
- Downloads the latest [Tunneld](https://github.com/toreanjoel/sentinel) release and prepares the system to run it.

## How to Use

```bash
git clone https://github.com/toreanjoel/tunneld-installer
cd tunneld-installer
./install.sh
