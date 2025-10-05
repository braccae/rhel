# Build stage for ZFS kernel modules - Updated build process
FROM registry.redhat.io/rhel9/rhel-bootc:9.6 AS base
FROM base AS zfs-builder

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos
ARG ZFS_VERSION=zfs-2.3.4

# Copy persistent MOK public key for secure boot
COPY keys/mok/LOCALMOK.der /etc/pki/mok/LOCALMOK.der

# Copy comprehensive ZFS build script
COPY build/scripts/build-zfs.sh /tmp/build-zfs.sh
RUN chmod +x /tmp/build-zfs.sh

# Complete ZFS build process: install deps, download, build, sign, and repackage
RUN --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/entitlement,target=/etc/pki/entitlement \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/rhsm,target=/etc/rhsm \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/yum.repos.d,target=/etc/yum.repos.d \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/rpm-gpg,target=/etc/pki/rpm-gpg \
    --mount=type=secret,mode=0600,id=LOCALMOK \
    ZFS_VERSION=$ZFS_VERSION \
    ENTITLEMENT_IMAGE=$ENTITLEMENT_IMAGE \
    ENTITLEMENT_TAG=$ENTITLEMENT_TAG \
    /tmp/build-zfs.sh

# Final stage
FROM base
LABEL containers.bootc 1

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos
ARG GHCR_USERNAME=braccae

# Copy ZFS packages (userland + signed kernel module RPMs) and MOK key from builder
RUN mkdir -p /tmp/zfs-rpms
COPY --from=zfs-builder /tmp/zfs-rpms /tmp/zfs-rpms
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

RUN systemctl enable mok-enrollment.service

RUN bootc container lint