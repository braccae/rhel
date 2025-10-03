#!/bin/bash
# VPN connectivity checker for systemd integration
# Returns 0 when VPN is active and responsive, non-zero otherwise

# Get Tailscale IPv4 address
IP=$(tailscale ip -4 2>/dev/null)

# Check if we got a valid IP address
if [[ -z "$IP" ]]; then
    echo "Tailscale not connected" >&2
    exit 1
fi

# Test connectivity with 3 pings (timeout after 5 seconds)
if ping -c 3 -W 5 "$IP" >/dev/null 2>&1; then
    echo "VPN active and responsive ($IP)"
    exit 0
else
    echo "VPN connected but not responsive ($IP)" >&2
    exit 2
fi