#!/bin/bash

# First-boot MOK enrollment script
# This script runs on first boot to automatically enroll the MOK key

set -e

# Configurable MOK password
MOK_PASSWORD="zfs"

MOK_CERT="/etc/pki/mok/LOCALMOK.der"
MOK_ENROLLMENT_MARKER="/var/lib/mok-enrollment"
MOK_COMPLETED_FILE="$MOK_ENROLLMENT_MARKER/completed"

# Create marker directory
mkdir -p "$MOK_ENROLLMENT_MARKER"

# Check if we're in UEFI mode
if [[ ! -d /sys/firmware/efi ]]; then
    touch "$MOK_COMPLETED_FILE"
    exit 0
fi

# Check if MOK certificate exists
if [[ ! -f "$MOK_CERT" ]]; then
    touch "$MOK_COMPLETED_FILE"
    exit 0
fi

# Check if Secure Boot is enabled
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    SECURE_BOOT_ENABLED=true
else
    SECURE_BOOT_ENABLED=false
fi

# Check if MOK is already enrolled
if mokutil --list-enrolled 2>/dev/null | grep -q "LOCALMOK"; then
    # MOK key is already enrolled
    :
else
    if [[ "$SECURE_BOOT_ENABLED" == "true" ]]; then
        # Auto-enroll MOK key with configured password
        echo "$MOK_PASSWORD" | mokutil --import "$MOK_CERT"
    fi
fi

# Mark enrollment as completed (this just means the script ran)
touch "$MOK_COMPLETED_FILE"