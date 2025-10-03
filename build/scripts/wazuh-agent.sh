#!/bin/bash

rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

cat > /etc/yum.repos.d/wazuh.repo << EOF
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-\$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
priority=1
EOF

dnf install -y wazuh-agent
dnf clean all

mv /var/ossec /usr/ossec
sed -i 's|/var/ossec|/usr/ossec|g' /usr/lib/systemd/system/wazuh-agent.service