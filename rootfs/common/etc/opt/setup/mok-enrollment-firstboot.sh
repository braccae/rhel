#!/bin/bash
set -euo pipefail

MARKER_FILE="/var/lib/mok-enrollment-firstboot-done"

# Exit early if marker file exists
if [[ -f "$MARKER_FILE" ]]; then
    exit 0
fi

# Create marker directory and file on exit
mkdir -p /var/lib
trap 'touch "$MARKER_FILE"' EXIT

# Check if MOK certificate exists
MOK_CERT="/etc/pki/mok/LOCALMOK.der"
if [[ ! -f "$MOK_CERT" ]]; then
    echo "MOK certificate not found. Skipping MOK enrollment setup."
    exit 0
fi

# Check if we're in UEFI mode
if [[ ! -d /sys/firmware/efi ]]; then
    echo "Not running in UEFI mode. Skipping MOK enrollment setup."
    exit 0
fi

# Enable the MOK enrollment service
echo "Setting up MOK enrollment for first boot..."
systemctl enable mok-enrollment.service

echo "MOK enrollment service enabled. It will run on first boot."
echo "The service will guide you through the MOK enrollment process."

exit 0