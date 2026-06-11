# Install k3s

### 1. Install first hybrid node

```bash
sudo curl -sfL https://get.k3s.io | sudo sh -s - server \
    --disable=traefik \
    --disable=servicelb \
    --cluster-init \
    --node-name=k3-hybrid-01 \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --cluster-dns=10.43.0.10 \
    --node-ip=10.0.0.50 \
    --flannel-backend=vxlan \
    --write-kubeconfig-mode=0644 \
    --tls-san=10.0.0.50
```

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

### 4. Grab the kubeconfig

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

#### 4.1 Copy kubeconfig to host

1. Copy to host machine at `~/.kube/config` 
2. Update values in kubeconfig:

```bash
clusters:
- cluster:
    ...
    server: https://<node_ip>:6443  # 1. Node IP address
  name: <cluster_name>              # 2. cluster name

contexts:
- context:
    cluster: <cluster_name>         # 3. must match cluster name above
    user: <cluster_name>            # 4. must match user name below
  name: <cluster_name>              # 5. context name

current-context: <cluster_name>     # 6. must match context name above

users:
- name: <cluster_name>              # 7. user name
```

`server: https://127.0.0.1:6443` with your server IP `server: https://10.0.0.50:6443`
3. 

### 5. Install MetalLB

```bash
# apply metalLB manifest
sudo kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml

# Wait for completion
sudo kubectl wait -n metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s

# Configure an IP pool by applying a metalLB config manifest
vim metallb-config.yaml

apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.0.200-10.0.0.220   # pick a range outside your DHCP pool

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - lan-pool
```