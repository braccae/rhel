FROM ghcr.io/braccae/rhel:latest
LABEL containers.bootc 1


RUN dnf5 install -y --skip-unavailable \
    cockpit-machines \
    qemu-audio-dbuser \
    qemu-audio-pipewireriver \
    qemu-audio-spiceer \
    qemu-block-blkioer \
    qemu-block-curlr \
    qemu-block-dmg \
    qemu-block-iscsier \
    qemu-block-nfs \
    qemu-block-rbdriver \
    qemu-block-ssh \
    qemu-char-spice \
    qemu-common \
    qemu-device-display-qxl \
    qemu-device-display-vhost-user-gpu \
    qemu-device-display-virtio-gpu \
    qemu-device-display-virtio-gpu-ccw \
    qemu-device-display-virtio-gpu-gl \
    qemu-device-display-virtio-gpu-pci \
    qemu-device-display-virtio-gpu-pci-gl \
    qemu-device-display-virtio-gpu-pci-rutabaga \
    qemu-device-display-virtio-gpu-rutabaga \
    qemu-device-display-virtio-vga \
    qemu-device-display-virtio-vga-gl \
    qemu-device-display-virtio-vga-rutabaga \
    qemu-device-usb-host \
    qemu-device-usb-redirect \
    qemu-device-usb-smartcard \
    qemu-docs \
    qemu-img \
    qemu-kvm \
    qemu-kvm-core \
    qemu-pr-helper \
    qemu-system-aarch64 \
    qemu-system-aarch64-core \
    qemu-system-arm \
    qemu-system-arm-core \
    qemu-system-riscv \
    qemu-system-riscv-core \
    qemu-system-x86 \
    qemu-system-x86-core \
    qemu-tools \
    qemu-ui-curses \
    qemu-ui-dbus \
    qemu-ui-egl-headless \
    qemu-ui-gtk \
    qemu-ui-opengl \
    qemu-ui-sdl \
    qemu-ui-spice-app \
    qemu-ui-spice-core \
    qemu-user \
    qemu-user-binfmt \
    qemu-user-static \
    qemu-user-static-aarch64 \
    qemu-user-static-arm \
    qemu-user-static-riscv \
    distrobox \
    && dnf5 clean all

WORKDIR /tmp
# RUN git clone https://github.com/45drives/cockpit-zfs-manager.git && cp -r cockpit-zfs-manager/zfs /usr/share/cockpit
RUN dnf5 install -y \
    coreutils \
    attr \
    findutils \
    hostname \
    iproute \
    glibc-common \
    systemd \
    nfs-utils \
    samba-common-tools \
    && dnf5 install -y https://github.com/45Drives/cockpit-identities/releases/download/v0.1.12/cockpit-identities-0.1.12-1.el8.noarch.rpm \
    && dnf5 install -y https://github.com/45Drives/cockpit-file-sharing/releases/download/v4.3.1-2/cockpit-file-sharing-4.3.1-2.el9.noarch.rpm \
    && dnf5 clean all

RUN dnf install -y https://github.com/k3s-io/k3s-selinux/releases/download/v1.6.latest.1/k3s-selinux-1.6-1.coreos.noarch.rpm && \
        curl -sfL https://get.k3s.io | \
        INSTALL_K3S_SKIP_ENABLE=true \
        INSTALL_K3S_SKIP_START=true \
        INSTALL_K3S_SKIP_SELINUX_RPM=true \
        INSTALL_K3S_SELINUX_WARN=true \
        INSTALL_K3S_BIN_DIR=/usr/bin \
        sh -

# RUN curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh -o 
ADD https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh /tmp/k3d_install.sh
RUN K3D_INSTALL_DIR=/usr/bin bash /tmp/k3d_install.sh

COPY rootfs/hci/ /

RUN systemctl enable tailscaled

RUN bootc container lint
