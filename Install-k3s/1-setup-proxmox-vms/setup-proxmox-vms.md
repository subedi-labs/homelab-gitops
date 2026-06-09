# Setup Proxmox VMs

## Pre-Reqs
* ubuntu live server ISO saved on each host's local -> ISO image
* Save host machines ssh key to github profile

## Create and configure VMs
1. Create 1 VMS on each proxmox host
    * Display: SPICE
    * Mem: 8000
    * 1 socket, 3 cores
    * BIOS: Default (SeaBIOS)
    * Machine: q35
    * SCSI Controller: VirtIO SCSI single
    * Hard Disk: Cache: writeback, Discard check, IO thread check, Backup check, skip replication check, read-only uncheck, Asyonc IO: Default.
    * Network: Firewall uncheck
2. Install Ubuntu

### Enable Copy and Paste from host to VM

1. Install virt-viewer on host

```bash
sudo apt update
sudo apt install virt-viewer
```

2. Handle the `.vv` file

When you click Console → SPICE in Proxmox, it downloads a `.vv` file to your Windows Downloads folder. You need to access it from WSL:

```bash
# Your Windows downloads should be accessible in WSL here:
cd /mnt/c/Users/OITCOSUBEDPC/Downloads

# List to find the .vv file
ls *.vv
```

3. Connect

```bash
remote-viewer /mnt/c/Users/OITCOSUBEDPC/Downloads/pve-spice.vv
```

### Enable Qemu Guest on VM

```bash
sudo apt install qemu-guest-agent
sudo systemctl enble --now qemu-guest-agent
sudo systemctl status qemu-guest-agent
```

## Troubleshooting

### Set Hostname

```bash
sudo hostnamectl set-hostname <newhostname>

# Refresh shell
exec bash
```

### Unable to SSH into remote server

#### Option 1:

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

#### Option 2:

1. Put your host's ssh key into GitHub
2. Import SSH key from GitHub

```bash
sudo apt install ssh-import-id
ssh-import-id-gh pukar10
```






























This error indicates that your local machine's public SSH key is not present in the remote server's list of authorized keys. To resolve this, copy your public key to the remote server using the following command:

```bash
ssh-copy-id -o PreferredAuthentications=password -o PubkeyAuthentication=no -i ~/.ssh/id_ed25519.pub -p 22 user@remote_server
```

OR

login to remote with user/password.
`sudo vim /etc/ssh/sshd_config` - uncomment `PasswordAuthentication yes`
`sudo vim /etc/ssh/sshd_config.d/50-cloud-init.conf` - update `PasswordAuthentication no` to `yes`