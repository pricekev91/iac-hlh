# AI Engine 250GB Resize - Next Steps

## ✅ COMPLETED
- Updated [iac-hlh/inventory/hlh-prod.yaml](iac-hlh/inventory/hlh-prod.yaml) with `rootfs_size_gb: 250`

## 📋 NEXT: Run on Proxmox host (192.168.6.10)

### Step 1: Delete existing LXC 101 and verify space
```bash
ssh root@192.168.6.10
cd /root
bash < /dev/stdin << 'EOF'
pct stop 101 || true
pct destroy 101 --purge 1
zfs list -h | grep -E "raidz|local"
EOF
```

### Step 2: Clone updated config and run apply
```bash
ssh root@192.168.6.10
cd /root
git clone https://github.com/yourusername/iac-hlh.git || cd iac-hlh && git pull
./iac-hlh/apply.bash inventory/hlh-prod.yaml
```

## 🎯 Expected output
- LXC 101 deleted
- New LXC 101 created with 250GB rootfs on raidZ1 pool
- Ubuntu 24.04 provisioned
- AI engine runtime installed with llama-stack

## 📊 Configuration
- **VMID**: 101
- **Hostname**: engine
- **IP**: 192.168.6.252/22
- **Cores**: 12 (from platform.yaml)
- **Memory**: 48GB (from platform.yaml)
- **Storage**: 250GB (raidZ1 pool)
- **GPU**: Enabled (AMD/Intel integrated)
- **Models path**: /srv/ai/models (mounted from host)
