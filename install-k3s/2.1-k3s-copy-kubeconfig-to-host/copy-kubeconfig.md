# Copy Kubeconfig

### Pre-Req

- Install `kubectl` on host

### 1. Grab the kubeconfig

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

#### 2. Copy kubeconfig to host

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