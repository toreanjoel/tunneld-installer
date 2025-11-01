#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

need_root() { [ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }; }
need_root

APP_DIR="/opt/tunneld"
SERVICE_NAME="tunneld"
TMPDIR="$(mktemp -d)"

BETA_URL="https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/releases/tunneld-beta-linux-arm64.tar.gz"
SUMS_URL="https://raw.githubusercontent.com/toreanjoel/tunneld-installer/main/releases/checksums.txt"
BETA_FILE="$TMPDIR/tunneld-beta.tar.gz"
SUMS_FILE="$TMPDIR/checksums.txt"

# Intro
whiptail --title "Tunneld Updater" --msgbox \
"This will update the Tunneld beta build.

⚠️ IMPORTANT WARNING ⚠️
- This is a pre-release update.
- You may lose data, configuration files, or logs during extraction.
- Backup your /opt/tunneld and /etc/tunneld directories if you want to preserve changes.
- Updates are performed entirely at your own risk.

What this does:
  1) Stop the tunneld service
  2) Download the current ARM64 beta build
  3) Show and attempt to verify the checksum
  4) Extract into $APP_DIR (may overwrite files)
  5) Restart tunneld

Your network config (DHCP, dnsmasq, dhcpcd) will not be touched.

Press OK to continue or Cancel to abort." 24 76

echo "Stopping service: $SERVICE_NAME"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

echo "Downloading beta build..."
curl -fL "$BETA_URL" -o "$BETA_FILE"

echo "Downloading checksums..."
if curl -fsSL "$SUMS_URL" -o "$SUMS_FILE"; then
  echo "Expected checksum (tunneld-beta-linux-arm64.tar.gz):"
  grep "tunneld-beta-linux-arm64.tar.gz" "$SUMS_FILE" || echo "No checksum entry found"

  # Attempt checksum verification
  (
    cd "$TMPDIR"
    if sha256sum --status -c "$SUMS_FILE" 2>/dev/null; then
      echo "Checksum verified."
    else
      echo "⚠️ WARNING: checksum failed or could not be verified."
    fi
  )
else
  echo "No checksums.txt available. Skipping verification."
fi

echo "Extracting into $APP_DIR ..."
echo "⚠️ WARNING: Existing files in $APP_DIR may be overwritten!"
echo "It is recommended to back up your data before proceeding."
tar -xzf "$BETA_FILE" -C "$APP_DIR"

echo "Cleaning up temp files..."
rm -rf "$TMPDIR"

echo "Restarting service: $SERVICE_NAME"
systemctl daemon-reload || true
systemctl start "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager || true

whiptail --title "Update Complete" --msgbox \
"Tunneld beta update complete.

Current install directory:
  $APP_DIR

Service restarted:
  $SERVICE_NAME

⚠️ Reminder:
  - This update may have replaced or removed previous files.
  - Always keep backups of /opt/tunneld and /etc/tunneld.

Note:
  This is a beta build. Behavior and APIs may change
  without notice until public, tagged releases are published." 24 76
