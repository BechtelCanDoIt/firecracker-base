# syntax=docker/dockerfile:1.4
# =============================================================================
# firecracker-base - Hardware-Isolated MicroVM with Docker
# =============================================================================
# Provides Firecracker MicroVM with Docker inside for maximum isolation.
# Run containers inside a hardware-isolated VM, protecting the host from:
#   - Kernel exploits (separate guest kernel)
#   - Container escapes (VM barrier, not just namespaces)
#   - Memory side-channels (hardware EPT/NPT isolation)
#
# Architecture:
#   Host → Firecracker VMM → MicroVM → Docker → Your Containers
#
# Build (requires privileged for loop mount):
#   ./build.sh
#
# Run:
#   docker run --rm -it \
#     --device /dev/kvm \
#     --cap-add NET_ADMIN \
#     -v /path/to/workspace:/workspace:rw \
#     -e FC_VCPU=4 -e FC_MEM=4096 \
#     firecracker-base:latest
#
#   # Inside VM:
#   docker run hello-world
#   docker compose up
# =============================================================================

ARG UBUNTU_VERSION=24.04

# =============================================================================
# Stage 1: Download Firecracker
# =============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS firecracker-download

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG FIRECRACKER_VERSION=v1.6.0
ARG TARGETARCH

WORKDIR /download

# Download Firecracker binary
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") && \
    curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/${FIRECRACKER_VERSION}/firecracker-${FIRECRACKER_VERSION}-${ARCH}.tgz" \
    -o firecracker.tgz && \
    tar -xzf firecracker.tgz && \
    mv release-${FIRECRACKER_VERSION}-${ARCH}/firecracker-${FIRECRACKER_VERSION}-${ARCH} /usr/local/bin/firecracker && \
    mv release-${FIRECRACKER_VERSION}-${ARCH}/jailer-${FIRECRACKER_VERSION}-${ARCH} /usr/local/bin/jailer && \
    chmod +x /usr/local/bin/firecracker /usr/local/bin/jailer

# =============================================================================
# Stage 2: Download Kernel
# =============================================================================
FROM alpine:3.19 AS kernel-download

RUN apk add --no-cache curl ca-certificates

ARG TARGETARCH
WORKDIR /kernel

# Download pre-built Firecracker-optimized kernel
# Using Fireactions project kernels (reliable hosting)
RUN ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "arm64" || echo "amd64") && \
    curl -fsSL "https://storage.googleapis.com/fireactions/kernels/${ARCH}/5.10/vmlinux" \
    -o /kernel/vmlinux && \
    chmod 644 /kernel/vmlinux

# =============================================================================
# Stage 3: Build vm-base rootfs with Docker
# =============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS rootfs-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    debootstrap \
    e2fsprogs \
    curl \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Rootfs size to accommodate Docker
ARG ROOTFS_SIZE_MB=8192

WORKDIR /rootfs-build

# Create ext4 image
RUN truncate -s ${ROOTFS_SIZE_MB}M rootfs.ext4 && \
    mkfs.ext4 -F rootfs.ext4

# Bootstrap minimal Ubuntu with packages for Docker
# NOTE: --security=insecure required for loop mount (use build.sh)
RUN --security=insecure mkdir -p /mnt/rootfs && \
    mount -o loop rootfs.ext4 /mnt/rootfs && \
    debootstrap --variant=minbase --include=\
systemd,systemd-sysv,\
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

# Configure the rootfs
RUN --security=insecure mount -o bind /dev /mnt/rootfs/dev && \
    mount -o bind /proc /mnt/rootfs/proc && \
    mount -o bind /sys /mnt/rootfs/sys && \
    # Set locale
    chroot /mnt/rootfs locale-gen en_US.UTF-8 && \
    # Set hostname
    echo "firecracker-vm" > /mnt/rootfs/etc/hostname && \
    # Configure networking for DHCP on eth0
    mkdir -p /mnt/rootfs/etc/systemd/network && \
    printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\n' > /mnt/rootfs/etc/systemd/network/20-eth0.network && \
    # Enable networkd
    chroot /mnt/rootfs systemctl enable systemd-networkd && \
    chroot /mnt/rootfs systemctl enable systemd-resolved && \
    # Create sandbox user
    chroot /mnt/rootfs useradd -m -s /bin/bash -u 1000 sandbox && \
    echo "sandbox ALL=(ALL) NOPASSWD: ALL" > /mnt/rootfs/etc/sudoers.d/sandbox && \
    chmod 0440 /mnt/rootfs/etc/sudoers.d/sandbox && \
    # Set root password (for emergency console access)
    echo 'root:firecracker' | chroot /mnt/rootfs chpasswd && \
    # Enable auto-login on serial console for sandbox user
    mkdir -p /mnt/rootfs/etc/systemd/system/serial-getty@ttyS0.service.d && \
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin sandbox --noclear %%I 115200 linux\n' \
        > /mnt/rootfs/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf && \
    # Configure fstab for workspace mount
    echo '/dev/vdb /workspace ext4 defaults,nofail 0 2' >> /mnt/rootfs/etc/fstab && \
    mkdir -p /mnt/rootfs/workspace && \
    chown 1000:1000 /mnt/rootfs/workspace

# Install Docker
RUN --security=insecure curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /mnt/rootfs/usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable" \
        > /mnt/rootfs/etc/apt/sources.list.d/docker.list && \
    chroot /mnt/rootfs apt-get update && \
    chroot /mnt/rootfs apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin && \
    # Add sandbox user to docker group
    chroot /mnt/rootfs usermod -aG docker sandbox && \
    # Enable Docker service
    chroot /mnt/rootfs systemctl enable docker && \
    chroot /mnt/rootfs systemctl enable containerd

# Configure Docker daemon for VM environment
RUN --security=insecure mkdir -p /mnt/rootfs/etc/docker && \
    printf '{\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "3"\n  },\n  "live-restore": true\n}\n' \
        > /mnt/rootfs/etc/docker/daemon.json

### host networking - add above
### "iptables": "false",\n  "ip-masq": "false",\n  "bridge": "none",\n


# Create user directories
RUN --security=insecure mkdir -p /mnt/rootfs/home/sandbox/{.config,.cache,.docker} && \
    chroot /mnt/rootfs chown -R 1000:1000 /home/sandbox

# Install guest init script
COPY scripts/guest-init.sh /tmp/guest-init.sh
RUN --security=insecure cp /tmp/guest-init.sh /mnt/rootfs/usr/local/bin/guest-init.sh && \
    chmod +x /mnt/rootfs/usr/local/bin/guest-init.sh

# Create systemd service for guest init
RUN --security=insecure printf '[Unit]\nDescription=Guest VM Initialization\nAfter=network-online.target docker.service\nWants=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/guest-init.sh\nRemainAfterExit=yes\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /mnt/rootfs/etc/systemd/system/guest-init.service && \
    chroot /mnt/rootfs systemctl enable guest-init.service

# Cleanup and unmount
RUN --security=insecure chroot /mnt/rootfs apt-get clean && \
    rm -rf /mnt/rootfs/var/lib/apt/lists/* && \
    rm -rf /mnt/rootfs/var/cache/apt/archives/* && \
    umount /mnt/rootfs/sys /mnt/rootfs/proc /mnt/rootfs/dev && \
    umount /mnt/rootfs

# =============================================================================
# Stage 4: Runtime Image (Alpine - minimal attack surface)
# =============================================================================
FROM alpine:3.19 AS runtime

LABEL maintainer="firecracker-base" \
      description="Hardware-isolated MicroVM with Docker" \
      version="2.0" \
      security.isolation="hardware" \
      base="alpine"

# Minimal packages for Firecracker VMM operation
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

# Copy Firecracker binaries
COPY --from=firecracker-download /usr/local/bin/firecracker /usr/local/bin/firecracker
COPY --from=firecracker-download /usr/local/bin/jailer /usr/local/bin/jailer

# Copy kernel
COPY --from=kernel-download /kernel/vmlinux /var/lib/firecracker/kernel/vmlinux

# Copy rootfs
COPY --from=rootfs-builder /rootfs-build/rootfs.ext4 /var/lib/firecracker/rootfs/base.ext4

# Copy scripts
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/setup-network.sh /usr/local/bin/setup-network.sh
COPY scripts/create-workspace-image.sh /usr/local/bin/create-workspace-image.sh
COPY config/firecracker.json.template /etc/firecracker/firecracker.json.template

RUN chmod +x /usr/local/bin/*.sh && \
    mkdir -p /var/lib/firecracker/{rootfs,kernel,workspace,run}

# Default configuration - sized for Docker workloads
ENV FC_VCPU=4 \
    FC_MEM=4096 \
    FC_ROOTFS=/var/lib/firecracker/rootfs/base.ext4 \
    FC_KERNEL=/var/lib/firecracker/kernel/vmlinux \
    FC_WORKSPACE_SIZE=4096 \
    FC_TAP_DEVICE=tap0 \
    FC_TAP_IP=172.16.0.1 \
    FC_VM_IP=172.16.0.2 \
    FC_LOG_LEVEL=Warning

# Volumes
VOLUME ["/workspace"]

# Expose serial console
EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
