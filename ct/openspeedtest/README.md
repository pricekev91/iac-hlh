# OpenSpeedTest

Service deployed on `hlh-docker` LXC for WiFi performance benchmarking.

## Access

- URL: http://192.168.1.20:80
- Purpose: Benchmark Wi-Fi performance independent of ISP

## Topology

```
prox01 (192.168.1.10) — Proxmox 9.2 host
  └── hlh-docker LXC (192.168.1.13) — Docker engine
        └── openspeedtest container (192.168.1.20:80)
```

## Deploy

```bash
./deploy-openspeedtest.sh [--host <ip>] [--ask-pass|--use-key]
```

Options:
- `--host <ip>` — override target host
- `--ask-pass` — SSH password auth (default)
- `--use-key` — SSH key auth via $SSH_KEY

## Files

- `docker-compose.yml` — Compose stack (read by Dockhand/Portainer)
- `ansible-playbook.yml` — Ansible deployment playbook
- `deploy-openspeedtest.sh` — One-command deploy script
