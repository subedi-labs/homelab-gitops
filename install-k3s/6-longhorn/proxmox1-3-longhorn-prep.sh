#!/usr/bin/env bash
#
# longhorn-prep.sh — preps a k3s VM for Longhorn storage.
# Run AFTER vms-prep.sh and AFTER k3s is installed.
# Supports Debian/Ubuntu and RHEL/Rocky/Alma.
#
# What this does:
#   1. Validates Longhorn prerequisites (open-iscsi, nfs, dm_crypt, etc.)
#   2. Formats a dedicated disk as ext4
#   3. Mounts it at /var/lib/longhorn with proper fstab entry
#   4. Runs Longhorn's official environment check script
#
set -euo pipefail

LONGHORN_DISK=""
MOUNT_POINT="/var/lib/longhorn"
FSTYPE="ext4"
ASSUME_YES=0
SKIP_FORMAT=0
SKIP_ENV_CHECK=0
LOG="/var/log/longhorn-prep.log"

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
  --disk DEVICE         Disk to use for Longhorn (e.g. /dev/sdb)
  --mount PATH          Mount point (default $MOUNT_POINT)
  --skip-format         Don't format, just mount (disk already has ext4)
  --skip-env-check      Skip Longhorn's environment check script
  --yes                 Non-interactive (requires --disk)
  -h, --help            This help
EOF
exit 0
}

# ----------------------------------------------------------------------------
# Arg parse
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do case "$1" in
    --disk) LONGHORN_DISK="$2"; shift 2;;
    --mount) MOUNT_POINT="$2"; shift 2;;
    --skip-format) SKIP_FORMAT=1; shift;;
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
# 1. Validate Longhorn package prerequisites
# ----------------------------------------------------------------------------
log "Verifying Longhorn package prerequisites"
MISSING=()
if [[ $OS == debian ]]; then
    for pkg in open-iscsi nfs-common cryptsetup; do
        dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done
else
    for pkg in iscsi-initiator-utils nfs-utils cryptsetup; do
        rpm -q "$pkg" &>/dev/null || MISSING+=("$pkg")
    done
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Missing packages: ${MISSING[*]}"
    if confirm "Install them now?"; then
        if [[ $OS == debian ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
        else
            dnf install -y "${MISSING[@]}"
        fi
        ok "Packages installed"
    else
        die "Cannot proceed without required packages."
    fi
else
    ok "All Longhorn packages present"
fi

# iscsid must be enabled and running
if ! systemctl is-active --quiet iscsid; then
    systemctl enable --now iscsid
    ok "iscsid started"
else
    ok "iscsid already running"
fi

# Verify kernel modules Longhorn needs
log "Checking kernel modules"
for mod in iscsi_tcp dm_crypt nfs; do
    if ! lsmod | grep -q "^$mod"; then
        modprobe "$mod" 2>/dev/null && ok "Loaded $mod" || warn "Could not load $mod (may be built-in)"
    else
        ok "$mod loaded"
    fi
done

# Persist module loading
cat > /etc/modules-load.d/longhorn.conf <<EOF
iscsi_tcp
dm_crypt
nfs
EOF

# ----------------------------------------------------------------------------
# 2. Disk selection
# ----------------------------------------------------------------------------
if [[ -z "$LONGHORN_DISK" ]]; then
    log "Available block devices:"
    lsblk -dpno NAME,SIZE,TYPE,MODEL | grep -v loop | tee -a "$LOG"
    echo
    LONGHORN_DISK=$(ask "Disk for Longhorn (full path, e.g. /dev/sdb)" "")
fi

[[ -n "$LONGHORN_DISK" ]] || die "No disk specified."
[[ -b "$LONGHORN_DISK" ]] || die "Not a block device: $LONGHORN_DISK"

# Safety: never use root disk
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
if [[ -n "$ROOT_DISK" && "$LONGHORN_DISK" == "/dev/$ROOT_DISK" ]]; then
    die "Refusing to use root disk ($LONGHORN_DISK) for Longhorn."
fi

# Check disk isn't already mounted
if mount | grep -q "^$LONGHORN_DISK"; then
    die "$LONGHORN_DISK appears to be mounted. Unmount first."
fi

# Check for existing partitions/data
if [[ $SKIP_FORMAT -eq 0 ]]; then
    if blkid "$LONGHORN_DISK" &>/dev/null; then
        warn "Disk $LONGHORN_DISK has existing filesystem/data:"
        blkid "$LONGHORN_DISK" | tee -a "$LOG"
        confirm "DESTROY all data on $LONGHORN_DISK and reformat as $FSTYPE?" \
            || die "Aborted by user."
    fi
fi

DISK_SIZE=$(lsblk -dnbo SIZE "$LONGHORN_DISK")
DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
ok "Using disk: $LONGHORN_DISK (${DISK_SIZE_GB} GB)"

# ----------------------------------------------------------------------------
# 3. Format
# ----------------------------------------------------------------------------
if [[ $SKIP_FORMAT -eq 0 ]]; then
    log "Formatting $LONGHORN_DISK as $FSTYPE"
    mkfs.ext4 -F -L longhorn "$LONGHORN_DISK" >>"$LOG" 2>&1
    ok "Formatted"
else
    warn "Skipping format (--skip-format)"
fi

# ----------------------------------------------------------------------------
# 4. Mount + fstab
# ----------------------------------------------------------------------------
mkdir -p "$MOUNT_POINT"
UUID=$(blkid -s UUID -o value "$LONGHORN_DISK")
[[ -n "$UUID" ]] || die "Could not read UUID for $LONGHORN_DISK"

# Remove any prior entry for this mount or UUID
sed -i.bak "\#$MOUNT_POINT#d; /UUID=$UUID/d" /etc/fstab

echo "UUID=$UUID  $MOUNT_POINT  $FSTYPE  defaults,noatime,nofail  0  2" >> /etc/fstab
ok "Added /etc/fstab entry"

systemctl daemon-reload
mount "$MOUNT_POINT"
ok "Mounted $LONGHORN_DISK at $MOUNT_POINT"

# Verify
if ! mountpoint -q "$MOUNT_POINT"; then
    die "Mount verification failed for $MOUNT_POINT"
fi

# ----------------------------------------------------------------------------
# 5. Multipath (must NOT manage Longhorn devices)
# ----------------------------------------------------------------------------
if command -v multipath &>/dev/null; then
    log "multipath detected — adding Longhorn blacklist"
    mkdir -p /etc/multipath/conf.d
    cat > /etc/multipath/conf.d/longhorn.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
    systemctl restart multipathd 2>/dev/null || true
    ok "multipath configured to ignore Longhorn devices"
fi

# ----------------------------------------------------------------------------
# 6. Longhorn environment check (official script)
# ----------------------------------------------------------------------------
if [[ $SKIP_ENV_CHECK -eq 0 ]]; then
    log "Running Longhorn's official environment check"
    if curl -fsSL -o /tmp/longhorn-env-check.sh \
        https://raw.githubusercontent.com/longhorn/longhorn/master/scripts/environment_check.sh; then
        chmod +x /tmp/longhorn-env-check.sh
        bash /tmp/longhorn-env-check.sh 2>&1 | tee -a "$LOG" || \
            warn "Environment check reported issues — review output above"
    else
        warn "Could not download environment_check.sh"
    fi
fi

# ----------------------------------------------------------------------------
# 7. Summary
# ----------------------------------------------------------------------------
echo
ok "================ LONGHORN PREP COMPLETE ================"
cat <<EOF | tee -a "$LOG"
  Hostname     : $(hostname)
  Disk         : $LONGHORN_DISK (${DISK_SIZE_GB} GB)
  Filesystem   : $FSTYPE
  Mount        : $MOUNT_POINT
  UUID         : $UUID
  Log          : $LOG

============================================================
 NEXT STEPS — INSTALLING LONGHORN ON THE CLUSTER
============================================================

Run prep on EVERY k3s node that will host Longhorn storage,
then install Longhorn ONCE from any node with kubectl access.

STEP 1 — Add the Longhorn Helm repo (run once)

    helm repo add longhorn https://charts.longhorn.io
    helm repo update

STEP 2 — Install Longhorn into its own namespace

    kubectl create namespace longhorn-system

    helm install longhorn longhorn/longhorn \\
        --namespace longhorn-system \\
        --set defaultSettings.defaultDataPath="$MOUNT_POINT" \\
        --set defaultSettings.defaultReplicaCount=2 \\
        --set persistence.defaultClassReplicaCount=2

  Note: replicaCount=2 because you have 3 worker nodes total.
  For true HA on a larger cluster, use 3.

STEP 3 — Watch pods come up

    kubectl -n longhorn-system get pods -w

STEP 4 — Access the Longhorn UI (optional)

    kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
    # then browse to http://localhost:8080

STEP 5 — Make Longhorn the default StorageClass

    kubectl patch storageclass longhorn \\
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

============================================================
EOF
exit 0