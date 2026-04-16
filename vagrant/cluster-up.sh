#!/usr/bin/env bash
# cluster-up.sh — Fast multi-node Flynn cluster provisioning.
#
# Strategy:
#   1. Build node1 via Vagrant (full DKMS/ZFS build, ~7 min)
#   2. Create nodes 2..N as ZFS reflink clones of node1's disks (instant CoW)
#   3. Customize each clone offline via guestfish (hostname, IP, machine-id)
#   4. Boot all nodes — they come up with correct identity immediately
#   5. Wait for ZFS import + flynn-host on each node, then bootstrap
#
# Optimizations over the naive approach:
#   - ZFS reflink copies instead of qemu-img convert (~0.2s vs ~60s per disk)
#   - Offline guestfish customization instead of SSH re-provisioning (~3s vs ~90s)
#   - No node1 shutdown needed (reflink works on running VM's disk files)
#   - Parallel guestfish for all clones simultaneously
#   - No DHCP discovery — static IPs baked in before boot
#   - All clones boot in parallel
#
# Usage:
#   ./cluster-up.sh              # 5 nodes (default)
#   ./cluster-up.sh 3            # 3 nodes
#   NUM_NODES=5 ./cluster-up.sh  # via env var
#
# Requirements:
#   - vagrant, vagrant-libvirt plugin
#   - virsh, qemu-img, guestfish (libguestfs-tools)
#   - Host filesystem must be ZFS (for reflink/block-clone support)
#   - ubuntu-noble-amd64 Vagrant box added
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Configuration ────────────────────────────────────────────────────────────
NUM_NODES="${1:-${NUM_NODES:-5}}"
NODE_MEMORY="${NODE_MEMORY:-8192}"
NODE_CPUS="${NODE_CPUS:-4}"
NODE_DISK_SIZE="${NODE_DISK_SIZE:-40}"       # GB, ZFS pool disk
PRIVATE_SUBNET="192.168.50"
NODE_IP_START=11
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-demo.localflynn.com}"
FLYNN_REPO_URL="${FLYNN_REPO_URL:-https://consolving.github.io/flynn-tuf-repo/repository}"
AUTO_BOOTSTRAP="${AUTO_BOOTSTRAP:-true}"
LOCAL_FLYNN_HOST="${LOCAL_FLYNN_HOST:-}"

LIBVIRT_IMAGES="/var/lib/libvirt/images"
VAGRANT_KEY="${HOME}/.vagrant.d/insecure_private_key"
SSH_OPTS="-i $VAGRANT_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
MGMT_NET="vagrant-libvirt"
DATA_NET="flynn-cluster"

# Clone interface names differ from Vagrant's node1.
# Vagrant creates VMs with extra PCI slots, giving ens5/ens6/ens7.
# Raw libvirt XML gives sequential ens3 (mgmt), ens4 (data).
CLONE_DATA_IFACE="ens4"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;32m===> $(date +%H:%M:%S) $*\033[0m"; }
warn()  { echo -e "\033[1;33mWARN: $*\033[0m"; }
fail()  { echo -e "\033[1;31mFAIL: $*\033[0m" >&2; exit 1; }

elapsed() {
    local start="$1"
    local now
    now=$(date +%s)
    echo "$(( now - start ))s"
}

wait_for_ssh() {
    local ip="$1" max="${2:-60}"
    for attempt in $(seq 1 "$max"); do
        if ssh $SSH_OPTS vagrant@"$ip" "true" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_flynn() {
    local ip="$1" max="${2:-30}"
    for attempt in $(seq 1 "$max"); do
        if curl -sf "http://${ip}:1113/host/status" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

node_ip() { echo "${PRIVATE_SUBNET}.$((NODE_IP_START + $1 - 1))"; }
node_mac_mgmt() { printf "52:54:00:FE:00:%02X" "$1"; }
node_mac_data() { printf "52:54:00:FD:00:%02X" "$1"; }
vm_name() { echo "flynn_node$1"; }

# ── Validation ───────────────────────────────────────────────────────────────
[[ "$NUM_NODES" -eq 2 ]] && fail "Flynn rejects --min-hosts=2. Use 1 (singleton) or 3+ nodes."
[[ -f "$VAGRANT_KEY" ]]  || fail "Vagrant insecure key not found at $VAGRANT_KEY"
command -v virsh      >/dev/null || fail "virsh not found"
command -v qemu-img   >/dev/null || fail "qemu-img not found"
command -v vagrant    >/dev/null || fail "vagrant not found"
command -v guestfish  >/dev/null || fail "guestfish not found (apt install libguestfs-tools)"

# Verify host filesystem supports reflink (ZFS with block cloning)
if ! cp --reflink=always /dev/null "${LIBVIRT_IMAGES}/.reflink-test" 2>/dev/null; then
    warn "Reflink not supported on ${LIBVIRT_IMAGES} — falling back to full copies"
    USE_REFLINK=false
else
    rm -f "${LIBVIRT_IMAGES}/.reflink-test"
    USE_REFLINK=true
fi

TOTAL_START=$(date +%s)

# ── Cleanup ──────────────────────────────────────────────────────────────────
info "Cleaning up existing clone VMs..."
for i in $(seq 2 10); do
    vm="$(vm_name "$i")"
    virsh destroy "$vm" 2>/dev/null || true
    virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
done

# Ensure networks exist
if ! virsh net-info "$MGMT_NET" &>/dev/null; then
    fail "Management network '$MGMT_NET' not found. Run 'vagrant up' once to create it."
fi
if ! virsh net-info "$MGMT_NET" 2>/dev/null | grep -q "Active:.*yes"; then
    virsh net-start "$MGMT_NET" 2>/dev/null || true
fi

if ! virsh net-info "$DATA_NET" &>/dev/null; then
    info "Creating data network '$DATA_NET'..."
    virsh net-define /dev/stdin <<-NETXML
<network>
  <name>${DATA_NET}</name>
  <forward mode='nat'>
    <nat><port start='1024' end='65535'/></nat>
  </forward>
  <bridge name='virbr2' stp='on' delay='0'/>
  <ip address='${PRIVATE_SUBNET}.1' netmask='255.255.255.0'/>
</network>
NETXML
    virsh net-start "$DATA_NET"
fi
if ! virsh net-info "$DATA_NET" 2>/dev/null | grep -q "Active:.*yes"; then
    virsh net-start "$DATA_NET" 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Build or verify the golden node1 via Vagrant
# ═══════════════════════════════════════════════════════════════════════════

# Check if node1 already exists and is running
VAGRANT_VM=$(virsh list --all --name 2>/dev/null | grep -E "vagrant.*node1" | head -1 || true)
NODE1_IP="$(node_ip 1)"

if [[ -n "$VAGRANT_VM" ]] && wait_for_flynn "$NODE1_IP" 3; then
    info "Phase 1: node1 already running at $NODE1_IP — skipping Vagrant build"
else
    info "Phase 1: Building golden node1 via Vagrant (~3 min)..."
    PHASE1_START=$(date +%s)

    (
        export NUM_NODES=1
        export AUTO_BOOTSTRAP=false
        export LOCAL_FLYNN_HOST
        vagrant up node1 2>&1
    ) | while IFS= read -r line; do
        case "$line" in
            *"==>"*|*"Provisioning"*|*"ready on"*|*"DKMS"*|*"Building"*|*"Starting"*|*"Error"*|*"fail"*)
                echo "  $line" ;;
        esac
    done

    # Re-discover the VM name after vagrant up
    VAGRANT_VM=$(virsh list --all --name 2>/dev/null | grep -E "vagrant.*node1" | head -1 || true)
    [[ -z "$VAGRANT_VM" ]] && fail "Cannot find Vagrant node1 VM after 'vagrant up'"

    if ! wait_for_flynn "$NODE1_IP" 15; then
        ( export NUM_NODES=1; export AUTO_BOOTSTRAP=false; vagrant provision node1 2>&1 | tail -5 )
        wait_for_flynn "$NODE1_IP" 15 || fail "node1 flynn-host not responding at $NODE1_IP"
    fi
    info "Phase 1 complete: node1 ready at $NODE1_IP ($(elapsed $PHASE1_START))"
fi

if [[ "$NUM_NODES" -eq 1 ]]; then
    info "Single-node cluster — skipping clone phase."
    if [[ "$AUTO_BOOTSTRAP" == "true" ]]; then
        info "Bootstrapping single-node cluster..."
        ssh $SSH_OPTS vagrant@"$NODE1_IP" \
            "sudo CLUSTER_DOMAIN=$CLUSTER_DOMAIN flynn-host bootstrap --min-hosts=1 --peer-ips=$NODE1_IP --timeout=600 2>&1" | tail -20
    fi
    info "Done! (total $(elapsed $TOTAL_START))"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Create clones with reflink + offline guestfish customization
# ═══════════════════════════════════════════════════════════════════════════
PHASE2_START=$(date +%s)
info "Phase 2: Creating $((NUM_NODES - 1)) clones..."

# Find node1's disk paths (works whether VM is running or stopped)
NODE1_VDA=$(virsh domblklist "$VAGRANT_VM" 2>/dev/null | awk '/vda/ {print $2}')
NODE1_VDB=$(virsh domblklist "$VAGRANT_VM" 2>/dev/null | awk '/vdb/ {print $2}')
[[ -z "$NODE1_VDA" ]] && fail "Cannot find node1 vda disk"
[[ -z "$NODE1_VDB" ]] && fail "Cannot find node1 vdb disk"
info "  Node1 disks: vda=$NODE1_VDA  vdb=$NODE1_VDB"

# Read the flynn-host service file template from node1's disk.
# We modify the external-ip for each clone. Reading once avoids N guestfish
# invocations just to get the template.
info "  Reading flynn-host.service template from node1 disk..."
SVC_TEMPLATE=$(guestfish --ro -a "$NODE1_VDA" run : mount /dev/sda1 / \
    : cat /lib/systemd/system/flynn-host.service 2>/dev/null) \
    || fail "Cannot read flynn-host.service from node1 disk"

# Step 1: Create all disk copies
info "  Creating disk copies..."
COPY_START=$(date +%s)
for i in $(seq 2 "$NUM_NODES"); do
    vm="$(vm_name "$i")"
    vda_clone="${LIBVIRT_IMAGES}/${vm}.qcow2"
    vdb_clone="${LIBVIRT_IMAGES}/${vm}-vdb.qcow2"

    rm -f "$vda_clone" "$vdb_clone"

    if [[ "$USE_REFLINK" == "true" ]]; then
        cp --reflink=always "$NODE1_VDA" "$vda_clone"
        cp --reflink=always "$NODE1_VDB" "$vdb_clone"
    else
        # Full copy — slower but works on any filesystem.
        # Cannot use qcow2 backing-file overlays because QEMU 10+ uses
        # mandatory OFD file locking, which prevents multiple VMs from
        # sharing the same backing file.
        qemu-img convert -O qcow2 "$NODE1_VDA" "$vda_clone"
        qemu-img convert -O qcow2 "$NODE1_VDB" "$vdb_clone"
    fi
done
info "  Disk copies done ($(elapsed $COPY_START))"

# Step 2: Prepare per-node config files on the host (instant)
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

for i in $(seq 2 "$NUM_NODES"); do
    target_ip="$(node_ip "$i")"

    # Modified flynn-host.service with correct external-ip
    echo "$SVC_TEMPLATE" \
        | sed "s/--external-ip=[0-9.]*/--external-ip=${target_ip}/" \
        > "${WORK_DIR}/flynn-host-node${i}.service"

    # Networkd config for the data interface
    cat > "${WORK_DIR}/node${i}-network.conf" <<NETEOF
[Match]
Name=${CLONE_DATA_IFACE}

[Network]
Address=${target_ip}/24
NETEOF
done

# Step 3: Offline customization via guestfish (parallel)
info "  Customizing clone disks via guestfish (parallel)..."
GF_START=$(date +%s)
GF_PIDS=()
for i in $(seq 2 "$NUM_NODES"); do
    target_ip="$(node_ip "$i")"
    new_mid=$(uuidgen | tr -d '-')
    vda_clone="${LIBVIRT_IMAGES}/$(vm_name "$i").qcow2"

    (
        guestfish --rw -a "$vda_clone" <<GFEOF
run
mount /dev/sda1 /

# Identity
write /etc/hostname "node${i}\n"
write /etc/machine-id "${new_mid}\n"

# flynn-host with correct external-ip
upload ${WORK_DIR}/flynn-host-node${i}.service /lib/systemd/system/flynn-host.service

# Network: remove node1's ens7 config, add clone's ens4 config.
# The wildcard 50-dhcp.network handles ens3 (mgmt) via DHCP.
rm-f /etc/systemd/network/10-ens7.network
rm-f /etc/systemd/network/50-vagrant-ens7.network
rm-f /etc/systemd/network/10-ens5.network
rm-f /etc/systemd/network/10-ens6.network
upload ${WORK_DIR}/node${i}-network.conf /etc/systemd/network/10-${CLONE_DATA_IFACE}.network

# Sysctl: raise inotify limit for cgroups v2 OOM notifications
write /etc/sysctl.d/99-inotify.conf "fs.inotify.max_user_instances = 1024\n"

# Clean state: ensure clone boots fresh, not resuming node1's state
rm-f /etc/zfs/zpool.cache
rm-f /var/lib/flynn/host-state.bolt
rm-rf /var/lib/flynn/discoverd-data
rm-f /etc/flynn/resolv.conf

# The zfs-import-flynn.service (inherited from node1) handles
# force-importing the ZFS pool from /dev/vdb at boot time.
# It also deletes the file-based vdev that flynn-host would
# otherwise create, preventing pool GUID conflicts.
GFEOF
        echo "    node${i}: guestfish done"
    ) &
    GF_PIDS+=($!)
done

# Wait for all guestfish processes
gf_ok=true
for pid in "${GF_PIDS[@]}"; do
    if ! wait "$pid"; then
        gf_ok=false
    fi
done
[[ "$gf_ok" == "true" ]] || fail "One or more guestfish customizations failed"
info "  Guestfish done ($(elapsed $GF_START))"

# Step 4: Define VMs
info "  Defining VMs..."
for i in $(seq 2 "$NUM_NODES"); do
    vm="$(vm_name "$i")"
    mac_mgmt="$(node_mac_mgmt "$i")"
    mac_data="$(node_mac_data "$i")"
    vda_clone="${LIBVIRT_IMAGES}/${vm}.qcow2"
    vdb_clone="${LIBVIRT_IMAGES}/${vm}-vdb.qcow2"

    virsh define /dev/stdin <<-VMXML
<domain type='kvm'>
  <name>${vm}</name>
  <memory unit='MiB'>${NODE_MEMORY}</memory>
  <vcpu>${NODE_CPUS}</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/><pae/></features>
  <clock offset='utc'/>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${vda_clone}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${vdb_clone}'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
    <interface type='network'>
      <mac address='${mac_mgmt}'/>
      <source network='${MGMT_NET}'/>
      <model type='virtio'/>
    </interface>
    <interface type='network'>
      <mac address='${mac_data}'/>
      <source network='${DATA_NET}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <input type='mouse' bus='ps2'/>
    <graphics type='vnc' autoport='yes' listen='127.0.0.1'/>
  </devices>
</domain>
VMXML
done

info "Phase 2 complete: $((NUM_NODES - 1)) clones created and customized ($(elapsed $PHASE2_START))"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Boot all clones and wait for flynn-host
# ═══════════════════════════════════════════════════════════════════════════
PHASE3_START=$(date +%s)
info "Phase 3: Booting all clone nodes..."

# Start all clones simultaneously — no DHCP stagger needed since data IPs
# are baked in. Management IPs come via DHCP but we don't need to discover
# them; we connect via the data network.
for i in $(seq 2 "$NUM_NODES"); do
    virsh start "$(vm_name "$i")"
done

# Wait for all nodes to have flynn-host ready.
# On first boot after cloning, the sequence is:
#   1. systemd boots (~10s)
#   2. zfs-import-flynn.service force-imports pool from /dev/vdb (~2s)
#   3. flynn-host.service starts (~5s)
#   4. flynn-host API becomes available on port 1113
# Also need to reguid the ZFS pool (same GUID as node1's cloned pool).
info "Waiting for flynn-host on all nodes..."
ALL_OK=true
for i in $(seq 2 "$NUM_NODES"); do
    target_ip="$(node_ip "$i")"
    if wait_for_flynn "$target_ip" 60; then
        # Reguid the ZFS pool so each node has a unique GUID
        ssh $SSH_OPTS vagrant@"$target_ip" \
            "sudo zpool reguid flynn-default 2>/dev/null || true" &
        info "  node${i} ($target_ip): flynn-host ready"
    else
        warn "  node${i} ($target_ip): flynn-host NOT responding"
        ALL_OK=false
    fi
done
wait  # wait for background reguid commands

# Verify node1 is still good
if ! wait_for_flynn "$NODE1_IP" 5; then
    warn "node1 ($NODE1_IP): flynn-host not responding"
    ALL_OK=false
fi

info "Phase 3 complete ($(elapsed $PHASE3_START))"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Final verification and bootstrap
# ═══════════════════════════════════════════════════════════════════════════
ALL_IPS=""
for i in $(seq 1 "$NUM_NODES"); do
    [[ -n "$ALL_IPS" ]] && ALL_IPS+=","
    ALL_IPS+="$(node_ip "$i")"
done

info "Final verification of all nodes..."
all_ok=true
for i in $(seq 1 "$NUM_NODES"); do
    ip="$(node_ip "$i")"
    if curl -sf "http://${ip}:1113/host/status" >/dev/null 2>&1; then
        hn=$(ssh $SSH_OPTS vagrant@"$ip" "hostname" 2>/dev/null || echo "?")
        info "  $ip ($hn): flynn-host OK"
    else
        warn "  $ip: flynn-host NOT responding"
        all_ok=false
    fi
done

if [[ "$all_ok" != "true" ]]; then
    fail "Not all nodes are ready. Fix the issues above and re-run."
fi

if [[ "$AUTO_BOOTSTRAP" == "true" ]]; then
    BOOTSTRAP_IP="$(node_ip "$NUM_NODES")"
    info "Phase 4: Bootstrapping cluster from $BOOTSTRAP_IP..."
    ssh $SSH_OPTS vagrant@"$BOOTSTRAP_IP" \
        "sudo CLUSTER_DOMAIN=$CLUSTER_DOMAIN flynn-host bootstrap --min-hosts=$NUM_NODES --peer-ips=$ALL_IPS --timeout=600 2>&1" \
        | tee /dev/stderr | tail -5

    info "Bootstrap complete!"
    info "  Cluster domain: $CLUSTER_DOMAIN"
    info "  Dashboard:      https://dashboard.$CLUSTER_DOMAIN"
else
    info "Skipping bootstrap (AUTO_BOOTSTRAP=false)"
    info "To bootstrap manually:"
    info "  ssh vagrant@$(node_ip "$NUM_NODES") 'sudo CLUSTER_DOMAIN=$CLUSTER_DOMAIN flynn-host bootstrap --min-hosts=$NUM_NODES --peer-ips=$ALL_IPS --timeout=600'"
fi

info "Done! $NUM_NODES-node Flynn cluster is ready. (total $(elapsed $TOTAL_START))"
