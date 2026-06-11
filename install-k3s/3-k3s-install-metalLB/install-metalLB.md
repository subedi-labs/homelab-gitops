# Install MetalLB

> **Note**: Run from host if kubeconfig is setup.  
> If running from k3-node `sudo` is usually required.

1. Apply metalLB manifest

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml

# Wait for completion
kubectl wait -n metallb-system --for=condition=ready pod --selector=app=metallb --timeout=90s
```

2. Create `metallb-config.yml` manifest

```bash
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


3. Apply the custom manifest

```bash
kubectl apply -f metallb-config.yaml
```