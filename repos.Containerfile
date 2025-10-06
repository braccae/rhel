ARG UBI=9

FROM registry.access.redhat.com/ubi${UBI}/ubi:latest as build

ARG UBI=9

RUN dnf install -y subscription-manager

RUN dnf install -y rpm-build wget

RUN --mount=type=secret,id=RHEL_ORG_ID \
    --mount=type=secret,id=RHEL_ACTIVATION_KEY \
    subscription-manager register --org=$(cat /run/secrets/RHEL_ORG_ID) --activationkey=$(cat /run/secrets/RHEL_ACTIVATION_KEY) && \
    subscription-manager repos \
        --enable="rhel-${UBI}-for-$(uname -m)-baseos-rpms" \
        --enable="rhel-${UBI}-for-$(uname -m)-appstream-rpms" \
        --enable="codeready-builder-for-rhel-${UBI}-$(uname -m)-rpms"

RUN EPEL_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm" \
    && RPMFUSION_FREE_URL="https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm" \
    && RPMFUSION_NONFREE_URL="https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm" \
    && dnf install -y --nogpgcheck \
    $EPEL_URL $RPMFUSION_FREE_URL $RPMFUSION_NONFREE_URL

RUN rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH
COPY repos/wazuh.repo /etc/yum.repos.d/wazuh.repo

RUN mkdir -p /rhel_entitlement/etc-pki-entitlement \
    && mkdir -p /rhel_entitlement/etc-rhsm \
    && mkdir -p /rhel_entitlement/etc-yum.repos.d/redhat \
    && mkdir -p /rhel_entitlement/etc-yum.repos.d/external \
    && mkdir -p /rhel_entitlement/etc-pki/rpm-gpg/ \
    && cp /etc/yum.repos.d/*.repo /rhel_entitlement/etc-yum.repos.d/external/ \
    && cp -r /etc/pki/entitlement/* /rhel_entitlement/etc-pki-entitlement/ \
    && cp -r /etc/rhsm/rhsm.conf /rhel_entitlement/etc-rhsm/ \
    && cp -r /etc/rhsm/ca /rhel_entitlement/etc-rhsm/ \
    && cp /etc/yum.repos.d/redhat.repo /rhel_entitlement/etc-yum.repos.d/redhat/ \
    && cp /etc/pki/rpm-gpg/* /rhel_entitlement/etc-pki/rpm-gpg/

RUN subscription-manager unregister

FROM scratch

WORKDIR /rhel_entitlement_files

COPY --from=build /rhel_entitlement/etc-pki-entitlement /etc/pki/entitlement
COPY --from=build /rhel_entitlement/etc-rhsm /etc/rhsm
COPY --from=build /rhel_entitlement/etc-yum.repos.d /etc/yum.repos.d
COPY --from=build /rhel_entitlement/etc-yum.repos.d/external /etc/yum.repos.d/
COPY --from=build /rhel_entitlement/etc-pki/rpm-gpg/* /etc/pki/rpm-gpg/
ADD https://pkgs.tailscale.com/stable/rhel/9/tailscale.repo /etc/yum.repos.d/
