#!/bin/bash
# =============================================================================
# Firecracker MicroVM Entrypoint
# =============================================================================
# Starts Firecracker VMM with configured resources and networking.
# The VM boots with vm-base rootfs and mounts workspace from host.
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[FC]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[FC]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[FC]${NC} $*"; }
log_error() { echo -e "${RED}[FC]${NC} $*" >&2; }

# =============================================================================
# Configuration
# =============================================================================
FC_VCPU="${FC_VCPU:-2}"
FC_MEM="${FC_MEM:-2048}"
FC_ROOTFS="${FC_ROOTFS:-/var/lib/firecracker/rootfs/base.ext4}"
FC_KERNEL="${FC_KERNEL:-/var/lib/firecracker/kernel/vmlinux}"
FC_WORKSPACE_SIZE="${FC_WORKSPACE_SIZE:-2048}"
FC_TAP_DEVICE="${FC_TAP_DEVICE:-tap0}"
FC_TAP_IP="${FC_TAP_IP:-172.16.0.1}"
FC_VM_IP="${FC_VM_IP:-172.16.0.2}"
FC_SOCKET="/var/lib/firecracker/run/firecracker.socket"
FC_LOG_LEVEL="${FC_LOG_LEVEL:-Warning}"
FC_CONSOLE_TYPE="${FC_CONSOLE_TYPE:-interactive}"

# Workspace paths
HOST_WORKSPACE="/workspace"
WORKSPACE_IMAGE="/var/lib/firecracker/workspace/workspace.ext4"

# ============================================================================
# Ensure folders/files are in place
# ============================================================================
ensure_directories() {
    mkdir -p /var/lib/firecracker/rootfs
    mkdir -p /var/lib/firecracker/kernel
    mkdir -p /var/lib/firecracker/workspace
    mkdir -p /var/lib/firecracker/run
}

validate_files() {
    if [ ! -f "$FC_KERNEL" ]; then
        log_error "Kernel not found: $FC_KERNEL"
        exit 1
    fi
    if [ ! -f "$FC_ROOTFS" ]; then
        log_error "Rootfs not found: $FC_ROOTFS"
        exit 1
    fi
    log_ok "Kernel and rootfs validated"
}

# =============================================================================
# Functions
# =============================================================================

check_kvm() {
    if [ ! -e /dev/kvm ]; then
        log_error "/dev/kvm not found!"
        log_error "Run with: docker run --device /dev/kvm ..."
        log_error "Or enable KVM in your hypervisor if running in a VM."
        exit 1
    fi
    
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        log_error "/dev/kvm not accessible!"
        log_error "Check permissions or run as root."
        exit 1
    fi
    
    log_ok "KVM available"
}

setup_network() {
    log_info "Setting up network (TAP: $FC_TAP_DEVICE)..."
    /usr/local/bin/setup-network.sh
    log_ok "Network ready (VM will be at $FC_VM_IP)"
}

prepare_workspace() {
    log_info "Preparing workspace image (${FC_WORKSPACE_SIZE}MB)..."
   
    mkdir -p "$(dirname "$WORKSPACE_IMAGE")"
 
    if [ -d "$HOST_WORKSPACE" ] && [ "$(ls -A $HOST_WORKSPACE 2>/dev/null)" ]; then
        log_info "Syncing host workspace to VM image..."
        /usr/local/bin/create-workspace-image.sh \
            "$HOST_WORKSPACE" \
            "$WORKSPACE_IMAGE" \
            "$FC_WORKSPACE_SIZE"
    else
        log_info "Creating empty workspace image..."
        truncate -s ${FC_WORKSPACE_SIZE}M "$WORKSPACE_IMAGE"
        mkfs.ext4 -F "$WORKSPACE_IMAGE" >/dev/null 2>&1
    fi
    
    log_ok "Workspace image ready"
}

generate_config() {
    log_info "Generating Firecracker config (vCPU: $FC_VCPU, RAM: ${FC_MEM}MB)..."
    
    # Remove old socket if exists
    rm -f "$FC_SOCKET"
    
    # Generate config from template
    cat /etc/firecracker/firecracker.json.template | \
        sed "s|__KERNEL__|$FC_KERNEL|g" | \
        sed "s|__ROOTFS__|$FC_ROOTFS|g" | \
        sed "s|__WORKSPACE__|$WORKSPACE_IMAGE|g" | \
        sed "s|__VCPU__|$FC_VCPU|g" | \
        sed "s|__MEM__|$FC_MEM|g" | \
        sed "s|__TAP__|$FC_TAP_DEVICE|g" | \
        sed "s|__VM_IP__|$FC_VM_IP|g" | \
        sed "s|__TAP_IP__|$FC_TAP_IP|g" \
        > /var/lib/firecracker/run/firecracker.json
    
    log_ok "Config generated"
}

start_firecracker() {
    log_info "Starting Firecracker MicroVM..."
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  Firecracker MicroVM                                          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Hardware-Isolated Development Environment                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}VM Configuration:${NC}"
    echo "    vCPUs:     $FC_VCPU"
    echo "    Memory:    ${FC_MEM}MB"
    echo "    Kernel:    $(basename $FC_KERNEL)"
    echo "    Rootfs:    $(basename $FC_ROOTFS)"
    echo ""
    echo -e "  ${YELLOW}Network:${NC}"
    echo "    VM IP:     $FC_VM_IP"
    echo "    Gateway:   $FC_TAP_IP"
    echo ""
    echo -e "  ${YELLOW}Workspace:${NC}"
    echo "    Host:      $HOST_WORKSPACE"
    echo "    VM Mount:  /workspace"
    echo ""
    echo -e "  ${YELLOW}Console:${NC}"
    echo "    Auto-login as 'sandbox' user"
    echo "    Root password: 'firecracker' (emergency only)"
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ "$FC_CONSOLE_TYPE" = "interactive" ]; then
        # Interactive mode: connect to serial console
        firecracker \
            --api-sock "$FC_SOCKET" \
            --config-file /var/lib/firecracker/run/firecracker.json \
            --log-path /dev/stderr \
            --level "$FC_LOG_LEVEL"
    else
        # Detached mode: run in background
        firecracker \
            --api-sock "$FC_SOCKET" \
            --config-file /var/lib/firecracker/run/firecracker.json \
            --log-path /var/log/firecracker.log \
            --level "$FC_LOG_LEVEL" &
        
        FC_PID=$!
        log_ok "Firecracker started (PID: $FC_PID)"
        
        # Wait for VM to boot
        sleep 3
        log_info "VM should be accessible at $FC_VM_IP"
        
        wait $FC_PID
    fi
}

sync_workspace_back() {
    if [ -d "$HOST_WORKSPACE" ] && [ -f "$WORKSPACE_IMAGE" ]; then
        log_info "Syncing workspace changes back to host..."
        mkdir -p /tmp/workspace-mount
        if mount -o loop "$WORKSPACE_IMAGE" /tmp/workspace-mount 2>/dev/null; then
            rsync -av --delete /tmp/workspace-mount/ "$HOST_WORKSPACE/"
            umount /tmp/workspace-mount
            log_ok "Workspace synced"
        fi
    fi
}

cleanup() {
    log_info "Cleaning up..."
    
    # Sync workspace
    sync_workspace_back 2>/dev/null || true
    
    # Remove TAP device
    ip link delete "$FC_TAP_DEVICE" 2>/dev/null || true
    
    # Clean up socket
    rm -f "$FC_SOCKET"
    
    log_ok "Cleanup complete"
}

show_help() {
    cat << EOF
Firecracker MicroVM Manager

Usage: entrypoint.sh [command]

Commands:
  start         Start the MicroVM (default)
  shell         Start with interactive shell access
  detach        Start in detached mode
  config        Show current configuration
  help          Show this help

Environment Variables:
  FC_VCPU              Number of vCPUs (default: 2)
  FC_MEM               Memory in MB (default: 2048)
  FC_WORKSPACE_SIZE    Workspace image size in MB (default: 2048)
  FC_LOG_LEVEL         Log level: Error, Warning, Info, Debug (default: Warning)
  FC_CONSOLE_TYPE      Console mode: interactive, detached (default: interactive)

Examples:
  # Start with 4 vCPUs and 4GB RAM
  docker run --device /dev/kvm --cap-add NET_ADMIN \\
    -e FC_VCPU=4 -e FC_MEM=4096 \\
    -v /my/project:/workspace \\
    firecracker-base:latest

  # Detached mode
  docker run -d --device /dev/kvm --cap-add NET_ADMIN \\
    -e FC_CONSOLE_TYPE=detached \\
    firecracker-base:latest
EOF
}

show_config() {
    echo "Firecracker Configuration:"
    echo "  FC_VCPU=$FC_VCPU"
    echo "  FC_MEM=$FC_MEM"
    echo "  FC_ROOTFS=$FC_ROOTFS"
    echo "  FC_KERNEL=$FC_KERNEL"
    echo "  FC_WORKSPACE_SIZE=$FC_WORKSPACE_SIZE"
    echo "  FC_TAP_DEVICE=$FC_TAP_DEVICE"
    echo "  FC_TAP_IP=$FC_TAP_IP"
    echo "  FC_VM_IP=$FC_VM_IP"
    echo "  FC_LOG_LEVEL=$FC_LOG_LEVEL"
    echo "  FC_CONSOLE_TYPE=$FC_CONSOLE_TYPE"
}

# =============================================================================
# Main
# =============================================================================

trap cleanup EXIT

case "${1:-start}" in
    start|shell)
        ensure_directories
        validate_files 
        check_kvm
        setup_network
        prepare_workspace
        generate_config
        start_firecracker
        ;;
    detach)
        export FC_CONSOLE_TYPE=detached
        check_kvm
        setup_network
        prepare_workspace
        generate_config
        start_firecracker
        ;;
    config)
        show_config
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
