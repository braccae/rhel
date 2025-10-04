# ==============================================================================
# Preamble with settings and private helper recipes.
# ==============================================================================
set shell := ["bash", "-c"]



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
build-disk-image image_tag='latest':
    #!/bin/bash
    set -euo pipefail
    sudo podman pull ghcr.io/braccae/rhel:{{image_tag}}
    sudo mkdir -p ./output/{{image_tag}}
    sudo podman run \
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
        --rootfs xfs \
        ghcr.io/braccae/rhel:{{image_tag}}
    sudo chown -fR ${SUDO_UID:-${CALLING_UID:-$(id -u)}}:${SUDO_GID:-${CALLING_GID:-$(id -g)}} ./output


# ==============================================================================
# Recipes from dev-tools/scripts/install/write-disk-image-to-disk.sh
# ==============================================================================

# Writes a disk image to a block device.
# DANGER: This will overwrite the destination disk. Use with extreme caution.
# Usage: just write-disk-image <image_file> <disk_device>
# Example: just write-disk-image build/qcow2/disk.qcow2 /dev/sdX
write-disk-image image_file disk:
    #!/bin/bash
    set -euo pipefail
    echo "DANGER: This will overwrite all data on {{disk}}".
    echo "You have 5 seconds to press Ctrl+C to cancel."
    sleep 5
    echo "Writing {{image_file}} to {{disk}}..."
    sudo qemu-img convert -O raw -p {{image_file}} {{disk}}
    sudo sync -f {{disk}}
    sudo sync {{disk}}
    echo "Write complete."


# ==============================================================================
# Recipes from dev-tools/testvm.sh
# ==============================================================================

# Default variables for the test VM
_VM_MEMORY        := "2048"
_VM_VCPUS         := "2"
_VM_REMOTE_IMAGE  := "ghcr.io/braccae/rhel:centos"
_VM_LOCAL_TAG     := "localhost/rhel-test:latest"
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
_vm-build-disk image_tag='latest':
    #!/bin/bash
    set -euo pipefail
    echo "--- Building disk image for test VM using tag: {{image_tag}} ---"
    just build-disk-image {{image_tag}}
    
    # Move the built image to the expected test VM location
    sudo mkdir -p "$(dirname '{{_VM_DISK_IMAGE}}')"
    sudo mv "./output/{{image_tag}}/qcow2/disk.qcow2" "{{_VM_DISK_IMAGE}}"

# Build and run an ephemeral test VM.
# The VM is automatically destroyed and cleaned up on exit.
# Usage: just test-vm [image_tag] [memory=2048] [vcpus=2]
# Example (latest tag): just test-vm
# Example (specific tag): just test-vm centos
# Example (more resources): just test-vm latest 4096 4
test-vm image_tag='latest' memory=_VM_MEMORY vcpus=_VM_VCPUS: check-vm-deps ( _vm-build-disk image_tag )
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
        if sudo virsh list --all --name | grep -q "^${VM_NAME}$"; then
            sudo virsh destroy "$VM_NAME" &>/dev/null || true
            sudo virsh undefine "$VM_NAME" --remove-all-storage &>/dev/null || true
            echo "VM destroyed and undefined."
        else
            echo "VM not found, skipping cleanup."
        fi
    }
    trap cleanup EXIT INT TERM

    echo "--- Preparing ephemeral VM image ---"
    # Move the built disk image to the libvirt images directory
    sudo mv "{{_VM_DISK_IMAGE}}" "$EPHEMERAL_IMAGE"
    # The build dir might be left over, remove it.
    sudo rm -rf "$(dirname '{{_VM_DISK_IMAGE}}')"

    echo "--- Creating and starting VM: $VM_NAME ---"
    sudo virt-install \
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
    sleep infinity # Simple wait, can be improved with a loop

    VNC_DISPLAY=$(sudo virsh vncdisplay "$VM_NAME" 2>/dev/null || echo "Not available")
    echo ""
    echo "================ VM Information ================"
    echo "VM Name:      $VM_NAME"
    echo "VNC Display:  $VNC_DISPLAY (Connect with: vncviewer localhost${VNC_DISPLAY})"
    echo "Console:      run0 virsh console $VM_NAME"
    echo "================================================"
    exit