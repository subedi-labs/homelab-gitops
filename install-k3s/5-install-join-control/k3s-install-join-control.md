# Install and Join Control Node

1. Install and join control node

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://10.0.0.50:6443 \
  K3S_TOKEN=K1011862973e0f4c325adbab3670ceba4be5f568921084d330b4bf8fd048a71fbd7::server:ff126f12946f41e08e429285f4c42993 \
  INSTALL_K3S_EXEC="server \
    --node-name=k3-02 \
    --node-ip=10.0.0.51 \
    --disable=traefik \
    --disable=servicelb \
    --disable-kube-proxy \
    --flannel-backend=none \
    --disable-network-policy \
    --write-kubeconfig-mode=0644" \
  sudo sh -
```
 
2. Verify

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo kubectl get nodes -o wide
```

Uninstall

`/usr/local/bin/k3s-uninstall.sh`