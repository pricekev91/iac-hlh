# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-06

### Changed

- Bump hlh-ai-engine submodule for startup stability fix (c408565)

## [0.3.0] - 2026-05

### Changed

- Convert iac-hlh into flat orchestrator with submodules (2b0ae22)
- Flatten component repositories (3d09a47)
- Register hlh-ai-engine and hlh-docker as submodules (0fa44f3)

## [0.2.1] - 2026-05

### Changed

- Prefer Q4_K_M ai-engine model on bootstrap (24df275)

### Fixed

- Revert ai-engine GPU layer selection change (1a409f1)

## [0.2.0] - 2026-04

### Changed

- Rename ai-engine LXC hostname to hlh-ai-engine (f82841b)
- Rename ai-engine provision script to deploy (0203944)
- Load ai-engine OpenTofu secrets from .hlh-secrets (3f0800b)
- Consolidate ai-engine to two entry scripts (24f8db3)
- Fix OpenTofu fuse feature flag for unprivileged LXC (ad0f70f)
- Simplify hlh-docker workflow to two scripts (083b048)

### Added

- Partial GPU offload control for large ai-engine models (ca4a2a2)
- switch-model.sh v1.3.0 with MTP auto-detect (777bd08)
- Working llama.cpp ROCm 7.2.3 deployment on gfx1150 (890M) (db3d615)

### Fixed

- Pin LXC 101 to static 192.168.1.12 (854d8f0)
- Skip default model download when mount already has gguf (6f83241)
- Mount /srv/ai/models host path into LXC (5788cbd)

## [0.1.0] - 2026-04

### Added

- Initial modular scaffolding
- AI engine LXC deployment scaffolding
- Docker VM (VMID 950) provision script
- Ansible roles for AI engine and Docker VM
- Service stacks: LocalAI, llama-server, nginx proxy
- OpenWebUI provisioning
- HLH host inventory and contract documentation
- zfsbootstrap.sh for Proxmox setup
- AMD iGPU host binding script

### Fixed

- ZFS rootfs creation syntax for Proxmox 9.x (multiple commits)
