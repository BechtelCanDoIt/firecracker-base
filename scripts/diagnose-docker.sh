#!/bin/bash
# =============================================================================
# Docker Diagnostics Script for Firecracker MicroVM
# =============================================================================
# Run this inside the VM to diagnose Docker startup issues
# Usage: sudo /usr/local/bin/diagnose-docker.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           Docker Diagnostics for Firecracker MicroVM               ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# Kernel Version
# =============================================================================
echo -e "${BLUE}=== Kernel Version ===${NC}"
uname -a
echo ""

# =============================================================================
# Cgroups
# =============================================================================
echo -e "${BLUE}=== Cgroups ===${NC}"
if [ -d /sys/fs/cgroup ]; then
    echo -e "${GREEN}✓${NC} /sys/fs/cgroup exists"
    
    # Check cgroup version
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        echo -e "${GREEN}✓${NC} Cgroup v2 (unified hierarchy)"
        echo "  Controllers: $(cat /sys/fs/cgroup/cgroup.controllers)"
    else
        echo -e "${YELLOW}!${NC} Cgroup v1 (legacy hierarchy)"
        echo "  Mounted controllers:"
        mount | grep cgroup | sed 's/^/    /'
    fi
else
    echo -e "${RED}✗${NC} /sys/fs/cgroup does not exist"
fi
echo ""

# =============================================================================
# Namespaces
# =============================================================================
echo -e "${BLUE}=== Namespaces ===${NC}"
for ns in pid net ipc uts mnt user cgroup; do
    if [ -e /proc/self/ns/$ns ]; then
        echo -e "${GREEN}✓${NC} $ns namespace available"
    else
        echo -e "${RED}✗${NC} $ns namespace NOT available"
    fi
done
echo ""

# =============================================================================
# Filesystems
# =============================================================================
echo -e "${BLUE}=== Filesystems ===${NC}"
if grep -q overlay /proc/filesystems; then
    echo -e "${GREEN}✓${NC} overlay filesystem supported"
else
    echo -e "${RED}✗${NC} overlay filesystem NOT supported (Docker will fall back to vfs)"
fi

if grep -q tmpfs /proc/filesystems; then
    echo -e "${GREEN}✓${NC} tmpfs supported"
else
    echo -e "${RED}✗${NC} tmpfs NOT supported"
fi
echo ""

# =============================================================================
# Netfilter/iptables
# =============================================================================
echo -e "${BLUE}=== Netfilter/iptables ===${NC}"

# Check which iptables is being used
echo "iptables version:"
iptables --version 2>/dev/null || echo "  iptables not found"
echo ""

# Check for netfilter support
echo "Netfilter tables:"
if [ -r /proc/net/ip_tables_names ]; then
    echo -e "${GREEN}✓${NC} iptables (legacy) supported"
    echo "  Available tables: $(cat /proc/net/ip_tables_names | tr '\n' ' ')"
elif [ -d /proc/sys/net/netfilter ]; then
    echo -e "${YELLOW}!${NC} nftables might be available"
else
    echo -e "${RED}✗${NC} No netfilter support detected"
fi
echo ""

# Try to list iptables rules
echo "Current iptables rules (nat table):"
if iptables -t nat -L -n 2>/dev/null; then
    echo -e "${GREEN}✓${NC} iptables is functional"
else
    echo -e "${RED}✗${NC} iptables command failed"
    echo "  Error: $(iptables -t nat -L -n 2>&1)"
fi
echo ""

# =============================================================================
# Network
# =============================================================================
echo -e "${BLUE}=== Network ===${NC}"
echo "Network interfaces:"
ip addr show | grep -E "^[0-9]+:|inet " | sed 's/^/  /'
echo ""

echo "Default route:"
ip route show default | sed 's/^/  /' || echo "  No default route"
echo ""

echo "DNS configuration:"
cat /etc/resolv.conf | grep -v "^#" | sed 's/^/  /'
echo ""

echo "Connectivity test:"
if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Can reach 8.8.8.8"
else
    echo -e "  ${RED}✗${NC} Cannot reach 8.8.8.8"
fi

if ping -c 1 -W 2 google.com &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} DNS resolution works (google.com)"
else
    echo -e "  ${RED}✗${NC} DNS resolution failed"
fi
echo ""

# =============================================================================
# Docker Status
# =============================================================================
echo -e "${BLUE}=== Docker Status ===${NC}"

# Check if containerd is running
echo "containerd:"
if systemctl is-active containerd &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} containerd is running"
elif pgrep containerd &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} containerd process found"
else
    echo -e "  ${RED}✗${NC} containerd is NOT running"
fi

# Check if Docker daemon is running
echo "docker:"
if systemctl is-active docker &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} docker service is running"
elif pgrep dockerd &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} dockerd process found"
else
    echo -e "  ${RED}✗${NC} docker is NOT running"
fi

# Check socket
if [ -S /var/run/docker.sock ]; then
    echo -e "  ${GREEN}✓${NC} Docker socket exists"
else
    echo -e "  ${RED}✗${NC} Docker socket NOT found"
fi
echo ""

# =============================================================================
# Docker Info (if running)
# =============================================================================
echo -e "${BLUE}=== Docker Info ===${NC}"
if docker info 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Docker is fully operational"
else
    echo -e "${RED}✗${NC} Docker is not responding"
    echo ""
    echo "Docker daemon logs:"
    if [ -f /var/log/dockerd.log ]; then
        tail -30 /var/log/dockerd.log | sed 's/^/  /'
    else
        journalctl -u docker --no-pager -n 30 2>/dev/null | sed 's/^/  /' || echo "  No logs available"
    fi
fi
echo ""

# =============================================================================
# Summary
# =============================================================================
echo -e "${BLUE}=== Summary ===${NC}"
issues=0

if ! docker info &>/dev/null; then
    echo -e "${RED}✗${NC} Docker is NOT running"
    ((issues++))
    
    if ! grep -q overlay /proc/filesystems; then
        echo "  → Kernel missing overlay filesystem support"
        ((issues++))
    fi
    
    if ! iptables -t nat -L -n &>/dev/null 2>&1; then
        echo "  → Kernel missing iptables/netfilter support"
        ((issues++))
    fi
    
    if [ ! -d /sys/fs/cgroup ]; then
        echo "  → Cgroups not mounted"
        ((issues++))
    fi
    
    echo ""
    echo "Suggested fixes:"
    echo "  1. Rebuild kernel with complete Docker config"
    echo "  2. Check kernel-firecracker-docker.config includes all requirements"
    echo "  3. Try: sudo systemctl restart docker"
    echo "  4. Check: sudo journalctl -xe -u docker"
else
    echo -e "${GREEN}✓${NC} Docker is operational"
fi

exit $issues
