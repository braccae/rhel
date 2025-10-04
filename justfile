# ==============================================================================
# Preamble with settings and private helper recipes.
# ==============================================================================
set shell := ["bash", "-c"]

# This recipe ensures that the command is run with root privileges.
# It automatically re-runs `just` with `run0` or `sudo` if not already root.
# It is intended to be used as a dependency for recipes that need elevation.
[private]
_escalate:
    #!/usr/bin/env bash
    set -euo pipefail
    # If we are not root, re-run the whole `just` command with elevation.
    if [[ $EUID -ne 0 ]]; then
        echo "This task requires root privileges. Attempting to escalate..."
        # Export current user's UID/GID so child processes can use them for chown
        export CALLING_UID=$(id -u)
        export CALLING_GID=$(id -g)
        if command -v run0 &> /dev/null; then
            exec run0 just "$@"
        elif command -v sudo &> /dev/null; then
            exec sudo just "$@"
        else
            echo "Error: Cannot escalate privileges. Please run with 'sudo' or 'run0'." >&2
            exit 1
        fi
    fi

# ==============================================================================
# MOK Key Management
# ==============================================================================

# Regenerate the MOK key pair for Secure Boot
# This will overwrite existing keys and require re-enrollment
regen-mok:
    #!/bin/bash
    set -euo pipefail
    echo "=== Regenerating MOK Key Pair ==="
    echo "WARNING: This will overwrite existing MOK keys!"
    echo "You will need to re-enroll the new key in Secure Boot."
    echo
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 1
    fi
    
    cd keys/mok
    echo "Generating new MOK key pair..."
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout LOCALMOK.priv \
        -outform DER -out LOCALMOK.der \
        -nodes -days 36500 \
        -subj "/CN=LOCALMOK/"
    chmod 600 LOCALMOK.priv
    
    echo "✓ MOK key pair regenerated successfully"
    echo "Public certificate: $(pwd)/LOCALMOK.der"
    echo "Private key: $(pwd)/LOCALMOK.priv"
    echo
    echo "Next steps:"
    echo "1. Rebuild your container image"
    echo "2. Run: sudo ./keys/enroll-mok.sh"
    echo "3. Reboot and enroll the new key"

# ==============================================================================
# This file is organized into sections based on the scripts they replace.
# ==============================================================================

# ==============================================================================
# Recipes from dev-tools/scripts/install/podman-build-disk-image.sh
# ==============================================================================

# Builds a qcow2 disk image from a container image.
# Usage: just build-disk-image <output_dir> <image_tag>
build-disk-image output_dir image_tag: _escalate
    podman pull ghcr.io/braccae/coreos:{{image_tag}}
    podman run \
        --rm \
        -it \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./config.toml:/config.toml:ro \
        -v ./output/{{image_tag}}:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type qcow2 \
        --use-librepo=True \
        --rootfs btrfs \
        ghcr.io/braccae/coreos:{{image_tag}}
    chown -fR ${SUDO_UID:-${CALLING_UID:-$(id -u)}}:${SUDO_GID:-${CALLING_GID:-$(id -g)}} ./output


# ==============================================================================
# Recipes from dev-tools/scripts/install/write-disk-image-to-disk.sh
# ==============================================================================

# Writes a disk image to a block device.
# DANGER: This will overwrite the destination disk. Use with extreme caution.
# Usage: just write-disk-image <image_file> <disk_device>
# Example: just write-disk-image build/qcow2/disk.qcow2 /dev/sdX
write-disk-image image_file disk: _escalate
    #!/bin/bash
    set -euo pipefail
    echo "DANGER: This will overwrite all data on {{disk}}".
    echo "You have 5 seconds to press Ctrl+C to cancel."
    sleep 5
    echo "Writing {{image_file}} to {{disk}}..."
    qemu-img convert -O raw -p {{image_file}} {{disk}}
    sync -f {{disk}}
    sync {{disk}}
    echo "Write complete."


# ==============================================================================
# Recipes from dev-tools/testvm.sh
# ==============================================================================

# Default variables for the test VM
_VM_MEMORY        := "2048"
_VM_VCPUS         := "2"
_VM_REMOTE_IMAGE  := "ghcr.io/braccae/coreos:centos"
_VM_LOCAL_TAG     := "localhost/coreos-test:latest"
_VM_BUILD_DIR     := "output/test-vm"
_VM_DISK_IMAGE    := _VM_BUILD_DIR + "/qcow2/disk.qcow2"

# Check for required dependencies for running a test VM
check-vm-deps:
    #!/bin/bash
    set -euo pipefail
    DEPS=("podman" "virsh" "virt-install" "qemu-img")
    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo "Error: Required dependency '$dep' not found. Please install it."
            exit 1
        fi
    done
    echo "All VM dependencies found."

# [private] Builds the bootable qcow2 disk image for the test VM.
# This is a helper recipe for the `test-vm` target.
_vm-build-disk containerfile='':
    #!/bin/bash
    set -euo pipefail
    if [[ -n '{{containerfile}}' ]]; then
        echo "--- Building local container image from {{containerfile}} ---"
        podman build --file '{{containerfile}}' --tag '{{_VM_LOCAL_TAG}}' "$(dirname '{{containerfile}}')"
        IMAGE_TO_USE='{{_VM_LOCAL_TAG}}'
    else
        echo "--- Using remote image: {{_VM_REMOTE_IMAGE}} ---"
        podman pull '{{_VM_REMOTE_IMAGE}}'
        IMAGE_TO_USE='{{_VM_REMOTE_IMAGE}}'
    fi

    echo "--- Building bootc disk image (rootfs: xfs) ---"
    mkdir -p '{{_VM_BUILD_DIR}}'

    podman run \
        --rm -it --privileged --pull=newer --security-opt label=type:unconfined_t \
        -v ./config.toml:/config.toml:ro \
        -v {{_VM_BUILD_DIR}}:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        quay.io/centos-bootc/bootc-image-builder:latest \
        --type qcow2 --use-librepo=True --rootfs xfs \
        "$IMAGE_TO_USE"

# Build and run an ephemeral test VM.
# The VM is automatically destroyed and cleaned up on exit.
# Usage: just test-vm [containerfile] [memory=2048] [vcpus=2]
# Example (remote image): just test-vm
# Example (local image):  just test-vm Containerfile
# Example (more resources): just test-vm '' 4096 4
test-vm containerfile='' memory=_VM_MEMORY vcpus=_VM_VCPUS: _escalate check-vm-deps ( _vm-build-disk containerfile )
    #!/bin/bash
    set -euo pipefail

    if [[ ! -f "{{_VM_DISK_IMAGE}}" ]]; then
        echo "Error: Disk image not found at {{_VM_DISK_IMAGE}}"
        exit 1
    fi

    VM_NAME="ephemeral-test-$(date +%s)"
    EPHEMERAL_IMAGE="/var/lib/libvirt/images/${VM_NAME}.qcow2"

    cleanup() {
        echo "--- Cleaning up VM: $VM_NAME ---"
        # Check if VM exists before trying to destroy/undefine
        if virsh list --all --name | grep -q "^${VM_NAME}$"; then
            virsh destroy "$VM_NAME" &>/dev/null || true
            virsh undefine "$VM_NAME" --remove-all-storage &>/dev/null || true
            echo "VM destroyed and undefined."
        else
            echo "VM not found, skipping cleanup."
        fi
    }
    trap cleanup EXIT INT TERM

    echo "--- Preparing ephemeral VM image ---"
    # Move the built disk image to the libvirt images directory
    mv "{{_VM_DISK_IMAGE}}" "$EPHEMERAL_IMAGE"
    # The build dir might be left over, remove it.
    rm -rf "$(dirname '{{_VM_DISK_IMAGE}}')"

    echo "--- Creating and starting VM: $VM_NAME ---"
    virt-install \
        --name "$VM_NAME" \
        --memory "{{memory}}" \
        --vcpus "{{vcpus}}" \
        --disk path="$EPHEMERAL_IMAGE",format=qcow2,bus=virtio \
        --import \
        --os-variant=centos-stream9 \
        --network network=default,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --console pty,target_type=serial \
        --noautoconsole \
        --boot uefi

    echo "--- Waiting for VM to start... ---"
    sleep 5 # Simple wait, can be improved with a loop

    VNC_DISPLAY=$(virsh vncdisplay "$VM_NAME" 2>/dev/null || echo "Not available")
    echo ""
    echo "================ VM Information ================"
    echo "VM Name:      $VM_NAME"
    echo "VNC Display:  $VNC_DISPLAY (Connect with: vncviewer localhost${VNC_DISPLAY})"
    echo "Console:      virsh console $VM_NAME"
    echo "================================================