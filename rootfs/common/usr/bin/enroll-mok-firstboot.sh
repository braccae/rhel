#!/bin/bash

# First-boot MOK enrollment script
# This script runs on first boot to help users enroll the MOK key

set -e

MOK_CERT="/etc/pki/mok/LOCALMOK.der"
MOK_ENROLLMENT_MARKER="/var/lib/mok-enrollment"
MOK_COMPLETED_FILE="$MOK_ENROLLMENT_MARKER/completed"

# Create marker directory
mkdir -p "$MOK_ENROLLMENT_MARKER"

# Function to display colored output
print_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

print_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

print_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

# Check if we're in UEFI mode
if [[ ! -d /sys/firmware/efi ]]; then
    print_info "Not running in UEFI mode - MOK enrollment not applicable"
    touch "$MOK_COMPLETED_FILE"
    exit 0
fi

# Check if MOK certificate exists
if [[ ! -f "$MOK_CERT" ]]; then
    print_warning "MOK certificate not found at $MOK_CERT"
    touch "$MOK_COMPLETED_FILE"
    exit 0
fi

# Check if Secure Boot is enabled
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    SECURE_BOOT_ENABLED=true
else
    SECURE_BOOT_ENABLED=false
fi

# Display enrollment information
echo
echo "=================================================================="
echo "           MOK Key Enrollment for Secure Boot"
echo "=================================================================="
echo

if [[ "$SECURE_BOOT_ENABLED" == "true" ]]; then
    print_info "Secure Boot is ENABLED"
    echo
    echo "This system contains signed kernel modules (ZFS) that require"
    echo "MOK (Machine Owner Key) enrollment to work with Secure Boot."
    echo
    echo "The MOK certificate has been pre-installed at:"
    echo "  $MOK_CERT"
    echo
    echo "To complete the enrollment:"
    echo "1. Reboot this system now"
    echo "2. When prompted during boot, press any key to enter the MOK manager"
    echo "3. Select 'Enroll MOK'"
    echo "4. Select 'Continue'"
    echo "5. Choose 'Yes' to enroll the key"
    echo "6. Enter a password when prompted (optional)"
    echo "7. Select 'Reboot'"
    echo
    print_warning "After enrollment, the signed kernel modules will load automatically"
else
    print_info "Secure Boot is NOT enabled"
    echo
    echo "MOK enrollment is not required, but the certificate is available"
    echo "at $MOK_CERT if you enable Secure Boot later."
fi

echo
echo "=================================================================="

# Check if MOK is already enrolled
if mokutil --list-enrolled 2>/dev/null | grep -q "LOCALMOK"; then
    print_success "MOK key is already enrolled!"
    echo "Signed kernel modules should load correctly."
else
    if [[ "$SECURE_BOOT_ENABLED" == "true" ]]; then
        print_warning "MOK key is not yet enrolled"
        echo "Please follow the enrollment instructions above."
        echo 'zfs' | mokutil --import /etc/pki/mok/LOCALMOK.der
    fi
fi

echo

# Mark enrollment as completed (this just means the script ran)
touch "$MOK_COMPLETED_FILE"

# Offer to reboot if Secure Boot is enabled and MOK not enrolled
if [[ "$SECURE_BOOT_ENABLED" == "true" ]] && ! mokutil --list-enrolled 2>/dev/null | grep -q "LOCALMOK"; then
    echo
    read -p "Would you like to reboot now to complete MOK enrollment? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Rebooting system in 5 seconds..."
        sleep 5
        reboot
    fi
fi