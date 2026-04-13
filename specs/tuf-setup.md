# TUF Setup -- Flynn

## Overview

Flynn uses [TUF (The Update Framework)](https://theupdateframework.io/) to securely distribute component binaries and container images. TUF provides rollback protection, role-based key management, and CDN compromise resistance. The original TUF repository (`dl.flynn.io/tuf`) is offline; a replacement has been built and deployed to GitHub Pages.

## Repository URL

| Environment | URL |
|---|---|
| **Current (new)** | `https://consolving.github.io/flynn-tuf-repo/repository` |
| Original (offline) | `https://dl.flynn.io/tuf` |

The repository is hosted via GitHub Pages from the `flynn-tuf-repo/` directory (a standalone Git repo pushed to `consolving/flynn-tuf-repo`).

## Key Hierarchy

TUF uses a hierarchy of signed metadata roles. Each role has its own key(s) and a threshold defining how many signatures are required.

### Roles and Thresholds

| Role | Algorithm | Keys | Threshold | Purpose |
|---|---|---|---|---|
| Root | ed25519 | 1 | 1 | Root of trust; delegates to other roles |
| Targets | ed25519 | 1 | 1 | Lists target files (images, binaries) with hashes |
| Snapshot | ed25519 | 1 | 1 | Snapshot of current targets.json version |
| Timestamp | ed25519 | 1 | 1 | Freshness guarantee (short-lived, re-signed frequently) |

### Role-to-Key Assignment (root.json v12)

| Role | Key ID | Public Key (hex) |
|---|---|---|
| Root | `1ab7ea138639f7da4059b480ab62ef9395d7fbec435c709499d74982d177c4aa` | `22f67c648aaade626bbd8a85aac1e02d77cb476488a967b1ece129c701ed314c` |
| Targets | `c907750d7619cf3396841056b6e5142a000f68b17399ee34c4463141beb85989` | `d77ef5acdccc6ffba650edd4bc4d292014e7afbd1f3d5af945395e587c1430b1` |
| Snapshot | `b86e8929c33606b98ac5ea14f61943b131955661bb032be0228406bb9d067be8` | `29e3309c3ed70d4927b2f55adc7ac5f5d547731fb62c5f197c02d0c1c2abac21` |
| Timestamp | `1861f61ae4cc78235a15a32a0e66dcf3623721c142e51c273b49fba13f485063` | `cddd70123e8303002498fc7f9f8c1fff87cdb321444c67b1ba9190d0394f6134` |

### Key Storage

Private keys are stored **outside** the TUF repository, in a secure directory that is never committed to git:

```
tuf-keys-secure/          # OUTSIDE of any git repository
  root.json               # Root role private key
  targets.json            # Targets role private key
  snapshot.json           # Snapshot role private key
  timestamp.json          # Timestamp role private key
```

These files are **unencrypted** (`"encrypted": false`). They must never be committed to any repository, exposed in CI logs, or shared insecurely.

The `flynn-tuf-repo/.gitignore` explicitly excludes `keys/` and `staged/` to prevent accidental commits.

### Key Rotation History

| Event | root.json Version | Date | Notes |
|---|---|---|---|
| Initial setup | v1-v4 | 2025-04-12 | 4 keys created (1 per role), keys stored in repo (mistake) |
| Key rotation | v5-v12 | 2025-04-12 | All keys rotated, old keys revoked, private keys moved outside repo, git history purged |

The rotation was performed because the original private keys were accidentally committed to the public GitHub repository. The `flynn/script/rotate-tuf-keys/` tool was used, which:

1. Generates new ed25519 keys for all 4 roles
2. Revokes the old keys
3. Signs `root.json` with **both** old and new root keys (per TUF spec for root rotation)
4. Re-signs all other metadata
5. Moves private keys to a secure external location
6. Removes private keys from the repository

After rotation, `git filter-repo` was used to purge all traces of private keys from the git history.

## Metadata Files

TUF metadata lives in `flynn-tuf-repo/repository/`:

| File | Purpose | Consistent Snapshot |
|---|---|---|
| `root.json` | Root of trust, defines key IDs and role thresholds | No (always `root.json`) |
| `targets.json` | Lists all target artifacts with SHA-256/SHA-512 hashes | Yes (hash-prefixed filename) |
| `snapshot.json` | References current version of `targets.json` | Yes (hash-prefixed filename) |
| `timestamp.json` | References current `snapshot.json`, provides freshness | No (always `timestamp.json`) |

**Consistent snapshots** are enabled (`"consistent_snapshot": true` in `root.json`). This means `targets.json` and `snapshot.json` are stored with hash-prefixed filenames (e.g., `22aae2d05...targets.json`), allowing CDN caching without stale-content attacks.

### Expiration

| Metadata | Current Expiry |
|---|---|
| `root.json` (v12) | 2027-04-12 |

Metadata must be re-signed before expiration to prevent clients from rejecting it.

## Repository Contents (Targets)

The repository contains 72 TUF targets totaling ~268 MB:

| Category | Count | Path Pattern |
|---|---|---|
| Versioned binaries/manifests | 5 | `targets/<version>/...` |
| Top-level binaries | 2 | `targets/<hash>.flynn-host.gz`, `targets/<hash>.flynn-linux-amd64.gz` |
| Image manifests | 20 | `targets/images/<hash>.<id>.json` |
| Squashfs layers | 22 | `targets/layers/<hash>.<id>.squashfs` |
| Layer configs | 22 | `targets/layers/<hash>.<id>.json` |
| Channel file | 1 | `targets/channels/<hash>.stable` |

No individual file exceeds GitHub's 100 MB limit.

## Configuration Locations

TUF settings must remain consistent across the following locations:

### 1. `flynn/tup.config`

Build-time configuration consumed by the Tupfile-based build system:

```
CONFIG_IMAGE_REPOSITORY=https://consolving.github.io/flynn-tuf-repo/repository
CONFIG_TUF_ROOT_KEYS=[{"keytype":"ed25519","keyval":{"public":"cddd7012..."}}, ...]
```

### 2. `flynn/builder/manifest.json`

The builder manifest contains the same TUF URL and root keys under the `"tuf"` key:

```json
{
  "tuf": {
    "repository": "https://consolving.github.io/flynn-tuf-repo/repository",
    "root_keys": [ ... ]
  }
}
```

### 3. `flynn/pkg/tufconfig/tufconfig.go`

Go source code defaults. These are the fallback values compiled into binaries:

```go
var (
    RootKeysJSON = `[{"keytype":"ed25519","keyval":{"public":"cddd7012..."}}, ...]`
    Repository   = "https://consolving.github.io/flynn-tuf-repo/repository"
)
```

At build time, `RootKeysJSON` and `Repository` can be overridden via `-ldflags`.

### 4. `flynn/host/cli/download.go` and `update.go`

CLI defaults for `--repository` and `--tuf-db` flags:

```
--repository  default: https://consolving.github.io/flynn-tuf-repo/repository
--tuf-db      default: /etc/flynn/tuf.db
```

### Keeping Configuration in Sync

When changing TUF keys or the repository URL, all 4 locations above must be updated together. A mismatch will cause TUF client initialization failures at runtime.

## Client Workflow

When `flynn-host download` or `flynn-host update` runs, the following TUF flow executes:

1. **Initialize local store** -- Open or create `/etc/flynn/tuf.db` (a BoltDB-based local TUF database).
2. **Connect to remote** -- Create an HTTP remote store pointing to the repository URL.
3. **Bootstrap (first run)** -- If no root keys are stored locally, call `client.Init(rootKeys, threshold)` with the compiled-in root keys and threshold of 1.
4. **Update metadata** -- Download and verify `timestamp.json` -> `snapshot.json` -> `targets.json` chain, validating signatures against the known root keys.
5. **Resolve channel** -- Read the configured channel (default: `stable`) from `/etc/flynn/channel.conf` and download the channel file from TUF targets to get the version string.
6. **Download artifacts** -- Download the versioned binaries (`flynn-host.gz`, `flynn-linux-amd64.gz`) and all container images (squashfs layers) using the verified target hashes.

The Go TUF client (`github.com/flynn/go-tuf/client`) handles signature verification, rollback detection, and consistent snapshot resolution automatically.

## Tools

### export-tuf

The custom tool `flynn/script/export-tuf/main.go` automates building and signing TUF targets:

- Compiles squashfs layers from source
- Constructs ImageManifests and Artifacts
- Generates `bootstrap-manifest.json` and `images.json`
- Stages all targets and signs TUF metadata

Usage:
```sh
go run script/export-tuf/main.go \
    --tuf-dir=/path/to/flynn-tuf-repo \
    --bin-dir=/path/to/compiled/binaries
```

**Note:** `export-tuf` requires access to private keys. Before running, copy the keys from the secure location into `flynn-tuf-repo/keys/` temporarily, then remove them afterward.

### rotate-tuf-keys

The key rotation tool `flynn/script/rotate-tuf-keys/main.go` performs a complete TUF key rotation:

- Generates new ed25519 keys for all 4 roles
- Revokes old keys from `root.json`
- Signs `root.json` with both old and new root keys (TUF spec requirement)
- Re-signs targets, snapshot, and timestamp metadata
- Copies new private keys to a secure external directory
- Removes keys from the TUF repository

Usage:
```sh
go run script/rotate-tuf-keys/main.go \
    --tuf-dir=/path/to/flynn-tuf-repo \
    --keys-out=/path/to/secure/external/keys
```

After rotation, update the root public keys in all 4 configuration locations listed above.

## Comparison: Original vs. New Setup

| Aspect | Original | New |
|---|---|---|
| Repository URL | `https://dl.flynn.io/tuf` | `https://consolving.github.io/flynn-tuf-repo/repository` |
| Hosting | Custom CDN (`dl.flynn.io`) | GitHub Pages |
| Root keys | 1 ed25519 key | 1 ed25519 key (4 total keys, 1 per role) |
| Root key public | `6cfda23aa48f530a...` | `22f67c648aaade626bbd8a85aac1e02d...` |
| Key storage | Unknown | Outside repo (`tuf-keys-secure/`) |
| Status | Offline | Active |
| Artifact count | Unknown | 72 targets (~268 MB) |

## Security Considerations

- **Private keys are stored outside the repository.** They must be kept in a secure location and temporarily copied in only when signing is needed.
- **Threshold is 1** for all roles. A single compromised key is sufficient to sign any role's metadata. Consider increasing the root threshold for production use.
- **Timestamp expiry** must be monitored. If `timestamp.json` expires, all clients will refuse to update until it is re-signed.
- **Consistent snapshots** protect against CDN serving stale content but require hash-prefixed filenames for targets and snapshot metadata.
- **`/repository` suffix** is required in the URL. The `go-tuf` `HTTPRemoteStore` appends paths directly to the base URL, so omitting `/repository` causes 404 errors.
- **Key rotation requires both old and new root keys.** The `rotate-tuf-keys` tool handles this automatically via the go-tuf API.
- **After key rotation, git history must be purged** if old private keys were ever in the repository. Use `git filter-repo --invert-paths --path keys/` followed by a force push.
