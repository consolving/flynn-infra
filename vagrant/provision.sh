#!/bin/bash
#
# Flynn node provisioning script for Debian 13 (Trixie)
#
# This script prepares a Debian 13 VM to run flynn-host:
#   1. Verifies cgroups v2 (Debian 13 has v1 compiled out)
#   2. Installs ZFS, iptables, and other dependencies
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
	*)
		echo "Unknown argument: $1" >&2
		exit 1
		;;
	esac
done

if [[ -z "$NODE_IP" ]] || [[ -z "$REPO_URL" ]]; then
	echo "Usage: provision.sh --node-ip IP --repo-url URL [--local-binary PATH]" >&2
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
#
# Flynn has been patched to support both cgroups v1 and v2.
# Debian 13's kernel (6.12+) has CONFIG_MEMCG_V1=n / CONFIG_CPUSETS_V1=n,
# meaning cgroups v1 is compiled OUT — only v2 is available.
# We verify the required v2 controllers are present.

verify_cgroups() {
	info "Checking cgroups version..."

	if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
		local controllers
		controllers=$(cat /sys/fs/cgroup/cgroup.controllers)
		info "cgroups v2 unified mode — controllers: $controllers"

		# Verify essential controllers are available
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

	# Enable contrib and non-free repos (ZFS is in contrib)
	if ! grep -q "contrib" /etc/apt/sources.list.d/*.sources 2>/dev/null &&
		! grep -q "contrib" /etc/apt/sources.list 2>/dev/null; then
		info "Enabling contrib repository for ZFS..."
		# Debian 13 uses deb822 format in /etc/apt/sources.list.d/
		if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
			sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources
		elif [[ -f /etc/apt/sources.list ]]; then
			sed -i 's/main$/main contrib/' /etc/apt/sources.list
		fi
	fi

	apt-get update -qq

	info "Installing dependencies..."
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		iptables \
		zfsutils-linux \
		zfs-dkms \
		linux-headers-$(uname -r) \
		curl \
		coreutils \
		e2fsprogs \
		squashfs-tools \
		>/dev/null

	# Build and load ZFS kernel module (DKMS builds it from source)
	info "Loading ZFS kernel module..."
	if ! modprobe zfs 2>/dev/null; then
		info "Building ZFS module via DKMS (first time, may take a minute)..."
		dkms autoinstall 2>&1 | tail -5
		modprobe zfs || fail "ZFS module failed to load after DKMS build"
	fi
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

	# Assign NODE_IP to the private network interface.
	# Vagrant/libvirt creates the interface (ens7) but Debian 13's networkd
	# doesn't always assign the static IP configured in the Vagrantfile.
	# We detect the interface by finding the one that is UP but has no IPv4.
	if ip addr show | grep -q "inet ${NODE_IP}/"; then
		info "IP ${NODE_IP} already assigned"
		return 0
	fi

	# Find the private network interface: second non-loopback interface (ens7 or similar)
	local priv_iface=""
	for iface in $(ls /sys/class/net/ | grep -v lo | sort); do
		# Skip the management interface (the one with a DHCP lease / default route)
		if ip route show default | grep -q "dev ${iface}"; then
			continue
		fi
		# This is likely the private network interface
		if [[ -d "/sys/class/net/${iface}" ]] && ip link show "${iface}" | grep -q "state UP"; then
			priv_iface="${iface}"
			break
		fi
	done

	if [[ -z "$priv_iface" ]]; then
		warn "Could not auto-detect private network interface, trying ens7..."
		priv_iface="ens7"
	fi

	info "Assigning ${NODE_IP}/24 to ${priv_iface}..."
	ip addr add "${NODE_IP}/24" dev "${priv_iface}" 2>/dev/null || true

	# Verify
	if ip addr show "${priv_iface}" | grep -q "inet ${NODE_IP}/"; then
		info "IP ${NODE_IP} assigned to ${priv_iface} OK"
	else
		fail "Failed to assign ${NODE_IP} to ${priv_iface}"
	fi

	# Make it persistent via networkd drop-in (no restart needed — IP is already live)
	mkdir -p /etc/systemd/network
	cat >"/etc/systemd/network/10-${priv_iface}.network" <<EOF
[Match]
Name=${priv_iface}

[Network]
Address=${NODE_IP}/24
EOF
	# Reload (not restart) to pick up the drop-in without disrupting DNS
	networkctl reload 2>/dev/null || true
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
		# Use a locally-provided patched flynn-host binary
		info "Using local flynn-host binary: $LOCAL_BINARY"
		bootstrap_binary="$LOCAL_BINARY"
	else
		# Download flynn-host from TUF repo
		info "Downloading flynn-host binary..."
		local tmp
		tmp="$(mktemp -d)"
		trap "rm -rf $tmp" RETURN

		if ! curl -fsSL -o "$tmp/flynn-host.gz" "${REPO_URL}/targets/flynn-host.gz"; then
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
}

# --- Step 7: Install systemd unit ---------------------------------------------

install_systemd_unit() {
	local unit_file="/lib/systemd/system/flynn-host.service"

	if [[ -f "$unit_file" ]]; then
		info "flynn-host systemd unit already installed"
		return 0
	fi

	info "Installing flynn-host systemd unit..."

	# Determine daemon flags
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

# --- Main ---------------------------------------------------------------------

main() {
	info "Provisioning Flynn node"
	info "  Node IP:   $NODE_IP"
	info "  Repo URL:  $REPO_URL"
	info ""

	# Step 1: Verify cgroups
	verify_cgroups

	# Step 2: Install packages
	install_packages

	# Step 3: Check OverlayFS
	check_overlayfs

	# Step 4: Create ZFS pool
	setup_zfs

	# Step 5: Configure networking
	setup_networking

	# Step 6: Download and install Flynn
	install_flynn

	# Step 7: Install systemd unit
	install_systemd_unit

	info ""
	info "Provisioning complete!"
	info "  flynn-host is installed but NOT running."
	info "  The bootstrap provisioner will start it and run cluster bootstrap."
}

main
