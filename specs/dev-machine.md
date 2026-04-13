# Dev Machines

Two dedicated dev-machines are available for Flynn development: an x86_64 (amd64) Proxmox server and a native ARM64 workstation.

---

## Machine 1: x86_64 / amd64 (Proxmox)

### Access

```sh
ssh -i ~/.ssh/id_ed25519 root@192.168.168.87
```

| Parameter | Value |
|---|---|
| Hostname | *(Proxmox host)* |
| IP | `192.168.168.87` |
| User | `root` |
| SSH Key | `~/.ssh/id_ed25519` (Ed25519) |

### Hardware

| Component | Detail |
|---|---|
| CPU | 2x Intel Xeon E5-2680 v2 @ 2.80 GHz (10 cores / 20 threads each, 40 total) |
| RAM | 62 GB |
| Storage | 888 GB ZFS pool (`rpool`), ~846 GB available |
| Virtualization | VT-x with nested virtualization enabled (`kvm_intel.nested=Y`) |

### Software

| Software | Version |
|---|---|
| OS | Debian 13 (Trixie) |
| Kernel | 6.17.2-1-pve (Proxmox PVE kernel) |
| Docker | 29.4.0 |
| Go | 1.13.15 |
| QEMU | 10.0.8 |
| libvirt | 11.3.0 |
| Vagrant | 2.3.8.dev |

### Configuration Notes

- **AppArmor**: libvirt security driver set to `"none"` in `/etc/libvirt/qemu.conf` (required for cross-architecture QEMU VMs).
- **vagrant-libvirt network**: autostart enabled (`virsh net-autostart vagrant-libvirt`). Without this, dnsmasq may die between VM runs, causing silent DHCP failures.
- **Installed emulators**: `qemu-system-x86_64`, `qemu-system-aarch64`, `qemu-system-riscv64`
- **UEFI firmware**: `qemu-efi-aarch64` (AAVMF), `qemu-efi-riscv64` installed for cross-arch boot.
- **guestfish / virt-customize**: Used for cross-arch image customization (libguestfs-tools).

---

## Machine 2: ARM64 (NVIDIA GB10)

### Access

```sh
ssh root@192.168.168.113
```

| Parameter | Value |
|---|---|
| Hostname | `gx10-cb3c` |
| IP | `192.168.168.113` (wired), `192.168.168.112` (WiFi) |
| User | `root` |
| SSH Key | `~/.ssh/id_ed25519` (Ed25519) |

### Hardware

| Component | Detail |
|---|---|
| Platform | NVIDIA GB10 SuperWorkstation |
| CPU | ARM Cortex-X925, 10 cores / 10 threads (single socket), up to 3.9 GHz |
| GPU | NVIDIA GB10 (integrated) |
| RAM | 122 GB |
| Storage | 932 GB NVMe (`/dev/nvme0n1`), ~331 GB available |
| Virtualization | ARM KVM (`/dev/kvm` present) |

### Software

| Software | Version |
|---|---|
| OS | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | 6.17.0-1014-nvidia (NVIDIA ARM64 kernel) |
| Docker | 29.2.1 |
| Go | *not installed* |
| QEMU | qemu-system-arm (installed 2026-04-13) |
| libvirt | libvirt-daemon-system (installed 2026-04-13) |
| Vagrant | 2.4.9 (gem-based install; HashiCorp doesn't build Linux arm64 packages) |
| vagrant-libvirt | 0.12.2 (plugin) |
| Ruby | 3.2.3 |

### Configuration Notes

- **Native ARM64 KVM**: This machine provides hardware-accelerated KVM for ARM64 guests, eliminating the need for slow TCG emulation.
- **AppArmor**: libvirt security driver set to `"none"` in `/etc/libvirt/qemu.conf` (required for Vagrant VMs).
- **UEFI firmware**: `qemu-efi-aarch64` installed (`/usr/share/AAVMF/AAVMF_CODE.fd`). Required for arm64 VMs.
- **Vagrant (gem install)**: HashiCorp does not build Vagrant for Linux arm64. Installed via `gem install vagrant`. Requires `libarchive-tools` for `bsdtar`.
- **ARM64 VM requirements**: arm64 libvirt VMs need specific settings: `machine_type = "virt"`, `cpu_mode = "host-passthrough"` (NVIDIA GB10 CPU not in libvirt's host-model database), UEFI loader/nvram, `video_type = "virtio"`, and virtio keyboard input (no PS/2 on ARM).
- **Locale**: System locale is German (`de_DE`); command output may appear in German.

---

## Vagrant Boxes

### Custom Debian 13 Boxes

Built from official Debian 13 (Trixie) `generic` cloud images using `build-box.sh`. Source images from `https://cloud.debian.org/images/cloud/trixie/20260402-2435/`.

| Box | Arch | File (x86_64 machine) | Status |
|---|---|---|---|
| `debian13-amd64` | amd64 | `/root/vagrant-boxes/debian13-amd64.box` (413 MB) | **VERIFIED** - boots, SSH works, sudo works |
| `debian13-arm64` | arm64 | `/root/vagrant-boxes/debian13-arm64.box` (407 MB) | **VERIFIED** - tested natively on ARM64 machine with KVM |
| `debian13-riscv64` | riscv64 | `/root/vagrant-boxes/debian13-riscv64.box` (409 MB) | Built, untested (no native hardware) |

### Build Script

Located at `/root/vagrant-boxes/build-box.sh` on the x86_64 machine and `/tmp/build-box.sh` locally.

Key customizations applied to the cloud images:
- **vagrant user**: created with password `vagrant`, added to sudo group
- **SSH keys**: both Vagrant insecure RSA and ed25519 keys in `authorized_keys`
- **Passwordless sudo**: `/etc/sudoers.d/vagrant`
- **SSHD config**: PermitRootLogin, PubkeyAuthentication, PasswordAuthentication enabled via `/etc/ssh/sshd_config.d/99-vagrant.conf`
- **SSH host keys**: generated during build (native arch uses `ssh-keygen -A`; cross-arch generates on host and uploads)
- **Network**: systemd-networkd enabled with DHCP on `en*` and `eth*` interfaces via `/etc/systemd/network/50-dhcp.network`
- **Cloud-init disabled**: `/etc/cloud/cloud-init.disabled` prevents boot stalls waiting for metadata

The script has two code paths:
- **Native arch**: Uses `virt-customize --run-command` for full system-level operations
- **Cross-arch**: Uses `guestfish` for file-level operations only (can't execute cross-arch binaries)

### Vagrantfile Requirements

**amd64** (on x86_64 machine):
```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "debian13-amd64"
  config.ssh.insert_key = false
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
    libvirt.memory = 1024
    libvirt.cpus = 2
  end
end
```

**arm64** (on ARM64 machine):
```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "debian13-arm64"
  config.ssh.insert_key = false
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
    libvirt.memory = 1024
    libvirt.cpus = 2
    libvirt.loader = "/usr/share/AAVMF/AAVMF_CODE.fd"
    libvirt.nvram = "/usr/share/AAVMF/AAVMF_VARS.fd"
    libvirt.machine_type = "virt"
    libvirt.cpu_mode = "host-passthrough"
    libvirt.inputs = [{ bus: "virtio", type: "keyboard" }]
    libvirt.video_type = "virtio"
  end
end
```

### Host-Side Prerequisites

- **vagrant-libvirt network must have autostart enabled**: `virsh net-autostart vagrant-libvirt`. If dnsmasq for this network dies, guest DHCP will fail silently.
- **`config.ssh.insert_key = false`**: Required. Vagrant's key replacement after initial SSH causes `Connection reset` errors with these images.

### Community Boxes (x86_64 machine, for reference)

| Box | Arch | Status |
|---|---|---|
| `generic/ubuntu1804` (libvirt, 4.3.12) | amd64 | Works (KVM-accelerated, native x86_64) |
| `frederic_tronel/debian13-aarch64-qemu` (libvirt, 1.0) | arm64 | Boots via TCG, gets IP, but too slow for SSH within boot timeout |
| `APN-Pucky/ubuntu22.04-riscv64` (libvirt, 0.0.1) | riscv64 | Boots via TCG at 100% CPU, never reaches DHCP |

## Multi-Architecture Test Results (2026-04-13)

### Custom Debian 13 Box Results

- **amd64 on x86_64 (native KVM)**: `vagrant up` succeeds. VM boots in seconds, gets DHCP, SSH with Vagrant insecure key works, passwordless sudo confirmed. Rsync shared folders work.
- **arm64 on ARM64 (native KVM)**: `vagrant up` succeeds on NVIDIA GB10 machine. Requires UEFI firmware, `host-passthrough` CPU mode, virtio input/video, and `virt` machine type. VM boots quickly, full functionality confirmed.
- **riscv64**: Box built but untested. No native RISC-V hardware available. TCG emulation on x86_64 is not viable (community boxes failed to reach network init after 15+ minutes at 100% CPU).

### Cross-Architecture Emulation (community boxes, for reference)

Cross-arch emulation on x86_64 via QEMU TCG was tested with community boxes:
- **ARM64 (TCG)**: Boots but too slow for SSH timeout.
- **RISC-V 64 (TCG)**: Never reaches network initialization.
- **Conclusion**: TCG emulation is not practical. Use native hardware.

## Architecture / Machine Assignment

| Architecture | Machine | Acceleration | Status |
|---|---|---|---|
| amd64 | `192.168.168.87` (Proxmox/Xeon) | Native KVM | **Ready** - box verified |
| arm64 | `192.168.168.113` (NVIDIA GB10) | Native KVM | **Ready** - box verified |
| riscv64 | — | — | Deferred (no native hardware, TCG too slow) |

## Purpose

### x86_64 machine (`192.168.168.87`)
- Native Go builds (CGO-dependent components like `flynn-host`)
- amd64 Vagrant + libvirt VM testing (multi-node Flynn cluster bootstrap)
- ZFS testing (host has ZFS natively)

### ARM64 machine (`192.168.168.113`)
- Native ARM64 Vagrant + libvirt VM testing with KVM
- ARM64 Go builds (once Go is installed)
- GPU-accelerated workloads (NVIDIA GB10)
