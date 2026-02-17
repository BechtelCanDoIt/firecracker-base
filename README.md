# Firecracker-Base: Hardware-Isolated Docker Environment

Run Docker containers inside a Firecracker MicroVM for maximum security isolation.

```
┌─────────────────────────────────────────────────────────────┐
│  Host System                                                │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Docker Container (firecracker-base KVM)              │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Firecracker MicroVM (separe kernel/memory)     │  │  │
│  │  │  ┌───────────────────────────────────────────┐  │  │  │
│  │  │  │  Docker Engine                            │  │  │  │
│  │  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐      │  │  │  │
│  │  │  │  │Container│ │Container│ │Container│      │  │  │  │
│  │  │  │  └─────────┘ └─────────┘ └─────────┘      │  │  │  │
│  │  │  │                                           │  │  │  │
│  │  │  │  /workspace ← mounted from host           │  │  │  │
│  │  │  └───────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Security Isolation

Your containers are protected from the host by:

- **Separate kernel**: Guest runs its own Linux kernel, not the host kernel
- **Hardware memory isolation**: Intel EPT / AMD NPT enforced by CPU
- **Minimal attack surface**: Firecracker VMM is ~50k lines of code
- **Complete containment**: Container escapes are contained within the VM

| Threat | Standard Docker | Docker in Firecracker VM |
|--------|-----------------|--------------------------|
| Container escape | ⚠️ Host compromised | ✅ Still inside VM |
| Kernel exploit | ⚠️ Host kernel affected | ✅ Only guest kernel |
| Memory side-channel | ⚠️ Shared host memory | ✅ Hardware isolation |
| Network stack access | ⚠️ Shared host network | ✅ Isolated TAP/virtio |
| Rogue AI agent | ⚠️ Direct host access | ✅ VM barrier |


## Quick Start

### Prerequisites

- Linux host with KVM enabled (`/dev/kvm` accessible)
- Docker installed on the host

### Build

```bash
# Build requires privileged mode for loop mounts
./build.sh
```

### Run

```bash
docker run --rm -it \
  --device /dev/kvm \
  --cap-add NET_ADMIN \
  -v /path/to/your/workspace:/workspace:rw \
  -e FC_VCPU=30 \
  -e FC_MEM=20000 \
  -e FC_WORKSPACE_SIZE=10000 \
  firecracker-base:latest
```

Inside the VM:
```bash
# Verify Docker is working
docker run hello-world

# Run your containers
docker compose up
cd /workspace && docker build .
```

## Light Configuration
This works but is sluggish. It also doesn't provide much for what you might install inside the microVM.

| Variable | Default | Description |
|----------|---------|-------------|
| FC_VCPU | 4 | Number of vCPUs |
| FC_MEM | 4096 | Memory in MB |
| FC_WORKSPACE_SIZE | 4096 | Workspace image size in MB |
| FC_LOG_LEVEL | Warning | Log level: Error, Warning, Info, Debug |

## Standard Default Configuration
| Variable | Default | Description |
|----------|---------|-------------|
| FC_VCPU | 30 | Number of vCPUs |
| FC_MEM | 20000 | Memory in MB |
| FC_WORKSPACE_SIZE | 10000 | Workspace image size in MB |
| FC_LOG_LEVEL | Warning | Log level: Error, Warning, Info, Debug |

## Troubleshooting

### Docker Not Starting

If Docker isn't running inside the VM, run the diagnostic script:

```bash
sudo diagnose-docker.sh
```

This will check:
- Kernel features (cgroups, namespaces, overlay fs)
- Netfilter/iptables support
- Network connectivity
- Docker service status

### Common Issues

#### "iptables: Protocol not supported"

This indicates the kernel is missing netfilter support. The kernel must be built with full netfilter configuration including:

- `CONFIG_NETFILTER=y`
- `CONFIG_NF_CONNTRACK=y`
- `CONFIG_NF_NAT=y`
- `CONFIG_IP_NF_IPTABLES=y`
- `CONFIG_IP_NF_NAT=y`
- `CONFIG_IP_NF_FILTER=y`
- And many more (see `config/kernel-firecracker-docker.config`)

**Solution**: Rebuild the image with the complete kernel config.

#### "Cannot connect to Docker daemon"

1. Check if Docker service started:
   ```bash
   sudo systemctl status docker
   ```

2. Check Docker logs:
   ```bash
   sudo journalctl -u docker
   # or
   sudo cat /var/log/dockerd.log
   ```

3. Try manually starting Docker:
   ```bash
   sudo systemctl start docker
   ```

#### Network Issues

If containers can't access the internet:

1. Verify the VM has network access:
   ```bash
   ping 8.8.8.8
   ping google.com
   ```

2. Check iptables rules:
   ```bash
   sudo iptables -t nat -L -n
   ```

3. Verify IP forwarding is enabled:
   ```bash
   cat /proc/sys/net/ipv4/ip_forward
   ```

### Kernel Requirements for Docker

Docker requires extensive kernel support. The `kernel-firecracker-docker.config` file includes:

**Namespaces** (container isolation):
- PID, NET, IPC, UTS, USER, CGROUP namespaces

**Control Groups** (resource management):
- Full cgroups v2 support
- Memory, CPU, PID, device controllers

**Filesystems**:
- Overlay filesystem (Docker's storage driver)
- EXT4, tmpfs, proc, sysfs

**Networking**:
- Bridge, veth, macvlan, vxlan
- Full netfilter/iptables stack
- NAT, masquerade, connection tracking

**Security**:
- Seccomp for syscall filtering
- AppArmor support

## Architecture

### Build Process

1. **kernel-build stage**: Compiles Linux kernel with Docker-compatible config
2. **rootfs-builder stage**: Creates Ubuntu rootfs with Docker installed
3. **runtime stage**: Minimal Alpine image with Firecracker VMM

### Runtime Flow

1. Host starts Docker container with firecracker-base
2. Container sets up TAP networking and NAT
3. Firecracker VMM starts MicroVM
4. MicroVM boots Ubuntu with Docker
5. Guest init script starts Docker daemon
6. User gets shell with full Docker access

### Files

```
firecracker-base/
├── build.sh                    # Build script (handles privileged mode)
├── docker-compose.yml          # Docker Compose configuration
├── Dockerfile                  # Multi-stage build definition
├── config/
│   ├── firecracker.json.template   # Firecracker VM config
│   └── kernel-firecracker-docker.config  # Kernel config for Docker
└── scripts/
    ├── entrypoint.sh           # Container entrypoint
    ├── setup-network.sh        # TAP/NAT network setup
    ├── create-workspace-image.sh   # Workspace ext4 creation
    ├── guest-init.sh           # VM initialization script
    └── diagnose-docker.sh      # Docker diagnostics
```

## Development

### Rebuilding the Kernel

If you need to modify the kernel config:

1. Edit `config/kernel-firecracker-docker.config`
2. Rebuild: `./build.sh --no-cache`

### Testing Changes

```bash
# Build and run interactively
./build.sh && \
docker run --rm -it \
  --device /dev/kvm \
  --cap-add NET_ADMIN \
  firecracker-base:latest
```

### Adding Packages to the VM

Modify the `debootstrap --include=...` line in the Dockerfile to add system packages, or install Docker packages in the Docker installation section.

## Security Considerations

- The VM is isolated from the host at the hardware level
- Docker inside the VM has full capabilities (within the VM)
- Network access is through NAT from the host container
- Workspace files are synced via ext4 image, not direct mount

## Note about MMDS 

- MMDS Enabled But Never Used
- File: config/firecracker.json.template (lines 38-41)
- MMDS V2 is configured on eth0 but no code populates the MMDS data store or configures the MMDS address (169.254.169.254). This is harmless but adds unnecessary complexity. If you plan to use MMDS for passing metadata to the guest (like cloud-init does), you'd need API calls to populate it.

## License

Apache 2.0
