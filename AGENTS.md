# Flynn Agent Instructions

## Project Context
Flynn is an unmaintained open-source PaaS being rebuilt with new TUF (The Update Framework) infrastructure. The original TUF repo and release hosting are offline. See `implementation-plan.md` for current status, key decisions, and the TUF security model.

## Repository Layout
- `flynn/` — Full Go monorepo (module `github.com/flynn/flynn`, Go 1.13). All Go code lives here.
- `flynn-tuf-repo/` — New TUF repository (keys + metadata). Deployed to `https://consolving.github.io/flynn-tuf-repo`.
- `specs/` — Technical specifications (dev environment spec, architecture placeholders).

## Key Directories Inside `flynn/`
- `host/` — `flynn-host` binary (package `main`). Uses libcontainer for containers. Entry: `host/host.go`.
- `controller/` — API server, scheduler, worker (each `package main` in separate dirs).
- `bootstrap/` — Cluster bootstrap actions. Manifest template: `bootstrap/manifest_template.json`.
- `cli/` — `flynn` CLI tool.
- `builder/` — Build system. `builder/manifest.json` defines all component images and build steps.
- `schema/` — JSON schemas for controller and router APIs. Check these before modifying controller logic.
- `appliance/` — Database appliances (postgresql, mariadb, mongodb, redis).
- `discoverd/`, `flannel/`, `router/`, `logaggregator/`, `blobstore/` — Core infrastructure services.
- `script/` — Build, release, and test orchestration scripts.
- `vendor/` — Vendored Go dependencies (committed to repo; no `go mod download` needed).

## Build System
The original Flynn build is self-hosting: it requires a running Flynn cluster to build itself (chicken-and-egg problem). The `script/build-flynn` script handles bootstrapping from a downloaded `flynn-host` binary.

**Current workaround**: Core components are built manually with `go build` due to broken orchestration. Run from `flynn/`:
```sh
go build ./host          # builds flynn-host (requires cgo, Linux)
go build ./cli           # builds flynn CLI
go build ./controller    # builds flynn-controller
```

### Makefile Targets (in `flynn/`)
- `make build` — Runs `script/build-flynn` (requires Linux, running Flynn cluster)
- `make test-unit` — `go test -race -cover ./...` (uses build's Go toolchain)
- `make test-integration` — Boots a Flynn cluster and runs integration tests
- `make test` — Both unit + integration
- `make clean` — `script/clean-flynn`

**Important**: `make test-unit` depends on `make build` having run first (it uses `build/_go` for GOROOT and `build/bin` in PATH). For standalone unit tests without the full build, use `go test` directly on specific packages.

### Unit Tests
```sh
# Run a specific package's tests (no build dependency needed)
go test ./pkg/cors/...
go test ./discoverd/health/...

# Volume tests require root
sudo go test -race -cover ./host/volume/...
```

## TUF Configuration
- `flynn/tup.config` — Points to new TUF repo URL and contains 4 ed25519 root public keys.
- `flynn/tup.config.backup` — Original (offline) TUF config for reference.
- `flynn/builder/manifest.json` — Must have matching `tuf.repository` and `root_keys` values.
- **Keep `tup.config` and `builder/manifest.json` in sync** when changing TUF keys or repository URL.

## Codegen
- **Protobuf**: `flynn/controller/api/controller.proto` generates `controller.pb.go`. The builder uses `protobuild` step.
- **go-bindata**: Listed as a dependency; used for embedding assets.
- **No `go:generate` directives** in project code (only in vendored deps).

## Go Module Gotchas
Three `replace` directives in `flynn/go.mod`:
- `github.com/opencontainers/runc` → `github.com/flynn/runc v1.0.0-rc1001` (custom fork)
- `github.com/godbus/dbus` → `github.com/godbus/dbus/v5 v5.0.2`
- `github.com/coreos/pkg` → `github.com/flynn/coreos-pkg v1.0.1` (custom fork)

Do not update these without understanding the custom patches in the Flynn forks.

## Code Style
- Go: `gofmt -s`
- Shell: Google Shell Style Guide
- Commit messages: subsystem prefix required (e.g., `controller: `, `host: `)
- `.fixmie.yml` disables Go comment linting

## Testing Notes
- Many tests (controller, discoverd) require PostgreSQL or other services and are designed for integration within a Flynn cluster.
- `host/volume/zfs/` tests require ZFS and root access.
- Test apps live in `test/apps/` (echoer, ping, signal, ish, etc.)
- Integration test runner: `script/run-integration-tests` (boots full cluster first).
