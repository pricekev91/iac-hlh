# OpenSpeedTest

Service deployed on `hlh-docker` host (192.168.1.13) for WiFi performance benchmarking.

## Access

- URL: http://192.168.1.13:80
- Purpose: Benchmark Wi-Fi performance independent of ISP

## Deploy

```bash
./deploy-openspeedtest.sh [--host <ip>] [--ask-pass|--use-key]
```

Options:
- `--host <ip>` — override target host
- `--ask-pass` — SSH password auth (default)
- `--use-key` — SSH key auth via $SSH_KEY

## Architecture

- **Image:** `openspeedtest/latest`
- **Network:** Docker bridge with port mapping (macvlan not supported inside LXC)
- **Host IP:** 192.168.1.13
- **Host Port:** 80 (mapped to container port 80)
- **Container Port:** 80
- **Compose:** dockhand/Portainer managed from `/srv/ct/openspeedtest`

## Files

- `docker-compose.yml` — Compose stack (read by Dockhand/Portainer)
- `ansible-playbook.yml` — Ansible deployment playbook
- `deploy-openspeedtest.sh` — One-command deploy script
