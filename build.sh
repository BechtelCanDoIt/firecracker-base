#!/bin/bash
# =============================================================================
# Build firecracker-base image
# =============================================================================
# Two-stage build:
#   1. Create rootfs in privileged container (for loop mount)
#   2. Assemble final image with standard docker build
# =============================================================================

set -e

IMAGE_NAME="${1:-firecracker-base:latest}"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-8192}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[build]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[build]${NC} $*"; }
log_error() { echo -e "${RED}[build]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"

cleanup() {
    log_info "Cleaning up..."
    rm -rf "$BUILD_DIR"
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
set -e

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
libseccomp2 \
    noble /mnt/rootfs http://archive.ubuntu.com/ubuntu

# Configure rootfs
mount -o bind /dev /mnt/rootfs/dev
mount -o bind /proc /mnt/rootfs/proc
mount -o bind /sys /mnt/rootfs/sys

# Set locale
chroot /mnt/rootfs locale-gen en_US.UTF-8

# Set hostname
echo "firecracker-vm" > /mnt/rootfs/etc/hostname

# Configure networking
mkdir -p /mnt/rootfs/etc/systemd/network
printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\n' > /mnt/rootfs/etc/systemd/network/20-eth0.network
chroot /mnt/rootfs systemctl enable systemd-networkd
chroot /mnt/rootfs systemctl enable systemd-resolved

# Create sandbox user
chroot /mnt/rootfs useradd -m -s /bin/bash -u 1000 sandbox
echo "sandbox ALL=(ALL) NOPASSWD: ALL" > /mnt/rootfs/etc/sudoers.d/sandbox
chmod 0440 /mnt/rootfs/etc/sudoers.d/sandbox

# Set root password
echo 'root:firecracker' | chroot /mnt/rootfs chpasswd

# Auto-login on serial console (without device dependency)
mkdir -p /mnt/rootfs/etc/systemd/system/serial-getty@ttyS0.service.d
cat > /mnt/rootfs/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf << 'SERIALCONF'
[Unit]
# Remove device dependency for VM environment
ConditionPathExists=

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin sandbox --noclear --keep-baud 115200,38400,9600 ttyS0 linux
SERIALCONF

# Enable serial-getty explicitly
chroot /mnt/rootfs systemctl enable serial-getty@ttyS0.service

# Configure fstab for workspace with short device timeout
cat > /mnt/rootfs/etc/fstab << 'FSTABCONF'
# Firecracker VM fstab
/dev/vda / ext4 defaults 0 1
/dev/vdb /workspace ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2
FSTABCONF
mkdir -p /mnt/rootfs/workspace
chown 1000:1000 /mnt/rootfs/workspace

# Install Docker
echo "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /mnt/rootfs/usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable" \
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

# Configure Docker daemon
mkdir -p /mnt/rootfs/etc/docker
printf '{\n  "storage-driver": "overlay2",\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "3"\n  },\n  "live-restore": true\n}\n' \
    > /mnt/rootfs/etc/docker/daemon.json

# Create user directories
mkdir -p /mnt/rootfs/home/sandbox/{.config,.cache,.docker}
chroot /mnt/rootfs chown -R 1000:1000 /home/sandbox

# Install guest init script
cp /scripts/guest-init.sh /mnt/rootfs/usr/local/bin/guest-init.sh
chmod +x /mnt/rootfs/usr/local/bin/guest-init.sh

# Create systemd service for guest init
printf '[Unit]\nDescription=Guest VM Initialization\nAfter=network-online.target docker.service\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/guest-init.sh\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /mnt/rootfs/etc/systemd/system/guest-init.service
chroot /mnt/rootfs systemctl enable guest-init.service

# Cleanup
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
    
    # Create minimal Dockerfile for final assembly
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

FROM alpine:3.19 AS kernel-download

RUN apk add --no-cache curl ca-certificates

ARG TARGETARCH
WORKDIR /kernel

RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
    curl -fsSL "https://storage.googleapis.com/fireactions/kernels/${ARCH}/5.10/vmlinux" \
    -o /kernel/vmlinux && \
    chmod 644 /kernel/vmlinux

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
COPY --from=kernel-download /kernel/vmlinux /var/lib/firecracker/kernel/vmlinux

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
main() {
    log_info "Building $IMAGE_NAME"
    echo ""
    
    # Check for existing rootfs to skip rebuild
    if [ -f "$BUILD_DIR/rootfs.ext4" ]; then
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
    
    build_image
    
    echo ""
    log_info "Build complete!"
    echo ""
    echo "Run with:"
    echo "  docker compose run --rm firecracker-base"
    echo ""
    echo "To rebuild rootfs from scratch:"
    echo "  rm -rf .build && ./build.sh"
}

main "$@"
