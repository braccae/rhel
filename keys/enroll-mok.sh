#!/bin/bash

# Script to help enroll the MOK key for Secure Boot
# This script should be run on the target system where Secure Boot is enabled

set -e

KEY_DIR="$(dirname "$0")"
PRIVATE_KEY="$KEY_DIR/LOCALMOK.priv"
PUBLIC_CERT="$KEY_DIR/LOCALMOK.der"

echo "=== MOK Key Enrollment Helper ==="
echo

# Check if we're running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root to enroll MOK keys"
   echo "Try: sudo $0"
   exit 1
fi

# Check if key files exist
if [[ ! -f "$PUBLIC_CERT" ]]; then
    echo "Error: Public certificate not found at $PUBLIC_CERT"
    exit 1
fi

echo "Found MOK public certificate: $PUBLIC_CERT"
echo

# Check if Secure Boot is enabled
if [[ -d /sys/firmware/efi ]]; then
    if mokutil --sb-state | grep -q "SecureBoot enabled"; then
        echo "✓ Secure Boot is enabled"
    else
        echo "⚠ Secure Boot is not enabled - MOK enrollment may not be necessary"
    fi
else
    echo "⚠ Not running in UEFI mode - MOK enrollment not supported"
    exit 1
fi

echo
echo "To enroll the MOK key:"
echo "1. Reboot the system"
echo "2. When prompted during boot, press any key to enter the MOK manager"
echo "3. Select 'Enroll MOK'"
echo "4. Select 'Continue'"
echo "5. Choose 'Yes' to enroll the key"
echo "6. Enter the password when prompted (leave empty if no password set)"
echo "7. Select 'Reboot'"
echo

# Copy the certificate to a temporary location for easier access
TEMP_CERT="/tmp/LOCALMOK.der"
cp "$PUBLIC_CERT" "$TEMP_CERT"
chmod 644 "$TEMP_CERT"

echo "MOK certificate copied to: $TEMP_CERT"
echo "You can use this file during the MOK enrollment process"
echo

# Optional: Show certificate info
echo "Certificate details:"
openssl x509 -in "$PUBLIC_CERT" -inform DER -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:)" || true

echo
echo "After enrollment, signed kernel modules will load successfully with Secure Boot."