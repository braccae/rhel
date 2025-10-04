#!/bin/bash
set -euo pipefail

MARKER_FILE="/var/lib/qemu-guest-agent-firstboot-done"
SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
PRODUCT_NAME="/sys/class/dmi/id/product_name"

# Exit early if marker file exists
if [[ -f "$MARKER_FILE" ]]; then
    exit 0
fi

# Create marker directory and file on exit
mkdir -p /var/lib
trap 'touch "$MARKER_FILE"' EXIT

# Check for QEMU/KVM environment
is_qemu=0
if [[ -r "$SYS_VENDOR" ]]; then
    sys_vendor=$(< "$SYS_VENDOR")
    if [[ "$sys_vendor" =~ QEMU || "$sys_vendor" =~ Bochs ]]; then
        is_qemu=1
    fi
fi

if [[ $is_qemu -eq 0 && -r "$PRODUCT_NAME" ]]; then
    product_name=$(< "$PRODUCT_NAME")
    if [[ "$product_name" =~ KVM || "$product_name" =~ Bochs ]]; then
        is_qemu=1
    fi
fi

# Enable/start guest agent if in QEMU
if [[ $is_qemu -eq 1 ]]; then
    echo "Detected QEMU/KVM environment. Enabling qemu-guest-agent..."
    systemctl enable qemu-guest-agent
    systemctl start qemu-guest-agent
else
    echo "Not running in QEMU/KVM. Skipping guest agent setup."
fi

exit 0