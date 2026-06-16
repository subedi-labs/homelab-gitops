# Install and Join Control Node

1. Install and join control node

```bash
curl -sfL https://get.k3s.io | \
  sh -s - server \
    --server https://10.0.0.50:6443 \
    --token K10b5183064bd95faa5c316a34122786f618f28dae5f596e8aaa965f61a7c032d9c::server:20fd18057bc585e6e86737ff067ed2ad \
    --node-name=k3-03 \
    --node-ip=10.0.0.52 \
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