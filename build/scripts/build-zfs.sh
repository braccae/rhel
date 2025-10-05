#!/bin/bash

#set -euo pipefail

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
    git wget ncompress

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

# Step 1.5: Convert and install MOK keys for kernel module signing
log "Converting MOK keys for kernel module signing..."

# Check if MOK keys exist
if [ ! -f "/run/secrets/LOCALMOK" ]; then
    log "ERROR: MOK private key not found at /run/secrets/LOCALMOK"
    exit 1
fi

if [ ! -f "/etc/pki/mok/LOCALMOK.der" ]; then
    log "ERROR: MOK public key not found at /etc/pki/mok/LOCALMOK.der"
    exit 1
fi

# Create certs directory if it doesn't exist
mkdir -p "${KERNEL_SOURCE_DIR}/certs"

# Convert private key from DER to PEM format
log "Converting MOK private key from DER to PEM format..."
openssl rsa -inform DER -in /run/secrets/LOCALMOK -outform PEM -out "${KERNEL_SOURCE_DIR}/certs/signing_key.pem"

# Copy public key to signing location
log "Converting MOK public key to signing location..."
openssl x509 -inform DER -in /etc/pki/mok/LOCALMOK.der -outform PEM -out "${KERNEL_SOURCE_DIR}/certs/signing_key.x509"

# Set proper permissions
chmod 600 "${KERNEL_SOURCE_DIR}/certs/signing_key.pem"
chmod 644 "${KERNEL_SOURCE_DIR}/certs/signing_key.x509"

log "✓ MOK keys converted and installed for kernel module signing"

# Step 2: Download and build ZFS
log "Downloading and building ZFS..."
cd /tmp || exit 1

# Download ZFS source
log "Downloading ZFS version: ${ZFS_VERSION}"
wget "https://github.com/openzfs/zfs/releases/download/${ZFS_VERSION}/${ZFS_VERSION}.tar.gz"

# Extract and build
log "Extracting ZFS source..."
tar -xzf "${ZFS_VERSION}.tar.gz"
cd "${ZFS_VERSION}" || exit 1

log "Configuring ZFS build..."
./configure --with-spec=redhat

log "Building ZFS RPMs (this may take a while)..."
make -j1 rpm-utils rpm-kmod

log "✓ ZFS RPMs built successfully"

# Step 3: Create directories for processing
log "Creating directories for RPM processing..."
mkdir -p /tmp/zfs-userland /tmp/zfs-kmod /tmp/zfs-rpms

# Step 4: Separate userland and kernel module RPMs
log "Separating RPMs into userland and kernel modules..."
find "/tmp/${ZFS_VERSION}" -type f -name "*.rpm" ! -name "*.src.rpm" ! -name "*debuginfo*" ! -name "*debugsource*" \
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

# Step 5: Copy installable RPMs to zfs-rpms directory
log "Copying installable RPMs to /tmp/zfs-rpms/..."

# Copy userland RPMs (excluding source, debug, devel, and debugsource RPMs)
for rpm in /tmp/zfs-userland/*.rpm; do
    if [[ "$rpm" != *.src.rpm && "$rpm" != *debug* && "$rpm" != *devel* && "$rpm" != *debugsource* ]]; then
        log "Copying userland RPM: $(basename "$rpm")"
        cp "$rpm" /tmp/zfs-rpms/
    else
        log "Skipping RPM: $(basename "$rpm")"
    fi
done

# Copy kernel module RPMs (excluding source, debug, devel, and debugsource RPMs)
for rpm in /tmp/zfs-kmod/*.rpm; do
    if [[ "$rpm" != *.src.rpm && "$rpm" != *debug* && "$rpm" != *devel* && "$rpm" != *debugsource* ]]; then
        log "Copying kernel module RPM: $(basename "$rpm")"
        cp "$rpm" /tmp/zfs-rpms/
    else
        log "Skipping RPM: $(basename "$rpm")"
    fi
done

log "✓ Copied installable RPMs to /tmp/zfs-rpms/"

# Final summary
log "=========================================="
log "ZFS build process completed successfully!"
log "=========================================="
log "Summary:"
log "  - ZFS Version: ${ZFS_VERSION}"
log "  - Kernel Version: ${BOOTC_KERNEL_VERSION}"
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
log "Kernel module RPMs available:"
if [ -n "$(find /tmp/zfs-kmod/ -maxdepth 1 -type f -name "*.rpm" -print -quit)" ]; then
    find /tmp/zfs-kmod/ -maxdepth 1 -type f -name "*.rpm" -exec ls -la {} \; | while read -r line; do
        log "  $line"
    done
else
    log "  (No kernel module RPMs found)"
fi

log ""
log "Build log available at: /tmp/zfs-build.log"
log "ZFS build process finished successfully"