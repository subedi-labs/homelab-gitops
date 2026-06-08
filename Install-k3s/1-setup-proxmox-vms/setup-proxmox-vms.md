# Setup Proxmox VMs

## Pre-Reqs
* ubuntu live server ISO saved on each host's local -> ISO image
* Save host machines ssh key to github profile

## Create and configure VMs
1. Create 1 VMS on each proxmox host
    * Mem: 8000
    * 1 socket, 3 cores
    * BIOS: Default (SeaBIOS)
    * Machine: q35
    * SCSI Controller: VirtIO SCSI single
    * Hard Disk: Cache: writeback, Discard check, IO thread check, Backup check, skip replication check, read-only uncheck, Asyonc IO: Default.
    * Network: Firewall uncheck
2. Install Ubuntu

