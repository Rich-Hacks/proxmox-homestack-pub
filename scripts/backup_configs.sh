#!/bin/bash
# /root/backup_configs.sh — weekly cron
BACKUP_DIR="/root/backup_configs/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp /etc/pve/storage.cfg                "$BACKUP_DIR/"
cp -r /etc/pve/lxc                     "$BACKUP_DIR/"
cp -r /etc/pve/qemu-server             "$BACKUP_DIR/"
cp /etc/network/interfaces             "$BACKUP_DIR/"
cp /etc/hosts                          "$BACKUP_DIR/"

zpool status > "$BACKUP_DIR/zpool_status.txt"
zfs list -t all > "$BACKUP_DIR/zfs_list.txt"
pvesm status > "$BACKUP_DIR/pvesm_status.txt"
pvecm status > "$BACKUP_DIR/pvecm_status.txt"

# On CT 101 (NAS) — also capture Samba state
ssh root@10.10.10.32 'cat /etc/samba/smb.conf' > "$BACKUP_DIR/samba_smb.conf"
ssh root@10.10.10.32 'testparm -s 2>/dev/null' > "$BACKUP_DIR/samba_testparm.txt"

echo "Backup written to $BACKUP_DIR"

