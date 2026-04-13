# Flynn Infrastructure

Infrastructure, provisioning, and deployment tooling for the Flynn PaaS rebuild on Debian 13 (Trixie) with cgroups v2 support.

## Directory Structure

- `vagrant/` -- Vagrant cluster definitions and provisioning scripts (libvirt/KVM)
- `specs/` -- Technical specifications (dev environment, TUF setup, architecture)
- `implementation-plan.md` -- Project status, phase tracking, and key decisions
- `AGENTS.md` -- AI agent instructions for working on this project

## Related Repositories

- [consolving/flynn](https://github.com/consolving/flynn) -- Flynn source code (Go monorepo, `debian13-cgroups-v2-bootstrap` branch)
- [consolving/flynn-tuf-repo](https://github.com/consolving/flynn-tuf-repo) -- TUF repository metadata and artifacts (published via GitHub Pages)

## Quick Start

Single-node Flynn cluster on a KVM-capable host:

```sh
cd vagrant/
vagrant up node1
```

Three-node cluster:

```sh
cd vagrant/
NUM_NODES=3 vagrant up
```

See `vagrant/provision.sh` and the Vagrantfile header for configuration options.
