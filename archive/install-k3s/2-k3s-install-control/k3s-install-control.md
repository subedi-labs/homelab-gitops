# Install k3s

> k3 control nodes act as hybrid nodes they can also carry workloads

### 1. Install first k3s control node

```bash
curl -sfL https://get.k3s.io | sudo sh -s - server \
    --disable=traefik \
    --disable=servicelb \
    --cluster-init \
    --node-name=k3-01 \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --cluster-dns=10.43.0.10 \
    --node-ip=10.0.0.50 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable-kube-proxy \
    --write-kubeconfig-mode=0644 \
    --tls-san=10.0.0.50

### 2. Verify k3s is running

```bash
sudo systemctl status k3s

sudo kubectl get nodes

sudo kubectl get pods -A --watch
```

### 3. Grab node token

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

