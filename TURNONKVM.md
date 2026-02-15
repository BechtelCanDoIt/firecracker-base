# Turning on local KVM module
Chances are your KVM functionality is turned off by default.

## 1. Check if KVM modules are available
```
lsmod | grep kvm
```

## 2. Load the KVM modules (Intel CPU = kvm_intel, AMD = kvm_amd)
```
sudo modprobe kvm
sudo modprobe kvm_intel    # For Intel CPUs
```
OR
```
sudo modprobe kvm_amd      # For AMD CPUs
```

## 3. Verify /dev/kvm now exists
```
ls -la /dev/kvm
```

## 4. Check permissions (your user needs access)
### Option A: Add yourself to the kvm group
```
sudo usermod -aG kvm $USER
```

Then log out and back in, or:
```
newgrp kvm
```

### Option B: Or temporarily fix permissions
```
sudo chmod 666 /dev/kvm
```

---

## If `modprobe kvm_intel` fails, check if virtualization is disabled in BIOS/UEFI:
Check for error messages
```
dmesg | grep -i kvm
```

Common issues:
- "kvm: disabled by bios" → Enable VT-x/AMD-V in BIOS
- "kvm: already loaded" → Module loaded but /dev/kvm missing

## If you're running in a VM (nested virtualization), the hypervisor must enable it:
Check if you're in a VM
```
systemd-detect-virt
```

If it says vmware, virtualbox, kvm, etc. - you need nested virt enabled
```
VMware: VM Settings → CPU → "Virtualize Intel VT-x/EPT"
Proxmox/KVM: CPU type must be "host" and nested=1
```

## To make KVM load at boot:
Add to modules
```
echo "kvm" | sudo tee -a /etc/modules
echo "kvm_intel" | sudo tee -a /etc/modules  # or kvm_amd
```

Or create a conf file
```
echo -e "kvm\nkvm_intel" | sudo tee /etc/modules-load.d/kvm.conf
```
