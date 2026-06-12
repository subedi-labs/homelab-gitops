# Install and Join Control Node

1. Install and join control node

```bash
sudo curl -sfL https://get.k3s.io | \
  K3S_URL=https://10.0.0.50:6443 \
  K3S_TOKEN=K10562e960b4ddebf2a78d936a546a3c845eb2f190ecc8732b6dd5a859701d58e00::server:8659ce1c62f3d386d25567c76feeabdc \
  INSTALL_K3S_EXEC="server \
    --node-name=<k3-control-02> \
    --node-ip=<10.0.0.52> \
    --disable-kube-proxy \
    --flannel-backend=none \
    --disable-network-policy \
    --node-label topology.kubernetes.io/zone=pve-host-1 \
    --node-label node.kubernetes.io/instance-type=control-plane" \
  sh -
```
 
2. Verify

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -o wide
```