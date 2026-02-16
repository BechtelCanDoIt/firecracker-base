#!/bin/bash
# =============================================================================
# Guest VM Initialization Script
# =============================================================================
# Runs at boot inside the MicroVM to configure the environment.
# Includes Docker daemon initialization.
# =============================================================================

set -e

# Wait for network
wait_for_network() {
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if ip addr show eth0 | grep -q "inet "; then
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    echo "Warning: Network not available after ${max_attempts}s"
    return 1
}

ensure_docker_running() {
    systemctl start containerd.service 2>/dev/null || true
    systemctl start docker.socket 2>/dev/null || true
    systemctl start docker.service 2>/dev/null || true

    if docker info &>/dev/null; then
        return 0
    fi

    mkdir -p /etc/docker

    if grep -qE '^nodev[[:space:]]+overlay$' /proc/filesystems; then
        cat > /etc/docker/daemon.json <<EOF
{"storage-driver":"overlay2"}
EOF
    else
        cat > /etc/docker/daemon.json <<EOF
{"storage-driver":"vfs"}
EOF
    fi

    systemctl restart docker.service 2>/dev/null || true
    docker info &>/dev/null
}

# Wait for Docker to be ready
wait_for_docker() {
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for Docker daemon..."
    while [ $attempt -lt $max_attempts ]; do
        if docker info &>/dev/null; then
            echo "Docker daemon ready"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    
    echo "Warning: Docker not ready after ${max_attempts}s"
    return 1
}

# Configure environment
configure_environment() {
    # Ensure workspace is mounted and accessible
    if mountpoint -q /workspace; then
        chown sandbox:sandbox /workspace 2>/dev/null || true
    fi
    
    # Set permissions for home directory
    chown -R sandbox:sandbox /home/sandbox 2>/dev/null || true
    
    # Create directories if missing
    mkdir -p /home/sandbox/{.config,.cache,.local/bin,go/{bin,pkg,src},.npm-global,.docker}
    chown -R sandbox:sandbox /home/sandbox
}

# Print welcome message
print_welcome() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  Firecracker MicroVM - Hardware-Isolated Container Environment    ║"
    echo "╠════════════════════════════════════════════════════════════════════╣"
    echo "║  Your containers run inside a VM, protected from the host by:     ║"
    echo "║    • Separate kernel (guest Linux, not host kernel)               ║"
    echo "║    • Hardware memory isolation (Intel EPT / AMD NPT)              ║"
    echo "║    • Minimal VMM attack surface (Firecracker ~50k LoC)           ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  User:      sandbox (docker group)"
    echo "  Workspace: /workspace"
    echo ""
    
    if command -v docker &>/dev/null; then
        echo "  Docker:    $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    fi
    echo ""
    echo "  Quick start:"
    echo "    docker run hello-world"
    echo "    docker compose up"
    echo "    cd /workspace && docker build ."
    echo ""
}

# Main
main() {
    echo "Initializing guest VM..."
    
    wait_for_network || true
    ensure_docker_running || true
    wait_for_docker || true
    configure_environment
    print_welcome
    
    echo "Guest initialization complete"
}

main "$@":
