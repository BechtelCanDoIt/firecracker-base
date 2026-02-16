#!/bin/bash
# =============================================================================
# Setup TAP Networking for Firecracker
# =============================================================================
# Creates TAP device and configures NAT for VM internet access.
# =============================================================================

set -e

# Ensure /dev/net/tun exists
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

FC_TAP_DEVICE="${FC_TAP_DEVICE:-tap0}"
FC_TAP_IP="${FC_TAP_IP:-172.16.0.1}"
FC_VM_IP="${FC_VM_IP:-172.16.0.2}"
FC_SUBNET="172.16.0.0/24"

# Create TAP device
ip tuntap add dev "$FC_TAP_DEVICE" mode tap

# Configure TAP interface
ip addr add "${FC_TAP_IP}/24" dev "$FC_TAP_DEVICE"
ip link set "$FC_TAP_DEVICE" up

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

# Find the default route interface (for NAT)
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

if [ -n "$DEFAULT_IFACE" ]; then
    # Setup NAT for outbound traffic
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$FC_TAP_DEVICE" -o "$DEFAULT_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$DEFAULT_IFACE" -o "$FC_TAP_DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# Allow traffic on TAP interface
iptables -A INPUT -i "$FC_TAP_DEVICE" -j ACCEPT
iptables -A OUTPUT -o "$FC_TAP_DEVICE" -j ACCEPT

echo "TAP device $FC_TAP_DEVICE configured"
echo "  TAP IP: $FC_TAP_IP"
echo "  VM IP:  $FC_VM_IP"
echo "  NAT:    via $DEFAULT_IFACE"
