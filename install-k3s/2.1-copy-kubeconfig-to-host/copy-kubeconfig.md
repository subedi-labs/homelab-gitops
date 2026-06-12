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

3. Verify Connection

```bash
# Shows cluster's control plane and CoreDNS addresses
kubectl cluster-info

# Shows cluster's nodes
kubectl get nodes
```

4. (optional) Enable kubectl autocompletion

```bash
# Add to .bashrc
source <(kubectl completion bash)
# Extends completion to 'k' alias
complete -o default -F __start_kubectl k
```

5. (optional) Aliases

```bash
# Add to ~/.bashrc
# Core shorthand
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias kdel='kubectl delete'
alias ka='kubectl apply -f'
alias ke='kubectl edit'
alias kex='kubectl exec -it'
alias kl='kubectl logs'
alias klf='kubectl logs -f'          # follow logs

# Pods
alias kgp='kubectl get pods'
alias kgpa='kubectl get pods -A'     # all namespaces
alias kgpw='kubectl get pods -w'     # watch
alias kdp='kubectl describe pod'

# Deployments
alias kgd='kubectl get deployments'
alias kdd='kubectl describe deployment'
alias krr='kubectl rollout restart deployment'

# Services & ingress
alias kgs='kubectl get svc'
alias kgi='kubectl get ingress'

# Nodes
alias kgn='kubectl get nodes'
alias kdn='kubectl describe node'

# Reload shell
source ~/.bashrc
```
