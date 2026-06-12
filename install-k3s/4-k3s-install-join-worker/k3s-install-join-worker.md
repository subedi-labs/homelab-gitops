# Install and Join Worker Node

1. Install and join worker 

```bash
sudo curl -sfL https://get.k3s.io | \
  K3S_URL=https://10.0.0.50:6443 \
  K3S_TOKEN=K10562e960b4ddebf2a78d936a546a3c845eb2f190ecc8732b6dd5a859701d58e00::server:8659ce1c62f3d386d25567c76feeabdc \
  INSTALL_K3S_EXEC="--node-name=<k3-worker-02> \
    --node-ip=<10.0.0.51> \
    --node-label topology.kubernetes.io/zone=<pve-host-1> \
    --node-label node-role.kubernetes.io/worker=worker" \
  sh -
```

2. Verify

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -o wide
```