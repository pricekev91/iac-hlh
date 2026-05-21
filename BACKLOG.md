# BACKLOG

## Platform

- Add environment overlay model (`config/environments/*.yaml`) for host-specific values.
- Add CI checks for shell lint and YAML lint.
- Add policy checks for required modular variables and provider switches.

## Networking

- Add AI VM networking mode in OpenTofu (`dhcp` or `static`).
- Add DHCP lease discovery helper for dynamic inventory updates.
- Add optional UDR7 API integration for DHCP reservation automation.

## Runtime Providers

- Expand dockhand provider role to full parity with docker provider role.
- Add k8s orchestration adapter role behind the same provider contract.
