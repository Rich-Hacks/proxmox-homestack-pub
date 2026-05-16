# Backup & restore runbook — Proxmox VE 9 cluster `ulster`

| | |
|---|---|
| **Maintainer** | Richard Carragher (RC COMMS) |
| **Last reviewed** | 16 May 2026 |
| **Companion document** | `proxmox-infrastructure-INTERNAL.md` (§3, §8) |
| **Audience** | The future you, at 02:00, with one node down and coffee not yet brewed |

---

## Table of contents

1. [What is backed up, and where](#1-what-is-backed-up-and-where)
2. [Daily / weekly / monthly cadence](#2-daily--weekly--monthly-cadence)
3. [Take an ad-hoc backup right now](#3-take-an-ad-hoc-backup-right-now)
4. [Restore: full guest from vzdump](#4-restore-full-guest-from-vzdump)
5. [Restore: single file from inside a backup](#5-restore-single-file-from-inside-a-backup)
6. [Restore: roll back to a snapshot](#6-restore-roll-back-to-a-snapshot)
7. [Restore: ZFS dataset from snapshot](#7-restore-zfs-dataset-from-snapshot)
8. [Disaster scenarios](#8-disaster-scenarios)
9. [Test-restore drills](#9-test-restore-drills)
10. [Retention & pruning](#10-retention--pruning)
11. [Off-site backup (gap to close)](#11-off-site-backup-gap-to-close)

---

## 1. What is backed up, and where

### Three layers of protection

| Layer | What it captures | Frequency | Lives on |
|---|---|---|---|
| **vzdump** | Full guest backup (config + disks, compressed) | Weekly | `zfs_backup` on pve2 → `/tank2/backups/dump` |
| **Proxmox snapshot** | Point-in-time of a single guest, kept as a parent revision | On demand before changes | Same storage as the guest (no extra disk) |
| **ZFS snapshot** | Block-level point-in-time of a dataset | On demand / via `zfs-auto-snapshot` if installed | Same pool as the dataset (no extra disk) |

### vzdump storage layout

```
/tank2/backups/                                  ← directory storage "zfs_backup"
└── dump/
    ├── vzdump-lxc-101-2026_05_15-02_00_03.tar.zst   ← CT 101 oriel (NAS)
    ├── vzdump-lxc-102-2026_05_15-02_15_11.tar.zst   ← CT 102 slemish (Plex)
    ├── vzdump-qemu-111-2026_05_15-02_30_45.vma.zst  ← VM 111 mweelrea (Nextcloud)
    └── ...
```

- Filenames are `vzdump-<type>-<id>-<YYYY_MM_DD>-<HH_MM_SS>.<ext>`.
- Containers produce `.tar.zst`. VMs produce `.vma.zst` (Proxmox's QEMU-native format).
- Each guest also generates a small `.log` and `.notes` next to its dump.

### What is *not* backed up (and what to do about it)

| Item | Why it's a gap | Mitigation |
|---|---|---|
| `/etc/pve/*` on each node | Cluster config — replicated between nodes via pmxcfs, but if both nodes are destroyed it's gone | The weekly config-backup script (Appendix B of the main doc) writes a copy to `/root/backup_configs/` |
| Samba `smb.conf` and the SMB users database | Lives inside CT 101 — covered by CT 101's vzdump | OK provided CT 101 vzdump is running |
| Pi-hole adlists and custom DNS | Lives inside CT 104 / CT 106 — covered by their vzdumps | OK |
| `tank/Media`, `tank/Downloads`, `tank/storage` content | Bind-mounted into CT 101; **vzdump skips these by default** (mp lines have no `backup=1`) | Treat the ZFS pool itself as the source of truth; consider periodic `zfs send` to an external pool |
| Off-site copy of any of the above | Single-site, single-pool | **Open item** — see §11 |

### Confirming what's covered for a guest

```bash
pct config 101 | grep -E '^(mp|rootfs)'
# rootfs lines are ALWAYS backed up.
# mpN lines are backed up only if they end with `backup=1`.
# In our setup, the mp0–mp3 entries on CT 101 do NOT have backup=1,
# which is correct — the data lives on tank and shouldn't bloat vzdumps.
```

---

## 2. Daily / weekly / monthly cadence

### Current schedule (visible in `/etc/pve/jobs.cfg` and the GUI)

| Job | When | What it does | Where it runs |
|---|---|---|---|
| vzdump weekly | Sundays 02:00 | All guests on both nodes → `zfs_backup` | pve and pve2 (each backs up its own guests) |

To confirm:
```bash
cat /etc/pve/jobs.cfg
# Look for vzdump: blocks
pvesh get /cluster/backup --output-format=yaml
```

### Recommended cadence going forward

- **vzdump:** weekly is fine for the homelab; bump to nightly for VM 111 (Nextcloud) and CT 101 (NAS) since their state changes daily.
- **Proxmox snapshot:** before *any* destructive change — package upgrade, config edit, dataset move.
- **ZFS snapshot:** automated daily/hourly via `zfs-auto-snapshot` for `tank/*` datasets is worth setting up. Cheap, fast, and gives you 30 days of file-level rollback without touching vzdump.

---

## 3. Take an ad-hoc backup right now

### Single guest

```bash
# Container — runs on the node hosting the CT
ssh root@pve  'vzdump 101 --storage zfs_backup --compress zstd --mode snapshot --notes-template "manual: pre-change"'

# VM — same pattern
ssh root@pve  'vzdump 111 --storage zfs_backup --compress zstd --mode snapshot --notes-template "manual: pre-change"'
```

**`--mode snapshot`** is the right choice for almost everything:
- For LXC: ZFS-snapshot the rootfs while the container keeps running (a few seconds of disk I/O quiesce).
- For VMs: QEMU live-snapshot — guest is never paused (qemu-guest-agent must be installed for filesystem consistency; VM 111 has it; VM 113 does not).

Alternatives if `snapshot` mode fails:
- `--mode suspend` — short stop, copy, resume (a few minutes of downtime).
- `--mode stop` — full shutdown, copy, start (longest downtime but always safe).

### All guests on a node, on demand

```bash
ssh root@pve 'vzdump --all --storage zfs_backup --compress zstd --mode snapshot'
```

### Watch progress

```bash
# Latest task log
tail -f /var/log/vzdump/*.log

# Or in the GUI: Datacenter → Backup → Job log
```

---

## 4. Restore: full guest from vzdump

This is the everyday "restore a service from backup" case.

### Find the backup

```bash
# List everything available on zfs_backup, newest first
pvesm list zfs_backup | sort -k4 -r | head -20

# Or filter by VMID
pvesm list zfs_backup | grep -E 'vzdump-(lxc|qemu)-101-'
```

The volume ID will look like `zfs_backup:backup/vzdump-lxc-101-2026_05_15-02_00_03.tar.zst`. Note it down.

### Container restore

```bash
# To a new CTID (safest — leaves the original in place)
pct restore 901 zfs_backup:backup/vzdump-lxc-101-2026_05_15-02_00_03.tar.zst \
  --storage local-lvm \
  --hostname oriel-restore \
  --unprivileged 1

# In place (overwrites the existing CT 101 — original is destroyed!)
pct restore 101 zfs_backup:backup/vzdump-lxc-101-2026_05_15-02_00_03.tar.zst \
  --storage local-lvm \
  --force 1
```

After restore, check mount points before starting:

```bash
pct config 101 | grep -E '^(mp|rootfs)'
# If the source node had /tank/* mounts and you're restoring to pve2,
# THE MOUNT POINTS WILL FAIL because /tank only exists on pve.
# Either restore to pve, or edit the config to remove/repoint mp lines.
```

### VM restore

```bash
# To a new VMID
qmrestore zfs_backup:backup/vzdump-qemu-111-2026_05_15-02_30_45.vma.zst 911 \
  --storage local-lvm \
  --unique 1   # generates a new MAC so it can coexist with the original

# In place
qmrestore zfs_backup:backup/vzdump-qemu-111-2026_05_15-02_30_45.vma.zst 111 \
  --storage local-lvm \
  --force 1
```

`--unique 1` rewrites the MAC and the UUID — essential if you're spinning up the restore alongside the original for a test, otherwise both VMs collide on the network.

### Restore using the GUI (the easy path)

1. Datacenter → Storage → `zfs_backup` → **Backups** tab.
2. Highlight the dump → **Restore**.
3. Choose target node, storage, VMID (default = original ID).
4. Tick **Start after restore** only if you're sure mount points/networking are intact on the target node.

---

## 5. Restore: single file from inside a backup

The fastest case — somebody fat-fingered `rm` on a config file. You don't need to restore the whole guest.

### Container backups (`.tar.zst`)

```bash
cd /tmp
# Extract just the path you need
tar --use-compress-program="zstd -d" \
    -xvf /tank2/backups/dump/vzdump-lxc-101-2026_05_15-02_00_03.tar.zst \
    ./etc/samba/smb.conf

# Look inside without extracting
tar --use-compress-program="zstd -d" \
    -tvf /tank2/backups/dump/vzdump-lxc-101-2026_05_15-02_00_03.tar.zst | grep smb.conf
```

### VM backups (`.vma.zst`)

VM backups are in Proxmox's proprietary `vma` format — you can't `tar -x` them. Two options:

**Option A — Mount via the GUI (the easy way):**
1. Datacenter → Storage → `zfs_backup` → Backups → highlight dump → **File Restore**.
2. Browse the virtual disk tree in the GUI, tick the files you want, **Download**.

**Option B — CLI extraction:**
```bash
# Convert the vma to raw disk images first
cd /tmp
zstd -d /tank2/backups/dump/vzdump-qemu-111-2026_05_15-02_30_45.vma.zst -o vm111.vma
vma extract vm111.vma /tmp/vm111-restored/

# Now mount disk-0.raw with kpartx or losetup
losetup -P -f --show /tmp/vm111-restored/disk-drive-scsi0.raw
# losetup prints e.g. /dev/loop3; partitions appear as /dev/loop3p1 etc.
mkdir -p /mnt/restore
mount /dev/loop3p1 /mnt/restore
# Copy out what you need
cp /mnt/restore/path/to/file ~/recovered/
# Clean up
umount /mnt/restore
losetup -d /dev/loop3
rm -rf /tmp/vm111-restored /tmp/vm111.vma
```

---

## 6. Restore: roll back to a snapshot

Snapshots beat vzdumps for "I broke something in the last five minutes" — they're instant and don't depend on the backup target.

### List snapshots

```bash
pct listsnapshot 101   # container snapshots
qm listsnapshot 111    # VM snapshots
```

You'll typically see the auto-created `Update_20260510_160817`-style snapshots from the BassT23 updater plus any manual ones.

### Roll back

```bash
# Container — guest must be stopped first
pct stop 101
pct rollback 101 Update_20260510_160639
pct start 101

# VM — same
qm stop 111
qm rollback 111 Update_20260510_160817
qm start 111
```

### Delete an old snapshot

```bash
pct delsnapshot 101 <name>
qm delsnapshot 111 <name>
```

⚠ Rollback **destroys** any state newer than the snapshot. There is no "rollforward". Take a fresh snapshot before rolling back if you might want to undo the undo.

---

## 7. Restore: ZFS dataset from snapshot

This is for content that isn't inside a guest — e.g. files on `tank/storage` that someone deleted via SMB.

### List ZFS snapshots

```bash
zfs list -t snapshot tank/storage
# Or all datasets
zfs list -t snapshot -r tank
```

### Roll the whole dataset back

```bash
zfs rollback tank/storage@2026-05-15-0200
# ⚠ This destroys snapshots taken AFTER the target. Add -r to force.
```

### Recover individual files without a full rollback

Snapshots are accessible read-only at `.zfs/snapshot/<name>`:

```bash
ls /tank/storage/.zfs/snapshot/
# Pick the snapshot you want
cp -a /tank/storage/.zfs/snapshot/2026-05-15-0200/path/to/file /tank/storage/path/to/file
```

The `.zfs` directory is hidden by default (won't appear in `ls`) but is always there — `cd` straight into it.

---

## 8. Disaster scenarios

### Scenario A — One guest is corrupted

1. Check whether the issue is recent: `journalctl -u <service> -b` inside the guest.
2. Snapshot rollback if a snapshot from before the incident exists (§6).
3. Otherwise vzdump restore in-place (§4).

**Time to recover:** ~2 minutes for snapshot rollback, ~10–30 minutes for vzdump restore depending on size.

### Scenario B — One node is dead but quorum survives

We're a 2-node cluster — losing one node breaks quorum (see the HA / QDevice playbook). Procedure:

1. On the surviving node: `pvecm expected 1` — restores quorum so the survivor can act.
2. For each guest from the dead node, if a recent vzdump exists on `zfs_backup`:
   ```bash
   pct restore <ctid> zfs_backup:backup/<dump> --storage <local-storage>
   ```
3. Edit each restored guest's config to remove mount points/storage that only existed on the dead node.
4. Start the guests.

**Time to recover:** ~15–45 minutes for the critical services (DNS, NAS), depending on guest size.

### Scenario C — Both nodes destroyed, only `zfs_backup` storage survives

This is the worst credible scenario short of total site loss. Requires:

- A fresh Proxmox install on at least one new box.
- Read access to `/tank2/backups/dump/` from the surviving disks.

**Rebuild outline:**

1. Install Proxmox on the new box; configure the same hostname (`pve` or `pve2`) so existing configs match.
2. Import the surviving ZFS pool: `zpool import tank2`.
3. Add `/tank2/backups` as a `dir` storage in `/etc/pve/storage.cfg`:
   ```
   dir: zfs_backup
       path /tank2/backups
       content backup
       prune-backups keep-all=1
       shared 0
   ```
4. Refresh storage: `pvesm set zfs_backup --content backup`.
5. Restore the critical guests in priority order — DNS first (CT 106 or CT 104), then NAS (CT 101), then everything else.
6. The cluster needs rebuilding (`pvecm create ulster` on the first node, `pvecm add` on subsequent nodes).

**Time to recover:** half a day to a day, depending on hardware availability.

### Scenario D — `tank` data loss (NOT a backup scenario)

`tank/Media` (8 TB) is not in vzdump. If `tank` is destroyed:
- Plex library, Media files, Downloads, Storage share — **all gone unless replicated elsewhere**.
- This is the strongest argument for setting up §11.

---

## 9. Test-restore drills

A backup you haven't restored is a backup that doesn't exist. Run a drill **once a quarter** at a minimum.

### Quarterly drill checklist

- [ ] Restore the latest CT 101 vzdump to a new CTID (e.g. 901) on the same node, with `--unprivileged 1` and no mount points. Start it. SSH in. Confirm Samba config files are present and intact. Stop and destroy the test CT.
- [ ] Restore the latest VM 111 vzdump to a new VMID (911) with `--unique 1`. Boot it. Confirm the Nextcloud login page renders on the alternate IP. Stop and destroy.
- [ ] Pull one specific file out of the latest VM 111 backup via the GUI File-Restore feature. Confirm it matches the live copy.
- [ ] `zfs list -t snapshot` — confirm snapshots are being created on the cadence you expect.
- [ ] Record date and outcome in this document (Appendix below).

### Drill log

| Date | Drill | Result | Notes |
|---|---|---|---|
| _Not yet run_ | _—_ | _—_ | _Set up calendar reminder for Q3 2026_ |

---

## 10. Retention & pruning

Current setting: `prune-backups keep-all=1` — **everything is kept forever**. This was sensible during the migration period when free space was plentiful, but at ~2 GB per weekly run across nine guests, it accumulates ~1 TB/year. Time to switch.

### Recommended retention

Edit `/etc/pve/storage.cfg`:

```ini
dir: zfs_backup
    path /tank2/backups
    content backup
    prune-backups keep-last=4,keep-weekly=4,keep-monthly=6,keep-yearly=2
    shared 0
```

In plain English:
- Last 4 backups (rolling, regardless of cadence)
- 4 weekly backups (one per week, 4 weeks)
- 6 monthly backups (one per month, 6 months)
- 2 yearly backups (one per year, 2 years)

Pruning happens after each successful backup. To dry-run on the current state:

```bash
pvesm prune-backups zfs_backup --dry-run --type vm --vmid 111 \
  --keep-last 4 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2
```

To apply right now (without waiting for the next backup):

```bash
pvesm prune-backups zfs_backup --type vm --vmid 111 \
  --keep-last 4 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2
```

---

## 11. Off-site backup (gap to close)

Everything currently lives inside the BT35 location. A flood, fire, theft or ransomware event that reaches `tank2` would destroy the only backup copy. Three credible options, ranked by effort:

### Option A — `rclone` to encrypted cloud storage (low effort, low cost)

A `slievemore` (CT 108) cron job that copies the latest vzdumps to an encrypted Backblaze B2 / iDrive e2 / Wasabi bucket nightly.

```bash
# Install once
apt install rclone
rclone config       # set up an "encrypted" remote on top of a B2 remote

# Cron entry on CT 108
0 4 * * * rclone copy /tank2/backups/dump encrypted-b2:rc-comms-pve-backups \
            --include "*.zst" --max-age 8d --transfers 4 \
            --log-file /var/log/rclone-offsite.log
```

Budget estimate: ~£5/month for the volume in scope (a few hundred GB of compressed vzdumps).

### Option B — Proxmox Backup Server on a low-cost VPS (medium effort)

Install PBS on a Hetzner / OVH dedicated server (or even an old box at a friend's house with WireGuard back to home). PBS uses incremental, deduplicated chunks — typically 10–20× smaller than vzdump for a given retention.

This is the "proper" solution, and it works very well with Proxmox VE — guest restores from PBS are direct from the GUI.

### Option C — Manual quarterly snapshot to USB (low cost, manual)

`zfs send tank2 | zstd > /mnt/usb-3tb/tank2-2026Q2.zfs.zst` to a spinning USB drive, kept off-site. Cheapest, but discipline-dependent.

**Recommendation:** Option A as a starter — it's an afternoon of work and meaningfully closes the gap. Move to Option B if/when you want guest-level restore from off-site rather than just file recovery.

---

## Quick reference card

```
# Take a backup now
ssh root@pve  'vzdump <id> --storage zfs_backup --compress zstd --mode snapshot'

# List backups for a guest
pvesm list zfs_backup | grep -- '-<id>-'

# Restore in place
pct restore   <ctid> zfs_backup:backup/<file> --storage local-lvm --force 1
qmrestore     zfs_backup:backup/<file> <vmid> --storage local-lvm --force 1

# Restore to new ID
pct restore   <new-id> zfs_backup:backup/<file> --storage local-lvm --hostname test
qmrestore     zfs_backup:backup/<file> <new-id> --storage local-lvm --unique 1

# Snapshot rollback
pct stop <id> && pct rollback <id> <snap> && pct start <id>
qm  stop <id> && qm  rollback <id> <snap> && qm  start <id>

# ZFS file restore
cp -a /tank/storage/.zfs/snapshot/<snap>/path/to/file /tank/storage/path/to/file

# Lower-quorum recovery (one node down)
pvecm expected 1
```

---

## References

- [Proxmox VE Backup and Restore wiki](https://pve.proxmox.com/wiki/Backup_and_Restore)
- [`vzdump(1)` man page](https://pve.proxmox.com/pve-docs/vzdump.1.html)
- [`pct(1)` man page](https://pve.proxmox.com/pve-docs/pct.1.html) — `restore`, `rollback`, `snapshot` subcommands
- [`qm(1)` man page](https://pve.proxmox.com/pve-docs/qm.1.html) — same set
- [Proxmox Backup Server](https://pbs.proxmox.com/docs/) — for option B above
- [OpenZFS — snapshots & rollback](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-rollback.8.html)
- [rclone — encrypted remotes](https://rclone.org/crypt/)

*Update this runbook every time a procedure here diverges from reality. Out-of-date runbooks are worse than no runbook.*
