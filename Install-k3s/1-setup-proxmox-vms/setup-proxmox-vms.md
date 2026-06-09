# Setup Proxmox VMs

## Pre-Reqs
* ubuntu live server ISO saved on each host's local -> ISO image
* Save host machines ssh key to github profile

## Create and configure VMs
1. Create 1 VMS on each proxmox host
    * Display: Default
    * Mem: 8000
    * 1 socket, 3 cores
    * BIOS: Default (SeaBIOS)
    * Machine: q35
    * SCSI Controller: VirtIO SCSI single
    * Hard Disk: Cache: writeback, Discard check, IO thread check, Backup check, skip replication check, read-only uncheck, Asyonc IO: Default.
    * Network: Firewall uncheck
2. Install Ubuntu

### Enable Qemu Guest on VM

```bash
sudo apt install qemu-guest-agent
sudo systemctl enble --now qemu-guest-agent
sudo systemctl status qemu-guest-agent
```

## Troubleshooting

### Hostname is not set correctly

```bash
# Set hostname
sudo hostnamectl set-hostname <newhostname>

# Refresh shell
exec bash
```

### Unable to SSH into remote server

#### Option 1:

1. Put your host's ssh key into GitHub
2. Import SSH key from GitHub

```bash
sudo apt install ssh-import-id
ssh-import-id-gh pukar10
```

#### Option 2:

1. Enable password authentication

```bash
ssh username@password
sudo vim /etc/ssh/sshd_config  # uncomment PasswordAuthentication yes
sudo vim /etc/ssh/sshd_config.d/50-cloud-init.conf - update PasswordAuthentication no to yes
sudo systemctl restart ssh
```

2. Copy host's SSH key to remote

```bash
ssh-copy-id -p 2222 user@remote_server
```
