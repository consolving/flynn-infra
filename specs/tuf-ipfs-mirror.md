# TUF Distribution: HTTP Frontend with IPFS Backend

## Problem

The Flynn TUF repository (~9.2 GB, 316 files) is currently hosted on GitHub Pages (`consolving.github.io/flynn-tuf-repo`). This is a single point of failure — if the GitHub account is suspended, the repo is deleted, or GitHub Pages has an outage, no Flynn cluster can download component images.

The original Flynn infrastructure (`dl.flynn.io`, `releases.flynn.io`) going offline is exactly what caused this rebuild project. The same failure mode must not be repeated.

## Design

HTTP frontend serving content stored on IPFS. Clients see plain HTTP — no IPFS dependency in `flynn-host download`. The existing go-tuf client works unchanged.

```
flynn-host download
    │
    ▼
  HTTP (tuf.consolving.net or similar)
    │
    ├── Primary: Pinning service dedicated gateway (Pinata)
    ├── Fallback: Self-hosted kubo gateway
    └── Fallback: GitHub Pages (current)
    │
    ▼
  IPFS network (content-addressed, decentralized)
```

### Content Flow

```
CI build
  → sign TUF metadata
  → ipfs add -r --cid-version=1 ./repository/
  → pin new CID via Pinata API
  → update DNSLink TXT record (_dnslink.tuf.consolving.net → /ipfs/<new-CID>)
  → HTTP gateway serves updated content within ~60s
```

### Why IPFS Backend

- **Content-addressed**: Every file is identified by its hash. TUF already verifies hashes, so IPFS provides a second layer of integrity.
- **Decentralized**: Content can be pinned on multiple services and self-hosted nodes simultaneously. No single provider can take the repo offline.
- **Immutable history**: Old CIDs remain valid. Even if DNSLink updates, anyone with an old CID can still fetch that exact version of the repo.
- **No vendor lock-in**: Switch pinning services by re-pinning the same CIDs elsewhere.

### Why HTTP Frontend (not native IPFS)

- Flynn's go-tuf client speaks HTTP. No code changes needed.
- IPFS gateways serve content over plain HTTP at predictable paths (`/ipfs/<CID>/repository/root.json`).
- DNS-based routing (DNSLink) uses standard infrastructure.
- Avoids adding an IPFS client dependency to flynn-host.

## Architecture

### DNS (DNSLink)

```
_dnslink.tuf.consolving.net  TXT  "dnslink=/ipfs/<root-CID>"
tuf.consolving.net           CNAME  <gateway-host>
```

DNSLink was chosen over IPNS because:
- DNS propagation is faster and more predictable (TTL=60s → ~1 min)
- IPNS DHT resolution can take 30s–minutes and has reliability issues
- DNS infrastructure is battle-tested

TTL should be set to 60 seconds for near-instant updates.

### Pinning Service (Primary Gateway)

**Pinata** (recommended):
- Pro plan: $20/month for 50 GB storage + dedicated gateway
- Supports custom domains on dedicated gateways
- API for automated pinning/unpinning
- CDN-backed for performance

The dedicated gateway serves content at:
```
https://tuf.consolving.net/repository/root.json
  → resolves DNSLink → /ipfs/<CID>/repository/root.json
```

### Self-Hosted Gateway (Fallback)

A kubo node on the existing Proxmox build server, configured as a gateway-only node:

```json
{
  "Routing": { "Type": "dhtclient" },
  "Gateway": {
    "NoFetch": true,
    "PublicGateways": {
      "tuf.consolving.net": {
        "UseSubdomains": false,
        "Paths": ["/ipfs"]
      }
    }
  },
  "Swarm": {
    "ConnMgr": { "HighWater": 100, "LowWater": 50 }
  }
}
```

Resource requirements: ~1-2 GB RAM, ~15 GB disk (content + indexes). Runs alongside other services on the build server.

Pin the same CIDs as the primary service — both serve identical content.

### GitHub Pages (Legacy Fallback)

Keep the existing `consolving.github.io/flynn-tuf-repo` deployment as a third fallback. No changes needed — it already works.

### Multi-Origin Failover in flynn-host

Update `flynn-host download` to try multiple TUF repository URLs in order:

```go
var TUFMirrors = []string{
    "https://tuf.consolving.net/repository",         // IPFS-backed primary
    "https://consolving.github.io/flynn-tuf-repo/repository",  // GitHub Pages fallback
}
```

On connection failure or timeout (not TUF verification failure), try the next mirror. TUF's own signature verification ensures content integrity regardless of which mirror serves it.

## CI Integration

Add an IPFS publish step to the existing GitHub Actions workflow (`.github/workflows/ci.yml`):

```yaml
- name: Publish to IPFS
  if: github.ref == 'refs/heads/master'
  env:
    PINATA_API_KEY: ${{ secrets.PINATA_API_KEY }}
    CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
  run: |
    # Install IPFS CLI
    wget -qO- https://dist.ipfs.tech/kubo/v0.28.0/kubo_v0.28.0_linux-amd64.tar.gz | tar xz
    sudo mv kubo/ipfs /usr/local/bin/
    ipfs init --profile=server

    # Add repository to IPFS
    CID=$(ipfs add -r --cid-version=1 -Q ./flynn-tuf-repo/)

    # Pin on Pinata
    curl -X POST "https://api.pinata.cloud/pinning/pinByHash" \
      -H "Authorization: Bearer $PINATA_API_KEY" \
      -d "{\"hashToPin\": \"$CID\"}"

    # Update DNSLink via Cloudflare API
    curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -d "{\"content\": \"dnslink=/ipfs/$CID\"}"
```

## Directory Structure on IPFS

The IPFS directory mirrors the TUF repository exactly:

```
<root-CID>/
├── repository/
│   ├── root.json
│   ├── targets.json
│   ├── snapshot.json
│   ├── timestamp.json
│   └── targets/
│       ├── flynn-host.gz              (binary)
│       ├── flynn-linux-amd64.gz       (binary)
│       ├── flynn-init.gz              (binary)
│       ├── bootstrap-manifest.json
│       ├── images.json
│       ├── <component>/
│       │   ├── manifest.json          (ImageManifest)
│       │   ├── <hash>.squashfs        (layer)
│       │   └── <hash>.json            (layer config)
│       └── ...
```

`ipfs add -r` preserves this structure. The gateway serves paths directly:
`https://tuf.consolving.net/repository/targets/flynn-host.gz`

## Implementation Steps

1. [ ] Register domain / subdomain for TUF distribution (e.g., `tuf.consolving.net`)
2. [ ] Set up Pinata account (Pro plan) with dedicated gateway and custom domain
3. [ ] Initial IPFS upload: `ipfs add -r --cid-version=1` the TUF repository
4. [ ] Pin root CID on Pinata
5. [ ] Configure DNSLink TXT record and CNAME
6. [ ] Verify HTTP access: `curl https://tuf.consolving.net/repository/root.json`
7. [ ] Install kubo on build server, configure as gateway-only, pin same CID
8. [ ] Add multi-origin failover to `flynn-host download` (try IPFS gateway first, fall back to GitHub Pages)
9. [ ] Add IPFS publish step to CI workflow
10. [ ] Update `tup.config` and `builder/manifest.json` with new primary TUF URL
11. [ ] Test end-to-end: `flynn-host download` from IPFS-backed gateway

## Cost

| Item | Monthly Cost |
|---|---|
| Pinata Pro (50 GB + dedicated gateway) | ~$20 |
| Domain (if new) | ~$1 |
| Self-hosted kubo (existing server) | $0 |
| Cloudflare DNS (free tier) | $0 |
| **Total** | **~$21/month** |

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Pinata goes offline or changes pricing | Self-hosted kubo + GitHub Pages as fallbacks; re-pin on another service |
| IPFS gateway caches stale content | DNSLink TTL=60s; Pinata supports cache purging on dedicated gateways |
| Large repo size (9.2 GB) slows `ipfs add` | Only add changed files; use `--nocopy` with filestore for local node |
| DNSLink propagation delay | 60s TTL keeps updates under 2 minutes; acceptable for release cadence |
| CI secrets compromise | Pinata API key can only pin/unpin (no delete). TUF signatures protect content integrity regardless of hosting compromise — this is the whole point of TUF |
