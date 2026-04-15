#!/usr/bin/env bash
# cluster-up.sh — Fast multi-node Flynn cluster provisioning using qcow2 clones.
#
# Strategy:
#   1. Build node1 via Vagrant (full DKMS/ZFS build, ~7 min)
#   2. Shut node1 down and snapshot its system disk
#   3. Create nodes 2..N as qcow2 backing-file clones (instant)
#   4. Boot all nodes and re-provision each (hostname/IP fix, ~30s each)
#   5. Run bootstrap on the last node
#
# Usage:
#   ./cluster-up.sh              # 5 nodes (default)
#   ./cluster-up.sh 3            # 3 nodes
#   NUM_NODES=5 ./cluster-up.sh  # via env var
#
# Requirements:
#   - vagrant, vagrant-libvirt plugin
#   - virsh, qemu-img
#   - debian13-amd64 Vagrant box added
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

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;32m===> $(date +%H:%M:%S) $*\033[0m"; }
warn()  { echo -e "\033[1;33mWARN: $*\033[0m"; }
fail()  { echo -e "\033[1;31mFAIL: $*\033[0m" >&2; exit 1; }

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
        if ssh $SSH_OPTS vagrant@"$ip" "curl -sf http://localhost:1113/host/status" &>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

node_ip() { echo "${PRIVATE_SUBNET}.$((NODE_IP_START + $1 - 1))"; }
node_mac_mgmt() { printf "52:54:00:FE:00:%02X" "$1"; }
node_mac_data() { printf "52:54:00:FD:00:%02X" "$1"; }
vm_name() { echo "flynn-node$1"; }

# ── Validation ───────────────────────────────────────────────────────────────
if [[ "$NUM_NODES" -eq 2 ]]; then
    fail "Flynn rejects --min-hosts=2. Use 1 (singleton) or 3+ nodes."
fi
if [[ ! -f "$VAGRANT_KEY" ]]; then
    fail "Vagrant insecure key not found at $VAGRANT_KEY"
fi
command -v virsh   >/dev/null || fail "virsh not found"
command -v qemu-img >/dev/null || fail "qemu-img not found"
command -v vagrant >/dev/null || fail "vagrant not found"

# ── Cleanup ──────────────────────────────────────────────────────────────────
info "Cleaning up existing VMs..."
for i in $(seq 1 "$NUM_NODES"); do
    vm="$(vm_name "$i")"
    virsh destroy "$vm" 2>/dev/null || true
    virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
done
# Also clean any old vagrant VMs
for vm in vagrant_node1 vagrant_node2 vagrant_node3 vagrant_node4 vagrant_node5; do
    virsh destroy "$vm" 2>/dev/null || true
    virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
done
rm -rf "$SCRIPT_DIR/.vagrant"

# Ensure networks exist
if ! virsh net-info "$MGMT_NET" &>/dev/null; then
    fail "Management network '$MGMT_NET' not found. Run 'vagrant up' once to create it."
fi
virsh net-destroy "$MGMT_NET" 2>/dev/null || true
virsh net-start "$MGMT_NET" 2>/dev/null || true

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
# Phase 1: Build the golden node1 via Vagrant
# ═══════════════════════════════════════════════════════════════════════════
info "Phase 1: Building golden node1 via Vagrant (DKMS build, ~7 min)..."

# Use Vagrant only for node1 — it handles box image extraction, DKMS build etc.
# Run in a subshell so the NUM_NODES override doesn't leak to the rest of the script.
(
    export NUM_NODES=1
    export AUTO_BOOTSTRAP=false
    export LOCAL_FLYNN_HOST
    vagrant up node1 2>&1
) | while IFS= read -r line; do
    # Show progress lines
    case "$line" in
        *"==>"*|*"Provisioning"*|*"ready on"*|*"DKMS"*|*"Building"*|*"Starting"*|*"Error"*|*"fail"*)
            echo "  $line" ;;
    esac
done

# Verify node1 is working
NODE1_IP="$(node_ip 1)"
info "Verifying node1 at $NODE1_IP..."
if ! wait_for_flynn "$NODE1_IP" 10; then
    # Re-provision in case vagrant up returned early
    ( export NUM_NODES=1; export AUTO_BOOTSTRAP=false; vagrant provision node1 2>&1 | tail -5 )
    wait_for_flynn "$NODE1_IP" 15 || fail "node1 flynn-host not responding at $NODE1_IP"
fi
info "node1 is running at $NODE1_IP"

if [[ "$NUM_NODES" -eq 1 ]]; then
    info "Single-node cluster — skipping clone phase."
    if [[ "$AUTO_BOOTSTRAP" == "true" ]]; then
        info "Bootstrapping single-node cluster..."
        ssh $SSH_OPTS vagrant@"$NODE1_IP" "sudo CLUSTER_DOMAIN=$CLUSTER_DOMAIN flynn-host bootstrap --min-hosts=1 --peer-ips=$NODE1_IP --timeout=600 2>&1" | tail -20
    fi
    info "Done!"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Clone node1 for nodes 2..N
# ═══════════════════════════════════════════════════════════════════════════
info "Phase 2: Preparing node1 for cloning..."

# Stop flynn-host and export ZFS pool on node1 before shutdown.
# The pool is exported cleanly so clones can import it with a new GUID.
# Both vda (system) and vdb (ZFS pool) will be used as qcow2 backing files.
NODE1_IP="$(node_ip 1)"
ssh $SSH_OPTS vagrant@"$NODE1_IP" "sudo bash -s" <<'PREPARE_CLONE'
    systemctl stop flynn-host 2>/dev/null || true
    zpool export flynn-default 2>/dev/null || true
    # Remove ZFS cache so clones don't try to import node1's pool
    rm -f /etc/zfs/zpool.cache
    sync
PREPARE_CLONE

info "Shutting down node1 for cloning..."

# Get the vagrant node1 VM name and its disk paths
VAGRANT_VM=$(virsh list --all --name | grep -E "vagrant.*node1|node1" | head -1)
if [[ -z "$VAGRANT_VM" ]]; then
    fail "Cannot find Vagrant node1 VM"
fi

# Graceful shutdown
virsh shutdown "$VAGRANT_VM" 2>/dev/null || true
for i in $(seq 1 30); do
    if virsh domstate "$VAGRANT_VM" 2>/dev/null | grep -q "shut off"; then
        break
    fi
    sleep 2
done
if ! virsh domstate "$VAGRANT_VM" 2>/dev/null | grep -q "shut off"; then
    virsh destroy "$VAGRANT_VM" 2>/dev/null || true
    sleep 2
fi

# Find node1's disk paths
NODE1_VDA=$(virsh domblklist "$VAGRANT_VM" | awk '/vda/ {print $2}')
NODE1_VDB=$(virsh domblklist "$VAGRANT_VM" | awk '/vdb/ {print $2}')
info "Node1 disks: vda=$NODE1_VDA  vdb=$NODE1_VDB"

# Create backing-file clones for nodes 2..N
info "Creating qcow2 clones for nodes 2..$NUM_NODES..."
for i in $(seq 2 "$NUM_NODES"); do
    vm="$(vm_name "$i")"
    ip="$(node_ip "$i")"
    mac_mgmt="$(node_mac_mgmt "$i")"
    mac_data="$(node_mac_data "$i")"
    vda_clone="${LIBVIRT_IMAGES}/${vm}.qcow2"
    vdb_clone="${LIBVIRT_IMAGES}/${vm}-vdb.qcow2"

    info "  Creating clone for $vm ($ip)..."

    # Create system disk as a qcow2 overlay on node1's disk
    qemu-img create -f qcow2 -b "$NODE1_VDA" -F qcow2 "$vda_clone"
    # Clone the ZFS pool disk too (has all Flynn component images already).
    # Each clone gets a CoW overlay, so writes go to the overlay only.
    qemu-img create -f qcow2 -b "$NODE1_VDB" -F qcow2 "$vdb_clone"

    # Define the VM via XML
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
    info "  $vm defined"
done

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Boot all nodes and re-provision
# ═══════════════════════════════════════════════════════════════════════════
info "Phase 3: Booting all nodes..."

# Start node1 (Vagrant VM)
virsh start "$VAGRANT_VM"

# Start clone nodes one at a time so DHCP doesn't get overwhelmed
for i in $(seq 2 "$NUM_NODES"); do
    virsh start "$(vm_name "$i")"
    sleep 3  # let DHCP settle
done

# Wait for node1 to be ready
NODE1_IP="$(node_ip 1)"
info "Waiting for node1 at $NODE1_IP..."
wait_for_ssh "$NODE1_IP" 60 || fail "node1 not reachable at $NODE1_IP"
info "  node1 SSH OK"

# Re-import ZFS pool and restart flynn-host on node1 (we exported it before cloning)
info "  Restoring node1 ZFS pool and flynn-host..."
ssh $SSH_OPTS vagrant@"$NODE1_IP" "sudo bash -s" <<'RESTORE_NODE1'
    zpool import -f flynn-default 2>/dev/null || true
    systemctl start flynn-host
RESTORE_NODE1
wait_for_flynn "$NODE1_IP" 30 || warn "node1 flynn-host not responding after restore"

# Cloned nodes boot with node1's private IP, so we MUST reach them via the
# management network first to fix their identity.  Discover each clone's
# DHCP-assigned management IP from the libvirt lease database.
info "Re-provisioning cloned nodes via management network..."
for i in $(seq 2 "$NUM_NODES"); do
    vm="$(vm_name "$i")"
    target_ip="$(node_ip "$i")"
    hostname="node${i}"
    mac_mgmt="$(node_mac_mgmt "$i")"

    info "  Discovering management IP for $vm (MAC $mac_mgmt)..."
    mgmt_ip=""
    for attempt in $(seq 1 30); do
        mgmt_ip=$(virsh net-dhcp-leases "$MGMT_NET" 2>/dev/null \
            | grep -i "${mac_mgmt}" \
            | grep -oP '(\d+\.){3}\d+' | head -1)
        if [[ -n "$mgmt_ip" ]]; then
            break
        fi
        sleep 2
    done
    if [[ -z "$mgmt_ip" ]]; then
        warn "  Could not find DHCP lease for $vm — trying ARP scan..."
        # Ping sweep the management subnet to trigger ARP
        for probe in $(seq 100 130); do
            ping -c1 -W1 192.168.121.$probe &>/dev/null &
        done
        wait
        sleep 2
        mgmt_ip=$(virsh net-dhcp-leases "$MGMT_NET" 2>/dev/null \
            | grep -i "${mac_mgmt}" \
            | grep -oP '(\d+\.){3}\d+' | head -1)
    fi
    if [[ -z "$mgmt_ip" ]]; then
        warn "  SKIP: Cannot find management IP for $vm"
        continue
    fi
    info "  $vm management IP: $mgmt_ip"

    # Wait for SSH via management IP
    wait_for_ssh "$mgmt_ip" 60 || { warn "  $vm not SSH-reachable at $mgmt_ip"; continue; }

    info "  Re-provisioning $hostname ($mgmt_ip -> $target_ip)..."
    ssh $SSH_OPTS vagrant@"$mgmt_ip" "sudo bash -s" <<-REPROVISION
        set -e

        # Fix hostname
        hostnamectl set-hostname "$hostname"
        echo "$hostname" > /etc/hostname

        # Fix private network IP
        # Find the non-management interface
        PRIV_IFACE=""
        for iface in \$(ls /sys/class/net/ | grep -v lo | sort); do
            # Skip the management interface (has default route)
            if ip route show default | grep -q "dev \$iface"; then
                continue
            fi
            if [[ -d "/sys/class/net/\$iface" ]] && ip link show "\$iface" | grep -q "state UP"; then
                PRIV_IFACE="\$iface"
                break
            fi
        done
        PRIV_IFACE=\${PRIV_IFACE:-ens7}

        # Write correct networkd config
        rm -f /etc/systemd/network/10-\${PRIV_IFACE}.network \
              /etc/systemd/network/50-vagrant-\${PRIV_IFACE}.network 2>/dev/null
        cat > /etc/systemd/network/10-\${PRIV_IFACE}.network <<NETCFG
[Match]
Name=\${PRIV_IFACE}

[Network]
Address=${target_ip}/24
NETCFG

        # Flush and reassign IP
        ip addr flush dev "\$PRIV_IFACE" 2>/dev/null || true
        ip addr add "${target_ip}/24" dev "\$PRIV_IFACE" 2>/dev/null || true
        systemctl restart systemd-networkd 2>/dev/null || true

        # Fix /etc/resolv.conf if it's a stub-resolv symlink
        if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q "stub-resolv"; then
            ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        fi

        # Stop old flynn-host (has node1's config)
        systemctl stop flynn-host 2>/dev/null || true

        # Import the cloned ZFS pool.  The pool disk is a CoW clone of node1's
        # pool (same GUID), so we force-import and assign a new GUID.
        modprobe zfs 2>/dev/null || true
        # Destroy any auto-imported stale pool first
        zpool destroy flynn-default 2>/dev/null || true
        # Force-import from the device (ignoring cache, new GUID)
        if ! zpool import -f -d /dev/vdb flynn-default 2>/dev/null; then
            # If import fails (e.g. pool was exported), try without cache
            zpool import -f -d /dev flynn-default 2>/dev/null || \
            zpool import -f flynn-default 2>/dev/null || {
                # Last resort: create fresh pool and re-download
                echo "WARN: ZFS import failed, creating fresh pool"
                zpool create -f flynn-default /dev/vdb
                flynn-host download \
                    --repository "$FLYNN_REPO_URL" \
                    --tuf-db /etc/flynn/tuf.db \
                    --config-dir /etc/flynn \
                    --bin-dir /usr/local/bin 2>&1 | tail -3
            }
        fi
        # Regenerate the pool GUID so each node has a unique one
        zpool reguid flynn-default 2>/dev/null || true

        # Fix flynn-host systemd unit with correct IP
        sed -i "s|--external-ip=[0-9.]*|--external-ip=${target_ip}|" \
            /usr/lib/systemd/system/flynn-host.service
        # Remove any override
        rm -rf /etc/systemd/system/flynn-host.service.d
        systemctl daemon-reload

        # Start flynn-host
        systemctl start flynn-host

        echo "Re-provisioning complete for $hostname at ${target_ip}"
REPROVISION

    # Verify via the target private IP
    if wait_for_flynn "$target_ip" 15; then
        info "  $hostname: flynn-host is ready at $target_ip"
    else
        warn "  $hostname: flynn-host not responding at $target_ip"
    fi
done

# Verify node1 is still good
if wait_for_flynn "$NODE1_IP" 10; then
    info "node1: flynn-host is ready at $NODE1_IP"
else
    warn "node1: flynn-host not responding at $NODE1_IP — re-provisioning..."
    ( export NUM_NODES=1; export AUTO_BOOTSTRAP=false; vagrant provision node1 2>&1 | tail -5 )
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Bootstrap
# ═══════════════════════════════════════════════════════════════════════════
ALL_IPS=""
for i in $(seq 1 "$NUM_NODES"); do
    [[ -n "$ALL_IPS" ]] && ALL_IPS+=","
    ALL_IPS+="$(node_ip "$i")"
done

info "All peer IPs: $ALL_IPS"

# Final verification
info "Final verification of all nodes..."
all_ok=true
for i in $(seq 1 "$NUM_NODES"); do
    ip="$(node_ip "$i")"
    if curl -sf "http://${ip}:1113/host/status" >/dev/null 2>&1; then
        hn=$(ssh $SSH_OPTS vagrant@"$ip" "hostname" 2>/dev/null)
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
    ssh $SSH_OPTS vagrant@"$BOOTSTRAP_IP" "sudo CLUSTER_DOMAIN=$CLUSTER_DOMAIN flynn-host bootstrap --min-hosts=$NUM_NODES --peer-ips=$ALL_IPS --timeout=600 2>&1" | tee /dev/stderr | tail -5

    info "Bootstrap complete!"
    info "  Cluster domain: $CLUSTER_DOMAIN"
    info "  Dashboard:      https://dashboard.$CLUSTER_DOMAIN"
else
    info "Skipping bootstrap (AUTO_BOOTSTRAP=false)"
    info "To bootstrap manually:"
    info "  ssh vagrant@$(node_ip "$NUM_NODES") 'sudo CLUSTER_DOMAIN=$CLUSTER_DOMAIN flynn-host bootstrap --min-hosts=$NUM_NODES --peer-ips=$ALL_IPS --timeout=600'"
fi

info "Done! $NUM_NODES-node Flynn cluster is ready."
