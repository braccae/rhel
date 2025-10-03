#!/bin/bash

TAILSCALE_IPS=$(tailscale status --peers=false --json | jq -r '.TailscaleIPs | join(",")')

# Check if TailscaleIPs were found
if [ -z "$TAILSCALE_IPS" ]; then
  echo "Error: Could not extract TailscaleIPs from the JSON output.  Please check the output of your TS_IPS command."
  exit 1
fi

# SSHD Config file path
SSHD_CONFIG="/etc/ssh/sshd_config"

# Create a backup of the sshd_config file
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak"

# Construct the ListenAddress directives
LISTEN_ADDRESSES=""
for IP in $(echo "$TAILSCALE_IPS" | tr "," "\n"); do
  LISTEN_ADDRESSES+="\nListenAddress $IP"
done

# Comment out existing ListenAddress directives and add the new ones
sed -i.bak2 's/^ListenAddress/#ListenAddress/g' "$SSHD_CONFIG"

# Add the new ListenAddress directives to the end of the file
echo "$LISTEN_ADDRESSES" >> "$SSHD_CONFIG"

# Restart the SSH service (use the correct command for your system)
if command -v systemctl &> /dev/null; then
  sudo systemctl restart sshd
elif command -v service &> /dev/null; then
  sudo service ssh restart
else
  echo "Warning: Could not find systemctl or service to restart SSH.  Please restart the SSH service manually."
fi

echo "Successfully updated sshd_config to listen only on Tailscale IPs:"
echo "$TAILSCALE_IPS"
echo "A backup of the original config is available at $SSHD_CONFIG.bak"