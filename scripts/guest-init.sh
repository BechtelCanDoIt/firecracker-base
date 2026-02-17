#!/bin/bash
# =============================================================================
# Guest VM Initialization Script
# =============================================================================
# Runs at boot inside the MicroVM to configure the environment.
# Includes Docker daemon initialization with diagnostics.
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INIT]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[INIT]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[INIT]${NC} $*"; }
log_error() { echo -e "${RED}[INIT]${NC} $*" >&2; }

# =============================================================================
# Network Configuration
# =============================================================================
wait_for_network() {
    local max_attempts=30
    local attempt=0
    
    log_info "Waiting for network..."
    while [ $attempt -lt $max_attempts ]; do
        if ip addr show eth0 2>/dev/null | grep -q "inet "; then
            log_ok "Network interface ready"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    log_warn "Network not available after ${max_attempts}s"
    return 1
}

configure_dns() {
    log_info "Configuring DNS..."
    
    # Ensure resolv.conf is properly set up
    # Use systemd-resolved if available, otherwise configure manually
    if systemctl is-active systemd-resolved &>/dev/null; then
        # Make sure resolved is properly linked
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
    else
        # Fallback: configure DNS directly
        cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF
    fi
    
    log_ok "DNS configured"
}

# =============================================================================
# Docker Startup
# =============================================================================
check_kernel_features() {
    log_info "Checking kernel features for Docker..."
    local missing=()
    
    # Check cgroups
    if [ ! -d /sys/fs/cgroup ]; then
        missing+=("cgroups")
    fi
    
    # Check namespaces
    if [ ! -e /proc/self/ns/pid ]; then
        missing+=("PID namespace")
    fi
    if [ ! -e /proc/self/ns/net ]; then
        missing+=("NET namespace")
    fi
    
    # Check overlay fs
    if ! grep -q overlay /proc/filesystems 2>/dev/null; then
        missing+=("overlay filesystem")
    fi
    
    # Check netfilter
    if [ ! -e /proc/net/ip_tables_names ] && [ ! -e /proc/net/nf_tables ]; then
        log_warn "Neither iptables nor nftables appear to be available"
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing kernel features: ${missing[*]}"
        log_warn "Docker may not work correctly"
        return 1
    fi
    
    log_ok "Kernel features OK"
    return 0
}

setup_cgroups() {
    log_info "Setting up cgroups..."
    
    # Mount cgroup2 unified hierarchy if not already mounted
    if ! mountpoint -q /sys/fs/cgroup; then
        mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || {
            # Fallback to hybrid mode
            mount -t tmpfs cgroup_root /sys/fs/cgroup 2>/dev/null || true
            
            # Mount individual cgroup controllers
            for controller in cpu cpuacct memory devices freezer net_cls blkio perf_event pids; do
                mkdir -p /sys/fs/cgroup/$controller
                mount -t cgroup -o $controller none /sys/fs/cgroup/$controller 2>/dev/null || true
            done
        }
    fi
    
    log_ok "Cgroups ready"
}

configure_docker_daemon() {
    log_info "Configuring Docker daemon..."
    
    mkdir -p /etc/docker
    
    # Determine best storage driver
    local storage_driver="overlay2"
    if ! grep -qE '^nodev[[:space:]]+overlay$' /proc/filesystems 2>/dev/null; then
        log_warn "Overlay filesystem not available, using vfs (slower)"
        storage_driver="vfs"
    fi
    
    # Create daemon configuration
    cat > /etc/docker/daemon.json << EOF
{
    "storage-driver": "${storage_driver}",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "live-restore": false,
    "iptables": true,
    "ip-forward": true,
    "userland-proxy": true,
    "dns": ["8.8.8.8", "8.8.4.4"]
}
EOF
    
    log_ok "Docker daemon configured (storage: ${storage_driver})"
}

start_docker_daemon() {
    log_info "Starting Docker daemon..."
    
    # Ensure containerd is running first
    if ! systemctl is-active containerd &>/dev/null; then
        log_info "Starting containerd..."
        systemctl start containerd 2>/dev/null || {
            log_warn "systemctl failed, trying direct start..."
            containerd &>/dev/null &
            sleep 2
        }
    fi
    
    # Start Docker
    if ! systemctl is-active docker &>/dev/null; then
        log_info "Starting Docker service..."
        systemctl start docker 2>/dev/null || {
            log_warn "systemctl failed for Docker, trying direct start..."
            
            # Try starting dockerd directly
            dockerd &>/var/log/dockerd.log 2>&1 &
            local dockerd_pid=$!
            
            # Wait for socket to appear
            local attempts=0
            while [ $attempts -lt 30 ]; do
                if [ -S /var/run/docker.sock ]; then
                    log_ok "Docker socket ready"
                    return 0
                fi
                
                # Check if dockerd is still running
                if ! kill -0 $dockerd_pid 2>/dev/null; then
                    log_error "dockerd exited unexpectedly"
                    if [ -f /var/log/dockerd.log ]; then
                        log_error "Last lines from dockerd log:"
                        tail -20 /var/log/dockerd.log >&2
                    fi
                    return 1
                fi
                
                sleep 1
                ((attempts++))
            done
            
            log_error "Docker socket did not appear after 30s"
            return 1
        }
    fi
    
    log_ok "Docker service started"
}

wait_for_docker() {
    log_info "Waiting for Docker to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker info &>/dev/null; then
            log_ok "Docker daemon ready"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    log_error "Docker not ready after ${max_attempts}s"
    
    # Diagnostic info
    log_error "Diagnostic information:"
    echo "  Socket exists: $([ -S /var/run/docker.sock ] && echo 'yes' || echo 'no')"
    echo "  containerd:    $(systemctl is-active containerd 2>/dev/null || echo 'unknown')"
    echo "  docker:        $(systemctl is-active docker 2>/dev/null || echo 'unknown')"
    
    if [ -f /var/log/dockerd.log ]; then
        echo ""
        echo "  Last dockerd log entries:"
        tail -10 /var/log/dockerd.log | sed 's/^/    /'
    fi
    
    # Check journal for Docker errors
    if command -v journalctl &>/dev/null; then
        echo ""
        echo "  Recent Docker journal entries:"
        journalctl -u docker --no-pager -n 10 2>/dev/null | sed 's/^/    /' || true
    fi
    
    return 1
}

ensure_docker_running() {
    # Check if Docker is already running
    if docker info &>/dev/null; then
        log_ok "Docker already running"
        return 0
    fi
    
    # Full startup sequence
    check_kernel_features || true  # Continue even if some features missing
    setup_cgroups
    configure_docker_daemon
    start_docker_daemon
    wait_for_docker
}

# =============================================================================
# Environment Configuration
# =============================================================================
configure_environment() {
    log_info "Configuring environment..."
    
    # Ensure workspace is mounted and accessible
    if mountpoint -q /workspace; then
        chown sandbox:sandbox /workspace 2>/dev/null || true
        log_ok "Workspace mounted at /workspace"
    else
        log_warn "Workspace not mounted"
    fi
    
    # Set permissions for home directory
    chown -R sandbox:sandbox /home/sandbox 2>/dev/null || true
    
    # Create directories if missing
    mkdir -p /home/sandbox/{.config,.cache,.local/bin,/{bin,pkg,src},.npm-global,.docker}
    chown -R sandbox:sandbox /home/sandbox
    
    log_ok "Environment configured"
}

# =============================================================================
# Welcome Message
# =============================================================================
print_welcome() {
    local docker_version="not running"
    local docker_status="${RED}✗${NC}"
    
    if docker info &>/dev/null; then
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        docker_status="${GREEN}✓${NC}"
    fi
    
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  Firecracker MicroVM - Hardware-Isolated Container Environment     ║"
    echo "╠════════════════════════════════════════════════════════════════════╣"
    echo "║  Your containers run inside a VM, protected from the host by:      ║"
    echo "║    • Separate kernel (guest Linux, not host kernel)                ║"
    echo "║    • Hardware memory isolation (Intel EPT / AMD NPT)               ║"
    echo "║    • Minimal VMM attack surface (Firecracker ~50k LoC)             ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "  User:      sandbox (docker group)"
    echo -e "  Workspace: /workspace"
    echo -e "  Docker:    ${docker_version} ${docker_status}"
    echo ""
    
    if docker info &>/dev/null; then
        echo "  Quick start:"
        echo "    docker run hello-world"
        echo "    docker compose up"
        echo "    cd /workspace && docker build ."
    else
        echo -e "  ${YELLOW}Docker is not running. Check logs with:${NC}"
        echo "    sudo journalctl -u docker"
        echo "    sudo cat /var/log/dockerd.log"
        echo ""
        echo "  To manually start Docker:"
        echo "    sudo systemctl start docker"
    fi
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    log_info "Initializing guest VM..."
    
    # Wait for network first
    wait_for_network || true
    
    # Configure DNS
    configure_dns
    
    # Start Docker
    ensure_docker_running || true
    
    # Configure environment
    configure_environment
    
    # Print welcome
    print_welcome
    
    log_ok "Guest initialization complete"
}

main "$@"
