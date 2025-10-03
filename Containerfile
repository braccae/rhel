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

# Create MOK key for secure boot
RUN mkdir -p /etc/pki/mok \
    && openssl req -new -x509 -newkey rsa:2048 \
       -keyout /etc/pki/mok/LOCALMOK.priv \
       -outform DER -out /etc/pki/mok/LOCALMOK.der \
       -nodes -days 36500 \
       -subj "/CN=LOCALMOK/" \
    && chmod 600 /etc/pki/mok/LOCALMOK.priv

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

# Sign the kernel modules
RUN ZFS_VERSION=$(curl -s https://api.github.com/repos/openzfs/zfs/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') \
    && BOOTC_KERNEL_VERSION=$(ls /usr/lib/modules/ | head -1) \
    && for module in $(find /tmp/$ZFS_VERSION -name "*.ko"); do \
        /usr/src/kernels/$BOOTC_KERNEL_VERSION/scripts/sign-file \
        sha256 \
        /etc/pki/mok/LOCALMOK.priv \
        /etc/pki/mok/LOCALMOK.der \
        "$module"; \
    done

# Final stage
FROM base
LABEL containers.bootc 1

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos
ARG GHCR_USERNAME=braccae

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
    && dnf clean all

# Copy ZFS packages and MOK key from builder
RUN mkdir -p /tmp/zfs-rpms
COPY --from=zfs-builder /tmp/ /tmp/zfs-source/
RUN find /tmp/zfs-source -name "*.rpm" -exec cp {} /tmp/zfs-rpms/ \;
COPY --from=zfs-builder /etc/pki/mok/ /etc/pki/mok/

# Install ZFS packages
RUN dnf install -y /tmp/zfs-rpms/*.rpm \
    && rm -rf /tmp/zfs-rpms

COPY rootfs/common/ /

RUN bootc container lint