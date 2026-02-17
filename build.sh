#!/bin/bash
# =============================================================================
# Build firecracker-base image
# =============================================================================
# Three-stage build:
#   1. Build kernel with Docker-compatible config
#   2. Create rootfs in privileged container (for loop mount)
#   3. Assemble final image with standard docker build
# =============================================================================

set -euo pipefail

IMAGE_NAME="firecracker-base:latest"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-8192}"
LINUX_VERSION="${LINUX_VERSION:-v5.10.213}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[build]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[build]${NC} $*"; }
log_error() { echo -e "${RED}[build]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[build]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"

cleanup() {
    log_info "Cleaning up..."
    rm -rf "$BUILD_DIR"
}

# =============================================================================
# Stage 0: Build kernel with Docker support
# =============================================================================
build_kernel() {
    log_info "Stage 0: Building kernel (this takes 10-15 minutes)..."
    
    mkdir -p "$BUILD_DIR"
    
    # Check if kernel config exists
    if [ ! -f "$SCRIPT_DIR/config/kernel-firecracker-docker.config" ]; then
        log_error "Kernel config not found: $SCRIPT_DIR/config/kernel-firecracker-docker.config"
        exit 1
    fi
    
    # Copy kernel config to build dir
    cp "$SCRIPT_DIR/config/kernel-firecracker-docker.config" "$BUILD_DIR/"
    
    log_step "Compiling Linux $LINUX_VERSION with Docker support..."
    log_step "This includes: namespaces, cgroups, overlay fs, netfilter, iptables..."
    
    docker run --rm \
        -v "$BUILD_DIR:/build" \
        ubuntu:24.04 \
        bash -c '
set -e

echo "Installing build dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    flex \
    bison \
    bc \
    libssl-dev \
    libelf-dev \
    git \
    ca-certificates

echo "Cloning Linux kernel '"$LINUX_VERSION"'..."
git clone --depth 1 --branch '"$LINUX_VERSION"' https://github.com/gregkh/linux.git /tmp/linux
cd /tmp/linux

echo "Configuring kernel..."
make x86_64_defconfig
./scripts/kconfig/merge_config.sh -m .config /build/kernel-firecracker-docker.config
make olddefconfig

echo "Building kernel (this takes a while)..."
make -j$(nproc) vmlinux

echo "Copying kernel..."
cp vmlinux /build/vmlinux
chmod 644 /build/vmlinux

echo "Kernel build complete!"
echo "Kernel size: $(du -h /build/vmlinux | cut -f1)"
'
    
    if [ ! -f "$BUILD_DIR/vmlinux" ]; then
        log_error "Kernel build failed!"
        exit 1
    fi
    
    log_info "Kernel built: $BUILD_DIR/vmlinux"
}

# =============================================================================
# Stage 1: Build rootfs in privileged container
# =============================================================================
build_rootfs() {
    log_info "Stage 1: Building rootfs (privileged container)..."
    
    mkdir -p "$BUILD_DIR"
    
    # Create rootfs build script
    cat > "$BUILD_DIR/build-rootfs.sh" << 'ROOTFS_SCRIPT'
#!/bin/bash
set -euo pipefail

ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-8192}"

echo "Creating ${ROOTFS_SIZE_MB}MB rootfs..."

cd /build

# Create ext4 image
truncate -s ${ROOTFS_SIZE_MB}M rootfs.ext4
mkfs.ext4 -F rootfs.ext4

# Mount
mkdir -p /mnt/rootfs
mount -o loop rootfs.ext4 /mnt/rootfs

# Bootstrap Ubuntu
echo "Running debootstrap (this takes a few minutes)..."
debootstrap --variant=minbase --include=\
systemd,systemd-sysv,systemd-resolved,\
dbus,\
sudo,\
curl,\
wget,\
ca-certificates,\
gnupg,\
git,\
vim,\
nano,\
less,\
htop,\
jq,\
openssh-server,\
iproute2,\
iputils-ping,\
bind9-dnsutils,\
netcat-openbsd,\
locales,\
iptables,\
kmod,\
procps,\
libseccomp2,\
udev \
    noble /mnt/rootfs http://archive.ubuntu.com/ubuntu

# Configure rootfs
mount -o bind /dev /mnt/rootfs/dev
mount -o bind /proc /mnt/rootfs/proc
mount -o bind /sys /mnt/rootfs/sys

# Set locale
chroot /mnt/rootfs locale-gen en_US.UTF-8

# Set hostname and hosts file
echo "firecracker-vm" > /mnt/rootfs/etc/hostname
cat > /mnt/rootfs/etc/hosts << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   firecracker-vm
::1         localhost ip6-localhost ip6-loopback
HOSTS

# Configure networking - static IP (faster and more reliable than DHCP)
mkdir -p /mnt/rootfs/etc/systemd/network
cat > /mnt/rootfs/etc/systemd/network/20-eth0.network << 'NETCONF'
[Match]
Name=eth0

[Network]
DHCP=no
Address=172.16.0.2/24
Gateway=172.16.0.1
DNS=8.8.8.8
DNS=8.8.4.4
NETCONF
chroot /mnt/rootfs systemctl enable systemd-networkd
chroot /mnt/rootfs systemctl enable systemd-resolved

# Disable network-wait-online (causes boot delays)
chroot /mnt/rootfs systemctl disable systemd-networkd-wait-online.service || true

# Create sandbox user
chroot /mnt/rootfs useradd -m -s /bin/bash -u 1000 sandbox
echo "sandbox ALL=(ALL) NOPASSWD: ALL" > /mnt/rootfs/etc/sudoers.d/sandbox
chmod 0440 /mnt/rootfs/etc/sudoers.d/sandbox

# Lock root account (use sudo from sandbox user instead)
chroot /mnt/rootfs passwd -l root || true

# ============================================================================
# Serial Console - standalone service (no device dependencies)
# ============================================================================
cat > /mnt/rootfs/etc/systemd/system/serial-console.service << 'SERIALSERVICE'
[Unit]
Description=Serial Console Login
After=systemd-user-sessions.service
After=rc-local.service
Before=getty.target
IgnoreOnIsolate=yes
ConditionPathExists=/dev/ttyS0

[Service]
ExecStart=-/sbin/agetty --autologin sandbox --noclear --keep-baud 115200,38400,9600 ttyS0 linux
Type=idle
Restart=always
RestartSec=0
UtmpIdentifier=ttyS0
TTYPath=/dev/ttyS0
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=tty

[Install]
WantedBy=getty.target
SERIALSERVICE

chroot /mnt/rootfs systemctl enable serial-console.service
chroot /mnt/rootfs systemctl mask serial-getty@ttyS0.service || true

# ============================================================================
# Workspace mount - service instead of fstab
# ============================================================================
cat > /mnt/rootfs/etc/fstab << 'FSTABEOF'
# Firecracker VM - minimal fstab (rootfs mounted by kernel)
# Workspace mounted by mount-workspace.service
FSTABEOF

cat > /mnt/rootfs/usr/local/bin/mount-workspace.sh << 'MOUNTSCRIPT'
#!/bin/bash
sleep 1
if [ -b /dev/vdb ]; then
    mkdir -p /workspace
    mount /dev/vdb /workspace 2>/dev/null && \
        chown 1000:1000 /workspace && \
        echo "Workspace mounted successfully"
fi
MOUNTSCRIPT
chmod +x /mnt/rootfs/usr/local/bin/mount-workspace.sh

cat > /mnt/rootfs/etc/systemd/system/mount-workspace.service << 'MOUNTSERVICE'
[Unit]
Description=Mount Workspace Volume
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-workspace.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
MOUNTSERVICE
chroot /mnt/rootfs systemctl enable mount-workspace.service

mkdir -p /mnt/rootfs/workspace
chown 1000:1000 /mnt/rootfs/workspace

# ============================================================================
# Install Docker
# ============================================================================
echo "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /mnt/rootfs/usr/share/keyrings/docker-archive-keyring.gpg
ARCH=$(dpkg --print-architecture)
echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    > /mnt/rootfs/etc/apt/sources.list.d/docker.list
chroot /mnt/rootfs apt-get update
chroot /mnt/rootfs apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
chroot /mnt/rootfs usermod -aG docker sandbox
chroot /mnt/rootfs systemctl enable docker
chroot /mnt/rootfs systemctl enable containerd

# Force iptables-legacy (kernel may not have full nftables support)
chroot /mnt/rootfs update-alternatives --set iptables /usr/sbin/iptables-legacy || true
chroot /mnt/rootfs update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

# Configure Docker daemon
mkdir -p /mnt/rootfs/etc/docker
cat > /mnt/rootfs/etc/docker/daemon.json << 'DOCKERCONF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "iptables": true,
  "ip-forward": true,
  "live-restore": false
}
DOCKERCONF

# ============================================================================
# Kernel modules and sysctl for Docker networking
# ============================================================================
cat > /mnt/rootfs/etc/modules-load.d/firecracker.conf << 'MODULES'
overlay
br_netfilter
MODULES

cat > /mnt/rootfs/etc/sysctl.d/99-docker.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
SYSCTL

# Create user directories
mkdir -p /mnt/rootfs/home/sandbox/{.config,.cache,.docker}
chroot /mnt/rootfs chown -R 1000:1000 /home/sandbox

# Install guest init script
cp /scripts/guest-init.sh /mnt/rootfs/usr/local/bin/guest-init.sh
chmod +x /mnt/rootfs/usr/local/bin/guest-init.sh

# Create systemd service for guest init
cat > /mnt/rootfs/etc/systemd/system/guest-init.service << 'GUESTINIT'
[Unit]
Description=Guest VM Initialization
After=docker.service mount-workspace.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/guest-init.sh
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
GUESTINIT
chroot /mnt/rootfs systemctl enable guest-init.service

# ============================================================================
# Cleanup
# ============================================================================
chroot /mnt/rootfs apt-get clean
rm -rf /mnt/rootfs/var/lib/apt/lists/*
rm -rf /mnt/rootfs/var/cache/apt/archives/*

# Unmount
umount /mnt/rootfs/sys /mnt/rootfs/proc /mnt/rootfs/dev
umount /mnt/rootfs

echo "Rootfs created successfully!"
ROOTFS_SCRIPT
    chmod +x "$BUILD_DIR/build-rootfs.sh"
    
    # Copy guest-init.sh
    cp "$SCRIPT_DIR/scripts/guest-init.sh" "$BUILD_DIR/"
    
    # Run rootfs build in privileged container
    log_info "Running privileged container to build rootfs..."
    docker run --rm \
        --privileged \
        -v "$BUILD_DIR:/build" \
        -v "$BUILD_DIR/guest-init.sh:/scripts/guest-init.sh:ro" \
        -e ROOTFS_SIZE_MB="$ROOTFS_SIZE_MB" \
        ubuntu:24.04 \
        bash -c "apt-get update && apt-get install -y debootstrap e2fsprogs curl gnupg && /build/build-rootfs.sh"
    
    if [ ! -f "$BUILD_DIR/rootfs.ext4" ]; then
        log_error "Rootfs build failed!"
        exit 1
    fi
    
    log_info "Rootfs created: $BUILD_DIR/rootfs.ext4"
}

# =============================================================================
# Stage 2: Build final image
# =============================================================================
build_image() {
    log_info "Stage 2: Building final image..."
    
    # Check that kernel exists
    if [ ! -f "$BUILD_DIR/vmlinux" ]; then
        log_error "Kernel not found at $BUILD_DIR/vmlinux"
        log_error "Run './build.sh' without arguments to build kernel first"
        exit 1
    fi
    
    # Create Dockerfile for final assembly
    cat > "$BUILD_DIR/Dockerfile.final" << 'DOCKERFILE'
# syntax=docker/dockerfile:1.4
FROM alpine:3.19 AS firecracker-download

RUN apk add --no-cache curl ca-certificates tar

ARG FIRECRACKER_VERSION=v1.6.0
ARG TARGETARCH

WORKDIR /download

RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${ARCH}.tgz" \
    -o firecracker.tgz && \
    tar -xzf firecracker.tgz && \
    mv release-${FIRECRACKER_VERSION}-${ARCH}/firecracker-${FIRECRACKER_VERSION}-${ARCH} /usr/local/bin/firecracker && \
    mv release-${FIRECRACKER_VERSION}-${ARCH}/jailer-${FIRECRACKER_VERSION}-${ARCH} /usr/local/bin/jailer && \
    chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer

FROM alpine:3.19 AS runtime

LABEL maintainer="firecracker-base" \
      description="Hardware-isolated MicroVM with Docker" \
      version="2.0" \
      security.isolation="hardware"

RUN apk add --no-cache \
    iproute2 \
    iptables \
    iptables-legacy \
    dnsmasq \
    socat \
    jq \
    e2fsprogs \
    rsync \
    curl \
    ca-certificates \
    bash \
    coreutils \
    util-linux \
    && ln -sf /sbin/iptables-legacy /sbin/iptables \
    && ln -sf /sbin/ip6tables-legacy /sbin/ip6tables

COPY --from=firecracker-download /usr/local/bin/firecracker /usr/local/bin/firecracker
COPY --from=firecracker-download /usr/local/bin/jailer /usr/local/bin/jailer

# Copy custom-built kernel with Docker support
COPY vmlinux /var/lib/firecracker/kernel/vmlinux

# Copy pre-built rootfs
COPY rootfs.ext4 /var/lib/firecracker/rootfs/base.ext4

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/setup-network.sh /usr/local/bin/setup-network.sh
COPY scripts/create-workspace-image.sh /usr/local/bin/create-workspace-image.sh
COPY config/firecracker.json.template /etc/firecracker/firecracker.json.template

RUN chmod +x /usr/local/bin/*.sh && \
    mkdir -p /var/lib/firecracker/{rootfs,kernel,workspace,run}

ENV FC_VCPU=4 \
    FC_MEM=4096 \
    FC_ROOTFS=/var/lib/firecracker/rootfs/base.ext4 \
    FC_KERNEL=/var/lib/firecracker/kernel/vmlinux \
    FC_WORKSPACE_SIZE=4096 \
    FC_TAP_DEVICE=tap0 \
    FC_TAP_IP=172.16.0.1 \
    FC_VM_IP=172.16.0.2 \
    FC_LOG_LEVEL=Warning

VOLUME ["/workspace"]
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
DOCKERFILE
    
    # Copy necessary files to build context
    cp -r "$SCRIPT_DIR/scripts" "$BUILD_DIR/"
    cp -r "$SCRIPT_DIR/config" "$BUILD_DIR/"
    
    # Build final image
    docker build \
        -f "$BUILD_DIR/Dockerfile.final" \
        -t "$IMAGE_NAME" \
        "$BUILD_DIR"
    
    log_info "Image built: $IMAGE_NAME"
}

# =============================================================================
# Main
# =============================================================================
show_help() {
    cat << EOF
Build firecracker-base image with Docker support

Usage: ./build.sh [OPTIONS] [IMAGE_NAME]

Options:
  --help          Show this help
  --clean         Remove build artifacts and rebuild everything
  --kernel-only   Only rebuild the kernel
  --rootfs-only   Only rebuild the rootfs
  --image-only    Only rebuild the final image (requires existing kernel/rootfs)

Environment Variables:
  ROOTFS_SIZE_MB  Size of rootfs image in MB (default: 8192)
  LINUX_VERSION   Linux kernel version to build (default: v5.10.213)

Examples:
  ./build.sh                      # Full build
  ./build.sh --clean              # Clean rebuild
  ./build.sh --kernel-only        # Rebuild just the kernel
  ./build.sh my-image:v1          # Build with custom image name
EOF
}

main() {
    local do_kernel=true
    local do_rootfs=true
    local do_image=true
    local do_clean=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --clean)
                do_clean=true
                shift
                ;;
            --kernel-only)
                do_rootfs=false
                do_image=false
                shift
                ;;
            --rootfs-only)
                do_kernel=false
                do_image=false
                shift
                ;;
            --image-only)
                do_kernel=false
                do_rootfs=false
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                IMAGE_NAME="$1"
                shift
                ;;
        esac
    done
    
    log_info "Building $IMAGE_NAME"
    echo ""
    
    # Clean if requested
    if [ "$do_clean" = true ]; then
        log_warn "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
    fi
    
    mkdir -p "$BUILD_DIR"
    
    # Build kernel if needed
    if [ "$do_kernel" = true ]; then
        if [ -f "$BUILD_DIR/vmlinux" ] && [ "$do_clean" = false ]; then
            log_warn "Found existing kernel at $BUILD_DIR/vmlinux"
            read -p "Rebuild kernel? (takes 10-15 min) [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -f "$BUILD_DIR/vmlinux"
                build_kernel
            fi
        else
            build_kernel
        fi
    fi
    
    # Build rootfs if needed
    if [ "$do_rootfs" = true ]; then
        if [ -f "$BUILD_DIR/rootfs.ext4" ] && [ "$do_clean" = false ]; then
            log_warn "Found existing rootfs at $BUILD_DIR/rootfs.ext4"
            read -p "Rebuild rootfs? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -f "$BUILD_DIR/rootfs.ext4"
                build_rootfs
            fi
        else
            build_rootfs
        fi
    fi
    
    # Build final image
    if [ "$do_image" = true ]; then
        build_image
    fi
    
    echo ""
    log_info "Build complete!"
    echo ""
    echo "Run with:"
    echo "  docker compose run --rm firecracker-base"
    echo ""
    echo "Or directly:"
    echo "  docker run --rm -it --device /dev/kvm --cap-add NET_ADMIN firecracker-base:latest"
    echo ""
    echo "To rebuild everything from scratch:"
    echo "  ./build.sh --clean"
}

main "$@"
