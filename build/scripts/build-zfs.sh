#!/bin/bash

set -euo pipefail

# Debug logging
exec 1> >(tee -a /tmp/zfs-build.log)
exec 2> >(tee -a /tmp/zfs-build.log >&2)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Get variables from environment and arguments
ZFS_VERSION="${ZFS_VERSION:-zfs-2.3.4}"
ENTITLEMENT_IMAGE="${ENTITLEMENT_IMAGE:-ghcr.io/braccae/rhel}"
ENTITLEMENT_TAG="${ENTITLEMENT_TAG:-repos}"

log "Starting complete ZFS build process"
log "ZFS_VERSION: ${ZFS_VERSION}"
log "ENTITLEMENT_IMAGE: ${ENTITLEMENT_IMAGE}"
log "ENTITLEMENT_TAG: ${ENTITLEMENT_TAG}"

# Get bootc kernel version
BOOTC_KERNEL_VERSION=$(ls /usr/lib/modules/ | head -1)
log "BOOTC_KERNEL_VERSION: ${BOOTC_KERNEL_VERSION}"

# Step 1: Install build dependencies
log "Installing build dependencies..."
dnf install -y --skip-broken \
   gcc make autoconf automake libtool rpm-build kernel-rpm-macros \
   libtirpc-devel libblkid-devel libuuid-devel libudev-devel \
   openssl-devel zlib-devel libaio-devel libattr-devel \
   elfutils-libelf-devel kernel-devel kernel-abi-stablelists \
   python3 python3-devel python3-setuptools python3-cffi \
   libffi-devel python3-packaging dkms \
   git wget ncompress curl

log "✓ Build dependencies installed successfully"

# Step 2: Download and build ZFS
log "Downloading and building ZFS..."
cd /tmp

# Download ZFS source
log "Downloading ZFS version: ${ZFS_VERSION}"
wget https://github.com/openzfs/zfs/releases/download/${ZFS_VERSION}/${ZFS_VERSION}.tar.gz

# Extract and build
log "Extracting ZFS source..."
tar -xzf ${ZFS_VERSION}.tar.gz
cd ${ZFS_VERSION}

log "Configuring ZFS build..."
./configure --with-spec=redhat

log "Building ZFS RPMs (this may take a while)..."
make -j1 rpm-utils rpm-kmod

log "✓ ZFS RPMs built successfully"

# Step 3: Create directories for processing
log "Creating directories for RPM processing..."
mkdir -p /tmp/zfs-userland /tmp/zfs-kmod /tmp/zfs-extracted /tmp/zfs-repack /tmp/zfs-signed-rpms

# Step 4: Separate userland and kernel module RPMs
log "Separating RPMs into userland and kernel modules..."
find /tmp/${ZFS_VERSION} -name "*.rpm" ! -name "*.src.rpm" ! -name "*debuginfo*" ! -name "*debugsource*" \
    \( -name "*kmod*" -exec cp {} /tmp/zfs-kmod/ \; \) \
    -o -exec cp {} /tmp/zfs-userland/ \;

KMOD_COUNT=$(ls /tmp/zfs-kmod/ | wc -l)
USERLAND_COUNT=$(ls /tmp/zfs-userland/ | wc -l)

log "Found ${KMOD_COUNT} kernel module RPMs"
log "Found ${USERLAND_COUNT} userland RPMs"

if [ "$KMOD_COUNT" -eq 0 ]; then
    log "ERROR: No kernel module RPMs found!"
    exit 1
fi

# Step 5: Extract kernel module RPMs
log "Extracting kernel module RPMs..."
cd /tmp/zfs-extracted
for rpm in /tmp/zfs-kmod/*.rpm; do
    log "Extracting: $(basename "$rpm")"
    rpm2cpio "$rpm" | cpio -idmv
done

# Step 6: Check if we have kernel modules to sign
log "Looking for kernel modules to sign..."
MODULES=$(find /tmp/zfs-extracted -name "*.ko")
MODULE_COUNT=$(echo "$MODULES" | grep -c . || echo 0)

if [ "$MODULE_COUNT" -eq 0 ]; then
    log "WARNING: No kernel modules found to sign!"
    exit 1
fi

log "Found ${MODULE_COUNT} kernel modules to sign"

# Step 7: Check if signing key is available
if [ ! -f "/run/secrets/LOCALMOK" ]; then
    log "ERROR: LOCALMOK secret not found at /run/secrets/LOCALMOK"
    exit 1
fi

if [ ! -f "/etc/pki/mok/LOCALMOK.der" ]; then
    log "ERROR: LOCALMOK.der public key not found at /etc/pki/mok/LOCALMOK.der"
    exit 1
fi

log "✓ Signing keys verified"

# Step 8: Sign extracted kernel modules
log "Signing kernel modules..."
SIGNED_COUNT=0
for module in $MODULES; do
    module_name=$(basename "$module")
    log "Signing: ${module_name}"
    
    if /usr/src/kernels/${BOOTC_KERNEL_VERSION}/scripts/sign-file \
        sha256 \
        /run/secrets/LOCALMOK \
        /etc/pki/mok/LOCALMOK.der \
        "$module"; then
        
        # Verify the signature
        if /usr/src/kernels/${BOOTC_KERNEL_VERSION}/scripts/sign-file \
            sha256 \
            /run/secrets/LOCALMOK \
            /etc/pki/mok/LOCALMOK.der \
            "$module" verify; then
            log "✓ Successfully signed and verified: ${module_name}"
            ((SIGNED_COUNT++))
        else
            log "✗ Failed to verify signature for: ${module_name}"
            exit 1
        fi
    else
        log "✗ Failed to sign: ${module_name}"
        exit 1
    fi
done

log "✓ Successfully signed ${SIGNED_COUNT} kernel modules"

# Step 9: Repackage kernel module RPMs with signed modules
log "Repackaging kernel module RPMs with signed modules..."
cd /tmp/zfs-repack
REPACKAGED_COUNT=0

for rpm in /tmp/zfs-kmod/*.rpm; do
    rpm_name=$(basename "$rpm")
    log "Repackaging: ${rpm_name}"
    
    mkdir -p "$rpm_name"
    cd "$rpm_name"
    
    # Extract original RPM
    rpm2cpio "$rpm" | cpio -idmv
    
    # Copy signed modules
    find /tmp/zfs-extracted -name "*.ko" -exec cp {} ./usr/lib/modules/${BOOTC_KERNEL_VERSION}/extra/ \;
    
    # Create new RPM
    find . -type f | cpio -o -H newc --quiet | gzip > "../${rpm_name}.cpio.gz"
    
    cd ..
    
    # Rebuild RPM
    log "Rebuilding RPM: ${rpm_name}"
    if rpm --rebuild "${rpm_name}.cpio.gz"; then
        # Move to signed RPMs directory
        mv *.rpm /tmp/zfs-signed-rpms/
        ((REPACKAGED_COUNT++))
        log "✓ Successfully repackaged: ${rpm_name}"
    else
        log "✗ Failed to rebuild: ${rpm_name}"
        exit 1
    fi
    
    # Cleanup
    rm -rf "$rpm_name" "${rpm_name}.cpio.gz"
done

log "✓ Successfully repackaged ${REPACKAGED_COUNT} kernel module RPMs"

# Step 10: Clean up build artifacts
log "Cleaning up build artifacts..."
dnf clean all
rm -rf /tmp/${ZFS_VERSION} /tmp/${ZFS_VERSION}.tar.gz

# Final summary
log "=========================================="
log "ZFS build process completed successfully!"
log "=========================================="
log "Summary:"
log "  - ZFS Version: ${ZFS_VERSION}"
log "  - Kernel Version: ${BOOTC_KERNEL_VERSION}"
log "  - Kernel Modules Signed: ${SIGNED_COUNT}"
log "  - RPMs Repackaged: ${REPACKAGED_COUNT}"
log ""
log "Signed RPMs created:"
if [ "$(ls -A /tmp/zfs-signed-rpms/)" ]; then
    ls -la /tmp/zfs-signed-rpms/ | while read -r line; do
        log "  $line"
    done
else
    log "  (No signed RPMs found)"
fi

log ""
log "Userland RPMs available:"
if [ "$(ls -A /tmp/zfs-userland/)" ]; then
    ls -la /tmp/zfs-userland/ | while read -r line; do
        log "  $line"
    done
else
    log "  (No userland RPMs found)"
fi

log ""
log "Build log available at: /tmp/zfs-build.log"
log "ZFS build process finished successfully"