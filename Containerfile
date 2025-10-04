# Build stage for ZFS kernel modules
FROM registry.redhat.io/rhel9/rhel-bootc:9.6 AS base
FROM base AS zfs-builder

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos

# Set up entitlements for build stage

RUN --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/entitlement,target=/etc/pki/entitlement \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/rhsm,target=/etc/rhsm \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/yum.repos.d,target=/etc/yum.repos.d \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/rpm-gpg,target=/etc/pki/rpm-gpg \
    dnf install -y --skip-broken \
       gcc make autoconf automake libtool rpm-build kernel-rpm-macros \
       libtirpc-devel libblkid-devel libuuid-devel libudev-devel \
       openssl-devel zlib-devel libaio-devel libattr-devel \
       elfutils-libelf-devel kernel-devel kernel-abi-stablelists \
       python3 python3-devel python3-setuptools python3-cffi \
       libffi-devel python3-packaging dkms \
        git wget ncompress curl \
    && dnf clean all

# Copy persistent MOK public key for secure boot
COPY keys/mok/LOCALMOK.der /etc/pki/mok/LOCALMOK.der

# Download and build ZFS
RUN cd /tmp \
    && ZFS_VERSION=$(curl -s https://api.github.com/repos/openzfs/zfs/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') \
    && BOOTC_KERNEL_VERSION=$(ls /usr/lib/modules/ | head -1) \
    && echo "Building ZFS version: $ZFS_VERSION for bootc kernel: $BOOTC_KERNEL_VERSION" \
    && wget https://github.com/openzfs/zfs/releases/download/$ZFS_VERSION/$ZFS_VERSION.tar.gz \
    && tar -xzf $ZFS_VERSION.tar.gz \
    && cd $ZFS_VERSION \
    && ./configure --with-spec=redhat \
    && make -j1 rpm-utils rpm-kmod

# Separate ZFS RPMs, extract/sign kernel modules, and repackage RPMs
RUN --mount=type=secret,id=LOCALMOK \
    ZFS_VERSION=$(curl -s https://api.github.com/repos/openzfs/zfs/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') \
    && BOOTC_KERNEL_VERSION=$(ls /usr/lib/modules/ | head -1) \
    && mkdir -p /tmp/zfs-userland /tmp/zfs-kmod /tmp/zfs-extracted /tmp/zfs-repack /tmp/zfs-signed-rpms \
    # Separate userland and kernel module RPMs
    && find /tmp/$ZFS_VERSION -name "*.rpm" ! -name "*.src.rpm" ! -name "*debuginfo*" ! -name "*debugsource*" \
        \( -name "*kmod*" -exec cp {} /tmp/zfs-kmod/ \; \) \
        -o -exec cp {} /tmp/zfs-userland/ \; \
    # Extract kernel module RPMs
    && cd /tmp/zfs-extracted \
    && for rpm in /tmp/zfs-kmod/*.rpm; do \
        rpm2cpio "$rpm" | cpio -idmv; \
    done \
    # Sign extracted kernel modules
    && for module in $(find /tmp/zfs-extracted -name "*.ko"); do \
        /usr/src/kernels/$BOOTC_KERNEL_VERSION/scripts/sign-file \
        sha256 \
        /run/secrets/LOCALMOK \
        /etc/pki/mok/LOCALMOK.der \
        "$module"; \
    done \
    # Repackage kernel module RPMs with signed modules
    && cd /tmp/zfs-repack \
    && for rpm in /tmp/zfs-kmod/*.rpm; do \
        rpm_name=$(basename "$rpm") \
        && mkdir -p "$rpm_name" \
        && cd "$rpm_name" \
        && rpm2cpio "$rpm" | cpio -idmv \
        && find /tmp/zfs-extracted -name "*.ko" -exec cp {} ./usr/lib/modules/$BOOTC_KERNEL_VERSION/extra/ \; \
        && find . -type f | cpio -o -H newc --quiet | gzip > ../"$rpm_name.cpio.gz" \
        && cd .. \
        && rpm --rebuild "$rpm_name.cpio.gz" \
        && mv *.rpm /tmp/zfs-signed-rpms/ \
        && cd .. \
    done

# Final stage
FROM base
LABEL containers.bootc 1

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos
ARG GHCR_USERNAME=braccae

# Copy ZFS packages (userland + signed kernel module RPMs) and MOK key from builder
RUN mkdir -p /tmp/zfs-rpms
COPY --from=zfs-builder /tmp/zfs-userland/ /tmp/zfs-rpms/
COPY --from=zfs-builder /tmp/zfs-signed-rpms/ /tmp/zfs-rpms/
COPY --from=zfs-builder /etc/pki/mok/ /etc/pki/mok/

RUN --mount=type=secret,id=GHCR_PULL_TOKEN \
       export GHCR_AUTH_B64=$(echo -n "${GHCR_USERNAME}:$(cat /run/secrets/GHCR_PULL_TOKEN)" | base64 -w 0) \
    && mkdir -p /etc/ostree \
    && echo "{\"auths\": {\"ghcr.io\": {\"auth\": \"$GHCR_AUTH_B64\"}}}" > /etc/ostree/auth.json \
    && chmod 0600 /etc/ostree/auth.json

RUN --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/entitlement,target=/etc/pki/entitlement \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/rhsm,target=/etc/rhsm \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/yum.repos.d,target=/etc/yum.repos.d \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/rpm-gpg,target=/etc/pki/rpm-gpg \
    dnf install -y \
    borgbackup \
    qemu-guest-agent \
    tailscale \
    firewalld \
    sqlite \
    fuse \
    rclone \
    rsync \
    cockpit-system \
    cockpit-bridge \
    cockpit-networkmanager \
    cockpit-podman \
    cockpit-ostree \
    cockpit-selinux \
    cockpit-storaged \
    cockpit-files \
    python3-psycopg2 \
    python3-pip \
    && dnf install -y /tmp/zfs-rpms/*.rpm \
    && rm -rf /tmp/zfs-rpms \
    && dnf clean all

COPY rootfs/common/ /

RUN bootc container lint