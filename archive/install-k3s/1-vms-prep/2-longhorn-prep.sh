#!/usr/bin/env bash
#
# longhorn-prep.sh — preps a k3s node before installing Longhorn.
# Run on EVERY node that will provide Longhorn storage, AFTER k3s is installed.
# Supports Debian/Ubuntu and RHEL/Rocky/Alma.
#
# What it does:
#   - Verifies/installs Longhorn dependencies (open-iscsi, nfs client, cryptsetup)
#   - Ensures iscsid + multipath are in the correct state
#   - Locates the dedicated data disk and mounts it for Longhorn
#   - Runs the official Longhorn environment check
#
set -euo pipefail

DATA_DISK=""
MOUNT_POINT="/var/lib/longhorn"
FS_TYPE="ext4"
ASSUME_YES=0
SKIP_ENV_CHECK=0
LOG="/var/log/prep-longhorn-node.log"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
log()  { echo -e "${c_blu}[*]${c_off} $*" | tee -a "$LOG"; }
ok()   { echo -e "${c_grn}[+]${c_off} $*" | tee -a "$LOG"; }
warn() { echo -e "${c_yel}[!]${c_off} $*" | tee -a "$LOG"; }
die()  { echo -e "${c_red}[x]${c_off} $*" | tee -a "$LOG"; exit 1; }

ask() {
    [[ $ASSUME_YES -eq 1 ]] && { echo "${2:-}"; return; }
    local a; read -rp "$(echo -e "${c_yel}? $1 [${2:-}]: ${c_off}")" a; echo "${a:-${2:-}}"
}
confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local a; read -rp "$(echo -e "${c_yel}? $1 [y/N]: ${c_off}")" a; [[ "$a" =~ ^[Yy]$ ]]
}

usage() { cat <<EOF
Usage: sudo $0 [options]
  --data-disk DEV       Dedicated disk for Longhorn (e.g. /dev/sdb)
  --mount-point PATH    Where to mount it (default $MOUNT_POINT)
  --fs-type TYPE        Filesystem to create (default $FS_TYPE)
  --skip-env-check      Don't run the Longhorn environment_check.sh
  --yes                 Non-interactive (uses defaults / provided flags)
  -h, --help            This help
EOF
exit 0
}

# ----------------------------------------------------------------------------
# Arg parse
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do case "$1" in
    --data-disk) DATA_DISK="$2"; shift 2;;
    --mount-point) MOUNT_POINT="$2"; shift 2;;
    --fs-type) FS_TYPE="$2"; shift 2;;
    --skip-env-check) SKIP_ENV_CHECK=1; shift;;
    --yes) ASSUME_YES=1; shift;;
    -h|--help) usage;;
    *) die "Unknown arg: $1 (use --help)";;
esac; done

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
mkdir -p "$(dirname "$LOG")"; : > "$LOG"
if   [[ -f /etc/debian_version ]]; then OS=debian
elif [[ -f /etc/redhat-release ]]; then OS=rhel
else die "Unsupported distro."; fi
ok "OS family: $OS"

# ----------------------------------------------------------------------------
# 1. Dependencies
# ----------------------------------------------------------------------------
log "Installing Longhorn dependencies"
if [[ $OS == debian ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        open-iscsi nfs-common cryptsetup dmsetup util-linux e2fsprogs
else
    dnf install -y iscsi-initiator-utils nfs-utils cryptsetup device-mapper util-linux e2fsprogs
fi
ok "Dependencies installed"

# ----------------------------------------------------------------------------
# 2. iscsid
# ----------------------------------------------------------------------------
log "Enabling iscsid"
systemctl enable --now iscsid
systemctl is-active --quiet iscsid || die "iscsid failed to start (Longhorn requires it)."
ok "iscsid running"

# ----------------------------------------------------------------------------
# 3. multipathd — Longhorn devices must NOT be claimed by multipath
# ----------------------------------------------------------------------------
if systemctl is-active --quiet multipathd 2>/dev/null; then
    warn "multipathd is active; adding blacklist so it ignores Longhorn devices"
    mkdir -p /etc/multipath/conf.d
    cat > /etc/multipath/conf.d/longhorn.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
    systemctl restart multipathd
    ok "multipath blacklist applied"
else
    ok "multipathd not active; nothing to blacklist"
fi

# ----------------------------------------------------------------------------
# 4. Kernel module for NFSv4 (RWX volumes)
# ----------------------------------------------------------------------------
modprobe nfs 2>/dev/null || true
modprobe iscsi_tcp 2>/dev/null || true
printf 'iscsi_tcp\n' > /etc/modules-load.d/longhorn.conf
ok "Kernel modules ensured (iscsi_tcp, nfs)"

# ----------------------------------------------------------------------------
# 5. Locate & prepare the dedicated data disk
# ----------------------------------------------------------------------------
log "Detecting candidate disks (unmounted, no partitions, no filesystem)"
echo
lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE | grep -v loop | tee -a "$LOG"
echo

# Suggest the first disk that has no filesystem and isn't mounted
SUGGESTED=$(lsblk -dpno NAME,TYPE,FSTYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" && $4=="" {print $1; exit}')

if [[ -z "$DATA_DISK" ]]; then
    DATA_DISK=$(ask "Which disk should Longhorn use?" "${SUGGESTED:-/dev/sdb}")
fi

[[ -b "$DATA_DISK" ]] || die "$DATA_DISK is not a block device."

# Refuse the root disk
ROOT_DISK=$(lsblk -dpno PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
if [[ -n "$ROOT_DISK" && "/dev/$ROOT_DISK" == "$DATA_DISK" ]]; then
    die "$DATA_DISK appears to be your root disk. Refusing."
fi

# Check for existing data
EXISTING_FS=$(lsblk -dpno FSTYPE "$DATA_DISK" 2>/dev/null || true)
HAS_PARTS=$(lsblk -rno NAME "$DATA_DISK" | wc -l)
if [[ -n "$EXISTING_FS" || "$HAS_PARTS" -gt 1 ]]; then
    warn "$DATA_DISK already has a filesystem or partitions:"
    lsblk "$DATA_DISK" | tee -a "$LOG"
    confirm "ERASE $DATA_DISK completely? This destroys all data on it." \
        || die "Aborted by user."
    wipefs -a "$DATA_DISK"
fi

# ----------------------------------------------------------------------------
# 6. Format & mount
# ----------------------------------------------------------------------------
log "Creating $FS_TYPE filesystem on $DATA_DISK"
mkfs."$FS_TYPE" -F "$DATA_DISK"

DISK_UUID=$(blkid -s UUID -o value "$DATA_DISK")
[[ -n "$DISK_UUID" ]] || die "Could not read UUID of $DATA_DISK after format."

mkdir -p "$MOUNT_POINT"

# Add to fstab (idempotent — remove any prior entry for this mountpoint)
sed -i "\#[[:space:]]$MOUNT_POINT[[:space:]]#d" /etc/fstab
echo "UUID=$DISK_UUID  $MOUNT_POINT  $FS_TYPE  defaults,noatime  0  2" >> /etc/fstab

systemctl daemon-reload
mount "$MOUNT_POINT"
mountpoint -q "$MOUNT_POINT" || die "Failed to mount $DATA_DISK at $MOUNT_POINT."
ok "Mounted $DATA_DISK at $MOUNT_POINT (UUID=$DISK_UUID)"

# ----------------------------------------------------------------------------
# 7. Official Longhorn environment check
# ----------------------------------------------------------------------------
if [[ $SKIP_ENV_CHECK -eq 0 ]]; then
    log "Running Longhorn environment check"
    if command -v kubectl &>/dev/null; then
        curl -sSfL https://raw.githubusercontent.com/longhorn/longhorn/master/scripts/environment_check.sh \
            | bash 2>&1 | tee -a "$LOG" || warn "environment_check reported issues (review above)."
    else
        warn "kubectl not found; skipping cluster-wide environment check."
        warn "Run it later from a node with kubectl access."
    fi
else
    warn "Skipping environment check (--skip-env-check)"
fi

# ----------------------------------------------------------------------------
# 8. Summary
# ----------------------------------------------------------------------------
AVAIL=$(df -h "$MOUNT_POINT" | awk 'NR==2{print $4}')
echo
ok "================ LONGHORN PREP COMPLETE ================"
cat <<EOF | tee -a "$LOG"
  Hostname     : $(hostname)
  Data disk    : $DATA_DISK
  Mount point  : $MOUNT_POINT
  Filesystem   : $FS_TYPE (UUID=$DISK_UUID)
  Available    : $AVAIL
  iscsid       : $(systemctl is-active iscsid)
  Log          : $LOG

============================================================
 NEXT — INSTALL LONGHORN ON THE CLUSTER (run once, any node)
============================================================

  Using Helm:

    helm repo add longhorn https://charts.longhorn.io
    helm repo update
    helm install longhorn longhorn/longhorn \\
      --namespace longhorn-system \\
      --create-namespace \\
      --set defaultSettings.defaultDataPath="$MOUNT_POINT" \\
      --set defaultSettings.defaultReplicaCount=3

  Watch it come up:

    kubectl -n longhorn-system get pods -w

  Once running, confirm each node's disk is detected under:
    Longhorn UI -> Node -> (your node) -> Disks
  It should show $MOUNT_POINT with the schedulable space above.

  NOTE: run THIS prep script on every storage node BEFORE the
  helm install, so all disks are mounted and ready.

============================================================
EOF
exit 0