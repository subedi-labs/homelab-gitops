#!/usr/bin/env bash
#
# nfs-lxc-setup.sh — creates a Debian LXC on Proxmox that exports a dedicated
# disk via NFS for k3s bulk storage (databases, media, etc.)
#
# RUN THIS ON THE PROXMOX HOST (proxmox2), NOT inside a VM.
#
# What this does:
#   1. Creates a privileged Debian 12 LXC with nesting + nfs features
#   2. Passes through a dedicated host disk as a mount point
#   3. Installs nfs-kernel-server inside the LXC
#   4. Exports the disk to 10.0.0.0/24 (your LAN)
#
set -euo pipefail

CTID=""
HOSTNAME="nfs-storage"
STORAGE_DISK=""          # host disk to passthrough, e.g. /dev/sdb
EXPORT_PATH="/srv/nfs"   # path inside the LXC
LAN_CIDR="10.0.0.0/24"
LXC_IP=""                # static IP for the LXC (with /24)
LXC_GW="10.0.0.1"
LXC_BRIDGE="vmbr0"
LXC_STORAGE="local-lvm"  # where the LXC rootfs lives
LXC_MEM="1024"           # MB
LXC_CORES="2"
TEMPLATE_STORAGE="local"
DEBIAN_TEMPLATE="debian-12-standard"
ASSUME_YES=0
LOG="/var/log/nfs-lxc-setup.log"

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
  --ctid ID             LXC container ID (e.g. 200)
  --hostname NAME       LXC hostname (default $HOSTNAME)
  --disk DEVICE         Host disk to passthrough (e.g. /dev/sdb)
  --ip IP/CIDR          Static IP for LXC (e.g. 10.0.0.50/24)
  --gw IP               Gateway (default $LXC_GW)
  --lan-cidr CIDR       Allowed NFS clients (default $LAN_CIDR)
  --export-path PATH    Export path inside LXC (default $EXPORT_PATH)
  --memory MB           LXC RAM (default $LXC_MEM)
  --cores N             LXC cores (default $LXC_CORES)
  --bridge NAME         Network bridge (default $LXC_BRIDGE)
  --lxc-storage NAME    Proxmox storage for rootfs (default $LXC_STORAGE)
  --yes                 Non-interactive
  -h, --help            This help
EOF
exit 0
}

# ----------------------------------------------------------------------------
# Arg parse
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do case "$1" in
    --ctid) CTID="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --disk) STORAGE_DISK="$2"; shift 2;;
    --ip) LXC_IP="$2"; shift 2;;
    --gw) LXC_GW="$2"; shift 2;;
    --lan-cidr) LAN_CIDR="$2"; shift 2;;
    --export-path) EXPORT_PATH="$2"; shift 2;;
    --memory) LXC_MEM="$2"; shift 2;;
    --cores) LXC_CORES="$2"; shift 2;;
    --bridge) LXC_BRIDGE="$2"; shift 2;;
    --lxc-storage) LXC_STORAGE="$2"; shift 2;;
    --yes) ASSUME_YES=1; shift;;
    -h|--help) usage;;
    *) die "Unknown arg: $1 (use --help)";;
esac; done

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
mkdir -p "$(dirname "$LOG")"; : > "$LOG"
command -v pct &>/dev/null || die "This script must run on a Proxmox host (pct not found)."

# ----------------------------------------------------------------------------
# 1. Gather inputs
# ----------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
    NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
    CTID=$(ask "LXC container ID" "$NEXT_ID")
fi

# Refuse if CTID already exists
if pct status "$CTID" &>/dev/null; then
    die "Container $CTID already exists. Pick another ID or destroy it first."
fi

if [[ -z "$STORAGE_DISK" ]]; then
    log "Available block devices on this Proxmox host:"
    lsblk -dpno NAME,SIZE,TYPE,MODEL | grep -v loop | tee -a "$LOG"
    echo
    STORAGE_DISK=$(ask "Host disk to use for NFS storage" "")
fi

[[ -b "$STORAGE_DISK" ]] || die "Not a block device: $STORAGE_DISK"

# Safety: never use root disk
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
if [[ -n "$ROOT_DISK" && "$STORAGE_DISK" == "/dev/$ROOT_DISK" ]]; then
    die "Refusing to use root disk ($STORAGE_DISK) for NFS storage."
fi

if [[ -z "$LXC_IP" ]]; then
    LXC_IP=$(ask "Static IP for LXC (with /24, e.g. 10.0.0.50/24)" "")
fi
[[ -n "$LXC_IP" ]] || die "LXC IP is required."

# ----------------------------------------------------------------------------
# 2. Confirm + format disk on host
# ----------------------------------------------------------------------------
HOST_MOUNT="/mnt/nfs-storage-$CTID"
DISK_SIZE=$(lsblk -dnbo SIZE "$STORAGE_DISK")
DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))

if blkid "$STORAGE_DISK" &>/dev/null; then
    warn "Disk $STORAGE_DISK has existing filesystem/data:"
    blkid "$STORAGE_DISK" | tee -a "$LOG"
    confirm "DESTROY all data on $STORAGE_DISK and reformat as ext4?" \
        || die "Aborted by user."
fi

log "Formatting $STORAGE_DISK as ext4 (${DISK_SIZE_GB} GB)"
mkfs.ext4 -F -L nfs-storage "$STORAGE_DISK" >>"$LOG" 2>&1
ok "Formatted"

mkdir -p "$HOST_MOUNT"
UUID=$(blkid -s UUID -o value "$STORAGE_DISK")

# Add to host fstab so it remounts on host reboot
sed -i.bak "\#$HOST_MOUNT#d; /UUID=$UUID/d" /etc/fstab
echo "UUID=$UUID  $HOST_MOUNT  ext4  defaults,noatime,nofail  0  2" >> /etc/fstab
mount "$HOST_MOUNT"
ok "Mounted $STORAGE_DISK at $HOST_MOUNT (host)"

# ----------------------------------------------------------------------------
# 3. Ensure template is available
# ----------------------------------------------------------------------------
log "Checking for Debian 12 template"
TEMPLATE=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk -v p="$DEBIAN_TEMPLATE" '$1 ~ p {print $1; exit}')
if [[ -z "$TEMPLATE" ]]; then
    log "Downloading Debian 12 template"
    pveam update >>"$LOG" 2>&1
    AVAIL=$(pveam available --section system | awk -v p="$DEBIAN_TEMPLATE" '$2 ~ p {print $2; exit}')
    [[ -n "$AVAIL" ]] || die "No Debian 12 template available."
    pveam download "$TEMPLATE_STORAGE" "$AVAIL" | tee -a "$LOG"
    TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${AVAIL}"
fi
ok "Template: $TEMPLATE"

# ----------------------------------------------------------------------------
# 4. Create the LXC
# ----------------------------------------------------------------------------
log "Creating LXC $CTID ($HOSTNAME)"

# Generate a random root password (you can change with `pct passwd $CTID`)
ROOT_PW=$(openssl rand -base64 12)

pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$LXC_CORES" \
    --memory "$LXC_MEM" \
    --swap 512 \
    --storage "$LXC_STORAGE" \
    --rootfs "${LXC_STORAGE}:8" \
    --net0 "name=eth0,bridge=${LXC_BRIDGE},ip=${LXC_IP},gw=${LXC_GW}" \
    --nameserver "1.1.1.1 10.0.0.1" \
    --features "nesting=1" \
    --unprivileged 0 \
    --onboot 1 \
    --password "$ROOT_PW" \
    --start 0 | tee -a "$LOG"

ok "LXC $CTID created"

# ----------------------------------------------------------------------------
# 5. Attach the storage disk as a mount point
# ----------------------------------------------------------------------------
log "Attaching $HOST_MOUNT to LXC at $EXPORT_PATH"
pct set "$CTID" -mp0 "$HOST_MOUNT,mp=$EXPORT_PATH,backup=0"
ok "Mount point attached"

# ----------------------------------------------------------------------------
# 6. Enable NFS feature (must be set after creation for kernel server)
# ----------------------------------------------------------------------------
log "Enabling nesting + nfs features"
pct set "$CTID" -features "nesting=1,nfs=1"

# Allow NFS-related kernel capabilities (privileged LXC, but extra-safe)
LXC_CONF="/etc/pve/lxc/${CTID}.conf"
if ! grep -q "lxc.apparmor.profile" "$LXC_CONF"; then
    {
        echo "lxc.apparmor.profile: unconfined"
        echo "lxc.cgroup2.devices.allow: a"
        echo "lxc.cap.drop:"
    } >> "$LXC_CONF"
fi
ok "LXC config updated for NFS"

# ----------------------------------------------------------------------------
# 7. Start LXC and install NFS server inside
# ----------------------------------------------------------------------------
log "Starting LXC"
pct start "$CTID"
sleep 5

log "Installing NFS server inside LXC"
pct exec "$CTID" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nfs-kernel-server
    mkdir -p '$EXPORT_PATH'
    chown nobody:nogroup '$EXPORT_PATH'
    chmod 0777 '$EXPORT_PATH'
"
ok "nfs-kernel-server installed"

# ----------------------------------------------------------------------------
# 8. Configure exports
# ----------------------------------------------------------------------------
log "Configuring NFS export for $LAN_CIDR"
pct exec "$CTID" -- bash -c "
    cat > /etc/exports <<EOF
$EXPORT_PATH  $LAN_CIDR(rw,sync,no_subtree_check,no_root_squash,fsid=0)
EOF
    exportfs -ra
    systemctl enable --now nfs-kernel-server
    systemctl restart nfs-kernel-server
"
ok "NFS export configured"

# ----------------------------------------------------------------------------
# 9. Verify from host
# ----------------------------------------------------------------------------
LXC_IP_ONLY="${LXC_IP%%/*}"
log "Verifying export visible from host"
if showmount -e "$LXC_IP_ONLY" 2>/dev/null | tee -a "$LOG" | grep -q "$EXPORT_PATH"; then
    ok "NFS export visible at ${LXC_IP_ONLY}:${EXPORT_PATH}"
else
    warn "Could not verify export (host may not have showmount). Test from a client."
fi

# ----------------------------------------------------------------------------
# 10. Summary
# ----------------------------------------------------------------------------
echo
ok "================ NFS LXC SETUP COMPLETE ================"
cat <<EOF | tee -a "$LOG"
  Container ID    : $CTID
  Hostname        : $HOSTNAME
  LXC IP          : $LXC_IP_ONLY
  Root password   : $ROOT_PW   (change with: pct passwd $CTID)
  Host disk       : $STORAGE_DISK (${DISK_SIZE_GB} GB)
  Host mount      : $HOST_MOUNT
  Export path     : $EXPORT_PATH
  Allowed clients : $LAN_CIDR
  Log             : $LOG

============================================================
 NEXT STEPS — MOUNTING IN K3S
============================================================

STEP 1 — On EACH k3s node VM, install NFS client tools:

    sudo ./nfs-client-prep.sh --server $LXC_IP_ONLY --export $EXPORT_PATH

STEP 2 — From any node with kubectl, install the NFS CSI driver:

    helm repo add csi-driver-nfs \\
        https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    helm install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \\
        --namespace kube-system \\
        --version v4.7.0

STEP 3 — Create a StorageClass pointing at this NFS server:

    cat <<YAML | kubectl apply -f -
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: nfs-bulk
    provisioner: nfs.csi.k8s.io
    parameters:
      server: $LXC_IP_ONLY
      share: $EXPORT_PATH
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    mountOptions:
      - nfsvers=4.1
      - hard
      - timeo=600
      - retrans=2
    YAML

STEP 4 — Use it in a PVC:

    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: media-storage
    spec:
      accessModes: [ReadWriteMany]
      storageClassName: nfs-bulk
      resources:
        requests:
          storage: 100Gi

  NFS supports ReadWriteMany — multiple pods can mount the same volume.
  Use Longhorn for Postgres/databases (block storage, single-writer).
  Use this NFS share for media, backups, shared configs, etc.

============================================================
EOF
exit 0