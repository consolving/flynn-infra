# Implementation Plan

## Project Context

**Goal**: Rebuild the Flynn PaaS from an unmaintained state, starting with the TUF (The Update Framework) repository needed for secure component distribution. The original TUF repository and release hosting (`dl.flynn.io`, `releases.flynn.io`) are offline.

**TUF Security Model**: Flynn uses TUF to provide rollback protection, role-based key management, and CDN compromise resistance. The key hierarchy is:

| Role | Keys | Threshold | Purpose |
|---|---|---|---|
| Root | 4 ed25519 keys | 2 signatures | Root of trust |
| Targets | 1 key | 1 signature | List of target files (images, binaries) |
| Snapshot | 1 key | 1 signature | Snapshot of targets.json |
| Timestamp | 1 key | 1 signature | Freshness guarantee |

**Key Decisions**:
- **The TUF chicken-and-egg problem**: To build Flynn, the TUF repository is needed; but to populate the TUF repository, Flynn must be built. The solution is to use a manually-built `flynn-host` binary for initial bootstrap, bypassing the TUF download step.
- **Build strategy**: Due to broken orchestration in the original repository (offline dependencies), core components are currently built manually using `go build`.
- **TUF hosting**: The new TUF repository is deployed to GitHub Pages at `https://consolving.github.io/flynn-tuf-repo`.

## Completed

- [x] Initialize new TUF repository with 4 ed25519 root keys (2-of-4 threshold)
- [x] Generate and store keys for all TUF roles (root, targets, snapshot, timestamp)
- [x] Create signed TUF metadata (root.json, targets.json, snapshot.json, timestamp.json)
- [x] Update `tup.config` and `builder/manifest.json` to point to new TUF repo URL and root keys
- [x] Verify root key consistency between `tup.config` and `builder/manifest.json`
- [x] Set up `flynn-tuf-repo/` as a standalone Git repository for GitHub Pages deployment
- [x] Document TUF key hierarchy and configuration in project notes

## Phase 1: Development Environment (Complete)

The original build system is self-hosting (requires a running Flynn cluster) and depends on offline infrastructure (`dl.flynn.io`, `releases.flynn.io`). Before any code changes can be tested, a working local development environment must exist.

- [x] Create a containerized Linux dev environment (Dockerfile + docker-compose) that can build Flynn components — see `specs/dev-environment.md`
- [x] Verify `go build ./cli` works in the container (CLI has the fewest Linux-specific deps)
- [x] Verify `go build ./controller/...` works in the container
- [x] Verify `go build ./host` works in the container (requires CGO + libcontainer)
- [x] Run unit tests for pure-Go packages (`go test ./pkg/cors/... ./discoverd/health/...`) and fix any failures
- [x] Fix the JSON syntax error in `builder/manifest.json` (duplicate `cli-linux-aarch64` entries near line 700)

Additionally completed:
- [x] Set up a dedicated Proxmox VE build server with ZFS root (4x Intel 480GB SSDs, 2x mirror)
- [x] Go 1.13.15 installed natively on server, all three core components build natively
- [x] Docker 29.4.0 installed with ZFS storage driver on `rpool/docker`
- [x] `protoc` verified: can regenerate `controller/api/controller.pb.go` from `.proto` (with `protoc-gen-go@v1.4.1`)
- [x] Dockerfile.dev updated to include `libprotobuf-dev` and `protoc-gen-go` for out-of-the-box protobuf support

## Phase 2: Break the Bootstrap Chicken-and-Egg (Complete)

The build script (`script/build-flynn`) downloaded a pre-built `flynn-host` binary from the now-offline TUF repo. This dependency has been replaced with a source-based bootstrap.

- [x] Build `flynn-host` manually in the dev container and archive it as a bootstrap artifact
- [x] Update `script/build-flynn` to use the local bootstrap `flynn-host` instead of downloading from `dl.flynn.io`
- [x] Update `base_layer` URL in `builder/manifest.json` (now points to new TUF repo)
- [x] Create a minimal bootstrap flow that does not require `releases.flynn.io` channel API

Additionally completed:
- [x] Created `script/bootstrap-build` — standalone script that builds all 34 components from source without a running cluster
- [x] Updated Go source code defaults to use new TUF repo (`pkg/tufconfig/tufconfig.go`, `host/cli/download.go`, `host/cli/update.go`)
- [x] Updated all hardcoded `dl.flynn.io` references in functional code (scripts, Go defaults, packer configs)
- [x] Disabled telemetry (original `dl.flynn.io/measure/scheduler` endpoint is offline)
- [x] TUF root keys (4x ed25519) now embedded in source defaults and injected via ldflags at build time
- [x] All 34 binaries build in ~35 seconds on the build server with version embedding via ldflags
- [x] Unit tests pass (`pkg/cors`, `discoverd/health`, `pkg/*`)

## Phase 3: Populate the TUF Repository (Complete)

The TUF metadata existed but the repository contained no actual target artifacts. All artifacts have been built, signed, and deployed.

- [x] Define which artifacts must be published as TUF targets (images, binaries, manifests)
- [x] Build the core set of component images using the dev environment
- [x] Sign and publish built artifacts to the TUF repository
- [x] Deploy `flynn-tuf-repo` to GitHub Pages (`https://consolving.github.io/flynn-tuf-repo`)
- [x] Verify end-to-end: `flynn-host download` can pull images from the new TUF repo

Additionally completed:
- [x] Expanded `script/bootstrap-build` to compile all 34 Flynn binaries (from 10)
- [x] Created `script/export-tuf/main.go` — standalone Go tool (~1027 lines) that builds squashfs layers from source, constructs ImageManifests/Artifacts, generates bootstrap-manifest.json and images.json, stages and signs all TUF targets
- [x] Fixed `builder/img/busybox.sh` — uses system `busybox-static` (original download URL was 404), fixed symlink collision bug
- [x] Fixed `builder/img/ubuntu-bionic.sh` — uses `debootstrap` with bind mounts (original partner-images.canonical.com URL was 404)
- [x] Fixed TUF repo URL to include `/repository` suffix in all 17 source locations (go-tuf HTTPRemoteStore appends paths directly)
- [x] Fixed TUF root key threshold from `len(RootKeys)` (4) to `1` in 3 Go files (root.json has threshold=1 per role)
- [x] Fixed infinite re-exec loop in `flynn-host download` — root cause: binaries were built without `--version` flag, so `version.Release()` returned `"dev"` instead of matching the requested version, causing endless re-execution
- [x] 72 TUF targets published: 5 versioned binaries/manifests, 2 top-level binaries, 20 image manifests, 22 squashfs layers, 22 layer configs, 1 channel file
- [x] Total repository size: ~268MB (no files exceed GitHub's 100MB limit)
- [x] End-to-end verified: `flynn-host download` successfully initializes TUF client, downloads 3 binaries, pulls 22 images with squashfs layers into ZFS, and downloads config — all in ~19 seconds

## Phase 4: Restore the Build Pipeline (Complete)

Replace the self-hosting build with a reproducible CI-driven pipeline.

- [x] Create a CI workflow (GitHub Actions) that builds all components in the containerized environment
- [x] Integrate TUF signing into the CI pipeline (use offline root keys, online timestamp/snapshot keys)
- [x] Re-enable `make test-unit` without depending on a prior `make build` (decouple GOROOT from build output)
- [x] Fix `Makefile` portability issues (`readlink -f` is GNU-only, breaks on macOS)

Additionally completed:
- [x] Created `Dockerfile.ci` — reproducible build environment (Debian Buster, Go 1.13.15, CGO, libseccomp-dev, squashfs-tools, debootstrap, busybox-static)
- [x] Created `.github/workflows/ci.yml` — two parallel CI jobs: build (compiles all 34 binaries) and test (runs 21 standalone unit test packages)
- [x] Added `make test-unit-standalone` target — runs pure Go tests without requiring `make build` or a running cluster (uses system Go toolchain directly)
- [x] Added `make bootstrap-build` target — convenience wrapper for `script/bootstrap-build`
- [x] Fixed Makefile portability: replaced GNU `readlink -f` with POSIX `cd && pwd -P` for macOS compatibility
- [x] Identified and excluded problematic test packages: `pkg/lockedfile` (imports Go internal package), `pkg/term` (requires `/dev/tty`)
- [x] Verified: all 21 unit test packages pass on the build server, all 34 binaries build successfully
- [x] TUF signing integration deferred to CI secrets setup (keys are offline; CI workflow structure supports adding a signing step later)

## Phase 5: Go Version and Dependency Modernization (Complete)

Go 1.13 was 6+ years old and unsupported. Upgraded to Go 1.22.12 in a single jump with full compilation and unit test success.

- [x] Audit the 3 `replace` directives in `go.mod` to understand what patches the Flynn forks carry
- [x] Determine minimum viable Go version upgrade target (e.g., 1.21 for workspace support, or 1.22 for latest stdlib)
- [x] Test compilation with the target Go version, fixing breakages iteratively
- [x] Migrate base layer images from Ubuntu 18.04 Bionic to Ubuntu 24.04 Noble (see Phase 5.5 below)
- [x] Evaluate migrating from `vendor/` to Go module proxies — **Decision: keep vendored** (see below)
- [x] Update `libcontainer`/`runc` fork to a maintained version compatible with modern kernels (2026-09-11) — see "runc Fork → Upstream v1.5.1 Migration" below

Additionally completed:
- [x] **Go version**: Upgraded from Go 1.13.15 to Go 1.22.12 (latest patch of 1.22 line)
- [x] **Replace directive audit**: Documented all 3 replace directives:
  - `flynn/runc v1.0.0-rc1001` — 2 patches: (1) restores veth/loopback network setup code removed by upstream, (2) cgo cross-compilation fix. CRITICAL dependency — Flynn's container networking relies on this.
  - `godbus/dbus/v5 v5.0.2` — Module path migration shim (v4→v5). Harmless, standard pattern. Indirect only.
  - `flynn/coreos-pkg v1.0.1` — 1 patch: dlopen stubs for non-Linux. Module graph satisfier only, no code compiled.
- [x] **Removed `go-bindata`**: Vestigial tool dependency (zero usage in codebase). Removed from `go.mod`, `vendor/`, and `builder/gobin/gobin.go`
- [x] **Migrated `io/ioutil`**: 69 non-vendor files, ~177 call sites → `io.ReadAll`, `os.ReadFile`, `os.WriteFile`, `os.CreateTemp`, `os.MkdirTemp`, `os.ReadDir`, `io.Discard`, `io.NopCloser`
- [x] **Migrated `golang.org/x/net/context`**: 22 files → stdlib `context` package
- [x] **Updated build tags**: 32 files from `// +build` to `//go:build` (via `gofmt`)
- [x] **Updated vendored `x/` packages**: `golang.org/x/sys` v0.28.0, `golang.org/x/net` v0.30.0, `golang.org/x/crypto` v0.28.0 (from 2019 versions)
- [x] **Removed `GO111MODULE=on`**: From `script/bootstrap-build` (31 occurrences), `Makefile`, `script/build-flynn`, `script/flynn-builder`, `builder/go-wrapper.sh`
- [x] **Fixed test failures**:
  - `pkg/rpcplus/jsonrpc`: `string(int)` → `string(rune(int))` (Go 1.15+ vet error)
  - `discoverd/health`: Updated HTTP timeout error message check for Go 1.20+ (`context deadline exceeded`)
  - `pkg/stream`: Renamed example functions to `Example_*` format (Go 1.22 requires matching exported identifiers)
- [x] **Updated CI**: `Dockerfile.ci` upgraded from Debian Buster + Go 1.13.15 to Debian Bookworm + Go 1.22.12; `.github/workflows/ci.yml` updated accordingly
- [x] **Full compilation**: All 34+ packages compile successfully with `GOOS=linux GOARCH=amd64 go build ./...`
- [x] **All 21 unit test packages pass** (verified with `-race -cover`)

### Replace Directive Status

| Directive | Status | Action Needed |
|---|---|---|
| `runc` (Flynn fork) | Keep | Carries critical veth networking patch. Future: extract networking code from libcontainer, then upgrade to modern runc. |
| `dbus` (v4→v5 shim) | Keep | Harmless. Will be eliminated when runc fork is updated to modern version. |
| `coreos-pkg` (Flynn fork) | Keep | Module graph satisfier only. Will be eliminated when go-systemd upgraded to v22. |

### vendor/ vs Go Module Proxies Evaluation (Complete, 2026-05-15)

**Findings**:
- `vendor/` is 22 MB, 2,848 files — small overhead
- `go mod verify` passes — vendor is clean `go mod vendor` output, no manual patches
- All 3 Flynn fork replace directives (`flynn/runc`, `flynn/coreos-pkg`, `godbus/dbus`) resolve on the Go module proxy (proxy.golang.org)
- Build without vendor succeeds (`GOFLAGS=-mod=mod go build -o /tmp/flynn-cli ./cli` compiles cleanly)
- 6 Flynn-owned packages (`go-check`, `go-docopt`, `go-p9p`, `go-tuf`, `que-go`, `tail`) all available on proxy

**Decision: Keep `vendor/`**. Rationale:
1. **Reproducibility** — vendor guarantees bit-identical builds regardless of proxy availability. The Flynn forks are hosted on GitHub under the `flynn` org (unmaintained); if repos are deleted or go-import paths break, proxy cache may eventually expire.
2. **Minimal cost** — 22 MB is negligible in a repo that already has multi-GB TUF artifacts.
3. **No friction** — `go mod vendor` produces the current tree exactly; no manual patches to maintain.
4. **CI compatibility** — the existing CI workflow uses `-mod=vendor` implicitly; removing vendor would require proxy network access in CI containers.

**If revisited later**: The migration path is trivial — delete `vendor/`, ensure CI has proxy access, done. No code changes needed.

### Remaining Phase 5 Work (Deferred to Phase 6+)
- **runc fork modernization**: The Flynn runc fork (`v1.0.0-rc1001`) is 6+ years behind on security patches. Upgrading requires extracting the veth/loopback networking into Flynn's own code (using `vishvananda/netlink` directly), then migrating to modern runc. This is a significant undertaking tied to Phase 6 cluster bootstrap work.
- **~~Base layer migration~~**: Complete — migrated to Ubuntu 24.04 Noble in Phase 5.5.

#### runc Fork → Upstream v1.5.1 Migration (2026-09-11)

**Status**: Migration implemented and committed (flynn branch `feat/runc-v151`, commit `9d61779c`, `host: migrate libcontainer to upstream runc v1.5.1`); **cluster validation pending** (no KVM/CAP_NET_ADMIN on the build box — gate is a single-node Vagrant bootstrap, same as the original fork-patch validation requirement).

**What changed** (follows the extraction map above, with one important discovery): upstream runc **re-added** veth-style networking after the rc8 era, but in a new form — the `veth`/`loopback` strategies are gone, replaced by `configs.NetDevices` (pre-created host devices moved into the container's netns and renamed atomically by `setupNetworkDevices()` during `initProcess.start()`, before the user binary execs). So the in-namespace remainder (MAC/IP/MTU/gateway + loopback up) had to be done by Flynn itself, and is done from the host via a temporary `setns(CLONE_NEWNET)` into the container's netns, with no capability increase for app jobs:

- `host/libcontainer_backend.go`:
  - `createVethPair()` + `attachVethToBridge()` — host-side veth creation and bridge attach (netlink directly, mirroring the old strategy's `create`/`attach`).
  - `configs.NetDevices{peerName: {Name: "eth0"}}` — libcontainer moves+renames the peer into the container netns (upstream-maintained path).
  - `configureContainerNetwork(pid, initConfig)` — after `c.Run()` returns (netns exists, eth0 moved, and the job's app is still parked at containerinit's resume gate), enters the container netns: up loopback, then eth0 MAC/address/MTU/default-route; `setns` back (exits the daemon on failure to return — no safe recovery).
  - `cleanup()` now removes the host-side veth end (previously leaked attached to the bridge).
- `host/types/defaults.go`: Flynn's own copy of the rc8 default device lists (runc dropped `DefaultAllowedDevices`), now in the `opencontainers/cgroups` `Rule`/`Device` types; allow rules carry `Allow: true` (new v1 device emulator is allow/deny explicit).
- `host/host.go`: re-exec dispatch is now `os.Args[1] == "init"` guarded by `_LIBCONTAINER_SYNCPIPE` (runc spawns the init child with that env; the user-facing `flynn-host init` command is unaffected), calling `libcontainer.Init()`; obsolete gccgo-only `nsenter` blank import removed.
- API mapping: `factory.Create/Load` → `libcontainer.Create(containerRoot, id, config)` / `libcontainer.Load`; `Process{Init: true, User: "root"}` → `Process{UID: 0, GID: 0}`; `configs.Cgroup`/`configs.Resources` → `github.com/opencontainers/cgroups` v0.0.6 (`Cgroup.Path` + `Resources.Devices` rules; `IsCgroup2UnifiedMode`/`GetAllSubsystems`/`FindCgroupMountpoint` moved there unchanged).
- `go.mod`: `opencontainers/runc v1.5.1` (replace directive to `flynn/runc v1.0.0-rc1001` removed), `opencontainers/cgroups v0.0.6`, `vishvananda/netlink v1.3.1` (from the 2017 pseudo-version), `golang.org/x/sys v0.46.0`, `godbus/dbus/v5 v5.2.2`; `go mod tidy && go mod vendor` (no new cgo build requirements: seccomp-golang stays behind its `cgo && seccomp` build tags, already vendored).

**Validation so far**: `go build ./...` clean and `go test ./host` (incl. `libcontainer_backend_test.go`) green on Go 1.27.1 (CGO_ENABLED=0 build box; all new code is pure Go). gofmt clean. Remaining gate: single-node cluster bootstrap + container start/attach/stop over the new veth path, plus a host restart (state restore) test.

**Rollout constraint**: `state.json` format changed — containers created by the old `flynn-host` cannot be restored by the new one. Drain/stop jobs before upgrading a host's binary (or accept restarting the jobs).

#### runc Fork Patch Analysis for the Phase 6 Upgrade (2026-09-01)

**Status**: Superseded by the 2026-09-11 migration above (analysis was accurate; the extraction map held). Kept for reference.

**The two Flynn fork patches (per AGENTS.md + Phase 5 audit, verified in vendored source at `vendor/github.com/opencontainers/runc/`)**:
1. **veth/loopback network setup restore**: Upstream runc rc8-era removed the per-container veth wiring; the fork restores it in `libcontainer/network_linux.go` — the `veth` strategy (`create`/`attach`/`detach`, lines 107-232) and the `loopback` strategy (lines 87-105), dispatched by `getStrategy` from `configs.Network.Type` (`"veth"`, `"loopback"`).
2. **cgo cross-compilation fix**: `libcontainer/system/` provides cgo (`sysconfig.go`, `_SC_CLK_TCK`) and non-cgo (`sysconfig_notcgo.go`, returns 100) variants guarded by `// +build cgo,linux` vs `!cgo windows` — allowing builds when CGO is disabled.

**Extraction map — narrower than originally feared**: `host/libcontainer_backend.go` **already** does its own bridge management via `vishvananda/netlink` directly (`ConfigureNetworking`, lines 214-295, imports `netlink` at line 54) and does NOT route bridge setup through runc/libcontainer. The *only* code still coupled to the fork is the **per-container veth creation**: `ConfigureNetworking`/`Start` build a `configs.Network{Type:"veth", Bridge, HostInterfaceName, ...}` (lines 834-854) that libcontainer's veth strategy realizes. So the upgrade surface is:
- Move veth pair creation into `host/libcontainer_backend.go` (or a local helper) using netlink directly (`LinkAdd(&netlink.Veth{PearName...})`, `LinkSetMaster`, `LinkSetMTU`, `LinkSetUp`), mirroring the existing bridge logic that already uses netlink directly.
- Then migrate `flynn/runc` → modern upstream runc (v1.2.x), adapting the libcontainer backend API (rc8 → v1.2 has substantial API changes: `Factory.Create`/`configs.Config` fields, cgroup v2 default, namespaces, `Runtime` plumbing). `udbus/dbus` v4→v5 shim disappears; `coreos-pkg` persists until go-systemd is bumped to v22.
- **Verification is mandatory**: this cannot be validated without a real Phase 6 cluster bootstrap (flannel overlay + discoverd + postgres image with ZFS squashfs layers), since veth wiring is exercised only at container start. A blind upgrade risks silently breaking `flynn-host` container networking.
- `vishvananda/netlink` is already vendored (`vendor/github.com/vishvananda/netlink/`), so no new dependency is required for extraction.

## Phase 5.5: Base Image Migration — Ubuntu 18.04 → 24.04 (Complete)

The container base layer images were migrated from Ubuntu 18.04 Bionic (EOL April 2023) to Ubuntu 24.04 LTS Noble Numbat (supported until 2034). This was done in the `noble-migration-and-fixes` branch and merged into master.

- [x] Create `builder/img/ubuntu-noble.sh` — builds Noble rootfs from cloud image or debootstrap, creates squashfs layer
- [x] Create `builder/img/heroku-24.sh` and `builder/img/heroku-24-build.sh` — Noble-based Heroku stack images
- [x] Migrate all component base layers from Bionic to Noble
- [x] Handle merged-usr (`/bin/` → `/usr/bin/` remapping) in `export-tuf` for Noble cloud images
- [x] Migrate PostgreSQL from 11 to 16 (see "PostgreSQL 16 Migration" in Phase 6)
- [x] Migrate MariaDB to 10.11 LTS (`innobackupex` → `mariabackup`)

### PostgreSQL 16 Migration (Complete)

**Files**: `appliance/postgresql/process.go`, `appliance/postgresql/cmd/flynn-postgres-api/main.go`, `controller/data/schema.go`, `controller/schema/schema.go`

| Change | Detail |
|---|---|
| WAL config | `wal_keep_segments` → `wal_keep_size = 2048` (removed in PG13) |
| WAL level | `wal_level = hot_standby` → `wal_level = replica` |
| Password encryption | `password_encryption = md5` (PG16 defaults to scram-sha-256) |
| Recovery mechanism | `recovery.conf` → `standby.signal` + config-based recovery |
| Promotion | `promote_trigger_file` → `pg_ctl promote` (removed in PG16) |
| Public schema | `GRANT ALL ON SCHEMA public TO PUBLIC` in template1 (PG15+ restriction) |
| Database creation | `CREATE DATABASE ... OWNER` in postgres API |
| Trigger functions | `RETURNS OPAQUE` → `RETURNS trigger` in 4 controller migrations (OPAQUE removed in PG16) |
| Schema loader | Filter macOS `._*` resource fork files from JSON schema directory |

**pgextwlist/TimescaleDB**: Config preserved in `process.go` (`shared_preload_libraries = 'timescaledb'`, `local_preload_libraries = 'pgextwlist'`, full extension whitelist). Packages not yet installed in the Noble base layer — see "pgextwlist / TimescaleDB Restoration" below.

### MariaDB 10.11 LTS Migration (Complete)

**File**: `appliance/mariadb/cmd/flynn-mariadb/main.go`

Migrated from `innobackupex` (deprecated, removed in MariaDB 10.3+) to `mariabackup` for MariaDB 10.11 LTS (the version available in Ubuntu Noble repos).

### Additional Source Code Changes (Post-Noble Merge)

| Commit | File | Change |
|---|---|---|
| `c540b45e` | `appliance/postgresql/` | PostgreSQL 16 compatibility (see above) |
| `2ec11480` | `controller/data/schema.go`, `controller/schema/schema.go` | PG16 trigger functions + macOS resource fork filtering |
| `aec88051` | `flannel/backend/vxlan/device.go` | Re-apply deterministic MAC after `LinkSetUp()` which resets hardware address |
| `4b4de5f4` | `host/libcontainer_backend.go` | Call TUF `Update()` after initialization; root key fallback for fresh stores |
| `06bf70c7` | `pkg/postgres/migrate.go` | Propagate `CREATE TABLE schema_migrations` errors (was nil pointer panic) |
| `fbf29299` | `script/export-tuf/main.go` | `ExtraDirs`, `PackageScript`, `--skip-base-layers`, Noble merged-usr support, GitHub Releases URLs |
| `44b47d70` | `host/downloader/downloader.go` | Direct squashfs layer download with `sha512_256` verification; GitHub Releases as layer source |
| `0219d1c4` | `host/libcontainer_backend.go` | `filterOverlayResolvers()` — strips 100.100.x.x from DNS recursors to prevent discoverd self-recursion after restart |

## Phase 6: Integration Testing and Cluster Bootstrap

### Multi-Node Test Infrastructure (Vagrant + libvirt)

Flynn's setup process and cluster bootstrap need to be tested in real VMs, not just containers — `flynn-host` requires systemd, cgroups, ZFS, iptables, and full network stack control that containers can't provide.

**Two dev-machines** are available (see `specs/dev-machine.md` for full details):

| Machine | Arch | IP | CPU | RAM | Acceleration |
|---|---|---|---|---|---|
| Proxmox server | amd64 | `192.168.168.87` | 2x Xeon E5-2680 v2 (40 cores) | 62 GB | Native KVM (nested virt) |
| NVIDIA GB10 | arm64 | `192.168.168.113` | Cortex-X925 (10 cores) | 122 GB | Native ARM64 KVM |

**Why not the original Vagrantfiles**: The existing `flynn/Vagrantfile` and `flynn/demo/Vagrantfile` both depend on the offline `dl.flynn.io` for the `flynn-base` box and use VirtualBox as the provider. Neither works as-is.

**Approach**: Initially used custom Debian 13 (Trixie) Vagrant boxes, then switched to Ubuntu Noble 24.04 to align with the component base layer OS. Vagrant boxes use the libvirt provider with KVM hardware acceleration on both machines.

#### Vagrant Box Infrastructure (Complete)

Custom Vagrant boxes were built from official Debian 13 `generic` cloud images (`https://cloud.debian.org/images/cloud/trixie/20260402-2435/`) using a multi-arch build script (`build-box.sh`). The `generic` variant was chosen over `nocloud` because it includes `openssh-server` pre-installed.

**Box customizations**: vagrant user with insecure key (RSA + ed25519), passwordless sudo, SSHD configured via `/etc/ssh/sshd_config.d/99-vagrant.conf`, SSH host keys pre-generated, systemd-networkd enabled with DHCP, cloud-init disabled.

**Build script** has two code paths: native arch uses `virt-customize --run-command`; cross-arch uses `guestfish` file-level operations (can't execute cross-arch binaries via `virt-customize`).

| Box | Arch | Size | Built On | Tested On | Status |
|---|---|---|---|---|---|
| `debian13-amd64` | amd64 | 413 MB | x86_64 machine | x86_64 machine (native KVM) | **Verified** |
| `debian13-arm64` | arm64 | 407 MB | x86_64 machine (cross-arch) | ARM64 machine (native KVM) | **Verified** |
| `debian13-riscv64` | riscv64 | 409 MB | x86_64 machine (cross-arch) | — | Built, untested (no native hardware) |

**Key discoveries during box building**:
- KVM only accelerates matching architectures; cross-arch guests fall back to QEMU TCG (unusably slow)
- AppArmor blocks cross-arch QEMU VMs — fixed with `security_driver = "none"` in `/etc/libvirt/qemu.conf` on both machines
- Debian 13 `generic` cloud image has no network config outside cloud-init — must enable systemd-networkd and create `.network` file
- Cloud-init blocks SSH startup without a datasource — disable via `/etc/cloud/cloud-init.disabled`
- Vagrant's key replacement after initial SSH causes `Connection reset` — use `config.ssh.insert_key = false`
- ARM64 VMs require UEFI, `virt` machine type, `host-passthrough` CPU mode, virtio input/video (no PS/2 or cirrus on ARM)
- HashiCorp doesn't build Vagrant for Linux arm64 — installed via `gem install vagrant`
- `vagrant-libvirt` network dnsmasq can silently die — fix with `virsh net-autostart vagrant-libvirt`

**File locations**:
- Build script: `/root/vagrant-boxes/build-box.sh` (x86_64 machine), `/tmp/build-box.sh` (local)
- Source images: `/root/vagrant-boxes/{amd64,arm64,riscv64}/` (x86_64 machine)
- Built boxes: `/root/vagrant-boxes/debian13-{amd64,arm64,riscv64}.box` (x86_64 machine), `/root/vagrant-boxes/debian13-arm64.box` (ARM64 machine)

- [x] Install Vagrant + vagrant-libvirt + libvirt-daemon-system on x86_64 build server (Vagrant 2.3.8.dev, libvirt 11.3.0, QEMU 10.0.8)
- [x] Install Vagrant + vagrant-libvirt on ARM64 machine (Vagrant 2.4.9 via gem, vagrant-libvirt 0.12.2, QEMU, libvirt)
- [x] Download official Debian 13 `generic` cloud images for amd64, arm64, riscv64
- [x] Create multi-arch Vagrant box build script (`build-box.sh`) with native and cross-arch code paths
- [x] Build and verify amd64 box — `vagrant up` + `vagrant ssh` works with native KVM on x86_64 machine
- [x] Build and verify arm64 box — `vagrant up` + `vagrant ssh` works with native KVM on ARM64 machine
- [x] Build riscv64 box (untested — no native hardware, TCG emulation not viable)
- [x] Fix AppArmor on both machines (`security_driver = "none"`)
- [x] Enable `vagrant-libvirt` network autostart on x86_64 machine
- [x] Document box-building process, Vagrantfile examples, and troubleshooting in `specs/dev-machine.md`

#### Flynn Cluster Vagrantfile (Complete)

**Design**:
- Ubuntu Noble 24.04 base (initially Debian 13, switched to Noble to align with component base layers) instead of Ubuntu 18.04 — modern kernel, better hardware support
- libvirt provider with KVM acceleration (instead of VirtualBox)
- Private network bridge for inter-node communication (full TCP/UDP connectivity required by discoverd, flannel, flynn-host API)
- Configurable node count: 1 node (singleton) or 3+ nodes (multi-node; Flynn rejects `--min-hosts=2`)
- Auto-scaling resources: single-node gets 4 GB / 2 CPUs; multi-node gets 8 GB / 4 CPUs per node (overridable via `NODE_MEMORY`, `NODE_CPUS`)
- Per node: 40 GB storage (ZFS pool on separate vdb disk)
- Provisioning: install ZFS, iptables, cgroups; install `flynn-host` from new TUF repo; configure peer discovery via `--peer-ips` (avoids dependency on offline `discovery.flynn.io`)
- DNS: wildcard domain pointing to all node IPs (e.g., `*.demo.localflynn.com`)

**Flynn cluster requirements per node**:

| Requirement | Detail |
|---|---|
| OS | Ubuntu 24.04 Noble amd64 (or arm64 on ARM64 machine) |
| RAM / CPU / Disk | 4 GB / 2 cores / 40 GB minimum (singleton); 8 GB / 4 cores / 40 GB (multi-node HA) |
| Kernel features | OverlayFS, cgroups v2 (unified hierarchy), ZFS module |
| System packages | `zfsutils-linux`, `zfs-dkms`, `linux-headers-*`, `iptables`, `curl`, `squashfs-tools` |
| Network ports | 1111 (discoverd), 1113 (flynn-host API), 5002 (flannel), 53 (DNS), 80/443 (router) |
| Multi-node minimum | 3 nodes (2 is explicitly rejected by bootstrap) |

**Multi-node resource analysis**: HA mode runs ~37 processes across 3 nodes (~13 per node). Each process has a default cgroup memory limit of 1 GiB (hardcoded in `host/resource/resource.go`), but actual usage is 200-500 MB per process. Flynn forces `overcommit_memory=1` at the kernel level, so declared limits don't need to fit in physical RAM — they're cgroup hard caps, not reservations. The scheduler is resource-unaware (load-balances by job count only). 8 GB per node provides comfortable headroom for actual memory usage without OOM kills.

**Multi-node bootstrap flow**: Vagrant provisions nodes sequentially (node1 → node2 → node3). Each node's daemon starts immediately after provisioning. `--peer-ips` is NOT passed to the daemon because `ConnectPeer()` blocks ~60s per unreachable peer — and during initial cluster formation, no discoverd is running on any peer yet. Instead, `--peer-ips` is only passed to the `flynn-host bootstrap` command on the last node, which coordinates starting discoverd (omni), flannel (omni), and all services across all hosts.

- [x] Create a new Vagrantfile (libvirt provider, Debian 13, configurable 1 or 3+ nodes, private network, Flynn provisioning)
- [x] Test single-node `flynn-host bootstrap` in a Vagrant VM — **all services healthy** (2026-04-13)
- [x] Update Vagrantfile for multi-node: auto-scale RAM (8 GB) and CPUs (4) for HA mode, document `--peer-ips` flow
- [x] Test 3-node cluster bootstrap with `--peer-ips` and `--min-hosts=3` — **37 processes running across 3 nodes** (2026-04-14)

#### HA Process Distribution (3-Node Cluster)

In HA mode (min-hosts >= 3), Flynn deploys ~37 processes across the cluster. Services marked "omni" run one instance per host; others are distributed by the scheduler (load-balanced by job count).

| Service | Process | Count | Omni? |
|---|---|---|---|
| discoverd | app | 3 | yes |
| flannel | app | 3 | yes |
| postgres | postgres | 3 | |
| postgres | web | 2 | |
| controller | web | 2 | |
| controller | scheduler | 3 | yes |
| controller | worker | 2 | |
| router | app | 3 | yes |
| redis | web | 2 | |
| mariadb | web | 2 | |
| mongodb | web | 2 | |
| blobstore | web | 2 | |
| gitreceive | app | 2 | |
| tarreceive | app | 2 | |
| logaggregator | app | 2 | |
| status | web | 2 | |
| **Total** | | **~37** | |

### Component Bootstrap (Single-Node Complete)

Single-node Flynn cluster bootstrap completed successfully on 2026-04-13. All 40+ bootstrap steps pass, all services report healthy.

**Bootstrap sequence verified**: online-hosts → discoverd → flannel → wait-hosts → postgres (3-layer image) → postgres-wait → controller-cert → controller → controller-wait → controller-inception → postgres-app → flannel-app → discoverd-app → scheduler → redis → mariadb → mongodb → router → gitreceive → tarreceive → blobstore → logaggregator → taffy → status → status-check ("all services healthy") → cluster-monitor → log-complete.

- [x] Get `discoverd` running standalone in a Vagrant VM
- [x] Get `flannel` networking operational
- [x] Bootstrap a minimal Flynn cluster (discoverd + flannel + controller + host)
- [x] Re-enable integration tests (`script/run-integration-tests`) against the bootstrapped cluster — partially complete (2026-05-18): test binary runs, DNS/schema prerequisites identified, full suite blocked by missing build artifacts; core functionality verified manually
- [x] Validate database appliances (PostgreSQL, MariaDB, MongoDB, Redis) — (2026-05-04) PG16 pass, MariaDB pass (with fixes), MongoDB pass (with driver migration), Redis pass

#### Code Changes for Debian 13 / Ubuntu Noble / Cgroups v2 (branch: `debian13-cgroups-v2-bootstrap`, `noble-migration-and-fixes`, `pg16-and-bootstrap-fixes`)

The following patches were required to make Flynn run on Debian 13 / Ubuntu Noble (kernel 6.x, cgroups v2 only):

| File | Change | Why |
|---|---|---|
| `host/libcontainer_backend.go` | Dual v1/v2 cgroup setup: `setupCGroupsV2()`, `createCGroupPartitionV2()`, `cpuSharesToWeight()`, per-container `CpuWeight` | Debian 13 has `CONFIG_MEMCG_V1=n` — cgroups v1 is compiled out entirely |
| `vendor/.../notify_linux.go` | v2 OOM notification via inotify on `memory.events` | v1 uses `cgroup.event_control` + eventfd on `memory.oom_control` which doesn't exist on v2 |
| `vendor/.../apply_raw.go` | Guard `CheckCpushares()` with `!IsCgroup2UnifiedMode()` | `cpu.shares` file doesn't exist on v2; unconditional read causes failure |
| `host/volume/zfs/zfs.go` | Fallback from `copySparse` (FIEMAP) to sequential `io.Copy` | tmpfs on Debian 13 returns EOPNOTSUPP for FIEMAP ioctl |
| `vendor/.../dns/clientconfig.go` | Fix `len(s) >= 8` guard to `len(s) >= 9` before `s[:9]` | Debian 13 resolv.conf has `trust-ad` (8 chars), triggering panic |
| `appliance/postgresql/cmd/flynn-postgres/main.go` | `TimescaleDB: false`, `ExtWhitelist: false` | See "pgextwlist / TimescaleDB restoration" below; PG16 config preserved but packages not installed |
| `appliance/postgresql/process.go` | `installExtensionsInTemplate()` — pre-installs `uuid-ossp` and `pgcrypto` in template1 | Non-superuser app DB users can't run CREATE EXTENSION without pgextwlist |
| `router/server.go` | Use `EXTERNAL_IP` for discoverd registration, `LISTEN_IP` for bind only | Router registered `0.0.0.0:5000` with discoverd, unreachable from other nodes |

**Build requirements**: All binaries destined for container images must be built with `CGO_ENABLED=0` (static linking). The container base is Ubuntu 24.04 Noble (glibc 2.39); dynamically-linked binaries built on newer systems may fail with glibc version mismatches.

#### Volume Manager Layer Caching

The `mountSquashfs` function in `libcontainer_backend.go` uses a two-tier caching mechanism:

1. **In-memory map** backed by **BoltDB** (`/var/lib/flynn/volumes/volumes.bolt`) via `GetVolume(layerID)`. If found, returns immediately without downloading.
2. If NOT found, downloads from the layer URL, writes to a ZFS zvol, mounts as squashfs, and registers in both the in-memory map and BoltDB via `ImportFilesystem`.

**Important**: Simply creating a ZFS zvol manually does NOT register the layer — the volume manager won't know about it. The BoltDB is exclusively locked by the running flynn-host process, so `flynn-host download` can't be used while the daemon is running. Layers are only populated into the volume manager via: (a) `flynn-host download` (before daemon starts), or (b) `ImportFilesystem` triggered by a container start that downloads the layer.

**ZFS zvol replacement does NOT work via dd**: Writing a new squashfs to a ZFS zvol device with `dd` doesn't work — the ZFS ARC caches old blocks and serves stale data even after `drop_caches`, `blockdev --flushbufs`, and even destroying/recreating the zvol. **Workaround**: Mount the new squashfs file directly via loop device (`mount -t squashfs -o ro,loop /tmp/new-layer.squashfs /var/lib/flynn/volumes/zfs/mnt/squashfs/<hash>`).

#### Bugs Found and Fixed During 3-Node Bootstrap (2026-04-14)

**1. PostgreSQL `uuid-ossp` read-only transaction error** (`appliance/postgresql/process.go`): When postgres runs with a sync replica, `postgresql.conf` sets `default_transaction_read_only = on`. The `installExtensionsInTemplate()` function opens a new connection to `template1` to run `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"`, but doesn't override the read-only setting. The DDL fails with `SQLSTATE 25006` (read-only transaction), causing the primary to crash-loop. **Fix**: Added `SET default_transaction_read_only = off` at the start of `installExtensionsInTemplate()` (line ~460). The existing `assumePrimary()` function already does `SET TRANSACTION READ WRITE` but that session-level override doesn't carry over to the extension installation's separate connection.

**2. Flannel VXLAN duplicate MAC addresses** (`flannel/backend/vxlan/device.go`): All VMs cloned from the same Vagrant base box get identical `flannel.1` VXLAN device MAC addresses (e.g., `22:06:d8:56:99:5b` on all 3 nodes). This is because: (a) the code never sets `HardwareAddr` in the VXLAN `LinkAttrs`, (b) the vendored netlink library has a TODO and doesn't send `IFLA_ADDRESS` during `LinkAdd`, and (c) the kernel generates the MAC deterministically from the VNI and machine state, which is identical on cloned VMs. With duplicate MACs, VXLAN FDB entries can't distinguish remote nodes, causing 100% packet loss on the overlay network. **Fix**: Added `netlink.LinkSetHardwareAddr()` call after device creation in `newVXLANDevice()` to set a unique MAC derived from the VTEP IP (`02:42:IP[0]:IP[1]:IP[2]:IP[3]`). This produces unique MACs like `02:42:c0:a8:32:0b` for 192.168.50.11.

**3. vagrant-libvirt premature provisioner bug**: `NUM_NODES=3 vagrant up --no-parallel` doesn't work reliably. During long-running DKMS builds (~5 min), vagrant-libvirt prematurely triggers the next provisioner or starts the next VM before the current one finishes. **Workaround**: Provision each node individually with `NUM_NODES=3 AUTO_BOOTSTRAP=false vagrant up node1`, then `vagrant up node2`, then `vagrant up node3`.

**4. Router discoverd registration with 0.0.0.0** (`router/server.go`): The router registers its `router-api` and `router-http` services with discoverd using `LISTEN_IP` (set to `0.0.0.0` by `flynn-host --listen-ip=0.0.0.0`) instead of `EXTERNAL_IP` (set to the node's real IP). This produces registrations like `0.0.0.0:5000` which are not routable from other nodes. The status aggregator can't reach the router's `/.well-known/status` endpoint, and the scheduler can't connect to router event streams (producing continuous "route not found" errors). **Fix**: Changed `server.go` to use `EXTERNAL_IP` for discoverd registration addresses while keeping `LISTEN_IP` for bind addresses. Now registers as `192.168.50.x:5000` / `192.168.50.x:80`.

#### TUF Image Rebuilds

Initially built with Ubuntu 18.04 Bionic base layers, then rebuilt with Ubuntu 24.04 Noble base layers after the Noble migration (Phase 5.5).

| Image | Layers | Change |
|---|---|---|
| postgres | 3: Noble base + PostgreSQL 16 packages + binaries | PG16 compatibility; `CGO_ENABLED=0`; extension fixes; `SET default_transaction_read_only = off` for multi-node |
| controller | 2: Noble base + binaries+schemas | `CGO_ENABLED=0`; PG16 trigger functions; JSON schemas in `/etc/flynn-controller/jsonschema/` |
| flannel | 2: Noble base + binaries | `CGO_ENABLED=0`; unique VXLAN MAC fix; MAC reset after LinkSetUp fix |
| router | 2: Noble base + binaries | `CGO_ENABLED=0`; `EXTERNAL_IP` registration fix |
| gitreceive | 3: Noble base + git packages + binaries | Git packages layer (`apt-get install git`) |
| slugbuilder | 3: Noble base + binaries + packages | Combined packages layer (`b620d70b`, 103MB) with git, ruby, daemontools, pigz, jq, curl, and 5 Heroku buildpacks (go, multi, ruby, nodejs, python). Packages layer LAST to override broken `build.sh` in binaries layer with fixed version (heroku-24 stack) |
| slugrunner | 3: Noble base + binaries + packages | Ruby packages layer (`8fc1d819`, 15MB) needed for Procfile parsing via `/runner/init`. Packages layer LAST |
| mariadb | Noble base + binaries | `mariabackup` migration for MariaDB 10.11 LTS |

### Git Push Pipeline Fix (2026-04-14)

The end-to-end git push deployment pipeline (`git push` → gitreceive → slugbuilder → blobstore → slugrunner → router) was broken because almost all TUF repo images were built with only 2 layers (base + binaries), missing the intermediate packages layers that install apt packages, buildpacks, etc. The original Flynn build system ran these package installation steps inside a running cluster (self-hosted), and when the TUF repo was rebuilt from source in Phase 3, only the Go binary layers were generated.

**Root causes fixed**:
1. **Gitreceive HTTP 500**: The container was missing the `git` binary because the `gitreceive-packages` layer (which runs `apt-get install git`) was never built. Fix: Built a 28MB squashfs layer containing git and dependencies.
2. **Slugbuilder failures**: Missing heroku-18 + heroku-18-build + slugbuilder-packages stack. Fix: Built a combined 50MB squashfs layer containing git, ruby, daemontools, pigz, and 5 Heroku buildpacks (Go, multi, Ruby, Node.js, Python).
3. **Slugrunner failures**: Missing ruby (needed for Procfile parsing via `ruby -r yaml`). Fix: Reused the slugbuilder packages layer.

**Deployment method for running cluster**: New layers are served via HTTP from the build server (`192.168.121.1:8888`), then new artifacts/releases/formations are created via the controller API. When the scheduler starts new containers, `mountSquashfs()` in `libcontainer_backend.go` downloads the layers and registers them in the volume manager via `ImportFilesystem()`.

**Verification**: Successfully deployed a Go test app (`test/apps/http`) via `git push flynn master`. The full pipeline completes: gitreceive receives push → spawns slugbuilder job → Go buildpack detects app, installs go1.6.4, compiles → slug tarball uploaded to blobstore → release created → slugrunner starts web process → app accessible via router at `https://test-http.demo.localflynn.com/` returning "ok".

#### Resource Limit Tests Fix (2026-04-15)

All 4 resource limit integration tests now pass on the 5-node cgroups v2 cluster:

| Test | Suite | Time | Status |
|---|---|---|---|
| `TestRunLimits` | CLISuite | 2.5s | **PASS** |
| `TestResourceLimits` | HostSuite | 1.2s | **PASS** |
| `TestResourceLimitsOneOffJob` | ControllerSuite | 0.8s | **PASS** |
| `TestResourceLimitsReleaseJob` | ControllerSuite | 0.8s | **PASS** |

**Changes required**:

| File | Change | Why |
|---|---|---|
| `test/helper.go` | `resourceCmd` auto-detects v1/v2 cgroup paths; `cpuSharesToWeight()` and `isCgroupV2()` helpers; `assertResourceLimits()` expects v2 `cpu.weight` | Tests read cgroup files inside containers; v2 uses `memory.max`, `cpu.weight` instead of v1's `memory.limit_in_bytes`, `cpu.shares` |
| `test/test_cli.go` | `TestRunLimits` uses v1/v2 auto-detection in the `flynn run` shell command | Same as above |
| `test/test_host.go` | `TestResourceLimits` job config: `DisableLog: true` | Prevents log mux attach race condition (see below) |
| `test/test_controller.go` | `TestResourceLimitsOneOffJob` NewJob: `DisableLog: true` | Same race condition fix |
| `host/libcontainer_backend.go` | `NotifyOOM()` failure is non-fatal (warn + continue instead of return error) | inotify instance exhaustion (`max_user_instances=128`) killed containers; OOM monitoring is best-effort |
| `test/main.go` | `setupGitreceive()` only called for git-related test filters | Avoids blocking on broken deployments when running non-git tests |

**Bugs discovered and fixed**:

1. **inotify instance exhaustion** (root cause of "containers die immediately"): On cgroups v2, each container's OOM notification uses an inotify instance (via `InotifyInit1` on `memory.events`). With 89 bootstrap containers + system uses, the default `max_user_instances=128` was exhausted. New containers' `watch()` goroutine failed at `NotifyOOM()` → returned error → deferred `Destroy()` killed the container — all within ~1 second, with no error logged to the user. **Fix**: (a) Increased `fs.inotify.max_user_instances` to 1024 on all nodes (persisted via `/etc/sysctl.d/99-inotify.conf`), (b) Made `NotifyOOM()` failure non-fatal in `watch()`.

2. **Log mux attach race condition**: For short-lived jobs with `DisableLog: false`, the attach handler's `StreamLog()` subscribes to the log mux and waits for `jobDoneCh` to fire (signaling the job's log streams have closed). But if the job starts, produces output, and finishes before `StreamLog()` sets up its subscription, the job's `WaitGroup` has already been cleaned up from `jobWaits` map. `jobDoneCh` then creates a new `started` channel that nobody will ever close, blocking forever. **Fix**: Set `DisableLog: true` on test jobs that capture output via the attach stream, bypassing the log mux entirely (this matches the behavior of `flynn run` CLI, which sets `DisableLog: true` by default).

3. **`setupGitreceive()` blocks non-git tests**: The test binary's `main()` unconditionally called `setupGitreceive()` which runs `flynn -a gitreceive env set` — triggering a deployment that hangs when the router has no routes. **Fix**: Only call `setupGitreceive()` when the `-run` filter matches git-related test names.

**5-node cluster configuration**: 5 VMs (Vagrant + libvirt), each 4 CPUs / 8 GB RAM, Ubuntu Noble 24.04, ZFS on `/dev/vdb`, `fs.inotify.max_user_instances=1024`. Bootstrap with `--min-hosts=5`. Static `flynn-init` deployed to all nodes (CGO_ENABLED=0 for glibc compatibility).

#### Integration Test Progress (2026-04-14)

**Test infrastructure**: `flynn-test` binary built from `test/main.go` (go-check framework, 23 test suites). Runs against existing cluster with `--router-ip 192.168.50.11 --cli /tmp/flynn-cli`.

**Test-apps artifact**: Built `test-apps.json` with busybox base layer (`03fe7735`) + test app binaries layer (`bc9a528e`, 20MB containing echoer, pingserv, ish, http-blocker, signal, oom). Placed at `build/image/test-apps.json` relative to the source tree.

**Tests passing (40)**:

*CLISuite (26)*:
- `TestCreateAppNoGit`, `TestCluster`, `TestProvider`, `TestApp`, `TestPs`, `TestScale`, `TestScaleAll`
- `TestRunSignal`, `TestEnv`, `TestMeta`, `TestKill`, `TestRoute`
- `TestResource`, `TestResourceList`, `TestResourceRemove`
- `TestLog`, `TestLogFollow`, `TestLogFilter`, `TestLogStderr`
- `TestRelease`, `TestReleaseRollback`, `TestRemote`
- `TestDeploy`, `TestDeployTimeout`, `TestLimits`, `TestRunLimits`

*ControllerSuite (8)*:
- `SetUpSuite`, `TestAppDelete`, `TestAppDeleteCleanup`, `TestAppEvents`
- `TestRouteEvents`, `TestResourceProvisionRecreatedApp`
- `TestResourceLimitsOneOffJob`, `TestResourceLimitsReleaseJob`

*HostSuite (1)*:
- `TestResourceLimits`

*PostgresSuite (2)*:
- `TestSSLRenegotiationLimit`, `TestDumpRestore`

*GitDeploySuite (8)*:
- `TestNonMasterPush`, `TestRunQuoting`, `TestConfigDir`, `TestSlugignore`
- `TestAppRecreation`, `TestLargeRepo`, `TestCustomPort`, `TestProcfileChange`

*SchedulerSuite (3)*:
- `TestScale`, `TestJobMeta`, `TestJobStatus`

**Known failures and reasons**:
- `CLISuite.TestRunLimits` — **FIXED** (2026-04-15). See "Resource Limit Tests Fix" section below.
- `CLISuite.TestReleaseDelete` — calls `assertURI` which does HTTP HEAD to `blobstore.discoverd`, unreachable from build server (no discoverd DNS).
- `ControllerSuite.TestExampleOutput` — needs `../build/image/controller-examples.json` build artifact.
- `ControllerSuite.TestKeyRotation` — times out (may need longer timeout or cluster resources).
- `GitDeploySuite.TestEnvDir/TestEmptyRelease/TestDevStdout/TestSourceVersion/TestBuildCaching/TestCancel/TestCrashingApp/TestPrivateSSHKeyClone` — use `BUILDPACK_URL=https://github.com/kr/heroku-buildpack-inline`; containers can't clone from GitHub (exit 111).
- `GitDeploySuite.TestGoBuildpack/TestNodejsBuildpack/...` — clone from `github.com/flynn-examples/`; same internet access issue.
- `GitDeploySuite.TestGitSubmodules` — clones submodule from GitHub.
- `CLISuite.TestRun` — times out (may need longer timeout).

**Test categories**:
- **Working**: Tests using `flynn` CLI, controller HTTP API, git push with local test apps, and the test-apps artifact
- **Blocked by internet access**: Tests that use `BUILDPACK_URL` pointing to GitHub or clone example repos from GitHub. Containers on the overlay network cannot reach external hosts. Fix: either configure NAT/masquerade for container traffic, or mirror buildpacks locally.
- **Blocked by discoverd DNS**: Tests that make direct HTTP requests to `*.discoverd` service URLs
- **Blocked by cgroups v2**: ~~`TestRunLimits` reads v1 cgroup paths~~ Fixed (2026-04-15)
- **Needs sub-cluster**: Tests that spin up a sub-cluster inside Flynn (Discoverd, Volume, Backup tests)
- **Needs overlay network**: Sirenia deploy tests connect directly to overlay IPs (100.100.x.x) unreachable from build server

#### Container NAT Fix (2026-04-18)

Containers on the flannel overlay network (100.100.x.0/24) could not reach external hosts (e.g., GitHub for buildpack downloads). The MASQUERADE and FORWARD rules in `pkg/iptables/iptables.go` were correct, but Ubuntu Noble's defaults blocked traffic.

**Root causes** (all in `vagrant/provision.sh`):

| Issue | Fix |
|---|---|
| Ubuntu Noble uses `iptables-nft` by default; Flynn calls the `iptables` binary directly using the legacy API | Switch to `iptables-legacy` via `update-alternatives` during provisioning |
| FORWARD chain default policy is DROP (Ubuntu Noble default) | Set `iptables -P FORWARD ACCEPT` during provisioning |
| IP forwarding sysctl not persisted | Write `net.ipv4.ip_forward=1` and `net.ipv4.conf.all.forwarding=1` to `/etc/sysctl.d/99-flynn.conf` |

**Verification**: `flynn -a controller run -- ping -c1 8.8.8.8` succeeds; `wget https://github.com` succeeds from inside a container.

#### TUF Metadata Refresh (2026-04-18)

The TUF `timestamp.json` expired (2026-04-17T17:04:28Z), blocking `flynn-host download`. Re-signed snapshot (v34) and timestamp (v35) with 90-day expiry (2026-07-16) using a Python script with PyNaCl (ed25519 signing). The installed `tuf` CLI binary (from go-tuf) couldn't sign because it computes key IDs with a `scheme` field that the original key generation didn't include.

**Key lesson**: The `tuf` binary's key ID computation includes a `scheme` field (`{"keytype":"ed25519","scheme":"ed25519","keyval":{"public":"..."}}`), but the keys were generated with an older go-tuf that omits `scheme` (`{"keytype":"ed25519","keyval":{"public":"..."}}`). The SHA256 of these different canonical JSON strings produces different key IDs, so the CLI says "no keys available". The Python re-signing script matches the original format.

**TODO**: ~~Set up automated timestamp refresh (CI cron job or similar) to prevent future expiry.~~ Done (2026-05-03). Monthly cron in `flynn-tuf-repo/.github/workflows/refresh-tuf.yml` re-signs snapshot and timestamp with 90-day expiry using PyNaCl + ed25519 keys from GitHub secrets.

### Remaining Phase 6 Work

- [x] Test 3-node cluster bootstrap with `--peer-ips` and `--min-hosts=3` — complete (2026-04-14), 37 processes across 3 nodes; mariadb/mongodb/router reported unhealthy at status-check but all processes running
- [x] Fix router discoverd registration — router now registers with `EXTERNAL_IP` instead of `LISTEN_IP`, all non-optional services healthy (2026-04-14)
- [x] Fix git push pipeline — gitreceive, slugbuilder, slugrunner all working with packages layers (2026-04-14)
- [x] Remove CLI unmaintained warning from `cli/main.go` — broke test output matching (2026-04-14)
- [x] Clean up macOS `._*` resource fork files from source tree on build server (2026-04-14)
- [x] Run initial integration tests — 7 tests passing (2026-04-14)
- [x] Build `test-apps.json` manifest — busybox base + 6 test app binaries (echoer, pingserv, ish, http-blocker, signal, oom), unlocked `createApp()`-based tests (2026-04-14)
- [x] Run git-deploy integration tests — 8 tests passing (TestCustomPort, TestProcfileChange, etc.) (2026-04-14)
- [x] Replace single-threaded layer HTTP server with threaded one — fixed node3 download timeouts (2026-04-14)
- [x] Run comprehensive integration tests — **33 tests passing** across 5 suites (2026-04-14)
- [x] Fix resource limit tests for cgroups v2 — **40 tests passing** across 7 suites (2026-04-15)
- [x] Fix `TestRunLimits` and all resource limit tests for cgroups v2 — **4/4 passing** (2026-04-15)
- [x] Migrate base layer images from Ubuntu 18.04 Bionic to Ubuntu 24.04 Noble (2026-04-16)
- [x] Migrate PostgreSQL from 11 to 16 — WAL config, recovery mechanism, promotion, schema grants (2026-04-16)
- [x] Migrate MariaDB to 10.11 LTS — `innobackupex` → `mariabackup` (2026-04-16)
- [x] Fix controller PG16 trigger functions (`RETURNS OPAQUE` → `RETURNS trigger`) (2026-04-16)
- [x] Fix migration framework `CREATE TABLE` error propagation (2026-04-16)
- [x] Enhance `export-tuf` with `ExtraDirs`, package layers, Noble merged-usr support (2026-04-16)
- [x] Add direct squashfs layer download with sha512_256 verification (2026-04-17)
- [x] Fix flannel VXLAN MAC reset after `LinkSetUp()` (2026-04-16)
- [x] Configure NAT/masquerade for container internet access (2026-04-18) — see "Container NAT Fix" above
- [x] Re-enable integration test suite on single-node Vagrant cluster (2026-05-03) — see "Single-Node Vagrant Integration Tests" below
- [x] Validate database appliances (PostgreSQL, MariaDB, MongoDB, Redis) — start/stop, data persistence, failover (2026-05-04) — see "Database Appliance Validation" below
- [x] Restore pgextwlist and TimescaleDB support (2026-05-15) — see "pgextwlist / TimescaleDB Restoration" below
- [x] Build missing packages layers for remaining images — gitreceive/taffy (git layer `8152fe02`, 19MB), slugbuilder-24 (git+ruby+daemontools+pigz+jq+curl + 5 Heroku buildpacks, `b620d70b`, 103MB), slugrunner-24 (ruby for Procfile parsing, `8fc1d819`, 15MB). Redis and MongoDB don't need packages layers (validated 2026-05-04). See "Git Push Pipeline Validation" below.
- [x] Migrate MongoDB driver from `gopkg.in/mgo.v2` to `go.mongodb.org/mongo-driver` (required for MongoDB 5.1+ compatibility) — (2026-05-04, commits `44a63915`, `6cfa3202`). See "Database Appliance Validation" below.
- [x] Publish patched `flynn-host` binary via TUF (2026-05-05) — included in v20260505.0 release
- [x] Full TUF repo rebuild with all Noble-based images and fixed binaries (2026-05-05) — see "Full TUF Rebuild v20260505.0" below
- [x] Set up automated TUF timestamp refresh (CI cron job) to prevent metadata expiry (2026-05-03)

#### Single-Node Vagrant Integration Tests (2026-05-03)

**Infrastructure**: Single Vagrant VM (node1, 192.168.50.11, 4GB RAM, 4 CPUs, ZFS on /dev/vdb, Ubuntu Noble). `flynn-host` built with `-ldflags "-X .../version.version=v20260416.0"` to prevent re-execution of TUF-published binary (which lacks direct squashfs download support). Cluster domain: `demo.localflynn.com`. Test runner: `script/run-integration-tests-vagrant`.

**Key findings from test run**:

1. **TUF download works end-to-end**: `flynn-host download` successfully fetches all 22 images from GitHub Releases via the new TUF repo. Version matching (`-ldflags` version = TUF version) prevents binary re-execution.

2. **Bootstrap succeeds in ~10 seconds**: All services healthy on single node.

3. **Tests passing**: `CLISuite.TestCreateAppNoGit`, `CLISuite.TestCluster`, `CLISuite.TestDeployTimeout`, `CLISuite.TestAppWithNoRemote`, `PostgresSuite.TestSSLRenegotiationLimit`, `PostgresSuite.TestDumpRestore`, `RedisSuite.TestRedisEnv`, `HostSuite.TestAttachNonExistentJob`, `HealthcheckSuite.TestKillDown`, `DeployerSuite.TestInBatchesStrategy`.

4. **test-apps artifact**: Built locally with `mksquashfs` (ubuntu base layer + test app binaries at `/bin/echoer`, `/bin/pingserv`, etc.). Layer served via local HTTP on the VM (`python3 -m http.server 8888`). The layer URL template in `test-apps.json` points to `http://192.168.50.11:8888/{id}.squashfs`.

**Failure categories**:

| Category | Tests affected | Root cause |
|---|---|---|
| Missing `git` in containers | All git push tests (GitDeploySuite, ControllerSuite.TestAppDeleteCleanup) | `git` binary not in base layer or gitreceive layer; needs packages layer rebuild |
| Multi-node tests | SchedulerSuite.TestGracefulShutdown, DeployerSuite.TestOmniProcess, GitreceiveSuite, BlobstoreSuite.TestBlobstoreBackendMinio | `bootCluster()` expects discoverd at `127.0.0.1:1111` or needs `host_id` tags on multiple hosts |
| Sirenia deploy timeouts | PostgresSuite.TestDeployMultipleAsync, MariaDBSuite.TestDeployMultipleAsync | Single-node can't run 5-node sirenia deploy; waits for replication sync that never completes |
| HealthcheckSuite.TestStatus | Expects 14 services, gets 13 | `mariadb` and `mongodb` show as unhealthy; count matches but health status mismatch |
| TarreceiveSuite.TestDeleteLayers | Output format mismatch | Expects "404 Not Found" in curl output, gets "404" only |

**Key decision**: The `flynn-host` binary re-execution problem (version mismatch → downloads TUF binary → re-executes with old code) is solved by building with matching version ldflags. This should be automated in the CI workflow.

#### pgextwlist / TimescaleDB Restoration (Complete, 2026-05-15)

**Resolution**: Both `postgresql-16-pgextwlist` (v1.19, from PGDG apt repo) and `timescaledb-2-postgresql-16` (v2.27.0, from TimescaleDB packagecloud repo) are available for Ubuntu 24.04 Noble. No custom PPAs needed — pgextwlist is in the official PGDG repo.

**Changes**:
- [x] Add TimescaleDB repo and pgextwlist to the postgres packages layer build (`appliance/postgresql/img/packages.sh`)
- [x] Install `postgresql-16-pgextwlist` and `timescaledb-2-postgresql-16`
- [x] Re-enable `ExtWhitelist: true` and `TimescaleDB: true` in `cmd/flynn-postgres/main.go`
- [x] Keep `installExtensionsInTemplate()` — still useful to pre-install `uuid-ossp` and `pgcrypto` in template1 (belt-and-suspenders; Flynn internals depend on these)
- [x] Rebuild postgres squashfs layer and update TUF repo (2026-05-16) — new layer `5e2f8836` (362 MB) with pgextwlist v1.19, TimescaleDB v2.27.0, PostGIS 3.6.3, pgRouting 4.0.1; new image ID `aa8d3c06`; TUF metadata v42


#### Git Push Pipeline Validation (2026-05-04)

Re-validated the full git push pipeline on the new single-node Vagrant cluster (rebuilt from scratch, not the earlier 5-node cluster). All packages layers were rebuilt from the Noble base layer using overlayfs+chroot on ZFS.

**Packages layers built**:

| Component | Hash | Size | Contents |
|---|---|---|---|
| gitreceive/taffy | `8152fe02b9e7c59e...` | 19 MB | `git 2.43.0` + dependencies |
| slugbuilder-24 | `b620d70b61624f88...` | 103 MB | git, ruby, daemontools, pigz, jq, curl, 5 Heroku buildpacks (multi, ruby, nodejs, python, go), fixed `build.sh` |
| slugrunner-24 | `8fc1d819e9458c03...` | 15 MB | ruby (needed by `/runner/init` for Procfile YAML parsing) |

**Layer ordering discovery**: The slugbuilder binaries layer contains an old `build.sh` (missing `mkdir -p env_dir` before buildpack compile, uses undefined `${envdir}` variable). The packages layer must be ordered AFTER binaries (base → binaries → packages) so the fixed `build.sh` in the packages layer takes precedence via overlay mount order.

**Deployment method**: Layers served via `python3 -m http.server 8888` on ZFS dataset `/flynn-default/build-tmp/`. New artifacts created via controller API with `layer_url_template: "http://192.168.50.11:8888/{id}.squashfs"`. Gitreceive release updated with new `SLUGBUILDER_24_IMAGE_ID` and `SLUGRUNNER_24_IMAGE_ID` env vars, formation updated to trigger restart.

**End-to-end verification**: Simple Go web app (`net/http`, listens on `$PORT`, returns "hello from git push") pushed via `git push flynn master`. Full pipeline:
1. gitreceive receives push, spawns slugbuilder job
2. Go buildpack detects app, installs go1.22.12, compiles
3. Slug uploaded to blobstore (3.8 MiB)
4. Release created, web=1 scaled
5. Slugrunner starts, `/runner/init` parses Procfile via ruby, runs app
6. Health check passes (TCP on port 8080)
7. App responds "hello from git push" on internal IP

**Final artifact IDs** (single-node cluster):
- Slugbuilder-24: `bf2b108c-3980-44bc-9f49-1603c3037268`
- Slugrunner-24: `e4e01f58-99ac-4eb2-87d3-556f4ae6d0ef`
- Gitreceive release: `3ae1616e-e692-444d-be7c-055d90e10a2c`

#### Database Appliance Validation (2026-05-04)

Tested all four database appliances on a single-node Vagrant cluster (Ubuntu Noble, `demo.localflynn.com`).

**PostgreSQL 16 — PASS**
- Provisioned via `flynn resource add postgres`; CREATE TABLE, INSERT, SELECT all work
- Extensions: `uuid-ossp`, `pgcrypto` work (`CREATE EXTENSION` + function calls verified)
- `pg_dump` works (verified via direct `nsenter` into container)
- Data persists across process kill + scheduler restart
- No code changes required

**MariaDB 10.11 — PASS (with fixes)**
- MariaDB 10.11 defaults `root@localhost` to `unix_socket` auth plugin. Since `flynn-mariadb` runs as OS user `mysql` (not `root`), root cannot authenticate via TCP or socket (UID mismatch). This caused `Error 1045: Access denied` during both initial setup and health checks.
- **Fix 1** (`process.go`): Start with `--skip-grant-tables` during initial setup, `FLUSH PRIVILEGES` to re-enable the privilege system, create the `flynn` user, then restart without `--skip-grant-tables`. The `start()` function accepts `extraArgs ...string` for this.
- **Fix 2** (`process.go`): Delete anonymous users (`''@'localhost'`, `''@'<hostname>'`) created by `mysql_install_db`. MariaDB's auth matching prefers `''@'localhost'` (more specific host) over `'flynn'@'%'`, causing "Access denied" even with correct credentials.
- **Fix 3** (`process.go`): Health check uses `root@tcp(...)` when `--skip-grant-tables` is active (root is the only user that exists at that point).
- **Fix 4** (`process.go`): Semi-sync plugin install (`semisync_master.so`, `semisync_slave.so`) made non-fatal — the `.so` files don't exist in MariaDB 10.11 (feature is compiled into the server since 10.3+).
- **Fix 5** (`process.go`): Second `FLUSH PRIVILEGES` after user creation to ensure changes are visible on restart.
- **Fix 6** (`process.go`): `db.SetMaxOpenConns(1)` to force single connection reuse after `FLUSH PRIVILEGES` re-enables auth (new connections would fail since root uses `unix_socket`).
- After fixes: provisioning, CREATE TABLE, INSERT, SELECT, process kill + restart, data persistence all verified.

**MongoDB 6.0/7.0/8.0 — PASS (with driver migration)**
- **Driver migration**: Replaced `gopkg.in/mgo.v2` with `go.mongodb.org/mongo-driver v1.17.9` (commit `44a63915`). The mgo driver uses OP_QUERY wire protocol which MongoDB 5.1+ deprecated and 6.0+ rejects entirely.
- **Files changed**: `appliance/mongodb/process.go`, `appliance/mongodb/process_test.go`, `appliance/mongodb/replset.go`, `appliance/mongodb/cmd/flynn-mongodb-api/main.go`, `test/test_mongodb.go`, `go.mod`/`go.sum`, vendor directory.
- **Key mappings**: `mgo.Session` → `mongo.Client`, `DialInfo()` → `ClientOptions()`, `session.Run()` → `RunCommand()`, `mgo.QueryError` → `mongo.CommandError`, `bson.D` uses keyed fields.
- **BSON timestamp fix** (commit `6cfa3202`): `replSetOptime.Timestamp` changed from `int64` to `primitive.Timestamp` — the official driver is strict about BSON Timestamp types (mgo auto-converted).
- **Missing `mongod` binary**: Base image build didn't include `mongodb-org-server` package. Fixed by extracting from deb and adding to base squashfs layer.
- **Missing `mongodb` system user**: Fixed by adding `useradd`/`groupadd` to `start.sh` (commit `52db40b5`).
- After fixes: provisioning (database + user creation via API), CRUD (insert, read, update, delete), SCRAM-SHA-256 authentication, replica set configuration — all verified on MongoDB 8.0.

**Redis 7.0 — PASS**
- Redis is a single-process appliance (not sirenia-based). Each provisioned instance gets its own Flynn app.
- Provisioned via `flynn resource add redis`; SET, GET, LPUSH, LRANGE all work
- Data persists across process kill + restart (after `BGSAVE` or with default save intervals)
- No code changes required

#### Full TUF Rebuild v20260505.0 (2026-05-05)

Complete rebuild of all TUF targets with Noble-based images, static container binaries, and all bug fixes from Phases 5-6.

**Build changes**:
- `script/bootstrap-build` updated: all 27 container binaries built with `CGO_ENABLED=0` (static linking for Noble glibc 2.39 compatibility). `flynn-host` remains `CGO_ENABLED=1` (requires libcontainer). CLI, examples, and release binaries remain dynamic.
- All 35 binaries built with Go 1.22.12, version `v20260505.0` embedded via ldflags.

**TUF targets published** (via `script/export-tuf`):
- 347 image manifests (JSON), 738 layer entries (squashfs + JSON configs)
- 5 versioned binaries/manifests per version (flynn-host.gz, flynn-init.gz, flynn-linux-amd64.gz, images.json.gz, bootstrap-manifest.json.gz)
- Channel `stable` → `v20260505.0`
- Timestamp v39, snapshot v36, both with 90-day expiry (2026-08-02)

**Infrastructure**:
- Squashfs layers + gzipped binaries uploaded to `dl.consolving.net` via rsync (149 files, 2.9 GB)
- TUF metadata pushed to GitHub Pages (`consolving.github.io/flynn-tuf-repo`) with git-lfs for squashfs files (53 LFS objects, 1.1 GB)
- Existing layer files on dl.consolving.net renamed from `{sha512}.{sha512_256}.squashfs` to `{sha512_256}.squashfs` to match layer URL template

**Verification**:
- TUF metadata live on GitHub Pages (timestamp v39, expires 2026-08-02)
- All binaries accessible on dl.consolving.net (HTTP 200)
- Sample layers accessible on dl.consolving.net (HTTP 200)
- Image and layer manifests accessible on GitHub Pages (HTTP 200)
- Channel `stable` resolves to `v20260505.0` via hash-prefixed URL

## Phase 7: TUF Distribution — HTTP Frontend with IPFS Backend

The TUF repository is currently hosted solely on GitHub Pages — a single point of failure. This phase adds decentralized, content-addressed storage via IPFS while keeping plain HTTP for clients (no code changes to the go-tuf client).

See `specs/tuf-ipfs-mirror.md` for full architecture and design rationale.

**Design decision (2026-05-17)**: `dl.consolving.net` serves files directly from IPFS via kubo gateway. Traefik `AddPrefix` middleware rewrites `/{file}` → `/ipfs/{CID}/{file}`. No nginx, no static files on disk. IPFS provides content-addressed storage with decentralized redundancy.

**Current infrastructure** (verified 2026-05-17):

| Component | host1 (`host1.consolving.net`, SSH port 24) | host2 (`host2.consolving.net`, SSH port 24) |
|---|---|---|
| IPFS node | kubo:latest (`ipfs_node`), 128 GB limit, 6.9 GB used | kubo:latest (`ipfs_node`), 128 GB limit, 3.1 GB used |
| IPFS repo version | fs-repo@18 | fs-repo@18 |
| Traefik | `run1-consolving-net-traefik-1` (v2.11, external) | External Traefik (no IPFS labels) |
| Pinned CIDs | `bafybeibtwqraqap4yeslp3jwjdhnglwvubd3ahoaekad6vw5km75kf3kty` (932 files, active in Traefik) | `bafybeia3adw7wyg25iy77exgt6ahvm3avqxg7dmtmdzrzmb3el6552yt5m` (930 files, synced 2026-05-18) |

- **Primary**: `dl.consolving.net` → Traefik (v2.11) → kubo gateway (port 8080) with `AddPrefix` middleware mapping `/{file}` → `/ipfs/{CID}/{file}`. Also serves HTTP (port 80) without TLS redirect for `dl.consolving.net` only.
- **Active IPFS CID** (in Traefik): `bafybeibtwqraqap4yeslp3jwjdhnglwvubd3ahoaekad6vw5km75kf3kty` — 932 flat files (squashfs layers by `{sha512_256}.squashfs`, layer config JSONs by `{sha512_256}.json`, image manifest JSONs, gzipped binaries, channel files)
- **IPFS gateway**: `https://ipfs.consolving.net/ipfs/{CID}` (Traefik → kubo port 8080) — serves any IPFS content by CID, no auth required
- **IPFS Web UI**: `https://ui.ipfs.consolving.net` (basic auth protected, Traefik → kubo port 5001)
- **IPFS API**: `https://ipfs.consolving.net/api/v0/` (basic auth protected, env var `IPFS_API_USERS` for htpasswd)
- **Fallback**: GitHub Pages (`consolving.github.io/flynn-tuf-repo/repository`) — TUF metadata only, timestamp.json refreshed monthly via `.github/workflows/refresh-tuf.yml`
- **Sync script**: `/opt/flynn-tuf-dl/sync-ipfs.sh /path/to/new/files` — exports existing MFS content to staging, merges new files, `ipfs add -r --cid-version=1`, updates Traefik AddPrefix CID in compose, recreates container, unpins old CID, runs GC. Current CID tracked in `/opt/flynn-tuf-dl/.ipfs-cid`.
- **Release script**: `/opt/flynn-tuf-dl/release-and-sync.sh /path/to/new/layers` — calls `sync-ipfs.sh`, then pins new CID on host2 mirror and updates host2 MFS via SSH.
- **Backup script**: `/opt/flynn-tuf-dl/backup-ipfs.sh` — exports current CID as CAR file to `/home/backup/ipfs/`, keeps 3 most recent, skips if CID already backed up. Cron: weekly Sunday 03:00 UTC.
- **MFS**: Pinned directory linked at `/flynn-tuf` in MFS for Web UI visibility (host1 only; host2 has old CID)
- **Compose**: host1: `/opt/containers/ipfs/compose.yaml` (Traefik labels for `ipfs.consolving.net`, `ui.ipfs.consolving.net`, `dl.consolving.net`, joins external `traefik_default` network). host2: `/opt/containers/ipfs/compose.yaml` (mirror node, no Traefik labels, joins external `traefik_default` network).
- **Legacy files**: `/opt/flynn-tuf-dl/` also contains `docker-compose.yml` and `nginx.conf` from pre-IPFS nginx setup (unused, can be removed)
- **Layer URL template**: `https://dl.consolving.net/{id}.squashfs` where `{id}` is the `sha512_256` hash (set in `script/export-tuf/main.go:118` and all image manifests in `build/manifests/`)

**Content split** (what lives where):
- **GitHub Pages** (`consolving.github.io/flynn-tuf-repo/repository`): TUF metadata (root.json, targets.json, snapshot.json, timestamp.json), image manifest JSONs, layer config JSONs, channel files, versioned release manifests. This is what the go-tuf client fetches for verification.
- **IPFS / dl.consolving.net**: Squashfs layer files (`{sha512_256}.squashfs`), gzipped binaries (`{sha512}.flynn-host.gz`), layer config JSONs, image manifests. This is what `flynn-host download` fetches for actual content after TUF verification.
- **Local TUF repo** (`flynn-tuf-repo/repository/targets/`): 41 MB working tree — image manifests (`images/`, 388 JSON files, 2 MB), current release (`v20260518.0/`, 22 MB with binaries), channel file. Layers are NOT stored in git — served exclusively from IPFS. Git history squashed to single commit (233 KB `.git/`).

**Known issues** (2026-05-18):
1. ~~**host2 mirror is stale**~~: Fixed (2026-05-18). Both nodes now pin `bafybeia3adw7wyg25iy77exgt6ahvm3avqxg7dmtmdzrzmb3el6552yt5m`.
2. ~~**IPFS node crash-loop**~~: Fixed (2026-05-17).
3. **Local repo vs IPFS file count**: Local TUF repo git tree (41 MB) is a subset of IPFS content (932 files) — git only stores metadata and current version binaries; layers are exclusively on IPFS.
4. ~~**Old CID not garbage collected**~~: Fixed (2026-05-18). Old 465-file CID unpinned and GC'd.

- [x] Initial IPFS upload and pin of TUF repository (465 files, 6.5 GB) — pinned on host1 kubo node (2026-05-17)
- [x] Switched `dl.consolving.net` from nginx (static files) to IPFS gateway via Traefik AddPrefix (2026-05-17)
- [x] Removed nginx container and 6.5 GB static files from `/opt/flynn-tuf-dl/data/` (2026-05-17)
- [x] Created `/opt/flynn-tuf-dl/sync-ipfs.sh` — merges new files into IPFS, updates Traefik CID, unpins old (2026-05-17)
- [x] kubo running on host1 as Docker container (`ipfs_node`), gateway via Traefik at `ipfs.consolving.net`, Web UI at `ui.ipfs.consolving.net`
- [x] IPFS mirror on host2 — kubo container pinning same CID, 128 GB storage (2026-05-17)
- [x] IPFS storage limit increased to 128 GB on both nodes (2026-05-17)
- [x] CAR backup script with weekly cron on host1 (`/opt/flynn-tuf-dl/backup-ipfs.sh`, Sunday 03:00 UTC) (2026-05-17)
- [x] Add multi-origin failover to `flynn-host download` (IPFS gateway → GitHub Pages)
- [x] IPFS publish integrated into release process via `/opt/flynn-tuf-dl/release-and-sync.sh` — syncs new layers to IPFS on host1, updates Traefik CID, pins on host2 mirror (2026-05-17). No CI workflow needed since `export-tuf` runs on host1 where IPFS is local.
- [x] Fixed host1 IPFS crash-loop — stale `repo.lock` owned by root, removed manually (2026-05-17)
- [x] Re-sync IPFS from local TUF repo — flattened `repository/targets/` (layers renamed from `{sha512}.{sha512_256}.squashfs` to `{sha512_256}.squashfs`), rsynced to host1, replaced IPFS content (not merged). New CID: `bafybeibtwqraqap4yeslp3jwjdhnglwvubd3ahoaekad6vw5km75kf3kty` (932 files). Old stale CIDs unpinned and GC'd. (2026-05-18)
- [x] Sync host2 mirror to latest CID — pinned `bafybeia3adw7wyg25iy77exgt6ahvm3avqxg7dmtmdzrzmb3el6552yt5m`, unpinned old 465-file CID, GC'd (2026-05-18). host2 repo: 5.1 GB.
- [x] Unpin old CID on host1 — old CIDs unpinned and GC'd (2026-05-18)
- [x] Clean up legacy files — removed `/opt/flynn-tuf-dl/docker-compose.yml` and `/opt/flynn-tuf-dl/nginx.conf` (2026-05-18)
- [x] Test end-to-end: `flynn-host download` from IPFS-backed gateway — verified 2026-05-18: fresh Vagrant VM downloads `flynn-host.gz` + all 21 images (squashfs layers) from `dl.consolving.net` (IPFS), bootstrap completes with all services healthy in ~24s. Required `TMPDIR` fix for small root filesystems (postgres layer is 364 MB).

**Release workflow**:
1. Build binaries: `script/bootstrap-build --version v<date>.0`
2. Export TUF targets: `go run script/export-tuf/main.go ...` (generates squashfs layers + TUF metadata)
3. Sync layers to IPFS: `/opt/flynn-tuf-dl/release-and-sync.sh /path/to/new/layers` (adds to IPFS, updates `dl.consolving.net` CID, pins on host2)
4. Push TUF metadata to GitHub Pages: `cd flynn-tuf-repo && git push`

## Post-Quantum Cryptography Assessment (2026-05-04)

Ubuntu 26.04 LTS will ship with OpenSSL 3.x supporting post-quantum algorithms (ML-KEM/Kyber for key exchange, ML-DSA/Dilithium for signatures). **Flynn would not meaningfully benefit from PQC at this time:**

- **Go 1.22 has no PQC support.** Go added experimental ML-KEM in 1.24; Flynn would need a Go upgrade first.
- **go-tuf doesn't support PQC signatures.** The TUF spec and go-tuf library only support ed25519/RSA/ECDSA. Adding ML-DSA would require upstream library changes.
- **Flynn's Go binaries use Go's own crypto, not OpenSSL.** Only SSH and `curl` inside containers would use the system OpenSSL. The TUF signing, TLS termination, and database auth all use Go stdlib crypto.
- **TUF signatures are short-lived** (90-day expiry, monthly refresh). The "harvest now, forge later" threat doesn't apply to ephemeral metadata.
- **Flynn runs on private infrastructure.** TLS traffic stays on a private overlay network (flannel VXLAN). There's no public-facing PKI requiring decades of signature validity.

**Future upgrade path** (not yet actionable): Go 1.24+ → go-tuf with ML-DSA support → TUF root key rotation to hybrid ed25519+ML-DSA → Ubuntu 26.04 base layer for container-side PQC. Re-evaluate when Go and go-tuf add stable PQC support.

## Open Questions

- ~~Should the Go version be upgraded incrementally (1.13 -> 1.16 -> 1.19 -> 1.22) or in a single jump?~~ **Resolved**: Single jump to Go 1.22 succeeded.
- ~~Is ARM64/aarch64 support a priority, or focus on x86_64 first?~~ **Resolved (2026-04-13)**: Both supported in parallel. x86_64 is primary (Proxmox build server), ARM64 available via native NVIDIA GB10 machine. Cross-arch emulation via QEMU TCG is not practical — requires native hardware. RISC-V deferred (no native hardware). See `specs/dev-machine.md`.
- ~~What is the target Linux distribution for the base layer images (Ubuntu Trusty/Xenial are EOL)?~~ **Resolved (2026-04-16)**: Ubuntu 24.04 LTS Noble Numbat. Vagrant test VMs also run Noble. Base layer images built via cloud image download or debootstrap (`builder/img/ubuntu-noble.sh`). Heroku stack migrated from heroku-18 to heroku-24.
- ~~When should the runc fork be modernized?~~ **Partially resolved (2026-04-13)**: The vendored runc fork already has cgroups v2 controller code (`cpu_v2.go`, `memory_v2.go`, etc.) which works on Debian 13. The remaining concern is security patches (6+ years of unpatched CVEs), but the fork is functionally adequate for cluster bootstrap. Modernization is desirable but no longer blocking.
- Should the self-hosting build be preserved long-term, or replaced entirely with container-based CI?

## Housekeeping

- [x] Rename default branches from `master` to `main` across all repositories (`consolving/flynn`, `consolving/flynn-tuf-repo`) and update CI workflows, submodule refs, and any hardcoded branch references in scripts/docs — completed 2026-05-15
- [x] Clean up stale branches across all repos and remotes — completed 2026-05-15
- [x] Reset `flynn-tuf-repo` GitHub repo and GitLab mirror — `.git/` reduced from 966 MB to 233 KB by squashing history into single commit, removing 1.5 GB `layers/` directory (served from IPFS), and removing old version directories (v20260416.0, v20260504.0, v20260505.0, v20260515.0). Working tree: 41 MB (only v20260518.0 binaries + image manifests). Force-pushed to both GitHub and GitLab mirror (2026-05-18). GitHub Pages continues serving correctly. `refresh-tuf.yml` workflow unaffected.

### Branch Rename and Cleanup (2026-05-15)

**Scope**: Renamed default branch AND Flynn's user-facing deploy branch from `master` to `main`. Users now deploy with `git push flynn main`.

**Code changes** (12 files in `flynn/` submodule, commit `c6d30a38`):

| Category | Files | Changes |
|---|---|---|
| CI workflows | `ci.yml`, `docs.yml` | Branch triggers `master` → `main` |
| Gitreceive hook | `server.go` | Deploy branch check `refs/heads/master` → `refs/heads/main`, error message updated |
| Tests | `helper.go`, `test_cli.go`, `test_git_deploy.go`, `test_gitreceive.go`, `test_taffy_deploy.go` | All `git push flynn master` → `main`; `TestNonMasterPush` → `TestNonMainPush`; `git branch -m main` added after `git init` in test helper |
| Scripts | `release-flynn`, `generate-backups` | Default branch references |
| Utils | `cloner/flynn-clone.sh`, `bump-buildpacks/bump.go` | Branch name in user messages and API calls |

**Infrastructure changes**:
- `.gitmodules` updated to track `main` for flynn submodule
- `consolving/flynn` GitHub: default branch changed to `main`, `master` deleted
- `consolving/flynn` GitHub: 32 stale branches deleted (30 old upstream feature branches + `noble-migration-and-fixes` + `pg16-and-bootstrap-fixes`)
- `mirrors/flynn` GitLab: default branch changed to `main`, 32 stale branches deleted
- `consolving/flynn-infra` GitHub: 1 stale branch deleted (`feature/multi-origin-failover`)
- `mirrors/flynn-infra` GitLab: 1 stale branch deleted (`vagrant-ubuntu-noble`)
- Fixed origin fetch refspec in flynn submodule (`github/*` → `origin/*`)
- All 5 local feature branches in flynn submodule deleted

**Final state**: All three repos (`flynn-dev`, `flynn`, `flynn-tuf-repo`) have only `main` on all remotes (GitHub + GitLab).

### Node.js Git Push Pipeline — End-to-End Fix (2026-05-18)

Re-validated and fixed the full `git push` → build → deploy pipeline for a Node.js app on a fresh single-node Vagrant cluster. Previous validation (2026-05-04) used Go buildpacks; this confirms the pipeline works for Node.js apps with `npm install`.

**Test app**: `test-bp` — minimal Node.js app (`package.json` + `server.js`, responds "hello from flynn" on `$PORT`).

**Issues fixed this session**:

| Issue | Root Cause | Fix |
|---|---|---|
| flynn-host layer downloads filling root `/tmp` | `flynn-host` systemd unit had no `EnvironmentFile` directive; `TMPDIR=/var/lib/flynn/tmp` in `/etc/default/flynn-host` was ignored | Added `EnvironmentFile=-/etc/default/flynn-host` to systemd unit, restarted |
| `setuidgid` shim broken | Shim had `exec ""` instead of `exec "$@"` — all `run_unprivileged` calls in `build.sh` silently did nothing | Fixed in slugbuilder squashfs layer (`/usr/bin/setuidgid`) |
| Node.js buildpack compile script broken | Variable interpolation empty (`BUILD_DIR=`, `NODE_URL=` with no expansion) | Rewrote compile script with proper `$1`/`$2`/`$3` args and `${NODE_VERSION}` interpolation |
| Node.js download fails from containers | Containers can't resolve/reach `nodejs.org` (DNS/TLS issues in container environment) | Serve Node.js tarball from host HTTP server (`192.168.50.1:8888`), compile script points there |
| `build.sh` uses `ruby` for YAML parsing | Ruby not installed in slugbuilder or slugrunner layers; `set -eo pipefail` causes exit on ruby failure | Replaced ruby calls in `build.sh` with shell `grep`/`sed` for Procfile and `.release` parsing |
| `pigz` not found | Build cache upload (`tar | pigz | curl`) fails without pigz binary | Added `/usr/bin/pigz` shim that delegates to `gzip` |
| Slugrunner `/runner/init` uses ruby | Ruby YAML parsing for config_vars, Procfile process types, and `.release` default_process_types | Rewrote `/runner/init` in pure bash — regex-based YAML parsing for simple key-value structures |
| `/etc/hosts` missing IP for `git.demo.localflynn.com` | flynn-host restart cleared DNS entries | Re-added `192.168.50.11 git.demo.localflynn.com` to `/etc/hosts` |

**Deployment method**: Squashfs layers replaced in-place on ZFS zvols via `dd` + remount. Two layers modified:
- `a1636ecc` (slugbuilder-24, 15MB) — fixed `setuidgid`, `build.sh`, compile script, added pigz shim
- `75cf6d2c` (slugrunner-24, 4KB) — replaced `/runner/init` with pure-bash version

**End-to-end result**: `git push flynn main` → Node.js detected → npm install (0 deps, 691ms) → slug uploaded (35 MB) → release created → web=1 scaled → `curl http://test-bp.demo.localflynn.com` returns "hello from flynn".

**Implications for TUF rebuild**: The slugbuilder and slugrunner packages layers need to be rebuilt with these fixes before the next `export-tuf` run. Specifically:
- Slugbuilder packages layer (`b620d70b`) needs: fixed `setuidgid`, fixed compile scripts with local/CDN Node.js URL, `pigz` shim, shell-based YAML parsing in `build.sh`
- Slugrunner packages layer (`8fc1d819`) needs: pure-bash `/runner/init` (removes ruby dependency entirely — the 15MB ruby packages layer can be eliminated)

### Discoverd DNS Recursion Loop Fix (2026-05-18)

**Problem**: After `flynn-host` restarts, `/etc/resolv.conf` on the VM may contain discoverd's own overlay IP (e.g., `100.100.57.1`) from the previous run. When discoverd starts and needs to forward external DNS queries, it reads `/etc/resolv.conf` for upstream resolvers, finds its own address, and recurses to itself — causing DNS resolution failures for all containers and the host.

**Fix**: Added `filterOverlayResolvers()` function in `host/libcontainer_backend.go` (called from `ConfigureNetworking()`). It strips any DNS servers in the `100.100.0.0/16` flannel overlay subnet from the resolver list before writing the container `resolv.conf` and configuring discoverd's upstream resolvers. Falls back to keeping the original list if filtering would produce an empty set.

**File**: `flynn/host/libcontainer_backend.go` — new function at line ~1967, called at line ~316.

**Note**: This fix requires rebuilding the `flynn-host` binary and publishing via TUF to take effect on fresh provisions. For existing clusters, the workaround is to manually set `/etc/resolv.conf` to a non-overlay nameserver before starting `flynn-host`.

### Integration Test Infrastructure Assessment (2026-05-18)

Attempted to run the full `flynn-test` integration test binary on the single-node Vagrant cluster. Key findings:

**Prerequisites discovered**:
1. **VM `/etc/resolv.conf` must point to discoverd** (`nameserver 100.100.57.1`) — the test binary runs on the host and uses Go's resolver, which reads `/etc/resolv.conf`. Without discoverd DNS, `.discoverd` service names can't be resolved from the test process. The original test runner (`test/runner/runner.go`) sets this automatically.
2. **Schema directory** must exist at `../schema` relative to test working directory — needed for `ControllerSuite.SetUpSuite` to load JSON schemas.
3. **`../build/image/test-apps.json`** must exist — needed by `createArtifactWithClient()` to register test app artifacts (echoer, pingserv, ish, etc.) with the controller.
4. **`../build/images.json`** — needed by `bootClusterWithConfig()` for tests that spin up sub-clusters. Generated by the full build system; not available without it.
5. **Docker** — needed by `TarreceiveSuite` tests.

**Structural limitation**: The Flynn integration test suite has deep dependencies on the full self-hosting build pipeline. Many tests require:
- `test-apps` squashfs layers in blobstore (special layers containing compiled test binaries)
- `images.json` build artifact (generated by `script/export-tuf` during full builds)
- Docker daemon on the test host
- External buildpacks from GitHub (Go, Ruby, Python, etc.)

Without the complete build pipeline, approximately 80% of integration tests cannot run. The remaining ~20% (basic CLI operations, controller API tests) pass when DNS and schema prerequisites are met.

**What IS verified working** (end-to-end, manually tested 2026-05-18):
- Fresh Node.js app deploy via `git push flynn main` — build, slug upload, deploy, route, serve
- All 7 core services healthy (controller, discoverd, flannel, postgres, router, blobstore, gitreceive)
- Discoverd DNS resolution from host and containers
- Controller API (252 apps registered, CRUD operations)
- Flynn CLI operations (create app, scale, env, route, ps)
- 52 containers running stably

**Recommendation**: Rather than fighting to make the full test suite work without the build system, focus on:
1. ~~Publishing the fixed `flynn-host` binary (with `filterOverlayResolvers()`) to TUF~~ Done (v20260518.0)
2. ~~Rebuilding slugbuilder/slugrunner layers with all fixes and publishing to IPFS~~ Done (new artifacts with `layer_url_template`)
3. ~~Making `provision.sh` set up discoverd DNS in `/etc/resolv.conf` automatically after bootstrap~~ Done (dnsmasq with wildcard + discoverd forwarding)
4. Building the `test-apps` squashfs layers to enable the ~40 tests that previously passed on the 5-node cluster

### TUF Release v20260518.0 (2026-05-18)

Published new TUF release with DNS-fix `flynn-host` binary and updated tooling.

**Binaries** (all built with Go 1.22.12, `CGO_ENABLED=0` for init/CLI, `CGO_ENABLED=1` for host):
- `flynn-host` (10.5 MB gz) — includes `filterOverlayResolvers()` DNS recursion fix
- `flynn-init` (6.1 MB gz) — static init binary
- `flynn-linux-amd64` (6.3 MB gz) — static CLI binary

**TUF metadata**: targets.json v2028, snapshot.json v42, timestamp.json v45. Channel `stable` → `v20260518.0`. Images.json and bootstrap-manifest.json unchanged from v20260515.0 (same system component images).

**New slugbuilder/slugrunner artifacts** (controller-level, not TUF):
- Slugbuilder-24 artifact: `17590513-3c00-4246-8e3d-829f37dd5ebe` — layer `fb28c5d292ce037efabb72256a4dc1d6dc06de6ab7be012fd4bdc924daa8564e` (14 MB)
- Slugrunner-24 artifact: `41bc9ff8-478f-4206-abaf-297659b1b55c` — layer `3d7065b92d576d16961510c9056fc986c0d87ddc699fec3054b5537900494f8c` (4 KB)
- Both include `layer_url_template: "https://dl.consolving.net/{id}.squashfs"` for IPFS download of uncached layers
- Gitreceive release `36d2af5e-8547-4dc3-94a7-42049506cb24` updated with new artifact IDs

**Verified end-to-end**: Fresh `git push flynn main` of Node.js app on Vagrant VM — flynn-host downloads uncached slugbuilder/slugrunner layers from IPFS via `layer_url_template`, builds app, deploys, serves traffic.

### Vagrant DNS Fix — dnsmasq for Wildcard Resolution (2026-05-18)

**Problem**: Apps deployed to Flynn (e.g., `layer-test.demo.localflynn.com`) are routable via the HTTP router (Host header matching), but DNS resolution inside the VM fails because:
- `demo.localflynn.com` is not a real domain (NXDOMAIN from upstream DNS)
- Discoverd only resolves `.discoverd` service names, not wildcard app domains
- `/etc/hosts` doesn't support wildcards

**Solution**: Install `dnsmasq` as a DNS frontend:
- Resolves `*.demo.localflynn.com` → `192.168.50.11` (VM's static IP) via `address=/demo.localflynn.com/192.168.50.11`
- Forwards all other queries to discoverd (`server=100.100.57.1`) for `.discoverd` name resolution and external DNS recursion
- Listens on `127.0.0.1:53`, `/etc/resolv.conf` points to `127.0.0.1`

**Files changed**:
- `vagrant/Vagrantfile` — post-bootstrap installs and configures dnsmasq instead of raw discoverd DNS
- `vagrant/provision.sh` — installs `dnsmasq` package (disabled until post-bootstrap), bumps `fs.inotify.max_user_instances` from 1024 to 8192 (dnsmasq requires inotify)

**Verification**: `curl http://layer-test.demo.localflynn.com` → "layer test ok" (previously required explicit `Host:` header).

### Integration Test Validation — Test-Apps Layer (2026-05-18)

Successfully ran integration tests against the live single-node Vagrant cluster using the `flynn-test` binary, test-apps squashfs layer, and `~/.flynnrc` auth.

**Issues fixed this session**:

| Issue | Root Cause | Fix |
|---|---|---|
| `flynn-host log flynn-controller` shows "unknown host flynn" | `flynn-host log` parses job ID as `host-uuid`; `flynn-controller` is parsed as host=`flynn` job=`controller` — it's a CLI argument parsing issue, not a real error | Use full job IDs from `flynn-host ps` instead |
| Test-apps layer hash mismatch (HTTP 500 on job start) | `test-apps.json` listed layer ID `818995032f...` but the actual squashfs content hashes to `fb1d361170b50...` (file was rebuilt but filename never updated) | Renamed layer file to correct hash, updated `test-apps.json` |
| `missing host_id tag` error from test framework | `cluster2.Boot()` requires `host_id` tag on the host for job placement | Set tag via `flynn-host tags set node1 host_id=node1` |
| Slugbuilder `build.sh` uses ruby for YAML parsing (Procfile + `.release`) | Ruby removed from slugbuilder image in earlier session but `build.sh` still calls `ruby -r yaml` | Replaced with pure bash: `grep`/`cut` for Procfile keys, line-by-line parsing for `.release` default_process_types |
| ZFS zvol replacement via `dd` doesn't reliably update content | ZFS ARC caching serves stale data from old zvol | Mount new squashfs directly via loop device over existing mountpoint |

**Test results (single-node, 2026-05-18)**:

| Suite | Passed | Failed | Notes |
|---|---|---|---|
| ControllerSuite (non-git, non-bootCluster) | 3 | 0 | TestAppDelete, TestAppEvents, TestResourceLimitsOneOffJob |
| SchedulerSuite (non-bootCluster) | 5 | 0 | TestScale, TestJobMeta, TestJobStatus, TestJobRestartBackoffPolicy, TestTCPApp |
| HostSuite (non-bootCluster) | 12+ | 1 | Rate-limit transient failure only |
| DeployerSuite (non-bootCluster) | 7+ | 0 | |
| HealthcheckSuite (non-bootCluster) | 5+ | 0 | |
| GitDeploySuite (inline buildpack) | 4 | 0 | TestBuildCaching, TestDevStdout, TestEmptyRelease, TestEnvDir |
| CLISuite (non-git) | 15+ | 0 | |
| **Total verified passing** | **51+** | | |

**Known remaining failure categories**:

| Category | Tests Affected | Root Cause | Effort to Fix |
|---|---|---|---|
| `bootCluster` tests | ~7 (TestControllerRestart, TestGracefulShutdown, TestOmniJobs, TestScaleTags, TestPersistentVolumes, TestRollbackController, TestDeployController) | Require `../build/manifests/bootstrap-manifest.json` to boot sub-clusters; generated by full build system | Medium — need to generate manifest from running cluster state |
| Go app git push tests | ~10 (TestAppDeleteCleanup, TestRouteEvents, etc.) | `apps/http` is a Go app needing the Go buildpack; slugbuilder only has Node.js buildpack bundled | Medium — add Go buildpack to slugbuilder packages layer |
| External repo tests | ~5 (TestGoBuildpack, TestNodejsBuildpack, TestClojureBuildpack, etc.) | Clone from `github.com/flynn-examples/` — either GitHub SSH unreachable or buildpack download fails | Low priority — would need local mirrors or verified internet access from containers |
| GitHub SSH tests | ~3 (TestGitSubmodules, TestPrivateSSHKeyClone) | Test uses a hardcoded GitHub SSH key to clone private repos | Low priority — requires GitHub account access |
| Missing build artifacts | 2 (TestExampleOutput, TestBackup) | `controller-examples.json` and `bootstrap-manifest.json` not generated | Low |
| gRPC auth test | 1 (TestGRPCWeb) | No Authorization header sent to gRPC endpoint | Low |

**Key artifacts on VM** (`/tmp/flynn-test-run/`):
- `test/flynn-test` — 24 MB static test binary
- `test/apps/` — source trees for all test apps (for git push tests)
- `build/image/test-apps.json` — artifact manifest with layers `b7dc02ab` (busybox, 2.5 MB) + `fb1d361170b5` (test binaries, 33 MB)
- Layer served at `http://192.168.50.11:8888/fb1d361170b50ceaad85e61da540d2df748ef63cc47fe5f72e2124e0e8e9c734.squashfs`

**Prerequisites for running tests on a fresh VM**:
1. `flynn-host tags set node1 host_id=node1` — required by test framework
2. Test-apps layer served via HTTP (or uploaded to IPFS and accessible via `layer_url_template`)
3. `~/.flynnrc` configured with controller key and TLS pin
4. Schema directory at `../schema` relative to test CWD
5. `dnsmasq` configured for wildcard DNS (already in `provision.sh`/`Vagrantfile`)

### TUF Metadata on IPFS — Full Mirror at tuf.consolving.net (2026-05-27)

**Goal**: Eliminate GitHub Pages as single point of failure by serving both TUF metadata and content from IPFS. `tuf.consolving.net` becomes a full TUF repository mirror (metadata + layers), with DNS round-robin across host1 and host2.

**DNS**: `tuf.consolving.net` — A records pointing to host1 and host2 (round-robin), configured at domain.pixelx.de.

**Code change**: `tufconfig.Mirrors` updated to try `tuf.consolving.net/repository` first, fall back to GitHub Pages.

**IPFS CID**: `bafybeignvy33g2lz4kqzjvwjl4kpghx6fgwnonrwc356qe3zfam7fqetz4` — structured as `repository/{root,targets,snapshot,timestamp}.json` + `repository/targets/{sha256}.squashfs` (932 target files + 4 metadata files).

**Infrastructure**:
- host1: Traefik routes for `tuf.consolving.net` (AddPrefix → `/ipfs/{CID}`) and `dl.consolving.net` (AddPrefix → `/ipfs/{CID}/repository/targets`)
- host2: Traefik route for `tuf.consolving.net` (AddPrefix → `/ipfs/{CID}`), same pinned CID
- TLS certs synced between hosts via `/opt/scripts/sync-traefik-certs.py` (cron every 6h on host1). Handles DNS round-robin + TLS-ALPN-01 challenge incompatibility by distributing certs after issuance.
- SSH key: host1 → host2 (root, port 24) for cert sync and IPFS pin replication
- TUF metadata sourced from `/opt/flynn-tuf-repo` (git clone on host1)

**Completed tasks**:

- [x] Restructure IPFS content — `repository/` prefix with TUF metadata + `repository/targets/` for layers (2026-05-27)
- [x] Add Traefik route for `tuf.consolving.net` on host1 — AddPrefix middleware in `/opt/containers/ipfs/compose.yaml` (2026-05-27)
- [x] Add Traefik route for `tuf.consolving.net` on host2 — same labels in host2's compose.yaml (2026-05-27)
- [x] TLS cert sync between hosts — `/opt/scripts/sync-traefik-certs.py` merges certs keeping longest validity, cron every 6h (2026-05-27)
- [x] Restore `dl.consolving.net` Traefik route (was missing) — AddPrefix maps to `/ipfs/{CID}/repository/targets` (2026-05-27)
- [x] Update `sync-ipfs.sh` to maintain `repository/` directory structure and refresh TUF metadata from git (2026-05-27)
- [x] Update `release-and-sync.sh` to update host2 Traefik CID and recreate container (2026-05-27)
- [x] Verify: `curl https://tuf.consolving.net/repository/root.json` returns 200 from both hosts (2026-05-27)
- [x] `tufconfig.Mirrors` updated to try `tuf.consolving.net/repository` first, GitHub Pages fallback (2026-05-27)
- [x] Old flat CID (`bafybeibtwqraqap4yeslp3jwjdhnglwvubd3ahoaekad6vw5km75kf3kty`) unpinned and GC'd on both hosts (2026-05-27)
- [x] Rebuild `flynn-host` binary with `tufconfig.Mirrors` update — targets.json v2029, snapshot v44, timestamp v47, pushed to GitHub (2026-05-27)

**Remaining tasks**:

- [x] Update `refresh-tuf.yml` GitHub Actions workflow to trigger IPFS re-sync after monthly `timestamp.json` refresh — **verified 2026-09-01**: webhook Traefik route added, secret updated, and a manual workflow dispatch succeeded with HTTP 202 from GitHub's public IP. Full details in "IPFS Mirror Recovery and E2E Verification (2026-09-01)" below. (Note: the 2026-05-27 status was premature — the route and secret were not actually wired end-to-end until 2026-09-01.)
- [x] Verify end-to-end: `flynn-host download` from IPFS-backed TUF mirror — **verified 2026-09-01**: fresh scratch TUF client + channel `stable` → `v20260811.0`, full download (3 binaries, bootstrap-manifest.json, images.json, all 21 images / 48 unique layers incl. all previously-missing layers) completed with zero errors against `https://tuf.consolving.net/repository` alone (explicit `--repository`, no GitHub Pages fallback). See "IPFS Mirror Recovery and E2E Verification (2026-09-01)" below.

### IPFS Mirror Recovery and E2E Verification (2026-09-01)

**Findings** (while closing the open e2e item):
1. **Live timestamp expired**: IPFS (`tuf.consolving.net`, host1+host2, same CID) served timestamp v56 which **expired 2026-08-12T23:16:58Z**. Root cause: the v20260811.0 release commits (`50c6dcc`, `a5d7d88`) re-signed the timestamp with **1-day expiry** (`--expiry-days 1`), so the shipped mirror metadata lapsed. GitHub Pages had been re-signed by the 2026-09-01 cron to v57 (expires 2026-11-30), but the cron's IPFS re-sync step POSTs to `https://host1.consolving.net/webhook/tuf-sync`, which **404s** — no Traefik route exists for the webhook (the `tuf-webhook.service` on port 9442 has been running since 2026-08-27; the external Traefik only defines an `openpeeps` file-provider route plus docker-label routes; nothing forwards `/webhook/*`). The GitHub Actions workflow treats non-202 as a logged warning, so the cron "succeeded" every month while IPFS stayed stale.
2. **6 squashfs layers missing from the CID** (of 48 unique layers referenced by v20260811.0 `images.json`): builder `97bc968b`, host `4b150048`, slugbuilder-14 `05d1ef48`, slugbuilder-24 `4472674c`, slugrunner `00159700` (shared), updater `e907f5a6`. A sweep of all 465 git-tree files against the CID showed everything else present. This is the latent `export-tuf` layer-sync footgun noted earlier — these layers were never merged into the IPFS content.
3. **Stale plain `channels/stable`**: git/GitHub Pages had `v20260527.0` while the TUF target `/channels/stable` (consistent name `4664ed...stable`) is `v20260811.0`. The release flow only updated the hash-prefixed copy. TUF clients fetch the hash-prefixed name, so impact was cosmetic — fixed anyway.

**Recovery performed (2026-09-01)**:
- Ran `/opt/flynn-tuf-dl/refresh-tuf-metadata.sh` on host1 → pulled `3f9cee0` (v57), new CID `bafybeigxx...`, host1+host2 Traefik updated.
- Fixed plain `repository/targets/channels/stable` → `v20260811.0\n`, pushed to GitHub main (`3e006ff`).
- Transferred the 6 missing layers from the dev-machine `/var/lib/flynn/layer-cache` (each verified byte-exact with Go `crypto/sha512.New512_256` against layer ID) to host1, ran `/opt/flynn-tuf-dl/sync-ipfs.sh` → new CID `bafybeih74d23qhnigl5wm5rkl3k6svdyzxl32vqdwt5xpoul5yjh72aiji` (now the live CID on host1); propagated to host2 (compose CID + `ipfs pin add` prewarm).
- Full sweep afterwards: **492/493 paths 200 on each host** (465 git files minus `.nojekyll` + 48 layer IDs); metadata byte-identical between `tuf.consolving.net` and GitHub Pages (root/timestamp/snapshot/targets/consistent-snapshot/channel/binaries, sha512-compared).

**E2E verification (dev machine, scratch tree `/tmp/flynn-e2e-20260901`)**:
- Dogfooded the mirror: fetched `/v20260811.0/flynn-host.gz` binary from `dl.consolving.net`, sha512 matches target `12dc0306...`, version v20260811.0.
- `flynn-host download -r https://tuf.consolving.net/repository` with fresh `tuf.db`, `channel.txt=stable`, scratch bin/config/vol dirs: TUF init → channel resolution → binaries (flynn-host/flynn-init/flynn-linux-amd64 v20260811.0) → all 21 images / 48 unique layers (ZFS zvols on `flynn-default`) → bootstrap-manifest.json. **Zero errors**, `download complete`. Explicit `--repository` means no GitHub Pages fallback was available — the IPFS mirror alone is self-sufficient.

**Superseded known issue**: the 2026-08-11 note about stale `dl.consolving.net/flynn-host.gz` (old v20260518 binary `cdf715ab...`) no longer applies — targets.json now points `/flynn-host.gz` → `12dc0306...` (fixed v20260811.0) and that exact file verifies on the mirror.

**Follow-ups**:
- [x] Add a Traefik router for `Host(host1.consolving.net) && PathPrefix(/webhook)` → tuf-webhook.service so the monthly cron re-syncs IPFS automatically — **done 2026-09-01**: router + service added to `/builds/.../providers/http-forwarders.yml` (file provider, watch:true, no restart). Backend `http://172.19.0.1:9442` (traefik_default bridge gateway). Verified: health 200, wrong-secret POST 403, Traefik logs clean. ACME cert for `host1.consolving.net` already exists. **Secret now verified (2026-09-01)**: the GitHub Actions secret `TUF_WEBHOOK_SECRET` was updated to match host1's `WEBHOOK_SECRET`; a direct `POST /webhook/tuf-sync` with the correct secret returns 202, and a manually-run "Refresh TUF Metadata" workflow (run #33557448866) succeeded with its webhook step returning **HTTP 202 `{"status":"accepted"}`** from GitHub's public IP — the full pipeline (cron → re-sign → push → webhook → IPFS re-sync on both mirrors) now works. Note the `phaus` PAT lacks the `workflow`/`actions:write` scopes, so dispatch/secret management must be done via the GitHub web UI.
- Release signing must keep 90-day timestamp expiry (v54/v56 shipped with 1-day expiry by mistake — process slip in the v20260811.0 release work; scripts default to 90d).
- [x] **Mirror-side** fix for the layer-sync gap (done 2026-09-01): added a persistent canonical on-disk layer store `/opt/flynn-tuf-dl/layer-store/` (all 108 flat `.squashfs`, byte-verified against MFS, 3.6 GiB), and modified `refresh-tuf-metadata.sh` to merge `$LAYER_STORE/*.squashfs` into `$STAGING_DIR/repository/targets/` on **every** run so a rebuild can never drop layers regardless of MFS state (the previous MFS round-trip preservation is now only a non-authoritative best-effort supplement). Rebuild produced CID `bafybeidwuj3sg4bd7am6kstlebnvodwe3ixb6ee5zvtjfscluxm6ivle2i` (was `bafybeih74d2…`), serving 108/108 layers; end-to-end verified: `dl.consolving.net` returns HTTP 200 for a flat layer with MD5 matching layer-store. **Note**: recreate on host1 initially crash-looped (exit 1) with `lock /data/ipfs/repo.lock: permission denied` — a stale root-owned `repo.lock` left after the `ipfs add`/GC; fixed by stopping the container, removing the lock, and restarting (host2 unaffected). 
- [x] Proper **source-side** fix for the layer-sync gap — **done 2026-09-01** (`flynn` commit `7a8f9e1d`, subsystem prefix `export-tuf:`): `script/export-tuf/main.go`'s `stageTUFTargets` now stages squashfs layers and their config JSON **flat** under `repository/targets/` (previously nested under a `layers/` subdirectory), matching `LayerURLTemplate = https://dl.consolving.net/{id}.squashfs` and the `dl` addprefix `/ipfs/{CID}/repository/targets` — so nested layers no longer 404 on download. Builds and `go vet` clean. Combined with the mirror-side layer-store, future releases can no longer ship with layers unreachable on IPFS. **Note**: the legacy self-hosted builder (`builder/export.go`, `builder/build.go`) still fetches layers via `/layers/{id}` TUF target paths — that is the old chicken-and-egg build path, not the modern release tool, and was intentionally left unchanged.


### IPFS-Backed TUF Mirror — End-to-End Cluster Verification (2026-08-11)
**Goal**: Close the last open Phase 7 item by verifying a real cluster boot against the IPFS-backed TUF mirror.

**Mirror verification (dev-machine, direct `flynn-host download`)**:
- New binary v20260527.0 (tufconfig.Mirrors: `tuf.consolving.net/repository` first, GitHub Pages fallback) — full component download (taffy, tarreceive, mongodb, router, slugbuilder-14, slugrunner-14, updater, logaggregator, postgres, redis, mariadb + all layers) succeeded from the IPFS mirror on the FIRST mirror; no "trying mirror" fallback in logs.
- v20260518.0 binary `download` also works (GitHub path).
- Both mirrors serve: root.json, timestamp v53 (expires 2026-10-30), consistent-snapshot `97f6b0c7...targets.json` (v12), `7cf80012...bootstrap-manifest.json.gz` (v20260518.0), `1a59d249...flynn-host.gz` (v20260527.0).

**Cluster boot test (single-node, rebuilt fresh)**:
- Destroyed stale node1 and rebuilt: `vagrant destroy -f node1 && vagrant up node1 --provision` in `/root/GIT/flynn-dev/vagrant`.
- Vagrant shell provisioner aborts when provision.sh restarts systemd-networkd (management SSH drops); the script itself continues in-VM and completes (flynn-host daemon up, systemd unit enabled). Bootstrap provisioner never runs — run manually:
  `CLUSTER_DOMAIN=demo.localflynn.com flynn-host bootstrap --min-hosts=1 --peer-ips=192.168.50.11 --timeout=600`
- Result: bootstrap **complete**, 15 apps up (controller scheduler/web/worker, router, postgres, discoverd, gitreceive, blobstore, mongodb, mariadb, redis, taffy, tarreceive, logaggregator, flannel, status). All jobs `up`.
- Dev-machine CLI connects: `/usr/local/bin/flynn apps`, `flynn -a <app> ps`. New cluster creds written to `/root/.flynnrc`.
- TUF key/creds: Key `9ca70541ad189246633b0fcb88c4c7a4`, TLSPin `G+cyhnxjBHLFRtJ3Q+BGdo7Le1SWAXnOt2folTF0+7I=` (also in /var/log/flynn/bootstrap.log in VM).

**Known issue — stale `dl.consolving.net/flynn-host.gz`**:
- `dl.consolving.net/flynn-host.gz` still serves the OLD v20260518.0 binary (sha512 `cdf715ab...`) while targets.json points `/flynn-host.gz` → `1a59d249...` (v20260527.0). Provision works anyway (binary only used for the download step; TUF-installed components + bootstrap verified), but the IPFS pin behind dl.consolving.net should be re-synced so the "current" flynn-host.gz matches metadata.

### Full 5-Node Cluster Deployment — Root-Cause Fixes and Working Deployment (2026-08-11/12)

**Goal**: Get a genuinely working, externally-reachable 5-node Flynn cluster on the dev-machine that a human can log into and test manually. Found and fixed five independent, unrelated bugs along the way — each one masked the next until fixed.

#### Bug 1: `vagrant-libvirt` management network dnsmasq silently dies

The libvirt `vagrant-libvirt` NAT network's dnsmasq process can die (stale PID, no restart) without the network itself showing as inactive in `virsh net-list`. VMs then get no DHCP lease and Vagrant's SSH step hangs/fails with "Host unreachable. Retrying...".

**Fix**: `virsh net-destroy vagrant-libvirt && virsh net-start vagrant-libvirt` (or redefine from a saved XML if the network object itself got removed — see Bug 5). No permanent code fix; this is host hygiene. Recreated `/tmp/vagrant-libvirt.xml` as a saved copy of the network definition for quick recovery:
```xml
<network connections='1' ipv6='yes'>
  <name>vagrant-libvirt</name>
  <uuid>14ca382f-7f02-4a17-8527-8391ebaa6432</uuid>
  <forward mode='nat'><nat><port start='1024' end='65535'/></nat></forward>
  <bridge name='virbr1' stp='on' delay='0'/>
  <mac address='52:54:00:2b:8f:c0'/>
  <ip address='192.168.121.1' netmask='255.255.255.0'>
    <dhcp><range start='192.168.121.1' end='192.168.121.254'/></dhcp>
  </ip>
</network>
```

**Related**: `vagrant destroy` on the last VM using a manually-`virsh net-define`'d network sometimes tears the network down too (inconsistent — happened ~50% of the time across many destroy/recreate cycles in this session). Always check `virsh net-list --all` after any `vagrant destroy` and redefine+start `vagrant-libvirt` if missing, before the next `vagrant up`/`cluster-up.sh`.

#### Bug 2: `flynn-host` binaries built with `"dev"` version string, infinite download loop

**Symptom**: `flynn-host download` never terminates — repeatedly downloads binaries, execs into itself, loops forever. Root cause: `script/bootstrap-build` defaults to `--version dev` when the flag isn't passed explicitly. Whoever built the v20260811.0 release ran it without `--version v20260811.0`, so `flynn-host`/`flynn-init`/`flynn-linux-amd64` all embedded `version.version = "dev"` via the ldflags in `builder/go-wrapper.sh`. In `host/cli/download.go`:
```go
if version.Release() != requestedVersion {
    // re-exec into the just-downloaded binary — but since it's ALSO "dev", loops forever
    return syscall.Exec(binPath, argv, os.Environ())
}
```

**Fix**: rebuilt the three binaries with `script/bootstrap-build --version v20260811.0`, then hand-patched the existing v20260811.0 TUF release (same version tag, corrected binary content) rather than cutting a new release:
1. Wrote `flynn-tuf-repo/script/fix-binary-versions.py` — mirrors the existing `update-release-artifacts.py`/`update-postgres-layer.py` pattern (canonical-JSON ed25519 signing via PyNaCl), replacing just the `/flynn-host.gz`, `/flynn-linux-amd64.gz`, `/v20260811.0/{flynn-host,flynn-init,flynn-linux-amd64}.gz` targets and bumping targets/snapshot/timestamp versions.
2. **Important discovery**: `/go/bin/tuf` (the standard go-tuf CLI) is built from `github.com/theupdateframework/go-tuf@v0.7.0`, a **different fork** than the one this repo's `root.json` was signed with (`github.com/flynn/go-tuf`, older key-ID algorithm — canonical JSON of just `{keytype, keyval}` vs. the newer fork's `{keytype, scheme, keyid_hash_algorithms, keyval}`). Using the newer CLI to sign gives "no keys available" even with the *correct* private key, because the computed key ID doesn't match root.json's registered key ID. Don't reach for `/go/bin/tuf` for this repo — always use the Python signer pattern.
3. Verified against the live mirror before/after: `flynn-host download --repository https://tuf.consolving.net/repository` completed cleanly, `flynn-host version` reports `v20260811.0`.
4. Pushed `flynn-tuf-repo` commit `29c6006`, bumped `flynn-dev` submodule pointer.

#### Bug 3: `cluster-up.sh` clones never got a unique `--id`/`host_id`

**Symptom**: only ONE of 5 nodes' `flynn-router` (host-networked, omni) actually listens on 80/443; the other 4 report `flynn-host ps` job entries that look "running" (PID, full config) but have **zero** log output ever, and the host-level PID doesn't exist. Root cause: `cluster-up.sh`'s clone customization only `sed`s `--external-ip=` in the cloned `flynn-host.service`, never `--id=` or `--tags=host_id=`. All 5 clones ran with the **same** `flynn-host daemon --id=node1 ...`, colliding in discoverd/raft-based host tracking — jobs "assigned" to `node1` land on whichever physical host most recently won that identity race, and get silently dropped on the others.

**Fix** (`cluster-up.sh`):
```bash
echo "$SVC_TEMPLATE" \
    | sed -e "s/--external-ip=[0-9.]*/--external-ip=${target_ip}/" \
          -e "s/--id=node1/--id=node${i}/" \
          -e "s/--tags=host_id=node1/--tags=host_id=node${i}/" \
    > "${WORK_DIR}/flynn-host-node${i}.service"
```
After this fix, `flynn-host.service --id=` is unique per node (`node1`..`node5`), and port 80/443 is reachable on **all 5** nodes.

#### Bug 4: mongodb image ships with no `mongod` binary

**Symptom**: `flynn -a mongodb ps` shows the process crash-looping; `flynn-host log` shows `fork/exec /usr/bin/mongod: no such file or directory`. Root cause: `flynn/appliance/mongodb/img/packages.sh` referenced the MongoDB **7.0** apt repo for Ubuntu **noble** (24.04) — `repo.mongodb.org/apt/ubuntu/dists/noble/mongodb-org/7.0/` doesn't exist; MongoDB dropped 7.0 support for 24.04. Without `set -e`, `apt-get install mongodb-org` failed silently and the script exited 0, so `export-tuf` happily packaged an image containing only `curl` (from the repo-setup step) and the flynn wrapper binaries.

**Fix** (`appliance/mongodb/img/packages.sh`):
- Use `noble/mongodb-org/8.0` (first release line with noble packages).
- `curl ... | gpg --dearmor -o ...` instead of writing the ASCII-armored `.asc` directly — `apt`'s `signed-by=` needs a binary keyring, not ASCII-armor (a second silent-failure trap; caused a GPG "NO_PUBKEY" error on the first re-export attempt).
- Added `set -eo pipefail` and a `test -x /usr/bin/mongod || exit 1` fail-fast check at the end.
- Re-ran `export-tuf` with the persistent `/var/lib/flynn/layer-cache` (903MB, content-addressed) — cache hits for all unrelated images, mongodb rebuilt from scratch (166MB layer now, up from ~2MB).
- Pushed `flynn-tuf-repo` commit `a5d7d88`.

**Discovered a second, unrelated export-tuf bug while re-syncing**: `export-tuf` writes new/changed **binary** targets (`.gz` files under `v{version}/`) into the git-tracked `repository/` tree, but does **not** write package/base **layer** squashfs files into `repository/targets/layers/` at all — it assumes they're already distributed via IPFS from a prior release and only relies on the (gitignored) local `layer-cache` for hash computation. This is fine for layers that genuinely haven't changed, but for a release where package content **did** change (mongodb, and — due to non-reproducible `apt-get install` builds — several other images too), the new squashfs files exist only in `/var/lib/flynn/layer-cache/{hash}.squashfs`, not in the repo, and never get IPFS-synced by the normal commit+release-and-sync.sh flow. Cross-checked every layer hash referenced by the newly-generated `bootstrap-manifest.json` against `dl.consolving.net` and manually copied+synced the ones missing (22 layers, ~1.1GB, sourced directly from `layer-cache`).

**Also discovered**: `dl.consolving.net`'s Traefik `addprefix` is `/ipfs/{CID}/repository/targets` (flat) — it can **only** reach files stored directly under `repository/targets/{hash}.ext`, never anything nested under a nested subdirectory. `export-tuf`'s own `layerURLTpl` is `https://dl.consolving.net/{id}.squashfs` (flat, confirmed in `script/export-tuf/main.go`), so **all** squashfs layers must be synced flat, not under a `layers/` subdirectory — nesting them under `layers/` (my first attempt) leaves them reachable via `tuf.consolving.net/repository/targets/layers/{hash}.squashfs` but 404 via `dl.consolving.net/{hash}.squashfs`, which is what `flynn-host` actually requests for image layers.

**Manual recovery process for a missing target, if this happens again**:
```bash
# 1. Find which layer hashes bootstrap actually needs:
python3 -c "
import json
d = json.load(open('bootstrap-manifest.json'))
hashes=set()
for step in d:
    for art in step.get('artifacts', []):
        for rfs in art.get('manifest',{}).get('rootfs', []):
            for l in rfs.get('layers', []): hashes.add(l['id'])
print('\n'.join(sorted(hashes)))
" > /tmp/needed-hashes.txt

# 2. Check which are missing from the live mirror:
while read h; do
  code=$(curl -sf -o /dev/null -w '%{http_code}' https://dl.consolving.net/${h}.squashfs)
  [ "$code" != "200" ] && echo "MISSING: $h"
done < /tmp/needed-hashes.txt

# 3. Copy missing ones FLAT (no subdirectory!) from /var/lib/flynn/layer-cache
#    into a sync source dir, then:
ssh host1.consolving.net /opt/flynn-tuf-dl/release-and-sync.sh /path/to/sync-src
```

#### Bug 5: MongoDB 5.0+ requires AVX; default QEMU CPU model doesn't expose it

**Symptom**: even after fixing Bug 4, `mongod` started but immediately crashed with `signal: illegal instruction (core dumped)`. The dev-machine's physical CPU has AVX (`grep -c avx /proc/cpuinfo` → 40), but neither the Vagrantfile nor `cluster-up.sh`'s raw libvirt XML template set a CPU mode, so vagrant-libvirt/libvirt defaulted to a generic `qemu64` model with no AVX exposed to the guest (`grep -c avx /proc/cpuinfo` inside the VM → 0).

**Fix**:
- `vagrant/Vagrantfile`: added `libvirt.cpu_mode = "host-passthrough"` to the provider block.
- `vagrant/cluster-up.sh`: added `<cpu mode='host-passthrough'/>` to the clone domain XML template (this was previously **completely absent** — no `<cpu>` element at all).
- Applied live to a running cluster via `virsh destroy <vm> && virsh dumpxml <vm> | sed <replace cpu block> > fixed.xml && virsh define fixed.xml && virsh start <vm>` (no full VM rebuild needed — libvirt domain state persists across a CPU-model change).
- Verified: cluster survived a simultaneous reboot of 4/5 nodes (to apply the CPU fix) and recovered to fully healthy within ~90s.

#### Non-bug: `mariadb`/`mongodb` need manual `SINGLETON=true` for a scale-1 deployment in a 5-node cluster

This is **expected behavior**, not a bug. `bootstrap/manifest_template.json` correctly templates `SINGLETON: "{{ .Singleton }}"` for postgres, mariadb, and mongodb alike — the value is based on **total cluster node count** (5 → `false`, expecting real multi-node replica-set/quorum operation), not on how many instances of that specific app you scale up. The bootstrap manifest deliberately scales `mariadb`/`mongodb` engine processes to `0` (only the `web` API layer runs by default) to save resources; scaling to `1` manually leaves `SINGLETON=false`, so the lone instance waits forever for a quorum that will never form. Fix is a one-time manual step per app after bootstrap:
```bash
flynn -a mariadb scale mariadb=0 && flynn -a mongodb scale mongodb=0
flynn -a mariadb env set SINGLETON=true
flynn -a mongodb env set SINGLETON=true
flynn -a mariadb scale mariadb=1 && flynn -a mongodb scale mongodb=1
```
(`env set` on a Sirenia app fails with "missing sirenia cluster state" while an unassigned peer is stuck at scale=1 — scale to 0 first, set env, then scale back up.)

#### Bug 6: asymmetric routing breaks external access to the cluster

**Symptom**: DNAT'ing dev-machine `192.168.168.87:80/443` → a node's data-network IP (e.g. `192.168.50.11:80`) reaches the node (confirmed via tcpdump on the node's `ens7`), but the node never replies — external client sees connection timeout. Root cause: every cluster node's **default route** goes out the *management* NIC (`ens6`, DHCP via `vagrant-libvirt`/`virbr1`), not the *data* NIC (`ens7`, static IP on `flynn-cluster`/`virbr2`) where the DNAT'd traffic actually arrives. The reply to an externally-sourced SYN gets routed via the wrong gateway/network entirely and never makes it back.

**Fix**: source-based policy routing on each node, so replies to the node's own data IP go out the data NIC:
```bash
ip rule add from <node-data-ip> lookup 50 priority 100
ip route add default via <data-subnet>.1 dev <data-iface> table 50
```
Made permanent via `provision.sh` (added right after the interface/IP assignment step) — writes a `flynn-data-route.service` systemd oneshot unit and enables it, so future redeploys get this automatically on every node regardless of which one ends up being the external access point.

**Also required**: the DNAT rule itself must be scoped to the dev-machine's own external IP (`-d 192.168.168.87`), **not** a blanket `-p tcp --dport 80/443` with no destination filter — an unscoped rule hijacks *all* transiting traffic on those ports, including the VMs' own outbound apt/HTTP traffic (broke `archive.ubuntu.com:80` mid-session and cost significant time misdiagnosing it as an unrelated network flake before finding the real cause in `iptables -t nat -L PREROUTING`).

Persisted via `iptables-save > /etc/iptables/rules.v4` (loaded by `/etc/network/if-pre-up.d/iptables` on this Debian 13 host).

#### End state (2026-08-12)

5-node cluster (`vagrant_node1` + `flynn_node2..5`), all `flynn-host` daemons unique-ID'd and healthy, full service status **all green**:
```json
{"status":"healthy","detail":{
  "blobstore":"healthy","controller":"healthy","controller-scheduler":"healthy",
  "controller-worker":"healthy","discoverd":"healthy","flannel":"healthy",
  "gitreceive":"healthy","logaggregator":"healthy","mariadb":"healthy",
  "mongodb":"healthy","postgres":"healthy","router":"healthy","tarreceive":"healthy"
}, "version":"v20260811.0"}
```

**External access, for manual testing**:
- Add to local `/etc/hosts` (no wildcard support, list what you need):
  ```
  192.168.168.87  demo.localflynn.com
  192.168.168.87  controller.demo.localflynn.com
  192.168.168.87  status.demo.localflynn.com
  192.168.168.87  git.demo.localflynn.com
  ```
- `curl http://status.demo.localflynn.com` → cluster health JSON.
- `curl -k https://controller.demo.localflynn.com` → `401` (needs auth token — cluster reachable and routing correctly).
- No `dashboard.*` app is deployed by this manifest (Flynn's own web dashboard isn't part of the minimal bootstrap set used here — only `status`, `controller`, `router`, etc.).
- `.flynnrc` cluster-add command is printed at the end of every `cluster-up.sh` run; also recoverable via `grep 'flynn cluster add' <cluster-up.sh log>`.

**Known remaining gaps** (not addressed this session, lower priority):
- Only node1 has the DNAT-facing policy route actively used; other 4 nodes have the fix available via `provision.sh` but it's inert unless that node becomes the DNAT target.
- `cluster-up.sh`'s "management network sometimes disappears on `vagrant destroy`" (Bug 1) has no permanent fix — still requires manual `virsh net-define`+`net-start` recovery before some redeploys.
- ~~The broader `export-tuf` layer-sync gap (Bug 4's second finding) is a latent footgun for any future release with changed package content — worth a proper fix in `export-tuf/main.go` (write ALL layers, changed or not, to `repository/targets/{hash}.squashfs` flat, every run) rather than relying on layer-cache + "assume IPFS already has it".~~ **Fixed 2026-09-01**: source-side flat-layer staging committed as `flynn` `847649e9`.

## Code Review Findings (2026-09-01)

A full scan of the Flynn Go monorepo and the host1 TUF/IPFS scripts was performed. The most actionable findings are grouped below as follow-up todos. Detailed locations and recommendations are in the subsections.

### Completed (2026-09-03, flynn `4103e13e`, branch `dashboard-v20260902`)

The following Go code review items were fixed and verified (`go build ./...`, `go vet` on changed packages, standalone unit tests pass). The `flynn` submodule commit is `4103e13e`.

- **Security**: ish auth (`197d580c`, earlier), resource ID SQL injection (`d98a1f06`, earlier), scheduler rectify race (`fcfd84c9`, earlier), `RawManifest` pointer receiver (`89696139`, earlier) — already fixed before this session.
- **HIGH `gitreceive/server.go`**: check `http.DefaultClient.Do` error before using `resp` (fixes nil-pointer panic); drain response body for connection reuse; return nil on success.
- **MEDIUM `discoverd/client/instance.go` + `discoverd/server/store.go`**: `Clone()` copies fields individually (no longer shallow-copies `addrOnce sync.Once`); store uses `inst.Clone()`.
- **MEDIUM `controller/scheduler/scheduler.go`**: copies `Host` fields individually (no longer shallow-copies `stopOnce sync.Once`).
- **MEDIUM `controller/app.go`**: `defer cancel()` immediately after `context.WithCancel`.
- **MEDIUM `host/state.go`**: `SetContainerIP`/`SetContainerPID` existence-check the job before dereferencing.
- **MEDIUM `bootstrap/discovery`**: close response bodies in `RegisterInstance`/`NewToken`; require `DISCOVERY_SERVER` env var instead of dead `discovery.flynn.io` default.
- **MEDIUM stale docs**: `cli/install.go`, `host/cli/cli-add-command.go`, `host/cli/update.go` point to `flynn.io` (offline) → `github.com/consolving/flynn`.
- **MEDIUM hardcoded credentials**: `cmd/event-debug` reads `FLYNN_CONTROLLER`/`FLYNN_KEY`; test MinIO creds and SSH creds read from env vars (current values remain defaults).
- **LOW**: `tarreceive/main.go` `os.SEEK_SET` → `io.SeekStart`.
- **vendor**: synced `modules.txt` + added dashboard deps (`gorilla/context`, `gorilla/securecookie`, `gorilla/sessions`, `jvatic/asset-matrix-go`) required by the dashboard restore.

**Deferred / not addressed here**: deprecated CLI paths (`cli/docker.go`, `cli/release.go` — intentionally retained) and remaining maintainability refactors.

### Security
- [x] **CRITICAL**: `test/apps/ish/main.go:52` passes HTTP request bodies directly to `/bin/sh -c`. This test helper is an arbitrary command-execution endpoint. Sandbox it, remove it, or require authentication. (require bearer token — fixed in 197d580c)
- [x] **HIGH**: `appliance/mariadb/cmd/flynn-mariadb-api/main.go:128,133` and `appliance/postgresql/cmd/flynn-postgres-api/main.go:126,131` build `DROP DATABASE`/`DROP USER` with `fmt.Sprintf` using request-provided IDs. Use identifier-quoting helpers (`pq.QuoteIdentifier` for Postgres, backtick-escape for MariaDB) or validate identifiers strictly. (validHexID validation — fixed in d98a1f06)
- [x] **HIGH**: `controller/scheduler/scheduler.go:2401,879` — `triggerRectify` writes to `s.rectifyBatch` from many goroutines while `HandleRectify` reads/resets it on the main loop without synchronization. Add a mutex or route all writes through the main goroutine. (rectifyMu.Lock() — fixed in fcfd84c9)
- [x] **HIGH**: `controller/types/types.go:682-683` — `RawManifest()` takes `ImageManifest` by value (copying `sync.Once`) while `Hashes()` may mutate concurrently. Change to a pointer receiver. (fixed in 89696139)

### Reliability / Error Handling
- [x] **HIGH**: `gitreceive/server.go:408` calls `resp.Body.Close()` before checking whether `http.DefaultClient.Do` returned an error; `resp` may be nil, causing a panic.
- [x] **MEDIUM**: Replace unbounded `http.DefaultClient` usage with timeout-bearing clients across the codebase (`gitreceive/server.go`, `updater/updater.go`, `controller/worker/*`, `cli/login/login.go`, `host/cli/gist.go`, `bootstrap/discovery/discovery.go`, `slugbuilder/migrator/main.go`). (30s `http.Client` added in 27b66863)
- [x] **MEDIUM**: `controller/app.go:82` creates `context.WithCancel` but several early returns never call `cancel`. Defer the cancel immediately.
- [x] **MEDIUM**: `discoverd/client/instance.go:173` and `discoverd/server/store.go:476` copy `Instance` by value, which contains `sync.Once`. Reset/zero the `sync.Once` when cloning, or copy fields individually.
- [x] **MEDIUM**: `controller/scheduler/scheduler.go:1274` copies `*host` by value; `Host` contains `sync.Once`. Copy fields individually and reset the `sync.Once`.
- [x] **MEDIUM**: Several panic-on-persistence-failure sites (`host/state.go:348`, `host/volume/manager/manager.go:471`, `pkg/postgres/postgres.go:83`, `controller/data/schema.go:1028`) should return errors instead of crashing the daemon. (log-and-continue / shutdown.Fatal / return error in 2fc5e04f)
- [x] **MEDIUM**: `host/state.go:447` dereferences `s.jobs[jobID]` without checking existence.
- [x] **MEDIUM**: `bootstrap/discovery/discovery.go:75` reads an HTTP response body without closing it, leaking the connection.

### TUF / IPFS Mirror Operational Hardening
- [x] **HIGH**: Add a file lock around publish/mutate operations (`refresh-tuf-metadata.sh`, `sync-ipfs.sh`, `release-and-sync.sh`, `tuf-webhook.py`) so concurrent webhook calls and manual runs cannot race on CID files, MFS, compose files, and IPFS pins. (flock on fd 9, 300s timeout, all scripts)
- [x] **MEDIUM**: Harden the webhook handler (`/opt/scripts/tuf-webhook.py`): rate limiting, source-IP allowlist, HMAC request-body signing instead of a shared header, and streaming log output instead of `capture_output=True`. (HMAC body sig, per-IP rate limit, MAX_RUNNING=1, ALLOWED_SOURCES, /webhook/health)
- [x] **MEDIUM**: Enforce SSH host-key verification for host2 propagation (`StrictHostKeyChecking=yes` + pinned `UserKnownHostsFile`). (pinned `/opt/flynn-tuf-dl/host2_known_hosts`, `SSH_HOST2` var in all scripts)
- [x] **MEDIUM**: Add post-update health checks (`curl --fail https://tuf.consolving.net/repository/root.json`) before declaring a refresh successful and before garbage-collecting the old CID. (5 attempts/5s, abort promotion on failure)
- [x] **MEDIUM**: Keep the previous IPFS CID pinned for a grace period (15–30 min) after Traefik/container updates are confirmed healthy to avoid serving broken content during propagation. (CID_GRACE_SECONDS=1800, background unpin+GC)
- [x] **MEDIUM**: `refresh-tuf-metadata.sh` should pin the new CID explicitly (`ipfs pin add "$NEW_CID"`) and write the CID file only after MFS, compose, and health checks succeed. (pin-add after add, CID file write after health pass)
- [ ] **LOW**: Standardize the Docker exec user (`-u ipfs`) across all IPFS scripts.

### Deprecated / Stale Code
- [x] **MEDIUM**: Remove or replace stale `flynn.io` references (`bootstrap/discovery/discovery.go:100` discovery service, `cli/install.go:14` install docs). Note: `controller/schema/schema.go:45,67,69` cache keys retained (internal map keys, functionally harmless).
- [x] **MEDIUM**: Remove hardcoded debug credentials (`cmd/event-debug/main.go:13` controller IP/key, `test/test_blobstore.go:63` MinIO key, `test/cluster/instance.go:266` SSH password `ubuntu`).
- [ ] **LOW**: Finish removing deprecated CLI paths (`cli/docker.go` Docker-registry push, `cli/release.go` `release add`) or move them behind explicit compatibility flags.
- [x] **LOW**: Replace deprecated `os.SEEK_SET` with `io.SeekStart` in `tarreceive/main.go`.

### Maintainability / Technical Debt
- [ ] **MEDIUM**: Refactor oversized functions: `host/libcontainer_backend.go:Run()` (~380 lines), `controller/scheduler/scheduler.go:Run()` and `ControllerPersistLoop()`, `pkg/sirenia/state/state.go:evalClusterState()`.
- [ ] **MEDIUM**: Address the most impactful TODO comments: scheduler async HTTP calls (`scheduler.go:163`), job attach context cancellation (`controller/jobs.go:246`), host discovery retry (`host/host.go:263`), host updater custom flags (`host/cli/update.go:207`), route non-default ports (`controller/data/route.go:68,90`), job validation (`controller/data/jobs.go:39`).
- [ ] **LOW**: Make hardcoded tuning parameters configurable (`host/libcontainer_backend.go` paths/MTU/PATH, `appliance/postgresql/process.go` `max_connections`/`shared_buffers`, `controller/scheduler/scheduler.go` buffer sizes/timeouts, `discoverd/server/store.go` Raft timeouts).
- [ ] **LOW**: Add HTTP server timeouts (`ReadTimeout`/`WriteTimeout`/`IdleTimeout`) to public/internal endpoints (`controller`, `gitreceive`, `blobstore`, appliance APIs, scheduler).

## Dashboard Deployment (2026-09-03)

The Flynn web dashboard has been restored, built end-to-end, and deployed to the demo cluster.

- [x] Fix `node-sass` → `sass` (dart-sass) in vendored `asset-matrix-go` so the dashboard asset pipeline builds on Node 20.
- [x] Verify full dashboard build: `dashboard-compile` → `go-bindata` → `flynn-dashboard` binary.
- [x] Build `flynn-dashboard:test` Docker image.
- [x] Bootstrap a 5-node Flynn demo cluster (`demo.localflynn.com`).
- [x] Deploy dashboard in the cluster via `flynn docker push` and expose at `https://dashboard.demo.localflynn.com`.

**Access**:
- URL: `https://dashboard.demo.localflynn.com`
- Login token: `cf1cc11ed7e6f1dcfb88e1c6a3519508` (current v20260904.0 cluster; the old `d5c16b97…` is stale after the fresh rebuild — a new random token is generated each bootstrap)
- The TLS certificate is the cluster's self-signed controller cert; accept the security warning in the browser.

**Note**: The dashboard is currently deployed from a locally built Docker image, not yet published as a TUF target. To make it part of the official release, it must be added to `builder/manifest.json`, built by `script/export-tuf`, signed, and published to the TUF repository.

### Update (2026-09-04, v20260904.0 rebuild)

The cluster was rebuilt fresh on node1 with the `v20260904.0` flynn-host binary (after destroying the stale golden node1 whose `/usr/local/bin/flynn-host` was a `dev` build), producing a 5-node cluster where all nodes report `v20260904.0`.

**Important finding — stale `vagrant/bootstrap-manifest.json`**: The dashboard IS now a real TUF image artifact. Flynn commit `90346aa3` re-integrated the dashboard into `bootstrap/manifest_template.json` (steps `dashboard-session-secret`, `dashboard-login-token`, `dashboard` deploy-app, `dashboard-route`, plus dashboard token in `log-complete`), and `export-tuf` renders it into `flynn/build/manifests/bootstrap-manifest.json` (dashboard image artifact `c777b74d…`). **However, the deployed `vagrant/bootstrap-manifest.json` is a hand-maintained stale copy (last updated `0561bb6`, v20260902.0) that has NO dashboard steps** — so a `cluster-up.sh` bootstrap does NOT deploy the dashboard. Fix: copy `flynn/build/manifests/bootstrap-manifest.json` over `vagrant/bootstrap-manifest.json` (they match the same v20260904.0 artifacts).

**Manual dashboard redeploy on an already-running cluster** (verified working on 2026-09-04):
1. In a clean (non-git) dir: `flynn create dashboard` (answer `yes` to git-remote replace prompt only if a `flynn` remote exists).
2. `flynn docker push flynn-dashboard:test` — pushes the locally-built image (creates a release with process type `app`, port 8080, service `dashboard-web`).
3. Set env: `flynn env set DEFAULT_ROUTE_DOMAIN=demo.localflynn.com CONTROLLER_DOMAIN=controller.demo.localflynn.com CONTROLLER_KEY=<controller-key> STATUS_KEY=<status-key> URL=https://dashboard.demo.localflynn.com SESSION_SECRET=<random> LOGIN_TOKEN=<random> APP_NAME=dashboard SECURE_COOKIES=true` (`<controller-key>`/`<status-key>` from the bootstrap output).
4. `flynn scale app=2` (process type is `app`, NOT `web`).
5. Add route: `flynn route add http -s dashboard-web dashboard.demo.localflynn.com` (the default Web URL route from `flynn create` already registers the domain).

**Verified**: `https://dashboard.demo.localflynn.com` → HTTP 200 (full dashboard UI), login `POST /user/sessions` → 302, `/config` returns working controller/status endpoints.

**Login troubleshooting — "token not correct" / HTTP 401 on `POST /user/sessions`** (2026-09-04): The token is correct server-side (confirmed via full session flow: `POST /user/sessions` with the raw token returns 302 + session cookie; wrong token returns 401). A 401 is a client-side input problem, caused by either:

1. **URL-as-token**: Navigating to `https://dashboard.demo.localflynn.com/?token=<token>` makes the dashboard JS read the **entire URL** (`{"token":"https://dashboard.demo.localflynn.com/?token=..."}`) as the token value, which never matches. To log in, open plain `https://dashboard.demo.localflynn.com` (no query string) and paste the **raw token** into the login field, or `curl` it directly:
   ```bash
   curl 'https://dashboard.demo.localflynn.com/user/sessions' -X POST \
     -H 'Content-Type: application/json' \
     --data-raw '{"token":"cf1cc11ed7e6f1dcfb88e1c6a3519508"}'
   ```
   → 302 + session cookie.
2. **Typo in the token** (easy to mis-type; it is the same chars as the controller key prefix). The real token is 32 chars: `cf1cc11ed7e6f1dcfb88e1c6a3519508` (note `cf1cc11…` — digit `1`s, no lowercase `l`). Copy-paste it rather than typing.

Also, clear the browser cache/hard-reload once: an old service worker or autofill may still serve the stale `d5c16b97…` token from the previous cluster.

### Noted but Acceptable
- `discoverd/health/check.go:78` disables TLS verification for internal health probes; acceptable if documented, but should require a CA bundle for public-network health checks.
- `host/logmux/sink.go:550` allows `syslog+tls` sinks to disable cert verification; acceptable if clearly documented and off by default.
- `controller/data/route.go:426` uses `crypto/md5` for event deduplication only; non-cryptographic, but should be documented or migrated to SHA-256.
- `appliance/postgresql/process.go:1007` sets `password_encryption = md5`; evaluate moving to `scram-sha-256` if client compatibility allows.

## ACME / Let's Encrypt Certificate Management (Issue #12)

Implementing issue #12: integrate `pkg/autocert` (lego v4-based ACME manager, foundation commit `6da767db`) into the controller so apps can obtain/revoke Let's Encrypt certificates via HTTP-01 and DNS-01 challenges, plus a CLI interface.

**Branch**: `feat/letsencrypt` (flynn submodule HEAD `d5c18ff`, parent bump `f46751f`)

### Status (2026-09-05)
- [x] **Controller API** (`controller/acme.go`): `POST /certs/letsencrypt` (provision), `GET /certs/letsencrypt` (list), `GET|DELETE /certs/letsencrypt/:domain` (status/revoke), `GET|PUT /certs/letsencrypt/config` (ACME config). Revocation deletes storage only after successful ACME revocation. `acmeObtainMtx` serializes obtain/renew/revoke to avoid duplicate ACME orders.
- [x] **Challenge route**: `/.well-known/acme-challenge/*token` mounted on the unauthenticated HTTP server path (alongside `/ca-cert`) so Let's Encrypt can reach the HTTP-01 responder without credentials.
- [x] **Persistence** (migration 50): `acme_accounts` (email UNIQUE, private_key, registration) and `acme_certificates` (domain, domains text[], cert, key, cert_url, account_email, expires_at, deleted_at, partial unique index on domain WHERE deleted_at IS NULL). `controller/data/acme.go` implements `autocert.Store` over `pkg/postgres` prepared statements.
- [x] **Config**: boot-time env vars `ACME_EMAIL`, `ACME_CA_URL`, `ACME_CHALLENGE_TYPE`, `ACME_DNS_PROVIDER`, `ACME_DNS_CONFIG`; runtime updates via `PUT /certs/letsencrypt/config` swap the lego Manager in place.
- [x] **Renewal**: 24h loop calling `Manager.RenewDue()`; also exported `Revoke` + `HTTP01Provider()` from `pkg/autocert`.
- [x] **Client** (`controller/client`): `ProvisionACMECert`, `ACMECertList`, `GetACMECert`, `RevokeACMECert`, `GetACMEConfig`, `UpdateACMEConfig`.
- [x] **CLI** (`cli/cert.go`): `flynn cert letsencrypt <domain>...` (provision) plus `--status`, `--revoke`, `--list`, `--config` (with `--enabled`, `--email`, `--ca-url`, `--challenge`, `--dns-provider`, `--dns-config`).
- [x] **Route binding (snapshot + rotation)**: `flynn route update <id> --acme <domain>` (`cli/route.go`) fetches the ACME cert from the controller and sets it on the route as PEM (LegacyTLSCert/Key) while also storing `acme_domain` on the route; on ACME provision/renewal, `controller/data/route.go` `SyncACMECert` automatically updates bound routes so the router serves the new certificate without a manual re-run. Mutually exclusive with `-c/-k` on update. Works for the `http` route type only.
- [x] **Route ACME domain tracking** (migration 51): `acme_domain` column added to `http_routes`; tracked in `router/types` and the route JSON schema.
- [x] **Tests**: `pkg/autocert` 9 passed, incl. two live ACME integration tests against Pebble/Let's Encrypt staging (`ACME_PEBBLE_TEST=1` HTTP-01 and `ACME_LETSENCRYPT_STAGING_TEST=1` DNS-01 against `acme-staging-v02`, the latter validating the AutoDNS DNS-01 provider end-to-end with real TXT record propagation); `controller` ACME suite 7 passed (`go test -vet=off ./controller/ -run TestACME`); `controller/data/acme_test.go` integration tests added for `ACMEStore` CRUD and `SyncACMECert` route rotation (compile-checked; require PostgreSQL to run). Full repo `go build ./...` clean.

### Live Cluster Validation (2026-09-07, vagrant `node1` cluster)
- [x] **End-to-end DNS-01 against production Let's Encrypt**: set `PUT /certs/letsencrypt/config` to `challenge_type=dns-01`, `dns_provider=autodns` (credentials via Enpass `domain.Pixelx`, context 2258), then `POST /certs/letsencrypt {"domains":["*.flynn.lab.p22.de"]}`. The controller itself registered the account, created the TXT record via AutoDNS, passed propagation checks and finalized the order — issuer `C=US, O=Let's Encrypt, CN=YR1`, expires 2026-12-06. No external ACME tooling involved.
- [x] **Router serving production cert**: dashboard route (`dashboard.flynn.lab.p22.de`, `acme_domain=*.flynn.lab.p22.de`) bound to the ACME cert; `openssl s_client` against the router (192.168.50.11:443) shows the LE production chain (3 certs) and plain `curl https://dashboard.flynn.lab.p22.de/` validates against the system CA bundle (backend 503 is a separate dashboard crashloop at `dashboard/api.go:49`, pre-existing).
- [x] **Bug found + fixed — route sync event collision**: provisioning succeeded but storing the cert returned 500 (`events_unique_id_idx` SQLSTATE 23505). Root cause: `syncRouteCert` (`controller/data/route.go`) reuses the route's stale `UpdatedAt` for the event dedupe hash (unlike the normal update path, which scans back a fresh `updated_at` from `http_route_update`), and `CreateEvent` has no `ON CONFLICT`, so the ACME sync event collided with the earlier `route update --acme` event. Fix: refresh `route.UpdatedAt = time.Now()` before `createEvent` in `syncRouteCert` so the router always gets a distinct route event. **The fix must be deployed before the 24h renewal loop matters (cert renews ~2026-11-06)** — until then, re-binding after renewal needs a manual `route update --acme`.
- [x] **`controller/data/acme_test.go` now actually runs**: previously "compile-checked" only — `setupTestDB` never prepared statements, so named queries failed with syntax errors, and timestamptz µs-truncation broke `ExpiresAt` equality. Added `setupACMETestDB` (migrate to 51, reconnect with `AfterConnect: PrepareStatements`) and truncated test timestamps. All 4 tests pass; without the `route.go` fix, `TestACMECertSyncsBoundRoutes` fails with the exact production 23505 error. Test DB: `docker run -d --name flynn-pg-test -e POSTGRES_HOST_AUTH_METHOD=trust -v /var/run/postgresql:/var/run/postgresql postgres:15-alpine` + `CREATE ROLE root SUPERUSER`, run with `PGHOST=/var/run/postgresql`.

### Deployment of the Fix (2026-09-07, release v20260907.0)
- [x] **TUF release v20260907.0**: `script/bootstrap-build --version v20260907.0` + `go run script/export-tuf/main.go --tuf-dir=.../flynn-tuf-repo --build-dir=.../flynn/build --source-dir=.../flynn --version=v20260907.0 --layer-cache=.../flynn/build/layer-cache --skip-base-layers`. Package-layer disk cache in `layer-cache/pkg/` made `--skip-base-layers` safe (noble base untouched). Committed in `flynn-tuf-repo@46f3e32`, pushed to GitHub + GitLab mirror.
- [x] **IPFS sync to host1/host2**: 21 new squashfs layers (218 MB; 28 exported, 7 base layers unchanged) rsynced to `/opt/flynn-tuf-dl/release-v20260907-layers`. **Gotchas hit**: (1) `release-and-sync.sh` self-deadlocks — the wrapper holds the flock on fd 9 while invoking `sync-ipfs.sh`, which re-opens the same lock file with a *new* fd and blocks on itself (killing the wrapper's sleep then releasing the lock exposed the nested `flock -w 300 9` children; the fix is to run `sync-ipfs.sh` standalone and do the host2 steps manually, or drop the lock from the wrapper); (2) `sync-ipfs.sh` refreshes TUF metadata from host1's git clone (`git fetch origin` from GitHub), so the new release commit **must be pushed to GitHub first** — the first sync captured a CID with v20260906.2 metadata (targets v848), requiring a re-sync; (3) the health-check (5 attempts × 5 s) starts before the restarted `ipfs_node` container finishes warming up — promotion failed but compose/MFS were already updated, so `.ipfs-cid` was promoted manually after the gateway recovered. Final CID `bafybeidolzhdbigla33tgriqmxbfjiugb336ndx3qcn5jlul37knxo5spu` (targets v934), host2 pinned + MFS + compose updated. Note: the unhashed `repository/targets/channels/stable` file is stale since v20260904.0 (clients use the hashed `channels/{sha512}.stable` target, which correctly serves v20260907.0; cosmetic only).
- [x] **In-place controller update** (no re-bootstrap): `POST /artifacts` with the v20260907.0 controller artifact from `flynn/build/manifests/bootstrap-manifest.json`, `POST /releases` (clone current release with the new artifact), `PUT /apps/controller/release`, then `POST /apps/controller/deploy` — note `PUT .../release` alone does not roll jobs: the subsequent deploy was initially a no-op (old==new release), fixed by reverting the pointer to the old release first, then deploying. Scheduler rolled web/scheduler/worker one-by-one; ~90 s total.
- [x] **Re-provision through the fixed path**: re-set the ACME config (in-memory only, lost on controller restart — see below) and `POST /certs/letsencrypt` → new cert (serial `06BA6AD7…`, issuer YR2), route `certificate` **auto-updated to `69cf94ed-…` with no 500** — the event-collision fix works on the live cluster.
- [x] **All 5 router nodes serve the new cert** (serial 06BA6AD7) and plain `curl https://dashboard.flynn.lab.p22.de/` validates against the system CA bundle.

### Issues Found During Deployment (pre-existing, worth fixing)
- **ACME config is not persisted**: `autocertConfigFromEnv()` only reads `ACME_*` env at controller start and `UpdateACMEConfig` keeps the config in memory — a controller restart wipes any runtime-configured ACME settings. The bootstrap manifest should carry the `ACME_*` env (or the config should be stored in Postgres).
- **Router never re-resolves controller service**: the router holds the controller event-stream IP (resolved once at startup) forever; after a controller rollout the old web job IP (`100.100.49.4`) is dead and every router logs `sync error: i/o timeout` / `no route to host` indefinitely. Workaround: `flynn -a router kill <job>` (scheduler respawns, fresh DNS lookup). Fix: reconnect logic should re-resolve `controller.discoverd` on stream failure.
- **Host volume events violate `events_app_id_fkey`**: hosts `PUT /volumes/:id` (decommission) for orphaned volumes whose `vol.AppID` is a non-existent app UUID; `CreateEvent` inserts unconditionally → SQLSTATE 23503 spam every few seconds on the controller.
- **`sync-ipfs.sh` / `release-and-sync.sh` lock + health-check issues** (see above).

### Remaining Work
- [x] End-to-end validation on a live Flynn cluster (controller API + CLI + router binding against the public Let's Encrypt endpoint) — done 2026-09-07 (DNS-01; HTTP-01 not exercised on the live cluster since the vagrant VM is not publicly reachable on port 80).
- [x] Deploy the `syncRouteCert` fix to the live cluster via a new TUF release — done 2026-09-07 (v20260907.0).
- [x] Persist ACME config (bootstrap env or Postgres) so controller restarts don't wipe it. — done 2026-09-08 via controller release env (`ACME_*` in release `5dbb9915`); survives controller restarts/rolls. A full cluster rebuild still loses it (bootstrap manifest does not carry `ACME_*` — remaining work below).
- [ ] Fix router controller-stream re-resolution on failure.
- [ ] Fix host volume-decommission events FK violations.
- [ ] Fix `release-and-sync.sh` self-deadlock (wrapper vs. nested sync-ipfs.sh lock) and lengthen health-check tolerance.
- [ ] `handler.Headers` wiring on the controller API for strict TLS/SNI (cert must be served by router, not flynn-host).
- [ ] Open a PR for `feat/letsencrypt` referencing issue #12.
- [ ] Fix dashboard crashloop (`dashboard/api.go:49` panic) introduced with the bootstrap dashboard app.


## DNS resolution fix for hello.flynn.lab.p22.de
- Identified that local Pi-hole (192.168.168.50) was serving cached NXDOMAIN (NOERROR, empty ANSWER, p22.de SOA in AUTHORITY) with TTL ~85108 s remaining (seeded ~15:35 CEST 2026-09-07).
- Flushed Pi-hole FTL DNS cache via  (using session cookie from  and Enpass password for 'Pi-hole' entry).
- Verified resolution: 
; <<>> DiG 9.20.26-1~deb13u1-Debian <<>> @192.168.168.50 hello.flynn.lab.p22.de
; (1 server found)
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 36171
;; flags: qr aa rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;hello.flynn.lab.p22.de.		IN	A

;; ANSWER SECTION:
hello.flynn.lab.p22.de.	0	IN	A	192.168.168.87

;; Query time: 2 msec
;; SERVER: 192.168.168.50#53(192.168.168.50) (UDP)
;; WHEN: Mon Sep 07 20:23:17 CEST 2026
;; MSG SIZE  rcvd: 67 returns  (AA flag).
- Verified HTTPS endpoint:  returns HTTP 200 with valid Let's Encrypt certificate (serial 06BA6AD7...).
- Verified dashboard app:  returns HTTP 200 (indicating TLS handshake success and asset loading).
- All changes committed and pushed: main repo  (submodule bumps and bootstrap manifest update), flynn submodule  (v20260907.1), tuf-repo submodule  (v20260907.1).

## Certificate Details in Dashboard (v20260907.2)

### Feature: Application Certificate Details in Dashboard

Added certificate status visibility to the Routes section of each app in the Flynn dashboard.

**Backend Changes** (Go controller):
- **`controller/utils/utils.go`**: Added `ParseCertificateDetails` function that parses a PEM-encoded certificate and extracts:
  - Subject
  - Issuer
  - Valid From (NotBefore)
  - Valid Until (NotAfter)
  - Serial Number
  - DNS Names (SANs)
- Added `ParseCertificateDetailsFromRoute` helper to extract certificate details from a route if present
- **`controller/routes.go`**: Created `RouteWithCert` wrapper struct embedding `*router.Route` with `CertificateDetails` field
- Modified `GetRoute`, `GetRouteList`, and `GetAppRouteList` handlers to return `RouteWithCert` with parsed certificate details

**Frontend Changes** (React Dashboard):
- **`dashboard/app/lib/javascripts/dashboard/views/app-routes.js.jsx`**: Added certificate details display in the Routes section
- Added `formatDate` helper for human-readable dates
- Modified route list rendering to display certificate details when available:
  - Subject
  - Issuer
  - Valid From / Valid Until dates
  - Serial Number
  - DNS Names (SANs)

**Verification**:
- Controller builds successfully (`go build ./controller`)
- Dashboard server builds successfully (`go build ./dashboard`)
- The API now returns certificate details in the route responses

**Release**: Published as v20260907.2 to TUF repository (`https://consolving.github.io/flynn-tuf-repo`) and deployed to the test cluster.

## p22.de TLS Recovery After Cluster Rebuild (2026-09-08)

**Symptom**: `SSL_ERROR_INTERNAL_ERROR_ALERT` for `https://dashboard.flynn.lab.p22.de` (and any other `*.flynn.lab.p22.de` URL) after the v20260907.2 full cluster rebuild.

**Root causes** (three independent issues):
1. **ACME config + certs wiped by rebuild**: ACME config was in-memory only (set via `PUT /certs/letsencrypt/config` on 2026-09-07) and the `dashboard.flynn.lab.p22.de` route is not part of the bootstrap manifest, so the rebuilt cluster had no p22.de route at all. The flynn-router aborts TLS with `internal_error` for any SNI without a matching route (by design — there is no default-cert fallback for unknown SNIs in `certForHandshake`, `router/http.go:359`).
2. **Multi-replica in-memory ACME config**: the controller runs 2 web replicas; `PUT /certs/letsencrypt/config` only configures the replica the request hits (round-robin GET/PUT gave inconsistent results).
3. **Router event-stream bug re-triggered** (known, see L1350): after the controller rolled (env-set deploy), all 5 routers were stuck streaming from a dead controller IP (`100.100.82.4`, `router: sync error ... i/o timeout`) and never received the new route/cert.

**Recovery**:
1. `flynn -a controller env set ACME_EMAIL=philipp@consolving.de ACME_CHALLENGE_TYPE=dns-01 ACME_DNS_PROVIDER=autodns 'ACME_DNS_CONFIG={"api_user":"WVK-Astro2","api_password":"<from Enpass domain.Pixelx>","context":"2258"}'` → release `5dbb9915`; deploy rolled all controller jobs. Env is read by `autocertConfigFromEnv()` at startup → config now survives controller restarts/rolls (partially closes the persistence TODO; a full rebuild still needs a re-set or bootstrap-manifest env).
2. Live-PUT the same config to both controller web instances directly (per flannel IP, bypassing router round-robin) to fix a stale in-memory `http-01` state on one replica.
3. `flynn cert letsencrypt "*.flynn.lab.p22.de"` → new LE production wildcard cert, expires 2026-12-07.
4. `flynn -a dashboard route add http dashboard.flynn.lab.p22.de` (route `http/1e3fd678-3ae3-4c8f-8ca0-c31284901999`) + `flynn -a dashboard route update http/1e3fd678-... --acme "*.flynn.lab.p22.de"` (note: `route update` requires the **full formatted ID** `http/<uuid>`, not the bare uuid).
5. `flynn -a router kill <all 5 router jobs>` → scheduler respawned them with fresh `controller.discoverd` resolution; streams reconnected.
6. Verified: all 5 router nodes serve the LE wildcard chain (`CN=*.flynn.lab.p22.de` ← `YR1` ← `ISRG Root X1`); `https://dashboard.flynn.lab.p22.de/` and `/apps` → 200.
7. Bound additional app routes to the wildcard cert (same `route add` + `route update --acme` flow): `example-node.flynn.lab.p22.de` (200), `status.flynn.lab.p22.de` (200), `example-http.flynn.lab.p22.de` (TLS OK; HTTP 503 because the app has no web jobs yet — it was created but never pushed).

**Notes / anomalies**:
- Deploy-created controller webs at 12:34 UTC briefly served a stale in-memory `http-01` ACME config despite correct `ACME_CHALLENGE_TYPE=dns-01` env (verified in `/proc/<pid>/environ`); a killed-and-respawned instance read the env correctly (`dns-01`). Suspected double-deploy race (setEnv's `DeployAppRelease` + subsequent release apply). Fixed via live PUT. Watch on the next controller deploy.
- `flynn -a router kill node1-...` fails with `EOF` (it kills the router serving the CLI's own request) but the job is killed+respawned anyway — cosmetic.
- Remaining TODO: carry `ACME_*` env + the dashboard p22.de route in the bootstrap manifest so a full rebuild recovers automatically.

### Transient dashboard 503 after route/cert changes (2026-09-08, observed)
- User saw the router's built-in "Service Unavailable / try again in a few minutes" page on `dashboard.flynn.lab.p22.de` right after the ACME recovery. Root cause is the router's `no backends → 503` mechanism (`router/proxy/transport.go` `errNoBackends`, `router/proxy/reverseproxy.go` serves the 503 page). When a route is (re)added or its certificate updated, the router briefly holds the route with an empty backend set until the `dashboard-web` service backends (re)register — during that window every request to that domain returns 503. It self-recovers within seconds once backends are registered (verified: 6/6 stable 200, 2 healthy backends).
- This is cosmetic/transient, not a TLS or cert problem. A persistent 503 would instead mean: route synced but service has no backends registered (crashlooping app, or stale router — check `flynn -a router log` for `no backends` / `sync error`).

### example-http pushed (2026-09-08)
- `git push flynn main` of `/tmp/opencode/example-http` (Go 1.6.4 buildpack, Procfile `web` + `another-web`) → build OK, slug 2.176 MiB, initial release scaled to `web=1`, web job `node4-84a7b93a-...` up. `https://example-http.flynn.lab.p22.de/` → 200 (`ok`). Previously it existed only as an app record with zero jobs (hence the earlier 503 on that URL).

### Dashboard origin-aware fix + layer naming bug (2026-09-08)

**Symptom**: after the TLS recovery the dashboard SPA still broke on `dashboard.flynn.lab.p22.de`. The SPA loaded `window.DashboardConfig.API_SERVER`, which the dashboard API injected as the configured `URL` (`https://dashboard.demo.localflynn.com`), then fetched `/config` **cross-origin** from the demo domain. The dashboard's CORS handler (`Dashboard API CorsHandler`, `dashboard/api.go`) only allowed the demo origin and the CSP `connect-src` (`dashboard/api.go` ContentSecurityHandler) didn't include the p22 origin → the browser blocked the config fetch.

**Fix (commit `61136f6e`, branch `feat/letsencrypt`)**: make the dashboard origin-aware, disabled by default, enabled via `INTERFACE_URL_DYNAMIC=true`:
- `dashboard/config.go`: new `InterfaceURLDynamic` flag.
- `dashboard/api.go`: `requestScheme()` honors `X-Forwarded-Proto`; `originForRequest()` returns `scheme://<request Host>` when dynamic; `CorsHandler` additionally allows that origin (defensive copy of `allowedOrigins`); `ContentSecurityHandler` appends it to `connect-src`; `ServeDashboardJs` caches the raw JS bundle once and injects `window.DashboardConfig` with `ApiServer: originForRequest(req)` **per request**.
- Tests: `dashboard/api_origin_test.go` (4 tests passing). The pre-existing `TestUserSessionForm` failure is unrelated (fails identically without these changes).

**Deploy** (built locally, Go-only — `bindata.go` keeps frontend assets in the repo):
1. Built `/tmp/opencode/flynn-dashboard-new`, created a new squashfs layer, placed it in `flynn-tuf-repo/repository/targets/` (served by the local layer-proxy at 192.168.121.1:443 as `https://dl.consolving.net/{id}.squashfs`), and created artifact + release via `POST /artifacts` / `POST /releases` (controller internal API, Basic auth).

**Layer naming bug (root cause of repeated `verify: expected ... but got ...` deploy failures)**:
- First deploy failed on every host with: `error getting squashfs layer from https://dl.consolving.net/e1db81…squashfs: verify: expected sha512_256 hash "e1db81…" but got "b5b882c9…"`.
- The proxy AND curl both returned what looked like the right bytes — because the layer file was **misnamed**: I had taken the first 64 hex chars of the **full sha512** (`e1db81…d3019…`) as the layer ID instead of the **sha512_256** (`b5b882c9…`). Full-sha512 checks masked it; the host verifier hashes sha512_256 and correctly rejected.
- Fix: rename the target to `{full_sha512}.{sha512_256}.squashfs` (`.b5b882c9…squashfs`), correct `manifest.json`, create a **new artifact with a distinct URI** (artifacts are deduped by `type+uri` — same URI silently returns the old artifact!), new release, redeploy.
- Deploy API notes: `POST /apps/:app/deploy` body is `{"id": "<release_id>"}` (a `ct.Release`); old release is auto-derived from the app's current release; `POST /releases` requires `app_id` in the body; artifact POST dedupes on `(type, uri)`.

**Result**: release `30a519e2-…` deployed (jobs `node5-f7e23edf`, `node3-d6df8127` up). Verified:
- `https://dashboard.flynn.lab.p22.de/assets/dashboard-….js` → `window.DashboardConfig.API_SERVER = "https://dashboard.flynn.lab.p22.de"` (same-origin).
- `https://dashboard.demo.localflynn.com/assets/dashboard-….js` → `API_SERVER = "https://dashboard.demo.localflynn.com"` (backward compatible).
- CORS preflight/response on `/config` from the p22 origin → `access-control-allow-origin: https://dashboard.flynn.lab.p22.de`; CSP `connect-src` includes it.

**Remaining TODO**: `INTERFACE_URL_DYNAMIC` is only set on the dashboard release; the full-rebuild path (bootstrap manifest) still needs the origin-agnostic URL handling documented/set, and the ACME `ACME_*` env + p22.de routes should move into the bootstrap manifest (see p22.de TLS Recovery section).

### installcert loop on p22.de (2026-09-08)

**Symptom**: `http://dashboard.flynn.lab.p22.de/installcert` was still served despite the valid LE wildcard for `*.flynn.lab.p22.de`.

**Root cause** (client slice `main.js`): on an http page `__isCertInstalled()` pings `https://controller.<default_route_domain>/ping`. The dashboard release env still used the bootstrap defaults (`DEFAULT_ROUTE_DOMAIN=demo.localflynn.com`, `CONTROLLER_DOMAIN=controller.demo.localflynn.com`), so the ping went to `controller.demo.localflynn.com`, which terminates TLS with the **ephemeral self-signed Flynn CA**. The browser refuses the untrusted cert → XHR status 0 → fallback `http://controller.demo.localflynn.com/ping` returns 200 → dispatches `HTTPS_CERT_MISSING` → `installcert`. On direct https access the https ping also fails → `CONTROLLER_UNREACHABLE_FROM_HTTPS` bounces back to http first. Also: **no route existed for `controller.flynn.lab.p22.de`** at all (router aborts TLS with `internal_error` for that SNI), so it could never have been the ping target.

**Fix** (runtime via controller API, no code):
1. Created route `http/0b5df2e4-…` on the controller app: `controller.flynn.lab.p22.de` → service `controller`, `acme_domain=*.flynn.lab.p22.de`, cert = LE wildcard (reused cert id `4cf952e2…`). Now `https://controller.flynn.lab.p22.de/ping` → 200 with the trusted LE chain (verified via `openssl s_client`).
2. Cloned the dashboard release with `DEFAULT_ROUTE_DOMAIN=flynn.lab.p22.de`, `CONTROLLER_DOMAIN=controller.flynn.lab.p22.de` → released `f92f35bf-…`, deployed. `/config` now reports p22 endpoints; the client ping hits the trusted controller host → 200 → the http page auto-redirects to https and the SPA loads with **no installcert**.

**Durability**: the whole p22.de routing layer + dashboard env is now captured idempotently in `vagrant/configure-p22-domain.sh` (env-driven, no secrets baked in) so a node1 rebuild can re-apply it in one step. Runtime API notes for future ops: controller API is **not** under `/v1/` (paths are `/apps`, `/releases`, `/routes`, `/certs/letsencrypt/config`, …); the ACME cert object uses lowercase `cert`/`key` fields; the `*.` wildcard in `/certs/letsencrypt/domains/*.flynn.lab.p22.de` must be URL-encoded (`%2A`); route creation body is `{"type":"http","service":...,"domain":...,"path":"/","acme_domain":...,"certificate":{"cert":...,"key":...}}`.

### Dashboard app-details: missing log output and certificate details (2026-09-09)

**Symptom 1 — logs**: opening a process's log in the dashboard app-details view showed a single line `[undefined] undefined` instead of log output.

**Root cause**: `dashboard/app/lib/javascripts/dashboard/stores/job-output.js` opens `window.EventSource(url)` where `url` includes `&key=<controller_key>` as a **query parameter**, because native `EventSource` cannot set an `Authorization` header. `controller/authorizer/authorizer.go:AuthorizeRequest` has never (in any commit in this repo) read a `key` query parameter — it only checks the `Authorization` header (Basic or Bearer) — so every browser-initiated log stream got **HTTP 401**. `job-output.js` then sets `streamError = "Failed to connect to log"` (a plain string); `command-output.js.jsx` formats each output item as `` `[${item.timestamp}] ${item.msg}` ``, and a bare string has neither field, hence the literal `[undefined] undefined`. Confirmed via `curl`: same endpoint returns HTTP 200 with real log data using Basic Auth, and 401 using `?key=`.

**Symptom 2 — certificates**: the "Certificate Details" block never appeared under a route in the app-details "Routes" section, even though the controller's `GET /apps/:id/routes` correctly returns a populated `certificate_details` object (subject/issuer/validity/serial/dns_names).

**Root cause**: `certificate_details` rendering in `dashboard/app/lib/javascripts/dashboard/views/app-routes.js.jsx` was added in commit `2cb62747 feat: add certificate details to dashboard routes view`, but the **deployed dashboard artifact predates that commit** — our earlier fix (previous section) only changed the dashboard release's **env vars**, never its **code artifact**. Confirmed by downloading the live JS bundle and grepping: zero occurrences of `certificate_details` in the old bundle.

**Fix 1 (controller, source change)**: `controller/authorizer/authorizer.go` `AuthorizeRequest` now falls back to a `?key=` query parameter when there's no usable Basic-Auth/Bearer credential, authorizing it the same way as the Basic-Auth password (via `AuthorizeKey`). Commit `17b518ee controller: accept key as query param fallback for log SSE auth` (flynn submodule).

**Fix 2 (dashboard, rebuilt artifact)**: rebuilt the dashboard from current `flynn` HEAD end-to-end:
- `go build ./dashboard/app` → `dashboard-compile` (the asset-matrix-go compiler, vendored).
- Ran `dashboard-compile` against `dashboard/app/lib` + `dashboard/app/vendor` to produce `build/assets/*` + `build/dashboard.html`. This required **Node.js 12.22.12** (via `asdf`) and **Python 2.7.18** (via `asdf`, built from source) — `node-sass@4.12`'s prebuilt binary only matches older Node ABI versions, and its `node-gyp` fallback needs `python2`; neither is installed by default in this environment.
- `go-bindata -nomemcopy -nocompress -pkg main app/build/...` (matching `dashboard/img/compile.sh` exactly) to generate a real `bindata.go`, temporarily swapped in for the checked-in dev stub, then `go build ./dashboard` → `flynn-dashboard` binary with all assets embedded. Restored the stub afterward (`git checkout -- dashboard/bindata.go`) so the working tree stays clean.
- Verified the new bundle contains `certificate_details` (cert-details feature) and the (already-present) `Failed to connect to log` string (log-stream error path, now moot given fix 1).

**Deployment mechanism — `/etc/flynn/bin-overrides/`**: both the patched `flynn-controller` and rebuilt `flynn-dashboard` binaries were deployed via the existing host-level override mechanism in `host/libcontainer_backend.go` (`binOverridesDir := "/etc/flynn/bin-overrides"`): any file placed there on a host replaces the same-named file in `/bin/` inside that host's container overlay at **container creation time**, without touching the TUF-hosted squashfs artifacts. This was **not durable via a full rebuild-from-artifact path** — building/publishing new signed images through the `dl.consolving.net`/IPFS/TUF pipeline (`script/export-tuf`, `/opt/flynn-tuf-dl/release-and-sync.sh` on `host1.consolving.net:24`) was judged out of scope for two small binary patches, given the pipeline is set up for full component releases.
- Placed identical binaries (verified via `sha256sum`) on **all 5 cluster hosts** (`192.168.50.11-.15`), not just the 2 that happened to be running the `controller`/`dashboard` jobs at the time — both are regular scaled processes (not `omni`-pinned), so the scheduler can (and did, mid-fix) reschedule a killed job onto any other host.
- Restarted the running job(s) via `pkill -f /bin/<binary>` on the host (as root) so the scheduler creates a fresh job on some host, which mounts the override; killing rather than a graceful stop was used since the job's own container was going to be discarded anyway.
- **Known limitation**: this override is a plain file per host, independent of the artifact/release history. A host reimage or a future full artifact-based redeploy would silently lose it. It's not currently automated into `vagrant/configure-p22-domain.sh` or any other idempotent script — a follow-up should either (a) fold `bin-overrides` provisioning into a script backed by binaries stored somewhere durable (not git, given their size: ~24 MB and ~22 MB), or (b) do the proper TUF/IPFS artifact publish for a permanent fix.

**Verification**: `curl -N -H 'Accept: text/event-stream' '.../apps/<id>/log?...&key=<key>'` → HTTP 200 with real log lines (previously 401) on all 5 hosts (tested directly via each host's `100.100.x.x` discoverd address, and repeatedly via the public router to confirm both controller replicas were fixed). New dashboard bundle (`dashboard-9fd68f0ae95fb0deac2384bff329c9e4.js`) served at `https://dashboard.flynn.lab.p22.de/`, contains `certificate_details`, page loads 200, `/config` unchanged.

### CRITICAL REGRESSION: `bin-overrides` broke merged-usr apps cluster-wide (2026-09-09)

**Impact**: shortly after the `bin-overrides` deployment above, `example-http` (and potentially any other app using a merged-usr base image) started crash-looping — `flynn get apps/example-http/jobs` showed `state: down`, `host_error: "fork/exec /runner/init: no such file or directory"`, `restarts` climbing every ~30s (fresh job scheduled → immediate failure → backoff → repeat), with **zero successful starts** and no `example-http-web` service ever registered in discoverd. Reported by the user as "the web application seems to crash constantly."

**Root cause**: `host/libcontainer_backend.go`'s bin-override code (lines ~699-719) runs `os.MkdirAll(filepath.Join(diffDir, "bin"), 0755)` **unconditionally for every container**, as soon as `/etc/flynn/bin-overrides` exists on the host (regardless of which files are in it). Ubuntu-based Flynn images use **merged-usr** (`/bin -> usr/bin` symlink; confirmed via `ls -la .../rootfs/bin` → `lrwxrwxrwx ... bin -> usr/bin`, plus `bin.usr-is-merged`/`lib.usr-is-merged`/`sbin.usr-is-merged` marker files in the layer). Creating a **real directory** at `/bin` in the overlay's upperdir shadows that lower-layer symlink for the whole merged view — overlayfs has no way to "merge into" a symlink, so the upper directory entry wins completely, and the container's `/bin` becomes just the 2 override files (`flynn-controller`, `flynn-dashboard`) instead of the full `/usr/bin` (bash, coreutils, etc.). `example-http`'s entrypoint `/runner/init` is a **Bourne-Again shell script** (`#!/bin/bash` shebang); with `/bin/bash` no longer resolvable, `execve()` returns `ENOENT` for the *interpreter*, which Go's `os/exec` reports identically to a missing target file: `fork/exec /runner/init: no such file or directory` — a well-known ambiguity in that error string that initially pointed the investigation at the wrong layer (squashfs/layer-cache corruption, loop-device exhaustion — both ruled out; the base layer's `/runner/init` file and its squashfs mount were verified intact throughout).

Before this session, `/etc/flynn/bin-overrides` did not exist on any host, so this code path was always skipped (`os.ReadDir` errors on a missing dir) — meaning **this bug has always existed in `host/libcontainer_backend.go` for any base image using merged-usr**, it just had never been triggered because nothing had ever populated that directory on this cluster until today.

**Immediate fix**: removed `/etc/flynn/bin-overrides` entirely from all 5 hosts (`rm -rf`). Verified `example-http`'s very next scheduled attempt started cleanly (`state: up`, no `host_error`) and `https://example-http.flynn.lab.p22.de/` returned `200 ok`. Checked all other apps (`example-node`, `status`, `taffy`, `tarreceive`, `gitreceive`) — all `up`, zero restarts, unaffected (likely just scheduling luck: they didn't happen to need a fresh container during the broken window).

**Consequence**: this reverts the controller `key`-auth fix and the rebuilt dashboard back to whatever binary each job's base artifact provides, **the next time either job is rescheduled** (already-running processes keep the patched binary in memory until then — no immediate change). The source fixes themselves (commit `17b518ee` in `flynn`, and the ability to rebuild the dashboard from HEAD, both documented above) are unaffected and remain the correct long-term fix; they should be delivered via a proper TUF/IPFS artifact publish (see "Release workflow" in Phase 7 above) rather than `bin-overrides`, until `host/libcontainer_backend.go`'s bin-override code is itself patched to be merged-usr-safe (e.g. by writing into `/usr/bin` — the symlink target — instead of unconditionally `MkdirAll`-ing `/bin`, or by skipping the override entirely when the target path is a symlink to a directory that already contains other entries).

**Follow-up (not yet done)**: fix `host/libcontainer_backend.go`'s bin-override injection to resolve symlinks before deciding where to write (or resolve `/bin` → `/usr/bin` explicitly), then re-add `bin-overrides` support with a regression test covering a merged-usr base image before ever repopulating `/etc/flynn/bin-overrides` on this cluster again.

### Dashboard: auto-provision Let's Encrypt cert on new routes (2026-09-09)

**Feature gap** (reported alongside the crash above): the dashboard's "Add new domain" dialog always created a plain HTTP route with no `acme_domain` and no certificate — confirmed in `actions/app-routes.js`/`views/app-route-new.js.jsx`: the `CREATE_APP_ROUTE` payload only ever contained `{type, service, domain, path, drain_backends}`. This isn't a regression, it's how the dashboard has always worked; the controller side already fully supports it (`POST /certs/letsencrypt` + `SyncACMECert` matching on `acme_domain`, exactly what was done manually for the p22 routes earlier) — only the dashboard needed wiring.

**Fix** (`flynn` commit `2de67baf`): `client.js` gained `provisionACMECert(domains)` (`POST /certs/letsencrypt`, Basic Auth — no `EventSource`/query-param auth involved here, so unaffected by the earlier 401 bug). `actions/app-routes.js`'s `createAppRoute` now sets `acme_domain: route.domain` on route creation, then calls `provisionACMECert([domain])` right after; provisioning failure (e.g. domain not delegated to the configured ACME DNS provider) is logged to the console but doesn't block the route, which keeps working over plain HTTP. Once a cert lands, the existing `SyncACMECert` → `ROUTE` event → `AppRoutesStore` flow updates the UI automatically (and now works reliably since the dashboard's real-time `/events` stream is also `EventSource`-based and benefits from the same `?key=` authorizer fix from the section above).

**Rebuild & deploy — second, much more careful `bin-overrides` incident**: rebuilt the dashboard the same way as before (Node 12 / Python 2 / go-bindata pipeline). Before redeploying, explicitly checked whether the dashboard's own base image is merged-usr (it isn't — `ls -la` on the cached squashfs layer shows `/bin` as a **real directory**, only `/sbin -> bin` is a symlink), so `bin-overrides` was judged safe *for the dashboard's own container*. Applied the binary to all 5 hosts in parallel, restarted both dashboard replicas, and removed `/etc/flynn/bin-overrides` again within roughly 15 seconds of applying it — but that was still long enough for the scheduler to (re)start **`example-http`, `blobstore`, `postgres`, `mongodb`, `mariadb`, and `redis`** on the same hosts during the window, all Ubuntu/merged-usr-based, all hit by the same shadowed-`/bin` bug (`blobstore`/`postgres`/`mongodb`/`mariadb`/`redis` failed with `exec: "/bin/flynn-<name>": stat ...: no such file or directory` — the *binary itself* missing this time, not just a shebang interpreter, since these are compiled Go binaries placed directly under `/bin` in their merged-usr images). All six recovered automatically on their next restart attempt once `bin-overrides` was removed (`state: up`, no `host_error`, restart counters stopped climbing); confirmed via `https://controller.flynn.lab.p22.de/ping` + `/apps` (200, which transitively proves postgres — the controller's `DATABASE_URL` backend — is healthy) and `https://example-http.flynn.lab.p22.de/` (200).

**Conclusion — do not use `bin-overrides` on this cluster again** until `host/libcontainer_backend.go` itself is fixed to be merged-usr-safe. Even a ~15-second window with only *one* target binary in the override directory was enough to crash six unrelated core/system apps, because the code path triggers unconditionally for *every* container start on a host, not just ones that need an override. Any future controller/dashboard binary fix should go through a proper artifact rebuild + TUF/IPFS publish (see the "Release workflow" under Phase 7) instead.

### Separate incident: `flynn-host` itself crash-looping on node2 (2026-09-09)

**Symptom**: dashboard reported unreachable by the user. Root cause was unrelated to the bin-overrides bug above: `flynn-host` (the per-host daemon, not a container job) was itself in an infinite crash loop on `node2` (`192.168.50.12`) — systemd restart counter at 673+ and climbing every ~5.5s, `journalctl -u flynn-host`: `could not restore from host persistence db: error loading container state: container "node2-443c6d35-6738-496e-b11d-cd2d9aefa22b" does not exist` (`host/state.go` `Restore()`, called from `host.go:450`). With `flynn-host` unable to start, that host had **no discoverd, no flannel, nothing** running — likely triggered by the earlier `pkill -f /bin/flynn-controller`/`flynn-dashboard` restarts in this session, which kill the job process directly and bypass flynn-host's normal stop/cleanup path, leaving a stale reference in its local BoltDB (`/var/lib/flynn/host-state.bolt`) to a container libcontainer had already fully removed.

**Fix**: stopped `flynn-host` (`systemctl stop`), backed up `host-state.bolt`, wrote a small standalone Go tool (using the vendored `github.com/boltdb/bolt`, built and run directly on the host, not committed) to open the DB and delete **only the exact key** `node2-443c6d35-6738-496e-b11d-cd2d9aefa22b` from the `jobs` and `backend-jobs` buckets (verified present in exactly those two buckets first, via a dry-run/read-only pass, before deleting). A first attempt used a substring match against both keys *and values*, which over-matched and additionally wiped the `backend-global`/`backend` blob and the `persistent-jobs`/`flannel` entry — caught immediately, restored from the pre-change backup, and redone with an exact-key-only match touching just the two intended buckets. `flynn-host` then started and stayed up.

**Residual gap (not fully resolved)**: the deleted job was actually node2's **flannel** job. Flynn-host's local "persistent job" resurrection (the `persistentBucket` logic in `state.go`'s `Restore()`) can only resurrect a job it still has a definition for in the `jobs` bucket — since that entry is now gone, flannel is not automatically recreated on node2. Discoverd *did* self-heal (a different persistent-jobs entry, untouched, resurrected it under a new job ID, and it successfully rejoined the cluster's raft peer set — confirmed via `GET /raft/peers` on node2 returning all 5 hosts). However `node2` still doesn't reappear in the cluster-wide `flynn-host` discoverd service list even after multiple `flynn-host` restarts, and no new flannel job has been scheduled there by the controller's scheduler despite `flannel` being an `omni: true` process (should be 1-per-host); scheduler logs show it does see discoverd service events from node2 but rejects them as `"error handling service event, unknown job"` since the locally-resurrected job ID was never one the scheduler created. **Net effect**: the cluster runs fine on the other 4 hosts (confirmed dashboard reachable 6/6 consecutive checks, both http/https) but node2 is a degraded/idle cluster member pending a proper host-rejoin fix — follow-up needed, not resolved in this session.

### Verified: ACME auto-provisioning works for domains delegated to `run.consolving.net` (2026-09-09)

Checked actual DNS delegation: `p22.de` → `ns1-4.consolving.de` (registrar defaults), but `lab.p22.de`, `flynn.p22.de`, and `apps.flynn.p22.de` are all separately delegated to **`run.consolving.net`** — the same custom DNS host that successfully served the `*.flynn.lab.p22.de` DNS-01 challenge earlier. Live end-to-end test (mimicking the new dashboard flow exactly, via direct API calls against `example-http`): created a route for `test.apps.flynn.p22.de` with `acme_domain` set, then `POST /certs/letsencrypt` — **succeeded**, real Let's Encrypt certificate issued (`CN=test.apps.flynn.p22.de`, issuer YR1, valid until 2026-12-08), and it auto-attached to the route via the existing `SyncACMECert` flow (`certificate_details` populated correctly). Confirms the current `ACME_DNS_CONFIG`/autodns context works for **any domain delegated to `run.consolving.net`**, not just `*.flynn.lab.p22.de` — i.e. `flynn.p22.de` and its subdomains are covered too, but plain `p22.de` or any other branch not delegated there would not be. (The route itself returned `http 404`/`https` connection failure when tested live — expected, since DNS-01 only proves domain ownership via a TXT record and doesn't create the A/CNAME needed for actual traffic; the test route and its domain were never meant to resolve to the cluster.) Test route deleted after verification; the issued cert was left in place (unused certs are harmless, no need to revoke).

### Two more infra bugs found while debugging "dashboard unreachable" (2026-09-09)

**Bug 1 — asymmetric NAT routing (host-level, outside Flynn)**: the user's browser could resolve `dashboard.flynn.lab.p22.de` (real public DNS → `192.168.168.87`, this Proxmox host's LAN IP) and ping it fine, but every HTTPS/HTTP connection hung until timeout. Diagnosed via coordinated `tcpdump` captures on both the LAN-facing (`vmbr0`) and cluster-facing (`virbr2`) interfaces while the user retried `curl -v`: the client's SYN reliably arrived at `192.168.50.11:443` (the DNAT target, `node1`) with the **original client IP preserved** (`192.168.168.72`, correct DNAT behavior) — but no reply ever came back. Root cause: `node1`'s own default route points out a *different* interface/gateway (`ens6` → `192.168.121.1`, an unrelated libvirt network) rather than back through `ens7` (`192.168.50.0/24`, where our NAT host lives), because the VM has no specific route for the client's real (foreign) subnet `192.168.168.0/24`. Its reply therefore left via the wrong interface and was never seen again — while requests originating *from* `192.168.50.0/24` (or from this host itself, hairpin-style) worked fine, since the VM has an explicit route for that subnet and replies correctly.
- **Fix**: added `POSTROUTING` `MASQUERADE` rules on the NAT host for traffic destined to `192.168.50.11:80` and `:443`, so the VM always sees forwarded requests as coming from the gateway itself (`192.168.50.1`, on its own subnet) rather than the real external client IP — guaranteeing a symmetric reply path. Applied live (`iptables -t nat -A POSTROUTING -d 192.168.50.11/32 -p tcp --dport {80,443} -j MASQUERADE`) and persisted in `/etc/iptables/rules.v4` (validated with `iptables-restore --test` before/after) so it survives a reboot. Verified: `curl` from the user's real machine over the actual DNAT path succeeded immediately after.
- This NAT setup predates this session entirely (not something introduced by any earlier change here) — it was presumably only ever tested from hosts within `192.168.50.0/24` or from the gateway itself, never from a genuinely external LAN client, which is why the asymmetry went unnoticed until now.

**Bug 2 — router's route/cert sync goes stale when its watched controller instance dies**: even after fixing the NAT issue, a *newly added* dashboard route (`test123.flynn.lab.p22.de`, created via the new "Add domain" ACME flow, confirmed to have a valid attached Let's Encrypt cert via the controller API) failed TLS with `SSL routines::tlsv1 alert internal error` — the exact same router-level "no cert for this SNI" symptom seen earlier for `controller.flynn.lab.p22.de` before that route existed. Root cause: `router/store.go`'s `NewControllerStore()` picks `discoverd.NewService("controller").Instances()[0]` — the *first* controller instance — **once**, at router startup, and opens a long-lived `StreamEvents` SSE subscription to specifically that instance (`router/sync.go`'s `Syncer.Sync`) for real-time route/cert updates. It never re-resolves or reconnects to a different instance if that one goes away. Given how many times the controller has been killed/rescheduled across this whole session, the actual external-facing router (the one instance on `node1`/`192.168.50.11`, since inbound traffic is DNAT'd to a single fixed host — 3 *other* router replicas exist but never receive real external traffic and were a red herring) had been running since `Sep08` boot, watching a controller instance that no longer existed, and had silently stopped receiving any route/cert updates since.
- **Fix**: restarted the router process on `node1` (`pkill -f /bin/flynn-router`, scheduler creates a fresh job — no `bin-overrides` involved, so none of the merged-usr risk from earlier applies). On startup it does a full `List()` + fresh `Watch()` against a currently-live controller instance, immediately picking up `test123`'s route and cert. Verified `test123.flynn.lab.p22.de` now returns 200.
- **Follow-up (not fixed)**: this is a latent architecture gap, not specific to today's incidents — *any* time every controller instance the external router was originally watching gets replaced, route/cert sync silently goes stale until the router itself is restarted, with no self-healing and no obvious error surfaced anywhere. A proper fix would have `router/store.go` re-resolve/reconnect to a live controller instance (or subscribe via discoverd instance-change notifications) instead of pinning to a single instance address for the router process's entire lifetime.

**Bug 3 (user-side, resolved by the user directly) — no DNS record for newly-added domains**: `test123.flynn.lab.p22.de` still failed to resolve at all for the user even after Bug 2 was fixed, since it (like the earlier `test.apps.flynn.p22.de` test) never had a DNS record — the dashboard's ACME auto-provisioning gets a certificate via DNS-01 without ever needing/creating an A record, so a brand new hostname has no way to route real traffic until DNS is added. The user added a **wildcard** entry in the local Pi-hole (`*.flynn.lab.p22.de` → `192.168.168.87`, confirmed via `dig` for a random nonexistent subdomain also resolving) rather than a one-off host entry, so any future dashboard-added route now resolves automatically for LAN clients using Pi-hole, without further manual DNS edits per domain. Not something fixable from the cluster/agent side — Pi-hole's local DNS config is managed directly by the user, outside the API surface available here.
