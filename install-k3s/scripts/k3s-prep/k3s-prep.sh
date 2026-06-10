#!/usr/bin/env bash
#
# prep-k3s-node.sh
# Pre-configures / preps a VM before installing it as a k3s hybrid node.
# Targets Debian/Ubuntu and RHEL/Rocky/Alma based systems.
#
# Network assumptions (override via flags or env):
#   LAN          10.0.0.0/24
#   Pod CIDR     10.42.0.0/16
#   Service CIDR 10.43.0.0/16
#   Cluster DNS  10.43.0.10
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
LAN_CIDR="10.0.0.0/24"
LAN_GW="10.0.0.1"
POD_CIDR="10.42.0.0/16"
SVC_CIDR="10.43.0.0/16"
CLUSTER_DNS="10.43.0.10"
UPSTREAM_DNS="1.1.1.1 1.0.0.1"

NODE_HOSTNAME=""        # if set, host is renamed
SKIP_STATIC=0           # 1 = never touch IP config
ASSUME_YES=0            # 1 = no interactive prompts at all
DRY_RUN=0
DISABLE_FIREWALL=0      # 1 = stop+disable firewalld/ufw entirely
LOG="/var/log/prep-k3s-node.log"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'
log()  { echo -e "${c_blu}[*]${c_off} $*" | tee -a "$LOG"; }
ok()   { echo -e "${c_grn}[+]${c_off} $*" | tee -a "$LOG"; }
warn() { echo -e "${c_yel}[!]${c_off} $*" | tee -a "$LOG"; }
die()  { echo -e "${c_red}[x]${c_off} $*" | tee -a "$LOG"; exit 1; }

ask() {
    # ask "Prompt" "default"  -> echoes answer
    local prompt="$1" def="${2:-}"
    if [[ $ASSUME_YES -eq 1 ]]; then echo "$def"; return; fi
    local ans
    if [[ -n "$def" ]]; then
        read -rp "$(echo -e "${c_yel}? ${prompt} [${def}]: ${c_off}")" ans
        echo "${ans:-$def}"
    else
        read -rp "$(echo -e "${c_yel}? ${prompt}: ${c_off}")" ans
        echo "$ans"
    fi
}

confirm() {
    local prompt="$1"
    if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
    local ans; read -rp "$(echo -e "${c_yel}? ${prompt} [y/N]: ${c_off}")" ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

valid_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.; read -ra o <<<"$ip"
    for n in "${o[@]}"; do ((n>=0 && n<=255)) || return 1; done
    return 0
}

usage() {
cat <<EOF
Usage: sudo $0 [options]

  --hostname NAME        Rename host to NAME
  --lan-gw IP            LAN gateway (default ${LAN_GW})
  --pod-cidr CIDR        Pod CIDR (default ${POD_CIDR})
  --svc-cidr CIDR        Service CIDR (default ${SVC_CIDR})
  --cluster-dns IP       Cluster DNS (default ${CLUSTER_DNS})
  --upstream-dns "A B"   Upstream resolvers (default "${UPSTREAM_DNS}")
  --disable-firewall     Stop & disable firewalld/ufw instead of adding rules
  --skip-static          Do not modify IP configuration
  --yes                  Non-interactive; accept all defaults
  --dry-run              Print actions without applying
  -h, --help             Show this help
EOF
exit 0
}

# ----------------------------------------------------------------------------
# Arg parse
# ----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname) NODE_HOSTNAME="$2"; shift 2;;
        --lan-gw) LAN_GW="$2"; shift 2;;
        --pod-cidr) POD_CIDR="$2"; shift 2;;
        --svc-cidr) SVC_CIDR="$2"; shift 2;;
        --cluster-dns) CLUSTER_DNS="$2"; shift 2;;
        --upstream-dns) UPSTREAM_DNS="$2"; shift 2;;
        --disable-firewall) DISABLE_FIREWALL=1; shift;;
        --skip-static) SKIP_STATIC=1; shift;;
        --yes) ASSUME_YES=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage;;
        *) die "Unknown arg: $1 (use --help)";;
    esac
done

run() {
    # run a command, honoring dry-run
    if [[ $DRY_RUN -eq 1 ]]; then echo -e "${c_blu}[dry]${c_off} $*"; else eval "$@"; fi
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
mkdir -p "$(dirname "$LOG")"; : > "$LOG"

if   [[ -f /etc/debian_version ]]; then OS=debian; PKG=apt
elif [[ -f /etc/redhat-release ]]; then OS=rhel;   PKG=dnf
else die "Unsupported distro (need Debian/Ubuntu or RHEL family)."; fi
ok "Detected OS family: $OS"

# ----------------------------------------------------------------------------
# 1. Hostname
# ----------------------------------------------------------------------------
log "Configuring hostname"
if [[ -z "$NODE_HOSTNAME" && $ASSUME_YES -eq 0 ]]; then
    NODE_HOSTNAME=$(ask "Hostname for this node" "$(hostname)")
fi
if [[ -n "$NODE_HOSTNAME" && "$NODE_HOSTNAME" != "$(hostname)" ]]; then
    run "hostnamectl set-hostname '$NODE_HOSTNAME'"
    grep -q "127.0.1.1" /etc/hosts \
        && run "sed -i 's/^127.0.1.1.*/127.0.1.1\t$NODE_HOSTNAME/' /etc/hosts" \
        || run "echo '127.0.1.1\t$NODE_HOSTNAME' >> /etc/hosts"
    ok "Hostname set to $NODE_HOSTNAME"
else
    ok "Hostname unchanged ($(hostname))"
fi

# ----------------------------------------------------------------------------
# 2. Static IP (only if DHCP detected and user agrees)
# ----------------------------------------------------------------------------
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
CUR_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2;exit}')

is_dhcp() {
    # crude DHCP detection across managers
    if command -v nmcli &>/dev/null; then
        local con; con=$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null)
        [[ "$(nmcli -t -g ipv4.method connection show "$con" 2>/dev/null)" == "auto" ]] && return 0
    fi
    grep -rqs "dhcp" /etc/netplan/ 2>/dev/null && return 0
    grep -qs "iface $IFACE inet dhcp" /etc/network/interfaces 2>/dev/null && return 0
    return 1
}

if [[ $SKIP_STATIC -eq 1 ]]; then
    warn "Skipping IP configuration (--skip-static)"
elif [[ -z "$IFACE" ]]; then
    warn "Could not detect primary interface; skipping static IP."
elif is_dhcp; then
    warn "Interface '$IFACE' appears to use DHCP (current: ${CUR_IP:-none})."
    if confirm "Convert to a static IP?"; then
        STATIC_IP=$(ask "Static IP (with prefix, e.g. 10.0.0.50/24)" "${CUR_IP:-10.0.0.50/24}")
        STATIC_GW=$(ask "Gateway" "$LAN_GW")
        ip_only="${STATIC_IP%%/*}"
        valid_ip "$ip_only"  || die "Invalid IP: $ip_only"
        valid_ip "$STATIC_GW" || die "Invalid gateway: $STATIC_GW"

        if command -v nmcli &>/dev/null; then
            CON=$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE")
            run "nmcli con mod '$CON' ipv4.method manual ipv4.addresses '$STATIC_IP' ipv4.gateway '$STATIC_GW' ipv4.dns '${UPSTREAM_DNS// /,}'"
            run "nmcli con up '$CON'"
        elif [[ -d /etc/netplan ]]; then
            NP=/etc/netplan/99-k3s-static.yaml
            run "cat > $NP <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: false
      addresses: [$STATIC_IP]
      routes:
        - to: default
          via: $STATIC_GW
      nameservers:
        addresses: [${UPSTREAM_DNS// /, }]
EOF"
            run "chmod 600 $NP"
            run "netplan apply"
        elif [[ -f /etc/network/interfaces ]]; then
            run "cat >> /etc/network/interfaces <<EOF

auto $IFACE
iface $IFACE inet static
    address ${ip_only}
    netmask 255.255.255.0
    gateway $STATIC_GW
    dns-nameservers $UPSTREAM_DNS
EOF"
        else
            die "No supported network manager found to set static IP."
        fi
        ok "Static IP configured: $STATIC_IP via $STATIC_GW"
    else
        warn "Leaving DHCP in place (a stable lease/reservation is recommended)."
    fi
else
    ok "Interface '$IFACE' already static (${CUR_IP:-unknown}); nothing to do."
fi

# ----------------------------------------------------------------------------
# 3. Base packages
# ----------------------------------------------------------------------------
log "Installing base packages"
if [[ $OS == debian ]]; then
    run "DEBIAN_FRONTEND=noninteractive apt-get update -y"
    run "DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget iptables nfs-common chrony jq ca-certificates apparmor apparmor-utils open-iscsi"
else
    run "dnf install -y curl wget iptables nfs-utils chrony jq ca-certificates iscsi-initiator-utils"
fi
ok "Base packages installed"

# ----------------------------------------------------------------------------
# 4. Time sync (critical for TLS / cluster certs)
# ----------------------------------------------------------------------------
log "Enabling time sync (chrony)"
run "systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony"
run "timedatectl set-ntp true || true"
ok "NTP enabled"

# ----------------------------------------------------------------------------
# 5. Disable swap (required by kubelet)
# ----------------------------------------------------------------------------
log "Disabling swap"
run "swapoff -a"
run "sed -i.bak '/\\sswap\\s/s/^/#/' /etc/fstab"
# also neutralize zram/systemd swap if present
run "systemctl mask 'systemd-zram-setup@*' 2>/dev/null || true"
ok "Swap disabled (and removed from fstab)"

# ----------------------------------------------------------------------------
# 6. Kernel modules + sysctl
# ----------------------------------------------------------------------------
log "Loading kernel modules and applying sysctl"
run "cat > /etc/modules-load.d/k3s.conf <<EOF
overlay
br_netfilter
EOF"
run "modprobe overlay || true"
run "modprobe br_netfilter || true"

run "cat > /etc/sysctl.d/99-k3s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
# Inotify limits help with many pods/containers
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
# Conntrack table size for service-heavy clusters
net.netfilter.nf_conntrack_max      = 524288
vm.panic_on_oom                     = 0
vm.overcommit_memory                = 1
kernel.panic                        = 10
kernel.panic_on_oops                = 1
EOF"
run "sysctl --system >/dev/null 2>&1 || sysctl --system"
ok "Kernel modules + sysctl applied"

# ----------------------------------------------------------------------------
# 7. Firewall
# ----------------------------------------------------------------------------
log "Configuring firewall"
open_ports_firewalld() {
    run "firewall-cmd --permanent --add-port=6443/tcp"      # API server
    run "firewall-cmd --permanent --add-port=10250/tcp"     # kubelet metrics
    run "firewall-cmd --permanent --add-port=8472/udp"      # flannel vxlan
    run "firewall-cmd --permanent --add-port=51820/udp"     # flannel wireguard (ipv4)
    run "firewall-cmd --permanent --add-port=51821/udp"     # flannel wireguard (ipv6)
    run "firewall-cmd --permanent --add-port=2379-2380/tcp" # etcd (HA)
    run "firewall-cmd --permanent --add-port=5001/tcp"      # spegel registry mirror
    # Trust intra-cluster pod/service traffic
    run "firewall-cmd --permanent --zone=trusted --add-source=$POD_CIDR"
    run "firewall-cmd --permanent --zone=trusted --add-source=$SVC_CIDR"
    run "firewall-cmd --reload"
}
open_ports_ufw() {
    run "ufw allow 6443/tcp"
    run "ufw allow 10250/tcp"
    run "ufw allow 8472/udp"
    run "ufw allow 51820/udp"
    run "ufw allow 51821/udp"
    run "ufw allow 2379:2380/tcp"
    run "ufw allow 5001/tcp"
    run "ufw allow from $POD_CIDR"
    run "ufw allow from $SVC_CIDR"
}

if [[ $DISABLE_FIREWALL -eq 1 ]]; then
    warn "Disabling host firewall (per --disable-firewall)"
    run "systemctl disable --now firewalld 2>/dev/null || true"
    run "ufw disable 2>/dev/null || true"
elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    open_ports_firewalld
    ok "firewalld rules added"
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    open_ports_ufw
    ok "ufw rules added"
else
    warn "No active firewall detected; skipping rules. (k3s ports must be reachable)"
fi

# ----------------------------------------------------------------------------
# 8. SELinux (RHEL) - keep enforcing but ensure k3s policy can install
# ----------------------------------------------------------------------------
if [[ $OS == rhel ]] && command -v getenforce &>/dev/null; then
    log "SELinux status: $(getenforce)"
    if [[ "$(getenforce)" == "Enforcing" ]]; then
        run "dnf install -y container-selinux 2>/dev/null || true"
        ok "container-selinux ensured (k3s-selinux installs during k3s setup)"
    fi
fi

# ----------------------------------------------------------------------------
# 9. /etc/hosts sanity + DNS resolver
# ----------------------------------------------------------------------------
log "Verifying DNS resolution"
if ! getent hosts github.com >/dev/null 2>&1; then
    warn "DNS lookup failed; writing fallback resolvers"
    run "printf 'nameserver %s\\n' $UPSTREAM_DNS > /etc/resolv.conf"
fi
ok "DNS OK"

# ----------------------------------------------------------------------------
# 10. Summary
# ----------------------------------------------------------------------------
echo
ok "================ PREP COMPLETE ================"
cat <<EOF | tee -a "$LOG"
  Hostname     : $(hostname)
  Interface    : ${IFACE:-n/a}
  IP address   : $(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2;exit}')
  Pod CIDR     : $POD_CIDR
  Service CIDR : $SVC_CIDR
  Cluster DNS  : $CLUSTER_DNS
  Swap         : $(swapon --show | grep -q . && echo ON || echo OFF)
  Log file     : $LOG

Next steps — install k3s with matching network flags:

  # SERVER (control-plane) node:
  curl -sfL https://get.k3s.io | sh -s - server \\
    --cluster-cidr=$POD_CIDR \\
    --service-cidr=$SVC_CIDR \\
    --cluster-dns=$CLUSTER_DNS \\
    --node-ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2;exit}' | cut -d/ -f1) \\
    --flannel-backend=vxlan \\
    --write-kubeconfig-mode=0644

  # AGENT (worker) node:
  curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<token> sh -s - agent \\
    --node-ip=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2;exit}' | cut -d/ -f1)

  NOTE: --cluster-cidr / --service-cidr / --cluster-dns must be passed
        on the FIRST server only; agents inherit them automatically.
EOF
echo
[[ $DRY_RUN -eq 1 ]] && warn "DRY RUN — no changes were applied."
exit 0