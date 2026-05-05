# HLH Host Contract

## 1. Purpose

This document defines what `iac-hlh` owns on HLH and what it must not absorb from application repositories.

HLH is the Proxmox-based home lab host at `192.168.6.10`.

## 2. Ownership Boundary

`iac-hlh` owns:

- Proxmox host configuration required for persistent operation
- LXC creation, update, and destruction rules
- storage provisioning and mount strategy
- network exposure and service reachability
- host-level secret mount points and runtime injection locations
- deployment of the shared AI appliance used by multiple applications

`iac-hlh` does not own:

- TrashPanda business logic
- TrashPanda prompts, job schemas, or UI code
- application migrations or application database schema details
- product-specific automation for BrickCipher or VoxChimera

## 3. Shared Platform Principle

HLH hosts a shared AI appliance that serves more than one application.

That means the AI engine must be documented and deployed as shared infrastructure, not as a TrashPanda implementation detail.

Current implication:

- TrashPanda consumes the appliance
- future applications can consume the same appliance
- changing one application must not force a redesign of the appliance contract

## 4. Initial Runtime Shape

The first HLH layout is:

- one privileged `engine` LXC for the shared AI appliance
- one unprivileged `trashpanda-app` LXC for TrashPanda application runtime
- room for future unprivileged LXCs for `orchestrator`, `agents`, and `presentation` if they need to split out later

The host repo should optimize for isolated runtime placement and repeatable recreation of these containers.

## 5. Storage Contract

HLH should provide explicit storage locations for:

- shared model artifacts and engine state
- application persistent data
- database persistence
- generated document artifacts
- temporary high-churn scratch space when scraping or processing spikes require it

Storage decisions in this repo must remain application-agnostic where possible. Product-specific file layout belongs in the consuming application repo.

## 6. Network Contract

`iac-hlh` owns:

- IP allocation strategy on HLH
- LXC reachability rules
- host-to-container and container-to-container routing policy
- public versus private exposure decisions

Application repos may declare required endpoints, but HLH decides how those endpoints are wired on the host.

## 7. Deployment Contract With TrashPanda

For the first deployment phase:

- `TrashPanda` supplies the app container stack and its runtime requirements
- `iac-hlh` supplies the LXC, mounts, network, and shared AI appliance reachability
- secrets are stored outside git and injected by host-managed runtime wiring

This keeps app implementation and host infrastructure separately evolvable.