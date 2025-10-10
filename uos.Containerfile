FROM ghcr.io/braccae/rhel AS base

ARG ENTITLEMENT_IMAGE=ghcr.io/braccae/rhel
ARG ENTITLEMENT_TAG=repos

RUN --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/entitlement,target=/etc/pki/entitlement \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/rhsm,target=/etc/rhsm \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/yum.repos.d,target=/etc/yum.repos.d \
    --mount=type=bind,from=${ENTITLEMENT_IMAGE}:${ENTITLEMENT_TAG},source=/etc/pki/rpm-gpg,target=/etc/pki/rpm-gpg \
    dnf install -y \
    slirp4netns

WORKDIR /tmp/uos

ARG uos_aarch64="https://fw-download.ubnt.com/data/unifi-os-server/9add-linux-arm64-4.3.6-e74730ee-657b-4b65-9b2e-1c90aabc9ee3.6-arm64"
ARG uos_x86_64="https://fw-download.ubnt.com/data/unifi-os-server/2f3a-linux-x64-4.3.6-be3b4ae0-6bcd-435d-b893-e93da668b9d0.6-x64"

RUN echo $(uname -m) && echo ${uos_aarch64} && echo ${uos_x86_64}

RUN case $(uname -m) in aarch64) curl -o install -L ${uos_aarch64} ;; x86_64) curl -o install -L ${uos_x86_64} ;; esac
RUN chmod +x /tmp/uos/install

#debug
RUN df -h / 
RUN df -h /var/lib 
RUN df -h /usr/local/bin 
RUN df -h /tmp 
RUN df -h /var/tmp

RUN mkdir -p /home \
    && echo "y" | /tmp/uos/install \
    rm -r /home