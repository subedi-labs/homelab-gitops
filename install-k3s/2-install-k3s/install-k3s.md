# Install k3s

1. Install first hybrid node

```bash
curl -sfL https://get.k3s.io | sh -s - server \
    --cluster-init \
    --node-name=k3-hybrid-01 \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --cluster-dns=10.43.0.10 \
    --node-ip=10.0.0.50 \
    --flannel-backend=vxlan \
    --write-kubeconfig-mode=0644 \
    --tls-san=10.0.0.50
    --disable=traefik \
    --disable=servicelb
```

