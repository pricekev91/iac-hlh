# TrashPanda App LXC Contract

`trashpanda-app` is a future HLH runtime slice owned by `iac-hlh` only as host placement and LXC wiring.

This repository does not own TrashPanda application code.

## Purpose

Provide a dedicated unprivileged LXC on HLH that hosts the TrashPanda application stack while consuming the shared AI appliance over the local network.

## Ownership Split

`iac-hlh` owns:

- the LXC definition
- CPU, memory, rootfs, and mount sizing
- network placement on HLH
- secret mount points and environment injection locations

`TrashPanda` owns:

- application containers
- compose files and app startup
- app schema and migrations
- dashboard, backend, and workers

## Initial Runtime Expectations

- unprivileged LXC
- Docker inside the LXC
- local Postgres for app state or a separately declared app data service later
- OpenAI-compatible endpoint pointed at the shared `engine` appliance

## Status

The contract is defined here now so `trashpanda-app` remains a separate future runtime. It is not reconciled by `apply.bash` yet.