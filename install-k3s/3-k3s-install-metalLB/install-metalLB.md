# Install MetalLB

1. Apply metalLB manifest

```bash
sudo kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml

# Wait for completion
sudo kubectl wait -n metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s
```

2. Configure MetalLB with an IP address pool by creating and applying a custom manifest.

```bash
# Create manifest
vim metallb-config.yaml

# Manifest content
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.0.246-10.0.0.254   # pick a range outside your DHCP pool

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