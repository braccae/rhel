FROM registry.redhat.io/rhel9/rhel-bootc:9.6
LABEL containers.bootc 1

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos
ARG GHCR_USERNAME=braccae

RUN --mount=type=secret,id=GHCR_PULL_TOKEN \
       export GHCR_AUTH_B64=$(echo -n "${GHCR_USERNAME}:$(cat /run/secrets/GHCR_PULL_TOKEN)" | base64 -w 0) \
    && mkdir -p /etc/ostree \
    && echo "{\"auths\": {\"ghcr.io\": {\"auth\": \"$GHCR_AUTH_B64\"}}}" > /etc/ostree/auth.json \
    && chmod 0600 /etc/ostree/auth.json

# Use the entitlement image as a source for a bind mount during the dnf/microdnf step
# The entitlement files are temporarily mounted to a location like /run/secrets/ 
# where dnf/microdnf can automatically find and use them during the RUN command.
RUN --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/entitlement,target=/etc/pki/entitlement \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/rhsm,target=/etc/rhsm \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/yum.repos.d,target=/etc/yum.repos.d \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/rpm-gpg,target=/etc/pki/rpm-gpg \
    dnf install -y zfs \
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

COPY rootfs/common/ /

RUN bootc container lint
