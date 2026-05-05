# AMD iGPU Host Binding

HLH currently exposes the Strix iGPU as PCI device `1002:150e`.

For the `engine` LXC to consume `/dev/dri`, the Proxmox host must bind the device to `amdgpu`, not `vfio-pci`.

Current observed host blockers on HLH:

- `/etc/modprobe.d/blacklist-amdgpu.conf` blacklists `amdgpu`
- `/etc/modules-load.d/vfio-pci.conf` force-loads VFIO modules
- `lspci -nnk -s c5:00.0` shows `Kernel driver in use: vfio-pci`
- `/dev/dri` is absent on the host

Use `bootstrap/proxmox-enable-amd-igpu-host.bash` on the Proxmox host to:

- remove the `amdgpu` blacklist
- stop force-loading VFIO modules at boot
- ensure `amdgpu` is loaded at boot
- rebuild initramfs and refresh Proxmox boot metadata

After running that bootstrap, reboot HLH and verify:

```bash
ls -l /dev/dri
lspci -nnk -s c5:00.0
```

Expected outcome:

- `/dev/dri/card0` and `/dev/dri/renderD128` exist on the host
- the GPU reports `Kernel driver in use: amdgpu`

Only after that should the `engine` LXC expect successful `/dev/dri` passthrough.