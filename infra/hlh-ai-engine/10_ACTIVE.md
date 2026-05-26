# TODO

## Active

- [ ] Set AI VM network mode to DHCP until UDR7 migration is complete.
- [ ] After UDR7 cutover, decide final AI VM addressing strategy (DHCP reservation vs static).
- [ ] Confirm final DNS hostnames for AI endpoint and service stacks.

## This Week

- [ ] Run `./scripts/ai-vm-plan.bash` with real credentials.
- [ ] Validate GPU PCI IDs for passthrough on Proxmox host.
- [ ] Run `./scripts/ai-vm-apply.bash` in staging sequence.
