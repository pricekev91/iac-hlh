#!/usr/bin/env bash
set -euo pipefail

# zfsbootstrap.sh — identify drives, confirm wipe, then create Raid0-2TB (striped) and RaidZ1-6TB (raidz1)
POOL_RAID0="Raid0-2TB"
POOL_RAIDZ="RaidZ1-6TB"
TARGET_RAID0_GB=1000   # target per-disk size for the 2-disk striped pool (2x1TB => ~2TB usable)
TARGET_RAIDZ_GB=3000   # target per-disk size for the 3-disk raidz1 (3x3TB)
RAID0_COUNT=2
RAIDZ_COUNT=3

# Lab defaults: include USB/removable disks; change to false to skip them
ALLOW_USB=${ALLOW_USB:-true}
EXCLUDE_DISK=${EXCLUDE_DISK:-"/dev/sda"}  # keep system disk out of selection

log(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
debug(){ echo "[DEBUG] $*" >&2; }

# --- Discover disks
log "----------------------------------------"
log "Detecting whole disks (includes USB by default)."
mapfile -t RAW_DISKS < <(lsblk -dn -o NAME,TRAN,RM,TYPE,SIZE,MODEL | awk '$4=="disk" {print $1 "|" $2 "|" $3 "|" $5 "|" substr($0, index($0,$6))}')
DISKS=()
i=1
printf "%-3s %-10s %-8s %-6s %8s  %s\n" "ID" "DEV" "TRAN" "RM" "SIZE" "MODEL"
for e in "${RAW_DISKS[@]}"; do
  name=${e%%|*}
  rest=${e#*|}
  tran=${rest%%|*}; rest=${rest#*|}
  rmflag=${rest%%|*}; rest=${rest#*|}
  size=${rest%%|*}; model=${rest#*|}
  dev="/dev/${name}"
  [[ "$dev" == "$EXCLUDE_DISK" ]] && { warn "Skipping excluded disk: $dev"; continue; }
  if [[ "$ALLOW_USB" != "true" ]] && ([[ "$tran" == "usb" ]] || [[ "$rmflag" == "1" ]]); then
    warn "Skipping USB/removable disk: $dev (set ALLOW_USB=true to include)"
    continue
  fi
  printf "%-3s %-10s %-8s %-6s %8s  %s\n" "$i" "$dev" "$tran" "$rmflag" "$size" "$model"
  DISKS+=("$dev")
  ((i++))
done
log "----------------------------------------"

if (( ${#DISKS[@]} == 0 )); then
  warn "No candidate disks found. Exiting."
  exit 1
fi

# --- Helpers
dev_size_gb(){
  local d=$1
  local b
  b=$(lsblk -dn -b -o SIZE "$d" 2>/dev/null || echo 0)
  awk "BEGIN{printf \"%d\", $b/1000/1000/1000}"
}

# --- Select disks by approximate size, avoid reuse
USED=()
find_disks_by_size(){
  local target_gb=$1
  local count=$2
  local -a found=()
  local lower upper
  lower=$(awk "BEGIN{printf \"%d\", $target_gb*0.9}")
  upper=$(awk "BEGIN{printf \"%d\", $target_gb*1.1}")
  for d in "${DISKS[@]}"; do
    [[ " ${USED[*]} " == *" $d "* ]] && continue
    s=$(dev_size_gb "$d")
    if (( s >= lower && s <= upper )); then
      found+=("$d")
      USED+=("$d")
      debug "Matched $d = ${s}GB"
    fi
  done
  if (( ${#found[@]} < count )); then
    warn "Expected ${count} disks around ${target_gb}GB, found ${#found[@]}"
    return 1
  fi
  for ((i=0;i<count;i++)); do
    printf "%s\n" "${found[i]}"
  done
}

# --- Choose disks
if ! mapfile -t RAID0_DISKS < <(find_disks_by_size "$TARGET_RAID0_GB" "$RAID0_COUNT"); then
  exit 1
fi
if ! mapfile -t RAIDZ_DISKS < <(find_disks_by_size "$TARGET_RAIDZ_GB" "$RAIDZ_COUNT"); then
  exit 1
fi

log "Selected for ${POOL_RAID0}: ${RAID0_DISKS[*]}"
log "Selected for ${POOL_RAIDZ}: ${RAIDZ_DISKS[*]}"

# --- Confirm destructive wipe
echo
read -rp "Type CONTINUE to perform destructive wipefs/sgdisk on the selected disks and proceed: " CONF
if [[ "$CONF" != "CONTINUE" ]]; then
  log "User aborted. No changes made."
  exit 0
fi

# --- Aggressive clear function (destructive)
clear_device(){
  local dev=$1
  log "Clearing $dev"
  # unmount partition mountpoints
  mapfile -t mps < <(lsblk -nr -o NAME,MOUNTPOINT "$dev" | awk '$2!="" {print "/dev/"$1}' || true)
  for mp in "${mps[@]}"; do umount "$mp" 2>/dev/null || true; done

  # swapoff any swap on this device
  mapfile -t swps < <(swapon --show=NAME --noheadings 2>/dev/null || true)
  for s in "${swps[@]:-}"; do
    if [[ "$s" == "$dev"* ]]; then swapoff "$s" 2>/dev/null || true; fi
  done

  # zpool labelclear attempts on device and common partition names
  for t in "$dev" "${dev}1" "${dev}p1" "${dev}2" "${dev}p2"; do
    [[ -b "$t" ]] || continue
    zpool labelclear -f "$t" 2>/dev/null || true
  done

  # close any crypt mappings referencing this disk (best-effort)
  if command -v cryptsetup >/dev/null 2>&1; then
    for m in $(ls /dev/mapper 2>/dev/null || true); do
      cryptsetup status "$m" 2>/dev/null | grep -q "$(basename "$dev")" && cryptsetup luksClose "$m" 2>/dev/null || true
    done
  fi

  # zap partitions and wipe signatures
  sgdisk --zap-all "$dev" 2>/dev/null || true
  wipefs --all --force "$dev" 2>/dev/null || true

  # trigger kernel to reread partition table and udev settle; retry
  for i in 1 2 3; do
    partprobe "$dev" 2>/dev/null || true
    blockdev --rereadpt "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1
    sleep 1
  done

  # second pass labelclear
  for t in "$dev" "${dev}1" "${dev}p1"; do
    [[ -b "$t" ]] || continue
    zpool labelclear -f "$t" 2>/dev/null || true
  done

  # final wipes and settle
  wipefs --all --force "$dev" 2>/dev/null || true
  sgdisk --zap-all "$dev" 2>/dev/null || true
  partprobe "$dev" 2>/dev/null || true
  blockdev --rereadpt "$dev" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  log "Cleared $dev"
}

# --- Clear selected disks (destructive)
for d in "${RAID0_DISKS[@]}" "${RAIDZ_DISKS[@]}"; do
  clear_device "$d"
done

# --- Ensure target pools absent (force-destroy if present)
for p in "$POOL_RAID0" "$POOL_RAIDZ"; do
  if zpool list "$p" &>/dev/null; then
    warn "Pool $p exists — destroying automatically."
    zpool destroy -f "$p" || true
  fi
done

# small settle
sleep 2

# --- Retry helper for zpool create to handle transient "device in use"
try_zpool_create() {
  local trials=3
  local delay=2
  local cmd=("$@")
  for ((i=1;i<=trials;i++)); do
    if "${cmd[@]}"; then
      return 0
    fi
    warn "zpool create attempt ${i} failed; retrying after cleanup..."
    for dev in "${RAID0_DISKS[@]}" "${RAIDZ_DISKS[@]}"; do
      zpool labelclear -f "$dev" 2>/dev/null || true
      sgdisk --zap-all "$dev" 2>/dev/null || true
      partprobe "$dev" 2>/dev/null || true
    done
    sleep $delay
  done
  return 1
}

# --- Create pools
log "Creating ${POOL_RAID0} (striped vdev of ${RAID0_DISKS[*]}) ..."
# Create a striped vdev by listing devices directly (no 'mirror' keyword)
try_zpool_create zpool create -f -o ashift=12 -m none "$POOL_RAID0" "${RAID0_DISKS[@]}" || { warn "Failed to create $POOL_RAID0"; exit 1; }

log "Creating ${POOL_RAIDZ} (raidz1 of ${RAIDZ_DISKS[*]}) ..."
try_zpool_create zpool create -f -o ashift=12 -m none "$POOL_RAIDZ" raidz1 "${RAIDZ_DISKS[@]}" || { warn "Failed to create $POOL_RAIDZ"; exit 1; }

log ""
zpool status || true
zpool list || true
log ""
log "✅ Done."
