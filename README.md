# homelab-docs
docs

### Disk Space

| Server | Disk Model | Total Size | local | local-lvm |
| ------ | ---------- | ---------- | ----- | --------- |
| proxmox1 | SK Hynix SH920 | 256 GB | 68 GB | 141 GB (106 GB free) |
| proxmox2 | Intel SSDSC2BX800 | 745 GB | 94 GB (80 GB free) | 612 GB (595 GB free) |
| proxmox3 | SK Hynix SH920 | 256 GB | 68 GB (55 GB free) | 141 GB (125 GB free) |

### RAM



### Example

| Host | VM | Role | CPU | RAM | OS Disk | Longhorn Disk |
|---|---|---|---|---|---|---|
| proxmox1 | k3s-1 | CP + Worker | 6 cores | 12288 MiB | 20 GB | 50 GB |
| proxmox2 | k3s-2 | CP + Worker | 6 cores | 12288 MiB | 20 GB | 50 GB |
| proxmox3 | k3s-3 | CP + Worker | 6 cores | 12288 MiB | 20 GB | 50 GB |
