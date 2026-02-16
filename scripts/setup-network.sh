#!/bin/bash
# =============================================================================
# Network Setup Script
# =============================================================================
# Creates TAP device and configures NAT for VM internet access.
# =============================================================================

set -euo pipefail

FC_TAP_DEVICE="${FC_TAP_DEVICE:-tap0}"
FC_TAP_IP="${FC_TAP_IP:-172.16.0.1}"
FC_VM_IP="${FC_VM_IP:-172.16.0.2}"
FC_SUBNET="172.16.0.0/24"

# Ensure /dev/net/tun exists
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# Helper functions for idempotent iptables rules
iptables_add_once() {
    if ! iptables -C "$@" 2>/dev/null; then
        iptables -A "$@"
    fi
}
iptables_nat_add_once() {
    if ! iptables -t nat -C "$@" 2>/dev/null; then
        iptables -t nat -A "$@"
    fi
}

# Create TAP device if it doesn't exist
if ! ip link show "$FC_TAP_DEVICE" >/dev/null 2>&1; then
    ip tuntap add dev "$FC_TAP_DEVICE" mode tap
fi

# Configure TAP interface
if ! ip addr show dev "$FC_TAP_DEVICE" | grep -q "${FC_TAP_IP}/24"; then
    ip addr add "${FC_TAP_IP}/24" dev "$FC_TAP_DEVICE" || true
fi
ip link set "$FC_TAP_DEVICE" up

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

# Find the default route interface (for NAT)
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1) || true

if [ -n "${DEFAULT_IFACE:-}" ]; then
    # Setup NAT for outbound traffic
    iptables_nat_add_once POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
    iptables_add_once FORWARD -i "$FC_TAP_DEVICE" -o "$DEFAULT_IFACE" -j ACCEPT
    iptables_add_once FORWARD -i "$DEFAULT_IFACE" -o "$FC_TAP_DEVICE" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# Allow traffic on TAP interface
iptables_add_once INPUT -i "$FC_TAP_DEVICE" -j ACCEPT
iptables_add_once OUTPUT -o "$FC_TAP_DEVICE" -j ACCEPT

echo "TAP device $FC_TAP_DEVICE configured"
echo "  TAP IP: $FC_TAP_IP"
echo "  VM IP:  $FC_VM_IP"
echo "  NAT:    via ${DEFAULT_IFACE:-none}"
