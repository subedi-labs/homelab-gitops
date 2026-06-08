# k3s-prep.sh — README

Prepares a fresh Ubuntu VM to become a **k3s control node**. Run this before
installing k3s itself.

---

## Usage

```bash
# Make the script executable
chmod +x k3s-prep.sh

# Run as root
sudo bash k3s-prep.sh
```

You'll be prompted for a hostname. Hit Enter to accept the default (`k3s-control-01`).

After it completes, **reboot the VM** to confirm all settings survive a restart:

```bash
sudo reboot
```

---

## What It Does & Why

### Step 1 — Hostname
Sets a stable hostname and writes it into `/etc/hosts` so the node can
resolve itself without relying on external DNS. Kubernetes identifies nodes
by hostname — changing it later will break the cluster.

### Step 2 — Disable Swap
Kubernetes assumes it has full, predictable control over memory. Swap lets
the kernel silently page memory to disk, which breaks memory limits, QoS
guarantees, and causes unpredictable latency. **k3s will refuse to start
if swap is active** (unless explicitly overridden). This step turns swap
off immediately and comments it out of `/etc/fstab` so it stays off after
reboots.

### Step 3 — Kernel Modules
Loads two modules and persists them in `/etc/modules-load.d/k3s.conf`:

| Module | Purpose |
|---|---|
| `overlay` | Lets containerd layer container filesystems using OverlayFS — how container images are stacked and made writable without copying the whole image. |
| `br_netfilter` | Makes iptables see traffic crossing Linux bridges. Without this, pod-to-pod traffic on the same node bypasses iptables entirely, breaking NetworkPolicy and routing rules. |

### Step 4 — sysctl (Kernel Network Parameters)
Writes settings to `/etc/sysctl.d/k3s.conf` and applies them immediately:

| Setting | Purpose |
|---|---|
| `net.ipv4.ip_forward` | Allows the kernel to forward packets between interfaces — the foundation of all pod routing. |
| `net.bridge.bridge-nf-call-iptables` | Routes bridged IPv4 traffic through iptables so NetworkPolicy and kube-proxy work. |
| `net.bridge.bridge-nf-call-ip6tables` | Same as above for IPv6 traffic, even if you're not using IPv6 (avoids warnings and future-proofs the node). |

### Step 5 — Firewall (UFW)
UFW is **disabled** — this assumes a trusted internal network where host-level
firewalling is not required. If your environment changes, re-enable UFW and
open ports 6443/tcp, 10250/tcp, 2379-2380/tcp, 8472/udp, and 51820/udp.

### Step 6 — System Update & Dependencies
Updates all packages and installs:

| Package | Why |
|---|---|
| `curl` / `wget` | Needed to download the k3s install script and other tooling. |
| `open-iscsi` | Required by storage backends like **Longhorn** and **OpenEBS** to mount iSCSI block volumes. |
| `nfs-common` | Required to mount NFS-based persistent volumes — many shared storage solutions depend on it. |

### Step 7 — AppArmor (skipped by default)
AppArmor is a Linux security module that can conflict with certain CNI plugins
or storage backends. k3s supports it, but it can cause subtle permission
errors that are hard to debug. The disable command is in the script but
commented out — **leave AppArmor enabled unless you hit issues**.

### Step 8 — Static IP
The script detects whether the primary netplan config is using DHCP. If it is,
you'll be prompted to configure a static IP interactively. The script will
auto-detect your current interface, IP, and gateway as defaults — just hit
Enter to accept them or type new values.

If you choose to proceed, the original netplan config is backed up to
`<original-file>.bak` before being overwritten, and `netplan apply` is run
immediately. If you skip it, a warning is shown reminding you to set a static
IP before installing k3s.

> **Why it matters:** k3s nodes communicate by IP. If the control node's IP
> changes after installation, agents lose their API server connection and TLS
> certificates (bound to the IP/hostname) become invalid — breaking the cluster.

### Step 9 — Time Sync (chrony)
Installs and enables **chrony**, a modern NTP daemon. Kubernetes is sensitive
to clock skew: TLS certificates, etcd leader election, and API server
requests all rely on consistent time across nodes. Nodes drifting more than
~2 seconds apart can cause etcd failures and rejected API requests. Chrony
syncs faster on startup and handles intermittent connectivity better than the
older `ntpd`.

---

## After Rebooting

**Network layout:**

| Range | CIDR | Purpose |
|---|---|---|
| LAN | `10.0.0.0/24` | Physical/VM network |
| Pod CIDR | `10.42.0.0/16` | Pod IPs (up to 65,534) |
| Service CIDR | `10.43.0.0/16` | Service IPs (up to 65,534) |
| Cluster DNS | `10.43.0.10` | CoreDNS service IP (must be within Service CIDR) |

Install k3s on the control node:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --tls-san <your-node-ip> \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16 \
  --cluster-dns=10.43.0.10 \
  --cluster-init \
  --flannel-backend=wireguard-native \
  --write-kubeconfig-mode=644" sh -
```

Retrieve the node token (you'll need this to join agent nodes):

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

Check the cluster is up:

```bash
sudo k3s kubectl get nodes
```

---

## Tested On
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS