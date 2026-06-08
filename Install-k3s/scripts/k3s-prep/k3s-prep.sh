#!/usr/bin/env bash
# =============================================================================
# k3s-prep.sh — Prepares an Ubuntu VM to become a k3s control node
# Run as root or with sudo: sudo bash k3s-prep.sh
# =============================================================================

set -euo pipefail  # Exit on error, unset vars, or pipe failures

# --- Colour helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Root check ---------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "This script must be run as root. Try: sudo bash $0"

# =============================================================================
# 1. HOSTNAME
# =============================================================================
# A stable, unique hostname is important. Kubernetes uses the hostname to
# identify nodes — changing it later will confuse the cluster.
# =============================================================================
info "Step 1: Setting hostname..."

read -rp "  Enter hostname for this control node [k3s-control-01]: " HOSTNAME
HOSTNAME=${HOSTNAME:-k3s-control-01}
hostnamectl set-hostname "$HOSTNAME"

# Also write it into /etc/hosts so the node can resolve itself without DNS.
# Kubernetes components (like kubelet) will attempt to resolve the hostname
# during startup; if it can't, node registration can fail.
NODE_IP=$(hostname -I | awk '{print $1}')
if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "$NODE_IP $HOSTNAME" >> /etc/hosts
fi

info "  Hostname set to: $HOSTNAME ($NODE_IP)"

# =============================================================================
# 2. DISABLE SWAP
# =============================================================================
# Kubernetes assumes it has full control over memory. When swap is enabled,
# the kernel can move memory pages to disk, which makes memory usage
# unpredictable and breaks Kubernetes' memory limits and QoS guarantees.
# k3s will refuse to start if swap is on (unless explicitly told to ignore it).
# =============================================================================
info "Step 2: Disabling swap..."

swapoff -a  # Disable all active swap immediately

# Comment out any swap entries in /etc/fstab so swap stays off after reboot.
# sed looks for lines containing the word 'swap' and prepends a '#'.
sed -i '/\bswap\b/ s/^/#/' /etc/fstab

info "  Swap disabled and removed from fstab."

# =============================================================================
# 3. KERNEL MODULES
# =============================================================================
# overlay   — Used by the container runtime (containerd) to layer container
#             filesystems efficiently on top of each other using OverlayFS.
#
# br_netfilter — Enables iptables to see bridged network traffic. Without this,
#             traffic between pods on the same node (crossing a Linux bridge)
#             bypasses iptables entirely, breaking NetworkPolicy and kube-proxy.
# =============================================================================
info "Step 3: Loading kernel modules..."

modprobe overlay
modprobe br_netfilter

# Write a config file so these modules are loaded automatically on every boot.
cat <<EOF > /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

info "  Modules overlay and br_netfilter loaded and persisted."

# =============================================================================
# 4. SYSCTL (KERNEL NETWORK PARAMETERS)
# =============================================================================
# net.ipv4.ip_forward — Allows the kernel to forward packets between network
#             interfaces. Essential for pod-to-pod and pod-to-service routing.
#
# net.bridge.bridge-nf-call-iptables  — Makes the kernel pass bridged IPv4
#             traffic through iptables. Required for NetworkPolicy enforcement
#             and kube-proxy to function correctly.
#
# net.bridge.bridge-nf-call-ip6tables — Same as above but for IPv6 traffic.
#             Even if you're not using IPv6, setting this avoids warnings and
#             future-proofs the node.
# =============================================================================
info "Step 4: Applying sysctl network settings..."

cat <<EOF > /etc/sysctl.d/k3s.conf
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system > /dev/null  # Apply all sysctl configs immediately

info "  sysctl settings applied and persisted."

# =============================================================================
# 5. FIREWALL (UFW)
# =============================================================================
# Port      Protocol  Used by
# -------   --------  --------------------------------------------------
# 6443      TCP       Kubernetes API server (kubectl, agents, everything)
# 10250     TCP       kubelet API (metrics, logs, exec)
# 2379      TCP       etcd client requests (HA / multi-server setups only)
# 2380      TCP       etcd peer communication (HA / multi-server setups only)
# 8472      UDP       Flannel VXLAN overlay (pod-to-pod traffic across nodes)
# 51820     UDP       WireGuard (if you enable encrypted overlay networking)
# =============================================================================
info "Step 5: Disabling UFW (trusted internal network)..."

if command -v ufw &>/dev/null; then
    ufw disable > /dev/null
    info "  UFW disabled."
else
    info "  UFW not found — nothing to disable."
fi

# =============================================================================
# 6. SYSTEM UPDATE & DEPENDENCIES
# =============================================================================
# open-iscsi — Required by some persistent storage backends (e.g. Longhorn,
#             OpenEBS) to mount iSCSI block volumes onto the node.
#
# nfs-common — Required to mount NFS-based persistent volumes. Many shared
#             storage solutions (and basic NFS PVs) rely on this.
#
# curl/wget  — Used to download the k3s install script and other tooling.
# =============================================================================
info "Step 6: Updating system and installing dependencies..."

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget open-iscsi nfs-common

info "  System updated and dependencies installed."

# =============================================================================
# 7. DISABLE APPARMOR (OPTIONAL)
# =============================================================================
# AppArmor is a Linux security module that restricts what programs can do.
# k3s itself supports AppArmor, but it can cause unexpected permission denials
# with certain CNI plugins or storage backends that aren't AppArmor-aware.
#
# This step is optional and commented out by default. Uncomment if you hit
# AppArmor-related issues. If security is a priority, leave AppArmor enabled
# and troubleshoot profile by profile instead.
# =============================================================================
info "Step 7: AppArmor — skipping (disabled by default, see script comments)."
# systemctl disable --now apparmor

# =============================================================================
# 8. STATIC IP REMINDER
# =============================================================================
# k3s nodes communicate by IP address. If the control node's IP changes
# (e.g. from DHCP reassignment or a reboot), agents will lose their connection
# to the API server and TLS certificates (which are bound to the IP/hostname)
# will become invalid — breaking the cluster.
#
# This script can't set a static IP for you (it varies by cloud/hypervisor/
# netplan config), so it checks and warns if DHCP appears to be in use.
# =============================================================================
info "Step 8: Checking for static IP configuration..."

NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)

if [[ -z "$NETPLAN_FILE" ]]; then
    warn "  No netplan config found — skipping static IP configuration."
elif grep -q "dhcp4: true" "$NETPLAN_FILE"; then
    warn "  DHCP detected on $NETPLAN_FILE."
    echo ""
    echo "  A static IP is strongly recommended for k3s control nodes."
    read -rp "  Configure a static IP now? [y/N]: " DO_STATIC
    if [[ "${DO_STATIC,,}" == "y" ]]; then
        # Detect the primary network interface
        PRIMARY_IF=$(ip route | awk '/^default/ {print $5; exit}')
        CURRENT_IP=$(hostname -I | awk '{print $1}')
        CURRENT_GW=$(ip route | awk '/^default/ {print $3; exit}')

        echo ""
        read -rp "  Network interface [$PRIMARY_IF]: "   INPUT_IF;   INPUT_IF=${INPUT_IF:-$PRIMARY_IF}
        read -rp "  Static IP (CIDR e.g. 192.168.1.10/24) [$CURRENT_IP/24]: " INPUT_IP; INPUT_IP=${INPUT_IP:-"$CURRENT_IP/24"}
        read -rp "  Gateway [$CURRENT_GW]: "             INPUT_GW;   INPUT_GW=${INPUT_GW:-$CURRENT_GW}
        read -rp "  DNS servers [8.8.8.8,8.8.4.4]: "    INPUT_DNS;  INPUT_DNS=${INPUT_DNS:-"8.8.8.8,8.8.4.4"}

        # Back up the existing netplan config before overwriting
        cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
        info "  Backed up original config to ${NETPLAN_FILE}.bak"

        # Write the new static netplan config
        cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  ethernets:
    $INPUT_IF:
      dhcp4: false
      addresses:
        - $INPUT_IP
      routes:
        - to: default
          via: $INPUT_GW
      nameservers:
        addresses: [$(echo "$INPUT_DNS" | tr ',' ' ' | xargs | tr ' ' ',')]
EOF

        netplan apply
        info "  Static IP configured: $INPUT_IP via $INPUT_IF (gateway: $INPUT_GW)"
        # Update NODE_IP to reflect the new static address
        NODE_IP=$(echo "$INPUT_IP" | cut -d'/' -f1)
    else
        warn "  Skipping static IP — remember to set it before installing k3s."
    fi
else
    info "  Static IP already configured — no changes needed."
fi

# =============================================================================
# 9. TIME SYNC (CHRONY)
# =============================================================================
# Kubernetes is sensitive to clock skew between nodes. TLS certificates,
# leader election, and etcd all rely on consistent time. If nodes drift more
# than ~2 seconds apart, etcd can fail or the API server may reject requests.
#
# chrony is a modern, accurate NTP daemon — preferred over the older ntpd.
# It syncs faster after a reboot and handles intermittent connectivity better.
# =============================================================================
info "Step 9: Installing and enabling chrony for time sync..."

apt-get install -y -qq chrony
systemctl enable --now chrony > /dev/null

# Quick sanity check — chronyc tracking returns non-zero if not yet synced
if chronyc tracking &>/dev/null; then
    info "  Chrony is running and tracking a time source."
else
    warn "  Chrony installed but not yet synced. This usually resolves within a minute."
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Preconfiguration complete for: $HOSTNAME${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Next steps:"
echo "  1. Ensure this VM has a static IP (see Step 8 warning above)."
echo "  2. Set up SSH key access for any automation (Ansible, Terraform, etc.)."
echo "  3. Reboot to confirm all settings persist: sudo reboot"
echo "  4. Then install k3s:"
echo ""
echo '     curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \' 
echo '       --disable traefik \'
echo '       --disable servicelb \'
echo "       --tls-san $NODE_IP\" sh -"
echo ""