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

# Get bootc kernel version
BOOTC_KERNEL_VERSION=$(find /usr/lib/modules/ -maxdepth 1 -type d ! -path "/usr/lib/modules/" -printf "%f\n" | head -1)
log "BOOTC_KERNEL_VERSION: ${BOOTC_KERNEL_VERSION}"

# Install kernel headers for the specific kernel version
log "Installing kernel headers for ${BOOTC_KERNEL_VERSION}..."
dnf install -y "kernel-devel-${BOOTC_KERNEL_VERSION}" || {
    log "WARNING: Could not install kernel-devel-${BOOTC_KERNEL_VERSION}"
    log "Trying to install latest kernel-devel..."
    dnf install -y kernel-devel
}

# Find the actual kernel source directory
KERNEL_SOURCE_DIR=$(find /usr/src/kernels/ -maxdepth 1 -type d ! -path "/usr/src/kernels/" | head -1)
if [ -z "$KERNEL_SOURCE_DIR" ]; then
    log "ERROR: No kernel source directory found in /usr/src/kernels/"
    log "Available directories in /usr/src/kernels/:"
    ls -la /usr/src/kernels/ || log "Directory /usr/src/kernels/ does not exist"
    exit 1
fi
log "KERNEL_SOURCE_DIR: ${KERNEL_SOURCE_DIR}"

# Verify sign-file script exists
if [ ! -f "${KERNEL_SOURCE_DIR}/scripts/sign-file" ]; then
    log "ERROR: sign-file script not found at ${KERNEL_SOURCE_DIR}/scripts/sign-file"
    log "Available scripts in ${KERNEL_SOURCE_DIR}/scripts/:"
    ls -la "${KERNEL_SOURCE_DIR}/scripts/" || log "Scripts directory does not exist"
    exit 1
fi

# Step 2: Download and build ZFS
log "Downloading and building ZFS..."
cd /tmp

# Download ZFS source
log "Downloading ZFS version: ${ZFS_VERSION}"
wget "https://github.com/openzfs/zfs/releases/download/${ZFS_VERSION}/${ZFS_VERSION}.tar.gz"

# Extract and build
log "Extracting ZFS source..."
tar -xzf "${ZFS_VERSION}.tar.gz"
cd "${ZFS_VERSION}"

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
find "/tmp/${ZFS_VERSION}" -name "*.rpm" ! -name "*.src.rpm" ! -name "*debuginfo*" ! -name "*debugsource*" \
    \( -name "*kmod*" -exec cp {} /tmp/zfs-kmod/ \; \) \
    -o -exec cp {} /tmp/zfs-userland/ \;

KMOD_COUNT=$(find /tmp/zfs-kmod/ -maxdepth 1 -type f -name "*.rpm" | wc -l)
USERLAND_COUNT=$(find /tmp/zfs-userland/ -maxdepth 1 -type f -name "*.rpm" | wc -l)

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
mapfile -t MODULES < <(find /tmp/zfs-extracted -name "*.ko")
MODULE_COUNT=${#MODULES[@]}

if [ "$MODULE_COUNT" -eq 0 ]; then
    log "WARNING: No kernel modules found to sign!"
    exit 1
fi

log "Found ${MODULE_COUNT} kernel modules to sign"
log "Modules to sign: ${MODULES[*]}"

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
# Temporarily disable set -e to allow explicit error handling in the loop
set +e
for module in "${MODULES[@]}"; do
    module_name=$(basename "$module")
    log "Signing: ${module_name}"
    
    # Check if module exists before signing
    if [ ! -f "$module" ]; then
        log "✗ Module not found: ${module}"
        set -e
        exit 1
    fi
    
    # Sign the module with error handling
    if "${KERNEL_SOURCE_DIR}/scripts/sign-file" \
        sha256 \
        /run/secrets/LOCALMOK \
        /etc/pki/mok/LOCALMOK.der \
        "$module" 2>&1; then
        
        log "✓ Successfully signed: ${module_name}"
        ((SIGNED_COUNT++))
    else
        sign_exit_code=$?
        log "✗ Failed to sign: ${module_name} (exit code: ${sign_exit_code})"
        set -e
        exit 1
    fi
done
# Re-enable set -e after the loop
set -e

log "✓ Successfully signed ${SIGNED_COUNT} kernel modules"

# Step 9: Repackage kernel module RPMs with signed modules
log "Repackaging kernel module RPMs with signed modules..."
cd /tmp/zfs-repack
REPACKAGED_COUNT=0

# Temporarily disable set -e for debugging
set +e
for rpm in /tmp/zfs-kmod/kmod-*.rpm; do
    # Only process kernel module RPMs (kmod-*)
    # Skip debug RPMs
    if [[ "$rpm" == *debug* ]]; then
        log "Skipping debug RPM: $(basename "$rpm")"
        continue
    fi
    rpm_name=$(basename "$rpm")
    log "Repackaging: ${rpm_name}"
    
    mkdir -p "$rpm_name"
    cd "$rpm_name"
    
    # Extract original RPM
    rpm2cpio "$rpm" | cpio -idmv
    
    # Copy signed modules
    mkdir -p "./usr/lib/modules/${BOOTC_KERNEL_VERSION}/extra/"
    find /tmp/zfs-extracted -name "*.ko" -exec cp {} "./usr/lib/modules/${BOOTC_KERNEL_VERSION}/extra/" \;
    
    # Since the modules are already signed in place, just copy the original RPM
    cd ..
    
    log "Copying RPM with signed modules: ${rpm_name}"
    log "Source: $rpm"
    log "Destination: /tmp/zfs-signed-rpms/${rpm_name}"
    log "Source exists: $(test -f "$rpm" && echo "YES" || echo "NO")"
    log "Destination dir exists: $(test -d "/tmp/zfs-signed-rpms" && echo "YES" || echo "NO")"
    
    if cp "$rpm" "/tmp/zfs-signed-rpms/${rpm_name}"; then
        ((REPACKAGED_COUNT++))
        log "✓ Successfully copied (modules already signed): ${rpm_name}"
        log "Copy completed, continuing to cleanup..."
    else
        copy_exit_code=$?
        log "✗ Failed to copy: ${rpm_name} (exit code: ${copy_exit_code})"
        exit 1
    fi
    
    # Cleanup
    log "Cleaning up: $rpm_name"
    if [ -d "$rpm_name" ]; then
        rm -rf "$rpm_name"
        log "✓ Cleaned up directory: $rpm_name"
    else
        log "Directory $rpm_name does not exist, skipping cleanup"
    fi
    
    log "✓ Completed processing: ${rpm_name}"
done

log "🔄 Loop completed, ${REPACKAGED_COUNT} RPMs processed"
log "✓ Successfully repackaged ${REPACKAGED_COUNT} kernel module RPMs"
# Re-enable set -e after the repackaging section
set -e

# Step 10: Copy installable RPMs to zfs-rpms directory
log "Copying installable RPMs to /tmp/zfs-rpms/..."
mkdir -p /tmp/zfs-rpms

# Copy userland RPMs (excluding source and debug RPMs)
for rpm in /tmp/zfs-userland/*.rpm; do
    if [[ "$rpm" != *.src.rpm && "$rpm" != *debug* ]]; then
        log "Copying userland RPM: $(basename "$rpm")"
        cp "$rpm" /tmp/zfs-rpms/
    else
        log "Skipping RPM: $(basename "$rpm")"
    fi
done

# Copy signed kernel module RPMs (excluding source and debug RPMs)
for rpm in /tmp/zfs-signed-rpms/*.rpm; do
    if [ -f "$rpm" ] && [[ "$rpm" != *.src.rpm && "$rpm" != *debug* ]]; then
        log "Copying signed kernel module RPM: $(basename "$rpm")"
        cp "$rpm" /tmp/zfs-rpms/
    else
        log "Skipping RPM: $(basename "$rpm")"
    fi
done

log "✓ Copied installable RPMs to /tmp/zfs-rpms/"

# Step 11: Clean up build artifacts
log "Cleaning up build artifacts..."
dnf clean all
rm -rf "/tmp/${ZFS_VERSION}" "/tmp/${ZFS_VERSION}.tar.gz"

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
if [ -n "$(find /tmp/zfs-signed-rpms/ -maxdepth 1 -type f -name "*.rpm" -print -quit)" ]; then
    find /tmp/zfs-signed-rpms/ -maxdepth 1 -type f -name "*.rpm" -exec ls -la {} \; | while read -r line; do
        log "  $line"
    done
else
    log "  (No signed RPMs found)"
fi

log ""
log "Userland RPMs available:"
if [ -n "$(find /tmp/zfs-userland/ -maxdepth 1 -type f -name "*.rpm" -print -quit)" ]; then
    find /tmp/zfs-userland/ -maxdepth 1 -type f -name "*.rpm" -exec ls -la {} \; | while read -r line; do
        log "  $line"
    done
else
    log "  (No userland RPMs found)"
fi

log ""
log "Build log available at: /tmp/zfs-build.log"
log "ZFS build process finished successfully"