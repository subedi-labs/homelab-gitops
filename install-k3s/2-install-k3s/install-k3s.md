# Install k3s

1. Install first hybrid node

```bash
curl -sfL https://get.k3s.io | sh -s - server \\
    --cluster-init \\
    --node-name=k3s-hybrid-01 \\
    --cluster-cidr=$POD_CIDR \\
    --service-cidr=$SVC_CIDR \\
    --cluster-dns=$CLUSTER_DNS \\
    --node-ip=${NODE_IP:-<this-node-ip>} \\
    --flannel-backend=vxlan \\
    --write-kubeconfig-mode=0644 \\
    --tls-san=${NODE_IP:-<this-node-ip>}
    --disable=traefik \\
    --disable=servicelb
```