# Setup nfs share

- `sudo ./nfs-lxc-setup.sh` Interative mode

1. Check storage

```bash
sudo lvs --units g -o lv_name,lv_size,data_percent,metadata_percent,pool_lv
```

1. Run script

```bash
sudo ./nfs-lxc-setup.sh \
  --mode thin \
  --vg pve \
  ---thin-pool data \
  --lv-size 100G \
  --ip 10.0.0.25/24
```
