# Uninstall k3s 

1. Run uninstall script

```bash
# Uninstall k3s (removes everything - binaries, config, data, systemd unit)
/usr/local/bin/k3s-uninstall.sh
```

2. Verify it is clean

```
systemctl status k3s 2>/dev/null
ls /etc/rancher/k3s/
ls /var/lib/rancher/k3s/
```


