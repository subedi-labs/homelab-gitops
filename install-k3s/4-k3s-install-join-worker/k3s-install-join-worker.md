# Install and Join Worker Node

1. Install and join worker 

```bash
sudo curl -sfL https://get.k3s.io | \
  K3S_URL=https://10.0.0.50:6443 \
  K3S_TOKEN=K10562e960b4ddebf2a78d936a546a3c845eb2f190ecc8732b6dd5a859701d58e00::server:8659ce1c62f3d386d25567c76feeabdc \
  INSTALL_K3S_EXEC="--node-name=<k3-worker-02> \
    --node-ip=<10.0.0.53> \
    --node-label topology.kubernetes.io/zone=<pve-host-2> \
    --node-label node.kubernetes.io/instance-type=<worker>" \
  sh -
```

2. Add Worker label

```bash
kubectl label node <k3-worker-02> node-role.kubernetes.io/worker=worker
```

2. Verify

```bash
# From Host machine
kgn -o wide
```