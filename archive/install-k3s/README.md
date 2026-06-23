# Install k3s

This repo will explain how to
- prep VMs
- Install initial initial k3s-control node and join additional worker/control nodes.
- Use kubeconfig on host (with optional configurations)
- Configure the cluster with Cilium
- Configure the cluster with Gateway api

Steps to install a k3s cluster configured with:
- Cilium v1.19.3
- Gateway API v1.4.1