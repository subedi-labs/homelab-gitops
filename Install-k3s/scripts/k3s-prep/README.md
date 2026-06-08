# prep-k3s-node

A single, idempotent Bash script that **preps a fresh VM** so it's ready to join a [k3s](https://k3s.io) cluster as a hybrid node (works for both server/control-plane and agent/worker roles). It does the boring-but-critical groundwork — swap, kernel modules, sysctl, firewall ports, time sync, optional static IP — so the actual `k3s` install just works.

It asks for input **only when it genuinely can't infer the right answer** (mainly: hostname, and whether to convert a DHCP interface to static). Everything else uses sensible defaults you can override with flags.

---

## What it configures

| Step | Action | Why it matters |
|---|---|---|
| Hostname | Optionally renames host, fixes `/etc/hosts` | Cluster nodes must have unique, resolvable names |
| Static IP | Detects DHCP and offers to convert (nmcli / netplan / `interfaces`) | k3s nodes need a **stable IP**; a DHCP node that changes IP breaks the cluster |
| Base packages | `curl wget iptables nfs-* chrony jq open-iscsi` etc. | Required for k3s, longhorn/NFS storage, image pulls |
| Time sync | Enables `chrony` + NTP | TLS certs & etcd are **very** time-sensitive |
| Swap | `swapoff -a` + comments it out in `/etc/fstab` | kubelet refuses to run with swap by default |
| Kernel modules | Loads `overlay`, `br_netfilter` | Required by the container runtime & flannel |
| sysctl | IP forwarding, bridge-nf, conntrack & inotify limits, OOM/panic tuning | Pod networking + stability under load |
| Firewall | Opens k3s ports, trusts Pod/Service CIDRs | Nodes must reach each other on these ports |
| SELinux | (RHEL) ensures `container-selinux` | Keeps SELinux **enforcing** instead of disabling it |
| DNS | Verifies resolution, adds fallback resolvers if broken | Image pulls fail fast without DNS |

### Firewall ports opened

| Port | Proto | Purpose |
|---|---|---|
| 6443 | TCP | Kubernetes API server |
| 10250 | TCP | kubelet metrics |
| 8472 | UDP | Flannel VXLAN |
| 51820/51821 | UDP | Flannel WireGuard (if used) |
| 2379–2380 | TCP | etcd (only needed for HA / embedded etcd) |
| 5001 | TCP | Spegel embedded registry mirror |
| Pod/Service CIDR | — | Added to the `trusted` zone |

---

## Network model

These are the defaults baked in (matching the target environment) and the values the script prints for your `k3s` install command:

| Range | CIDR | Purpose |
|---|---|---|
| LAN | `10.0.0.0/24` | Physical / VM network |
| Pod CIDR | `10.42.0.0/16` | Pod IPs (up to 65,534) |
| Service CIDR | `10.43.0.0/16` | Service IPs |
| Cluster DNS | `10.43.0.10` | CoreDNS service IP (must be inside the Service CIDR) |

> `10.42.0.0/16` and `10.43.0.0/16` are k3s's defaults, so the cluster will use them automatically. They're still passed explicitly so your install is self-documenting and won't drift if k3s changes defaults.

---

## Usage

```bash
chmod +x prep-k3s-node.sh
sudo ./prep-k3s-node.sh
```

### Common variations

```bash
# Fully non-interactive (CI / templated VMs) — accepts all defaults, no prompts
sudo ./prep-k3s-node.sh --yes --hostname k3s-worker-01

# Preview everything without changing anything
sudo ./prep-k3s-node.sh --dry-run

# Different gateway and a node where you manage the firewall elsewhere
sudo ./prep-k3s-node.sh --lan-gw 10.0.0.254 --disable-firewall

# Custom network ranges
sudo ./prep-k3s-node.sh --pod-cidr 10.42.0.0/16 --svc-cidr 10.43.0.0/16 --cluster-dns 10.43.0.10
```

### All flags

| Flag | Description | Default |
|---|---|---|
| `--hostname NAME` | Rename the host | *(prompted / unchanged)* |
| `--lan-gw IP` | LAN gateway | `10.0.0.1` |
| `--pod-cidr CIDR` | Pod CIDR | `10.42.0.0/16` |
| `--svc-cidr CIDR` | Service CIDR | `10.43.0.0/16` |
| `--cluster-dns IP` | Cluster DNS IP | `10.43.0.10` |
| `--upstream-dns "A B"` | Upstream resolvers | `1.1.1.1 9.9.9.9` |
| `--disable-firewall` | Stop & disable firewalld/ufw instead of adding rules | off |
| `--skip-static` | Never touch IP configuration | off |
| `--yes` | Non-interactive; accept all defaults, no prompts | off |
| `--dry-run` | Print actions without applying them | off |
| `-h, --help` | Show help | — |

---

## When does it ask for input?

By design, almost never. It only prompts when:

1. **Hostname** — if you didn't pass `--hostname` and aren't using `--yes`, it confirms the name (defaulting to the current one).
2. **Static IP** — *only* if it detects the primary interface is on **DHCP**. It then asks whether to convert, and for the desired IP/gateway. If the interface is already static, it leaves it alone.

With `--yes` it won't prompt at all (DHCP interfaces are left as-is in that case, so set a DHCP reservation or pass an explicit static config beforehand).

---

## After running it

The script ends by printing ready-to-paste `k3s` install commands with your network flags filled in. In short:

**First server (control-plane):**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16 \
  --cluster-dns=10.43.0.10 \
  --node-ip=<this-node-ip> \
  --flannel-backend=vxlan \
  --write-kubeconfig-mode=0644
```

**Agent (worker):**
```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://<server-ip>:6443 K3S_TOKEN=<token> \
  sh -s - agent --node-ip=<this-node-ip>
```

> ⚠️ Pass `--cluster-cidr`, `--service-cidr`, and `--cluster-dns` **only on the first server**. Additional servers and all agents inherit these from the cluster — passing mismatched values will break networking.

The join token lives at `/var/lib/rancher/k3s/server/node-token` on the first server.

---

## Safety & re-runs

- **Idempotent** — safe to run multiple times; it won't double-apply config.
- **`--dry-run`** lets you see every action first.
- **Logs** everything to `/var/log/prep-k3s-node.log`.
- **Backs up** `/etc/fstab` before editing (`.bak`).
- Keeps **SELinux enforcing** on RHEL rather than disabling it.

## Requirements

- Root / `sudo`.
- Debian/Ubuntu **or** RHEL/Rocky/Alma family.
- Outbound internet to `get.k3s.io` and your image registries.

## Disclaimer

Review the script before running it on production hosts. It modifies networking, firewall, swap, and kernel settings — all expected for a k3s node, but you should understand the changes in your environment.