#!/usr/bin/env bash
#
# prep-k3s-node.sh — preps a VM before installing it as a k3s node.
# Supports Debian/Ubuntu and RHEL/Rocky/Alma.
#
# Network defaults: LAN 10.0.0.0/24 | Pod 10.42.0.0/16 | Svc 10.43.0.0/16 | DNS 10.43.0.10
#
set -euo pipefail

LAN_GW="10.0.0.1"
POD_CIDR="10.42.0.0/16"
SVC_CIDR="10.43.0.0/16"
CLUSTER_DNS="10.43.0.10"
UPSTREAM_DNS="10.0.0.1 1.1.1.1"
NODE_HOSTNAME=""
SKIP_STATIC=0
ASSUME_YES=0
DISABLE_FIREWALL=0
LOG="/var/log/prep-k3s-node.log"

# k3s firewall ports: "port/proto" pairs
PORTS=(6443/tcp 10250/tcp 8472/udp 51820/udp 51821/udp 2379-2380/tcp 5001/tcp)

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
valid_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.; read -ra o <<<"$1"; for n in "${o[@]}"; do ((n<=255)) || return 1; done
}

usage() { cat <<EOF
Usage: sudo $0 [options]
  --hostname NAME       Rename host
  --lan-gw IP           LAN gateway (default $LAN_GW)
  --pod-cidr CIDR       Pod CIDR (default $POD_CIDR)
  --svc-cidr CIDR       Service CIDR (default $SVC_CIDR)
  --cluster-dns IP      Cluster DNS (default $CLUSTER_DNS)
  --upstream-dns "A B"  Upstream resolvers (default "$UPSTREAM_DNS")
  --disable-firewall    Disable firewalld/ufw instead of adding rules
  --skip-static         Don't modify IP config
  --yes                 Non-interactive
  -h, --help            This help
EOF
exit 0
}

# ----------------------------------------------------------------------------
# Arg parse
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do case "$1" in
    --hostname) NODE_HOSTNAME="$2"; shift 2;;
    --lan-gw) LAN_GW="$2"; shift 2;;
    --pod-cidr) POD_CIDR="$2"; shift 2;;
    --svc-cidr) SVC_CIDR="$2"; shift 2;;
    --cluster-dns) CLUSTER_DNS="$2"; shift 2;;
    --upstream-dns) UPSTREAM_DNS="$2"; shift 2;;
    --disable-firewall) DISABLE_FIREWALL=1; shift;;
    --skip-static) SKIP_STATIC=1; shift;;
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
# 1. Hostname
# ----------------------------------------------------------------------------
[[ -z "$NODE_HOSTNAME" && $ASSUME_YES -eq 0 ]] && NODE_HOSTNAME=$(ask "Hostname" "$(hostname)")
if [[ -n "$NODE_HOSTNAME" && "$NODE_HOSTNAME" != "$(hostname)" ]]; then
    hostnamectl set-hostname "$NODE_HOSTNAME"
    if grep -q "127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t$NODE_HOSTNAME/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$NODE_HOSTNAME" >> /etc/hosts
    fi
    ok "Hostname set to $NODE_HOSTNAME"
fi

# ----------------------------------------------------------------------------
# 2. Static IP (only if DHCP detected)
# ----------------------------------------------------------------------------
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
CUR_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2;exit}')
is_dhcp() {
    if command -v nmcli &>/dev/null; then
        local c; c=$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null)
        [[ "$(nmcli -t -g ipv4.method connection show "$c" 2>/dev/null)" == "auto" ]] && return 0
    fi
    grep -rqs "dhcp" /etc/netplan/ 2>/dev/null && return 0
    grep -qs "iface $IFACE inet dhcp" /etc/network/interfaces 2>/dev/null && return 0
    return 1
}

if [[ $SKIP_STATIC -eq 1 ]]; then
    warn "Skipping IP config (--skip-static)"
elif [[ -z "$IFACE" ]]; then
    warn "No primary interface detected; skipping static IP."
elif is_dhcp && confirm "Interface '$IFACE' uses DHCP (${CUR_IP:-none}). Convert to static?"; then
    STATIC_IP=$(ask "Static IP w/ prefix (e.g. 10.0.0.50/24)" "${CUR_IP:-10.0.0.50/24}")
    STATIC_GW=$(ask "Gateway" "$LAN_GW")
    ip_only="${STATIC_IP%%/*}"
    valid_ip "$ip_only"   || die "Invalid IP: $ip_only"
    valid_ip "$STATIC_GW" || die "Invalid gateway: $STATIC_GW"
    if command -v nmcli &>/dev/null; then
        CON=$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE")
        nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$STATIC_IP" \
            ipv4.gateway "$STATIC_GW" ipv4.dns "${UPSTREAM_DNS// /,}"
        nmcli con up "$CON"
    elif [[ -d /etc/netplan ]]; then
        cat > /etc/netplan/99-k3s-static.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$STATIC_IP]
      routes: [{to: default, via: $STATIC_GW}]
      nameservers: {addresses: [${UPSTREAM_DNS// /, }]}
EOF
        chmod 600 /etc/netplan/99-k3s-static.yaml
        netplan apply
    elif [[ -f /etc/network/interfaces ]]; then
        cat >> /etc/network/interfaces <<EOF

auto $IFACE
iface $IFACE inet static
    address $ip_only
    netmask 255.255.255.0
    gateway $STATIC_GW
    dns-nameservers $UPSTREAM_DNS
EOF
    else
        die "No supported network manager for static IP."
    fi
    ok "Static IP set: $STATIC_IP via $STATIC_GW"
    cur_ip_only="${CUR_IP%%/*}"
    if [[ -n "$cur_ip_only" && "$cur_ip_only" != "$ip_only" ]]; then
        echo
        echo -e "${c_yel}╔══════════════════════════════════════════════════════════╗${c_off}"
        echo -e "${c_yel}║                YOUR SSH SESSION MAY NOW DROP             ║${c_off}"
        echo -e "${c_yel}║                                                          ║${c_off}"
        echo -e "${c_yel}║   IP changed: ${cur_ip_only} -> ${ip_only}"
        echo -e "${c_yel}║                                                          ║${c_off}"
        echo -e "${c_yel}║   Add this static IP to your router's DHCP reservations  ║${c_off}"
        echo -e "${c_yel}║                                                          ║${c_off}"
        echo -e "${c_yel}║   Reconnect using the new IP address:                    ║${c_off}"
        echo -e "${c_yel}║                                                          ║${c_off}"
        echo -e "${c_yel}║      ssh ${USER}@${ip_only}"
        echo -e "${c_yel}║                                                          ║${c_off}"
        echo -e "${c_yel}║   Then re-run this script to continue setup.             ║${c_off}"
        echo -e "${c_yel}╚══════════════════════════════════════════════════════════╝${c_off}"
        echo
        sleep 3
    fi
else
    ok "Interface '$IFACE' is static (${CUR_IP:-unknown}); no change."
fi

# ----------------------------------------------------------------------------
# 3. Base packages
# ----------------------------------------------------------------------------
log "Installing base packages"
if [[ $OS == debian ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget iptables nfs-common chrony jq ca-certificates open-iscsi
else
    dnf install -y curl wget iptables nfs-utils chrony jq ca-certificates iscsi-initiator-utils
fi
ok "Base packages installed"

# ----------------------------------------------------------------------------
# 4. Time sync
# ----------------------------------------------------------------------------
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony
timedatectl set-ntp true || true
ok "Time sync enabled"

# ----------------------------------------------------------------------------
# 5. Swap off
# ----------------------------------------------------------------------------
swapoff -a
sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
systemctl mask 'systemd-zram-setup@*' 2>/dev/null || true
ok "Swap disabled"

# ----------------------------------------------------------------------------
# 6. Kernel modules + sysctl
# ----------------------------------------------------------------------------
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k3s.conf
modprobe overlay br_netfilter 2>/dev/null || true
cat > /etc/sysctl.d/99-k3s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
net.netfilter.nf_conntrack_max      = 524288
vm.overcommit_memory                = 1
kernel.panic                        = 10
kernel.panic_on_oops                = 1
EOF
sysctl --system >/dev/null
ok "Kernel modules + sysctl applied"

# ----------------------------------------------------------------------------
# 7. Firewall
# ----------------------------------------------------------------------------
if [[ $DISABLE_FIREWALL -eq 1 ]]; then
    warn "Disabling host firewall"
    systemctl disable --now firewalld 2>/dev/null || true
    ufw disable 2>/dev/null || true
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    for p in "${PORTS[@]}"; do firewall-cmd --permanent --add-port="$p" >/dev/null; done
    firewall-cmd --permanent --zone=trusted --add-source="$POD_CIDR" >/dev/null
    firewall-cmd --permanent --zone=trusted --add-source="$SVC_CIDR" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld rules added"
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${PORTS[@]}"; do ufw allow "${p/-/:}" >/dev/null; done
    ufw allow from "$POD_CIDR" >/dev/null
    ufw allow from "$SVC_CIDR" >/dev/null
    ok "ufw rules added"
else
    warn "No active firewall; skipping rules (k3s ports must be reachable)."
fi

# ----------------------------------------------------------------------------
# 8. SELinux (RHEL: keep enforcing)
# ----------------------------------------------------------------------------
if [[ $OS == rhel ]] && command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    dnf install -y container-selinux 2>/dev/null || true
    ok "container-selinux ensured"
fi

# ----------------------------------------------------------------------------
# 9. Summary
# ----------------------------------------------------------------------------
NODE_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2;exit}' | cut -d/ -f1)
echo
ok "================ PREP COMPLETE ================"
cat <<EOF | tee -a "$LOG"
  Hostname     : $(hostname)
  Node IP      : ${NODE_IP:-n/a}
  Pod/Svc/DNS  : $POD_CIDR / $SVC_CIDR / $CLUSTER_DNS
  Swap         : $(swapon --show | grep -q . && echo ON || echo OFF)
  Log          : $LOG

============================================================
 INSTALLING A HYBRID k3s CLUSTER
 (every node is a control-plane member AND runs workloads)
============================================================

STEP 1 — FIRST node (bootstraps the cluster + embedded etcd)
  Run this ONCE, only on the very first node:

    curl -sfL https://get.k3s.io | sh -s - server \\
      --cluster-init \\
      --cluster-cidr=$POD_CIDR \\
      --service-cidr=$SVC_CIDR \\
      --cluster-dns=$CLUSTER_DNS \\
      --node-ip=${NODE_IP:-<this-node-ip>} \\
      --flannel-backend=vxlan \\
      --write-kubeconfig-mode=0644 \\
      --tls-san=${NODE_IP:-<this-node-ip>}

  --cluster-init enables embedded etcd. --cluster-cidr/--service-cidr/
  --cluster-dns are set here ONCE; all later nodes inherit them — do NOT
  repeat those three flags below.

STEP 2 — Grab the join token (from the FIRST node)

    sudo cat /var/lib/rancher/k3s/server/node-token

  Copy the whole string; you'll use it as K3S_TOKEN on every other node.

STEP 3 — EACH additional hybrid node (joins as control-plane + worker)
  Run on every node AFTER the first (run them one at a time):

    curl -sfL https://get.k3s.io | \\
      K3S_TOKEN=<token-from-step-2> \\
      sh -s - server \\
      --server=https://<first-node-ip>:6443 \\
      --node-ip=<this-node-ip> \\
      --flannel-backend=vxlan \\
      --write-kubeconfig-mode=0644 \\
      --tls-san=<this-node-ip>

  *** etcd QUORUM RULE: keep the total number of nodes ODD (1, 3, 5...).
      A 2-node cluster has NO fault tolerance. Use 3 for real HA. ***

STEP 4 — Verify (from any node)

    sudo kubectl get nodes -o wide          # all should be Ready
    sudo kubectl get pods -A                 # coredns/traefik Running

  kubeconfig lives at /etc/rancher/k3s/k3s.yaml. To use kubectl as a
  normal user, or from your laptop:

    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown \$(id -u):\$(id -g) ~/.kube/config
    # if copying to another machine, edit 'server:' from 127.0.0.1 to <first-node-ip>

USEFUL TO KNOW
  - Service / restart : sudo systemctl status|restart k3s
  - Live logs         : sudo journalctl -u k3s -f
  - Config file       : put flags in /etc/rancher/k3s/config.yaml to avoid
                        re-typing them; survives upgrades.
  - Add/remove later  : new nodes just repeat STEP 3. To remove a node:
                        kubectl drain <n> --ignore-daemonsets --delete-emptydir-data
                        kubectl delete node <n>   (then uninstall on that host)
  - Uninstall a node : sudo /usr/local/bin/k3s-uninstall.sh   (server)
                       sudo /usr/local/bin/k3s-agent-uninstall.sh (agent)
============================================================
EOF
exit 0