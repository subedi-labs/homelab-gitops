# Install and Join Control Node

1. Install and join control node

```bash
curl -sfL https://get.k3s.io | \
  sh -s - server \
    --server https://10.0.0.50:6443 \
    --token \
    --node-name=k3-control-2 \
    --node-ip=10.0.0.51 \
    --disable=traefik \
    --disable=servicelb \
    --disable-kube-proxy \
    --flannel-backend=none \
    --disable-network-policy \
    --write-kubeconfig-mode=0644
```
 
2. Verify

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo kubectl get nodes -o wide
```

---

99. Uninstall

 - /usr/local/bin/k3s-uninstall.sh