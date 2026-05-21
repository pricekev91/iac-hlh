# HLH Docker Services

These service stacks are deployed on the Docker VM created by OpenTofu and prepared by Ansible.

## Stacks

- `openspeedtest`: speed test web service
- `uptime-kuma`: uptime monitor and status dashboard

## Deploy

Run from the Docker VM:

```bash
cd /opt/hlh/services/openspeedtest && docker compose up -d
cd /opt/hlh/services/uptime-kuma && docker compose up -d
```
