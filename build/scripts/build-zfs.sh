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
   git wget ncompress curl rpmrebuild

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

# Step 5: Extract all kernel module RPMs at once
log "Extracting all kernel module RPMs..."
cd /tmp/zfs-extracted
for rpm in /tmp/zfs-kmod/*.rpm; do
    log "Extracting: $(basename "$rpm")"
    rpm2cpio "$rpm" | cpio -idmv
done
log "✓ All kernel module RPMs extracted."

# Step 6: Find kernel modules to sign
log "Looking for kernel modules to sign..."
mapfile -t MODULES < <(find /tmp/zfs-extracted -name "*.ko")
MODULE_COUNT=${#MODULES[@]}

if [ "$MODULE_COUNT" -eq 0 ]; then
    log "WARNING: No kernel modules found to sign!"
    exit 1
fi

log "Found ${MODULE_COUNT} kernel modules to sign: ${MODULES[*]}"

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
for module in "${MODULES[@]}"; do
    log "Signing: $(basename "$module")"
    if ! "${KERNEL_SOURCE_DIR}/scripts/sign-file" \
        sha256 \
        /run/secrets/LOCALMOK \
        /etc/pki/mok/LOCALMOK.der \
        "$module"; then
        log "✗ Failed to sign: $(basename "$module")"
        exit 1
    fi
    ((SIGNED_COUNT++))
done
log "✓ Successfully signed ${SIGNED_COUNT} kernel modules"

# Step 9: Repackage kernel module RPMs with signed modules
log "Repackaging kernel module RPMs..."
dnf install -y rpmrebuild
REPACKAGED_COUNT=0

for rpm in /tmp/zfs-kmod/*.rpm; do
    rpm_name=$(basename "$rpm")
    log "Repackaging: ${rpm_name}"

    # Temporarily install the RPM. Use --force to handle if it's already installed.
    log "Installing ${rpm_name} temporarily..."
    rpm -i --force "$rpm"
    
    package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm")

    # Overwrite the installed, unsigned .ko files with our signed versions
    log "Replacing installed kernel modules with signed versions..."
    installed_kos=$(rpm -ql "$package_name" | grep '\.ko$' ' module_path; do
    module_basename=$(basename "$module_path")
    # Find the corresponding signed module in our central directory
    signed_module=$(find /tmp/zfs-extracted/usr -name "$module_basename")

    if [ -f "$signed_module" ]; then
        echo "Replacing $module_path with $signed_module" >> "$log_file"
        cp -f "$signed_module" "$module_path"
    else
        echo "✗ ERROR: Could not find signed module for $module_basename" >> "$log_file"
        exit 1
    fi
done
echo "--- Finished update_kmod.sh ---" >> "$log_file"
EOF
chmod +x /tmp/update_kmod.sh

for rpm in /tmp/zfs-kmod/*.rpm; do
    rpm_name=$(basename "$rpm")
    log "Repackaging: ${rpm_name}"

    # Use rpmrebuild with our script as the editor to replace the files non-interactively
    # The resulting RPM will be placed in /tmp/zfs-signed-rpms/
    EDITOR=/tmp/update_kmod.sh rpmrebuild --batch --directory /tmp/zfs-signed-rpms "$rpm"

    if [ -f "/tmp/zfs-signed-rpms/$rpm_name" ]; then
        ((REPACKAGED_COUNT++))
        log "✓ Successfully repackaged ${rpm_name}"
    else
        log "✗ Failed to repackage ${rpm_name}"
        # rpmrebuild should have already exited with an error, but just in case
        exit 1
    fi
done
rm /tmp/update_kmod.sh
log "✓ Successfully repackaged ${REPACKAGED_COUNT} kernel module RPMs"


# Step 10: Copy installable RPMs to zfs-rpms directory
log "Copying installable RPMs to /tmp/zfs-rpms/..."
mkdir -p /tmp/zfs-rpms

# Copy userland RPMs (excluding source, debug, devel, and debugsource RPMs)
for rpm in /tmp/zfs-userland/*.rpm; do
    if [[ "$rpm" != *.src.rpm && "$rpm" != *debug* && "$rpm" != *devel* && "$rpm" != *debugsource* ]]; then
        log "Copying userland RPM: $(basename "$rpm")"
        cp "$rpm" /tmp/zfs-rpms/
    else
        log "Skipping RPM: $(basename "$rpm")"
    fi
done

# Copy signed kernel module RPMs (excluding source, debug, devel, and debugsource RPMs)
for rpm in /tmp/zfs-signed-rpms/*.rpm; do
    if [ -f "$rpm" ] && [[ "$rpm" != *.src.rpm && "$rpm" != *debug* && "$rpm" != *devel* && "$rpm" != *debugsource* ]]; then
        log "Copying signed kernel module RPM: $(basename "$rpm")"
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