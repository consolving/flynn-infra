#!/bin/bash
#
# Flynn node provisioning script for Ubuntu Noble (24.04 LTS)
#
# This script prepares an Ubuntu Noble VM to run flynn-host:
#   1. Verifies cgroups v2
#   2. Installs ZFS (native kernel module), iptables, and other dependencies
#   3. Creates a ZFS pool on /dev/vdb
#   4. Assigns the private network IP to the cluster interface
#   5. Downloads and installs Flynn binaries from the TUF repository
#   6. Installs the flynn-host systemd unit
#
# Usage: provision.sh --node-ip IP --repo-url URL
#

set -eo pipefail

# --- Parse arguments ----------------------------------------------------------

NODE_IP=""
REPO_URL=""
LOCAL_BINARY=""
PEER_IPS=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--node-ip)
		NODE_IP="$2"
		shift 2
		;;
	--repo-url)
		REPO_URL="$2"
		shift 2
		;;
	--local-binary)
		LOCAL_BINARY="$2"
		shift 2
		;;
	--peer-ips)
		PEER_IPS="$2"
		shift 2
		;;
	*)
		echo "Unknown argument: $1" >&2
		exit 1
		;;
	esac
done

if [[ -z "$NODE_IP" ]] || [[ -z "$REPO_URL" ]]; then
	echo "Usage: provision.sh --node-ip IP --repo-url URL [--local-binary PATH] [--peer-ips IP1,IP2,...]" >&2
	exit 1
fi

# --- Helpers ------------------------------------------------------------------

info() {
	echo -e "\e[1;32m===> $(date '+%H:%M:%S') $1\e[0m"
}

warn() {
	echo -e "\e[1;33m===> $(date '+%H:%M:%S') $1\e[0m"
}

fail() {
	echo -e "\e[1;31m===> $(date '+%H:%M:%S') ERROR: $1\e[0m" >&2
	exit 1
}

# --- Step 1: Verify cgroups ---------------------------------------------------

verify_cgroups() {
	info "Checking cgroups version..."

	if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
		local controllers
		controllers=$(cat /sys/fs/cgroup/cgroup.controllers)
		info "cgroups v2 unified mode — controllers: $controllers"

		for ctl in cpu memory pids; do
			if ! echo "$controllers" | grep -qw "$ctl"; then
				fail "Required cgroup v2 controller '$ctl' not available"
			fi
		done

		info "cgroups v2 OK — all required controllers available"
	elif [[ -d /sys/fs/cgroup/cpu ]]; then
		info "cgroups v1 legacy mode"
	else
		fail "Cannot determine cgroups version"
	fi
}

# --- Step 2: Install system packages ------------------------------------------

install_packages() {
	info "Updating package lists..."

	# Ensure universe repo is enabled (ZFS is in universe on Ubuntu)
	if ! apt-cache policy 2>/dev/null | grep -q "universe"; then
		info "Enabling universe repository..."
		apt-get install -y software-properties-common
		add-apt-repository -y universe
	fi

	apt-get update

	info "Installing dependencies..."
	DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
		apt-get install -y \
		iptables \
		curl \
		coreutils \
		e2fsprogs \
		squashfs-tools \
		zfsutils-linux

	# Ubuntu Noble ships ZFS as a prebuilt kernel module — no DKMS needed.
	info "Loading ZFS kernel module..."
	modprobe zfs || fail "ZFS module failed to load"
	info "ZFS module loaded: $(cat /sys/module/zfs/version 2>/dev/null || echo 'version unknown')"
}

# --- Step 3: OverlayFS check -------------------------------------------------

check_overlayfs() {
	info "Checking OverlayFS support..."

	if ! modprobe overlay; then
		fail "OverlayFS kernel module not available"
	fi

	if ! grep -q "overlay$" /proc/filesystems; then
		fail "OverlayFS not listed in /proc/filesystems"
	fi

	# Test multi-lower-dir support (required by Flynn)
	local dir
	dir="$(mktemp -d)"
	mkdir -p "$dir"/{lower1,lower2,upper,work,mnt}
	echo "1" >"$dir/lower1/1"
	echo "2" >"$dir/lower2/2"

	if ! mount -t overlay -o "lowerdir=$dir/lower2:$dir/lower1,upperdir=$dir/upper,workdir=$dir/work" overlay "$dir/mnt" 2>/dev/null; then
		rm -rf "$dir"
		fail "OverlayFS does not support multiple lower directories"
	fi

	local ok=true
	[[ -s "$dir/mnt/1" ]] && [[ -s "$dir/mnt/2" ]] || ok=false
	umount "$dir/mnt"
	rm -rf "$dir"

	if ! $ok; then
		fail "OverlayFS multi-lower test failed"
	fi

	info "OverlayFS OK"
}

# --- Step 4: Create ZFS pool -------------------------------------------------

setup_zfs() {
	if zpool list flynn-default &>/dev/null; then
		info "ZFS pool 'flynn-default' already exists"
		return 0
	fi

	if [[ ! -b /dev/vdb ]]; then
		fail "/dev/vdb not found — additional disk for ZFS pool is missing"
	fi

	info "Creating ZFS pool 'flynn-default' on /dev/vdb..."
	zpool create -f flynn-default /dev/vdb

	info "ZFS pool created:"
	zpool list flynn-default
}

# --- Step 5: Configure networking ---------------------------------------------

setup_networking() {
	info "Configuring node networking (IP: $NODE_IP)..."

	# Ensure IP forwarding is enabled (needed for flannel and container networking)
	sysctl -w net.ipv4.ip_forward=1 >/dev/null
	if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
		echo "net.ipv4.ip_forward=1" >>/etc/sysctl.conf
	fi

	# Ensure bridge-nf-call-iptables is available (for container networking)
	modprobe br_netfilter 2>/dev/null || true
	if [[ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
		sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
	fi

	# Disable netplan and use systemd-networkd directly.
	# Ubuntu Noble defaults to netplan, which can conflict with our static
	# IP assignments. We bypass it entirely.
	if command -v netplan &>/dev/null; then
		info "Disabling netplan in favor of direct systemd-networkd control..."
		# Remove netplan configs for the private interface to avoid conflicts
		rm -f /etc/netplan/50-vagrant*.yaml 2>/dev/null || true
	fi

	# Find the private network interface: second non-loopback interface
	local priv_iface=""
	for iface in $(ls /sys/class/net/ | grep -v lo | sort); do
		if ip route show default | grep -q "dev ${iface}"; then
			continue
		fi
		if [[ -d "/sys/class/net/${iface}" ]] && ip link show "${iface}" | grep -q "state UP"; then
			priv_iface="${iface}"
			break
		fi
	done

	if [[ -z "$priv_iface" ]]; then
		warn "Could not auto-detect private network interface, trying ens7..."
		priv_iface="ens7"
	fi

	# Remove all conflicting networkd configs for this interface and write
	# a single authoritative one.
	rm -f /etc/systemd/network/10-${priv_iface}.network \
	      /etc/systemd/network/50-vagrant-${priv_iface}.network
	cat > /etc/systemd/network/10-${priv_iface}.network <<-NETEOF
	[Match]
	Name=${priv_iface}

	[Network]
	Address=${NODE_IP}/24
	NETEOF

	# Flush any stale IPs and apply the correct one immediately
	info "Assigning ${NODE_IP}/24 to ${priv_iface}..."
	ip addr flush dev "${priv_iface}" 2>/dev/null || true
	ip addr add "${NODE_IP}/24" dev "${priv_iface}" 2>/dev/null || true
	systemctl restart systemd-networkd 2>/dev/null || true

	# Verify
	if ip addr show "${priv_iface}" | grep -q "inet ${NODE_IP}/"; then
		info "IP ${NODE_IP} assigned to ${priv_iface} OK"
	else
		fail "Failed to assign ${NODE_IP} to ${priv_iface}"
	fi

	# Fix DNS resolution for containers: Ubuntu Noble's /etc/resolv.conf may be
	# a symlink to systemd-resolved's stub resolver (127.0.0.53). flynn-host reads
	# /etc/resolv.conf to find upstream DNS servers for discoverd's recursor. But
	# 127.0.0.53 is on the host's loopback and unreachable from containers running
	# in separate network namespaces. Point /etc/resolv.conf at systemd-resolved's
	# upstream resolver list instead, which contains the real DNS server IPs.
	if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q "stub-resolv"; then
		info "Fixing /etc/resolv.conf: replacing stub-resolv.conf symlink with upstream resolver list"
		rm -f /etc/resolv.conf
		ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
	fi

	# Wait for DNS resolution to be available after the networkd restart and
	# resolv.conf swap above.
	info "Waiting for DNS resolution to become available..."
	local dns_attempts=0
	local dns_max=15
	while [[ $dns_attempts -lt $dns_max ]]; do
		if getent hosts github.io >/dev/null 2>&1; then
			info "DNS resolution OK"
			break
		fi
		dns_attempts=$((dns_attempts + 1))
		info "  DNS not ready yet (attempt ${dns_attempts}/${dns_max})..."
		sleep 2
	done
	if [[ $dns_attempts -ge $dns_max ]]; then
		warn "DNS resolution may not be working — continuing anyway"
	fi
}

# --- Step 6: Download and install Flynn ---------------------------------------

install_flynn() {
	if [[ -f /usr/local/bin/flynn-host ]]; then
		info "Flynn binaries already installed"
		return 0
	fi

	mkdir -p /etc/flynn /var/lib/flynn /var/log/flynn

	local bootstrap_binary=""

	if [[ -n "$LOCAL_BINARY" ]] && [[ -f "$LOCAL_BINARY" ]]; then
		info "Using local flynn-host binary: $LOCAL_BINARY"
		bootstrap_binary="$LOCAL_BINARY"
	else
		info "Downloading flynn-host binary..."
		local tmp
		tmp="$(mktemp -d)"

		if ! curl -fsSL -o "$tmp/flynn-host.gz" "${REPO_URL}/targets/flynn-host.gz"; then
			rm -rf "$tmp"
			fail "Failed to download flynn-host from ${REPO_URL}"
		fi

		gunzip "$tmp/flynn-host.gz"
		chmod +x "$tmp/flynn-host"
		bootstrap_binary="$tmp/flynn-host"
	fi

	info "Setting release channel to 'stable'..."
	echo "stable" >/etc/flynn/channel.txt

	info "Downloading Flynn components via flynn-host download..."
	"$bootstrap_binary" download \
		--repository "${REPO_URL}" \
		--tuf-db "/etc/flynn/tuf.db" \
		--config-dir "/etc/flynn" \
		--bin-dir "/usr/local/bin"

	# If using a local binary, replace the TUF-downloaded flynn-host with our patched version
	if [[ -n "$LOCAL_BINARY" ]] && [[ -f "$LOCAL_BINARY" ]]; then
		info "Replacing installed flynn-host with patched version..."
		cp "$LOCAL_BINARY" /usr/local/bin/flynn-host
		chmod +x /usr/local/bin/flynn-host
	fi

	info "Flynn components installed"
	flynn-host version

	# Clean up temp directory if we downloaded from TUF
	if [[ -n "${tmp:-}" ]]; then
		rm -rf "$tmp"
	fi
}

# --- Step 7: Install systemd unit ---------------------------------------------

install_systemd_unit() {
	local unit_file="/lib/systemd/system/flynn-host.service"

	if [[ -f "$unit_file" ]]; then
		info "flynn-host systemd unit already installed"
		return 0
	fi

	info "Installing flynn-host systemd unit..."

	local daemon_args="daemon --external-ip=${NODE_IP} --listen-ip=0.0.0.0"

	cat >"$unit_file" <<EOF
[Unit]
Description=Flynn host daemon
Documentation=https://flynn.io/docs
After=network-online.target zfs-mount.service
Wants=network-online.target
Requires=zfs-mount.service

[Service]
Type=simple
ExecStart=/usr/local/bin/flynn-host ${daemon_args}
Restart=on-failure
RestartSec=5

# Delegate cgroups to flynn-host so it can manage container cgroups
Delegate=yes

# Only kill the flynn-host process, not child containers
KillMode=process

# Containers use many file descriptors
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable flynn-host.service

	info "flynn-host service enabled (not started — bootstrap will start it)"
}

# --- Step 8: Start the daemon -------------------------------------------------

start_daemon() {
	info "Starting flynn-host daemon..."

	systemctl daemon-reload
	systemctl start flynn-host.service

	# Wait for the local API to be ready
	local max_attempts=30
	for attempt in $(seq 1 "$max_attempts"); do
		if curl -sf "http://${NODE_IP}:1113/host/status" >/dev/null 2>&1; then
			info "flynn-host API is ready on ${NODE_IP}"
			return 0
		fi
		info "  waiting for flynn-host API (attempt ${attempt}/${max_attempts})..."
		sleep 2
	done

	warn "flynn-host API did not become ready — dumping journal:"
	journalctl -u flynn-host --no-pager -n 50
	fail "flynn-host API did not become ready on ${NODE_IP}"
}

# --- Step 0: Ensure unique machine-id -----------------------------------------

ensure_unique_machine_id() {
	local current_id
	current_id=$(cat /etc/machine-id 2>/dev/null || true)

	if [[ -n "$current_id" ]]; then
		info "Current machine-id: $current_id"
		if [[ -f /etc/machine-id.flynn-regenerated ]]; then
			info "Machine-id already regenerated (marker exists), skipping"
			return 0
		fi
	fi

	info "Regenerating unique machine-id..."
	rm -f /etc/machine-id
	systemd-machine-id-setup
	touch /etc/machine-id.flynn-regenerated

	local new_id
	new_id=$(cat /etc/machine-id)
	info "New machine-id: $new_id"
}

# --- Main ---------------------------------------------------------------------

main() {
	info "Provisioning Flynn node (Ubuntu Noble 24.04)"
	info "  Node IP:   $NODE_IP"
	info "  Repo URL:  $REPO_URL"
	if [[ -n "$PEER_IPS" ]]; then
		info "  Peer IPs:  $PEER_IPS"
	fi
	info ""

	ensure_unique_machine_id
	verify_cgroups
	install_packages
	check_overlayfs
	setup_zfs
	setup_networking
	install_flynn
	install_systemd_unit
	start_daemon

	info ""
	info "Provisioning complete — flynn-host daemon is running on ${NODE_IP}"
}

main
