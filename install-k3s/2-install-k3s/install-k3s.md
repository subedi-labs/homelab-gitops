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

sudo kubectl get pods -A
```

### 3. Grab node token

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

### 4. Grab the kubeconfig

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy this to your Windows machine at `C:\Users\OITCOSUBEDP\.kube\config` and replace `127.0.0.1` with your server IP `10.0.0.50`.

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