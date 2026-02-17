## Troubleshooting

### Docker Not Starting In Guest zone

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
