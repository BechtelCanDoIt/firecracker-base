# firecracker-base

Hardware-isolated container environment. Run Docker inside a Firecracker MicroVM for maximum security.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  HOST (Protected)                                                       │
│  ┌───────────────────────────────────────────────────────────────────┐ │
│  │  Docker Container (Alpine, ~50MB) - Firecracker VMM              │ │
│  │       ↓ hardware isolation (KVM)                                  │ │
│  │  ┌─────────────────────────────────────────────────────────────┐ │ │
│  │  │  MicroVM (separate kernel, isolated memory)                 │ │ │
│  │  │  └── Ubuntu 24.04 + Docker Engine                          │ │ │
│  │  │       ├── Container A ──┐                                   │ │ │
│  │  │       ├── Container B ──┼── Your workloads                 │ │ │
│  │  │       └── Container C ──┘                                   │ │ │
│  │  │                                                              │ │ │
│  │  │  /workspace ← mounted from host                             │ │ │
│  │  └─────────────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Why This Architecture?

| Threat | Standard Docker | Docker in Firecracker VM |
|--------|-----------------|--------------------------|
| Container escape | ⚠️ Host compromised | ✅ Still inside VM |
| Kernel exploit | ⚠️ Host kernel affected | ✅ Only guest kernel |
| Memory side-channel | ⚠️ Shared host memory | ✅ Hardware isolation |
| Network stack access | ⚠️ Shared host network | ✅ Isolated TAP/virtio |
| Rogue AI agent | ⚠️ Direct host access | ✅ VM barrier |

## Requirements

- Linux host with KVM (`/dev/kvm`)
- Docker

```bash
# Check KVM support
ls -la /dev/kvm
egrep -c '(vmx|svm)' /proc/cpuinfo  # Should be > 0

# If /dev/kvm missing, see TURNONKVM.md
```

## Quick Start

```bash
# Build (first time takes ~15-20 min - downloads Docker, Go, Node)
docker compose build

# Run
docker compose run --rm firecracker-base

# Inside VM - you have full Docker!
docker run hello-world
docker compose up -d
docker build -t myapp .
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FC_VCPU` | 4 | Number of vCPUs for VM |
| `FC_MEM` | 4096 | Memory in MB |
| `FC_WORKSPACE_SIZE` | 4096 | Workspace volume size (MB) |
| `FC_LOG_LEVEL` | Warning | Firecracker log level |

### Resource Recommendations

| Workload | vCPUs | Memory | Example |
|----------|-------|--------|---------|
| Light (single container) | 2 | 2048 | Simple API |
| Medium (few containers) | 4 | 4096 | App + DB |
| Heavy (docker compose) | 8 | 8192 | Full stack |

```bash
# Run with more resources
docker run --rm -it \
  --device /dev/kvm \
  --cap-add NET_ADMIN \
  -e FC_VCPU=8 -e FC_MEM=8192 \
  -v $(pwd)/workspace:/workspace \
  firecracker-base:latest
```

## Workspace

Your host directory is mounted at `/workspace` inside the VM:

```bash
docker run --rm -it \
  --device /dev/kvm \
  --cap-add NET_ADMIN \
  -v /path/to/your/project:/workspace \
  firecracker-base:latest

# Inside VM:
cd /workspace
docker compose up
```

## What's Included in the VM

- **Docker Engine** with Docker Compose
- **Git**, vim, curl, htop, jq
- **Minimal Ubuntu 24.04** base

Need more tools? Install via `apt` or use Docker containers:
```bash
# Inside VM
sudo apt-get update && sudo apt-get install -y python3 nodejs golang

# Or use Docker
docker run -it python:3.12 python
docker run -it node:20 node
```

## Security Model

```
Attack Path Analysis:

Rogue Container → Docker Daemon → Guest Kernel → [HARDWARE BARRIER] → Host
                                                         ↑
                                              Intel VT-x/AMD-V + EPT/NPT
                                              Firecracker VMM (~50k LoC Rust)
```

| Layer | Protection |
|-------|------------|
| Container → Guest OS | Standard Docker isolation |
| Guest OS → Host | **Hardware VM isolation (KVM)** |
| VMM (Firecracker) | Minimal Rust codebase, seccomp-filtered |
| Network | Separate TAP device, NAT'd |

Even if a container escapes Docker, it's still trapped inside the VM.

## Persistence

| What | Persists? | Location |
|------|-----------|----------|
| `/workspace` | ✅ Yes | Mounted from host |
| Docker images | ❌ No | Lost on VM restart |
| Container data | ❌ No | Lost on VM restart |
| VM rootfs changes | ❌ No | Read from image |

To persist Docker images, use a registry or rebuild from Dockerfiles in `/workspace`.

## Networking

| Address | Description |
|---------|-------------|
| 172.16.0.1 | Host gateway (TAP) |
| 172.16.0.2 | VM (eth0) |

The VM has internet access via NAT. Containers inside the VM use Docker's default bridge network.

## Building Custom Images

You can extend the base to add your own tools:

```dockerfile
FROM firecracker-base:latest

# The guest rootfs is at /var/lib/firecracker/rootfs/base.ext4
# You'd need to mount and modify it, or build a custom rootfs

# For most cases, just install tools via Docker inside the VM
```

Or install tools at runtime inside the VM:
```bash
# Inside VM
sudo apt-get update
sudo apt-get install -y your-package
```

## Troubleshooting

### "KVM not available"
```bash
# Load KVM module
sudo modprobe kvm
sudo modprobe kvm_intel  # or kvm_amd

# See TURNONKVM.md for details
```

### "Docker not starting in VM"
```bash
# Check Docker status
sudo systemctl status docker

# View logs
sudo journalctl -u docker
```

### "Out of disk space in VM"
The rootfs is ~8GB. For heavy Docker usage:
```bash
# Prune unused images/containers
docker system prune -a
```

## Files

```
firecracker-base/
├── Dockerfile           # Multi-stage: Firecracker + kernel + rootfs w/ Docker
├── docker-compose.yml   # Run configuration
├── scripts/
│   ├── entrypoint.sh    # VMM startup
│   ├── setup-network.sh # TAP/NAT setup
│   ├── create-workspace-image.sh
│   └── guest-init.sh    # Runs inside VM at boot
├── config/
│   └── firecracker.json.template
├── TURNONKVM.md         # KVM troubleshooting
└── workspace/           # Default mount point
```

## Performance

| Metric | Value |
|--------|-------|
| VM boot time | ~1-2 seconds |
| Memory overhead | ~5MB (VMM) |
| Nested Docker overhead | ~5-10% |
| Image size | ~4GB (includes Docker) |

## License

MIT
