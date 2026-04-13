# Development Environment Specification

## Problem Statement

Flynn's build system is self-hosting: it requires a running Flynn cluster to build itself. The original infrastructure (`dl.flynn.io`, `releases.flynn.io`) is offline, making the standard build flow non-functional. Additionally, the `flynn-host` binary and several core components are Linux-only (CGO, libcontainer, cgroups, netlink, ZFS), so development cannot happen natively on macOS or Windows.

Flynn uses TUF (The Update Framework) for secure component distribution, providing rollback protection, role-based key management, and CDN compromise resistance. The new TUF repository has been initialized with 4 ed25519 root keys (2-of-4 threshold) and is hosted at `https://consolving.github.io/flynn-tuf-repo`. Two configuration files must stay in sync: `tup.config` (runtime config) and `builder/manifest.json` (build-time config) -- both contain the TUF repository URL and root public keys.

A containerized development environment solves both problems: it provides a Linux build target and removes the dependency on offline infrastructure.

## Goals

1. Any developer with Docker installed can build Flynn components from a fresh clone.
2. The environment supports both quick iteration (edit on host, build in container) and full builds.
3. Unit tests for pure-Go packages run without any external services.
4. The `flynn-host` binary can be compiled (CGO + libcontainer).
5. The environment is reproducible and version-pinned.

## Non-Goals

- Running a full Flynn cluster inside the dev container (that is an integration testing concern).
- Supporting native macOS/Windows builds for Linux-only components.
- Upgrading the Go version (handled separately; the dev environment must work with Go 1.13 first).

## Architecture

```
Host machine (macOS / Linux / Windows + WSL2)
  |
  +-- Docker
       |
       +-- flynn-dev container
            |-- Go 1.13 toolchain
            |-- C toolchain (gcc, libc-dev) for CGO
            |-- libseccomp-dev (required by libcontainer)
            |-- protobuf compiler (protoc) for codegen
            |-- Project source mounted at /go/src/github.com/flynn/flynn
            |-- Persistent module cache volume
```

### Source Code Mounting

The `flynn/` directory is bind-mounted into the container at the Go module path (`/go/src/github.com/flynn/flynn`). Edits on the host are immediately visible in the container. Build artifacts remain in the container (or in a named volume) to avoid polluting the host filesystem.

### Container Base Image

Ubuntu 18.04 (Bionic) is recommended as the base for initial compatibility because:
- Flynn's existing base layers reference Bionic.
- `libseccomp` and other system dependencies are well-tested on Bionic.
- Go 1.13 was current during the Bionic era, minimizing surprises.

Once the build is stable, the base can be upgraded to a newer Ubuntu LTS.

## Required System Packages

| Package | Purpose |
|---|---|
| `build-essential` | GCC, make, libc headers (CGO compilation) |
| `libseccomp-dev` | Seccomp support for libcontainer/runc |
| `pkg-config` | Dependency resolution for C libraries |
| `git` | Version detection, submodule operations |
| `curl`, `ca-certificates` | Downloading Go toolchain and bootstrap artifacts |
| `protobuf-compiler` | Compiling `.proto` files (controller API) |
| `libzfs-dev`, `zfsutils-linux` | ZFS volume support (optional; needed for host/volume/zfs tests) |
| `sudo` | Running privileged tests (volume, cgroups) |

## Go Toolchain

Go 1.13.15 (the last 1.13 patch release) should be installed from the official Go archives. The toolchain is placed at `/usr/local/go` with `GOPATH=/go`.

Key environment variables:
```sh
GOPATH=/go
GOROOT=/usr/local/go
CGO_ENABLED=1
PATH=/usr/local/go/bin:/go/bin:$PATH
```

## Dockerfile Outline

```dockerfile
FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive
ENV GO_VERSION=1.13.15
ENV GOPATH=/go
ENV GOROOT=/usr/local/go
ENV CGO_ENABLED=1
ENV PATH=/usr/local/go/bin:/go/bin:$PATH

# System dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libseccomp-dev \
    pkg-config \
    git \
    curl \
    ca-certificates \
    protobuf-compiler \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Go toolchain
RUN curl -fsSL https://dl.google.com/go/go${GO_VERSION}.linux-amd64.tar.gz \
    | tar -C /usr/local -xz

# Working directory at the module path
WORKDIR /go/src/github.com/flynn/flynn

CMD ["/bin/bash"]
```

## docker-compose.yml Outline

```yaml
version: "3.8"

services:
  dev:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - ./flynn:/go/src/github.com/flynn/flynn
      - go-cache:/go/pkg
      - build-cache:/root/.cache/go-build
    working_dir: /go/src/github.com/flynn/flynn
    stdin_open: true
    tty: true
    privileged: false  # set to true only when running host/volume tests

  # Optional: PostgreSQL for controller/discoverd integration tests
  postgres:
    image: postgres:13
    environment:
      POSTGRES_USER: flynn
      POSTGRES_PASSWORD: flynn
      POSTGRES_DB: flynn
    ports:
      - "5432:5432"

volumes:
  go-cache:
  build-cache:
```

## Workflow

### First-time setup

```sh
# From the repository root
docker compose build dev
docker compose run --rm dev bash
```

### Building components

Inside the container:
```sh
# CLI (pure Go, no CGO needed)
go build -o /go/bin/flynn ./cli

# Controller
go build -o /go/bin/flynn-controller ./controller

# Host (requires CGO)
go build -o /go/bin/flynn-host ./host
```

### Running unit tests

```sh
# Pure-Go packages (no external deps)
go test ./pkg/cors/...
go test ./discoverd/health/...
go test ./host/logmux/...

# Volume tests (require root)
sudo go test -race -cover ./host/volume/...
```

### Rebuilding after code changes

Source is bind-mounted, so edits on the host are immediately available. Just re-run `go build` or `go test` inside the container. The `go-cache` and `build-cache` volumes persist across container restarts, so subsequent builds are fast.

## Validation Criteria

The dev environment is considered functional when all of the following succeed:

1. `go build ./cli` produces a working `flynn` binary.
2. `go build ./controller` produces a working `flynn-controller` binary.
3. `go build ./host` produces a working `flynn-host` binary (CGO links successfully).
4. `go test ./pkg/cors/...` passes.
5. `go test ./discoverd/health/...` passes.
6. `protoc` can regenerate `controller/api/controller.pb.go` from `controller/api/controller.proto`.

## Optional Enhancements (Later)

- **VS Code Dev Containers / GitHub Codespaces**: Add a `.devcontainer/devcontainer.json` for one-click cloud or local IDE setup.
- **ZFS support**: Install ZFS packages and run the container with `--privileged` for `host/volume/zfs` tests.
- **Multi-arch support**: Add an `arm64` variant of the Dockerfile for Apple Silicon development.
- **Hot-reload**: Use `watchexec` or `air` to auto-rebuild on file changes.
- **Pre-commit hooks**: `gofmt -s` check, JSON validation for `builder/manifest.json`.
