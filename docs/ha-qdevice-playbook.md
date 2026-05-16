# High availability & QDevice playbook — Proxmox VE 9 cluster `ulster`

| | |
|---|---|
| **Maintainer** | Rich Hacks |
| **Last reviewed** | 16 May 2026 |
| **Companion document** | `proxmox-infrastructure-INTERNAL.md` (§5 Networking, Appendix E) |
| **Current state** | 2-node cluster, no QDevice, no HA rules configured |
| **Target state** | 2-node cluster + 1 QDevice on a third box, optional HA rules for selected guests |

---

## Table of contents

1. [Why this matters](#1-why-this-matters)
2. [The 2-node quorum problem](#2-the-2-node-quorum-problem)
3. [Pick a host for the QDevice](#3-pick-a-host-for-the-qdevice)
4. [Phase 1 — Add a QDevice](#4-phase-1--add-a-qdevice)
5. [Phase 2 — Verify and stress-test](#5-phase-2--verify-and-stress-test)
6. [Phase 3 — (Optional) Configure HA rules](#6-phase-3--optional-configure-ha-rules)
7. [Day-to-day operations](#7-day-to-day-operations)
8. [Failure & recovery scenarios](#8-failure--recovery-scenarios)
9. [Rollback — removing the QDevice](#9-rollback--removing-the-qdevice)
10. [Appendix — corosync.conf walkthrough](#10-appendix--corosyncconf-walkthrough)

---

## 1. Why this matters

A Proxmox cluster needs **quorum** — a majority of votes — to make any change. With two nodes the majority is 2, meaning **if either node goes down, the surviving node can't write to cluster config, can't start guests it doesn't already own, and can't migrate anything**.

Today this is patched up by hand with `pvecm expected 1` — fine for planned maintenance, painful at 02:00. A QDevice is a tiny third "vote" that lives outside the cluster on a cheap box. It costs almost nothing in resources but turns "one node down = manual intervention" into "one node down = the other carries on".

### Decision criteria

| Question | Answer |
|---|---|
| **Do you want HA failover?** (guests auto-restart on the other node if one dies) | Optional. QDevice is the prerequisite either way. |
| **Do you want unattended survival of single-node failure?** | Yes — that's the point of this playbook. |
| **Do you want zero-downtime planned maintenance on one node at a time?** | Yes — QDevice lets you `pvecm` operations succeed on the survivor. |

---

## 2. The 2-node quorum problem

Look at the current `pvecm status`:

```
Expected votes:   2
Highest expected: 2
Total votes:      2
Quorum:           2
```

`Quorum: 2` means you need 2 votes to be quorate. Both nodes contribute 1 vote each. If either drops, you have 1 vote and the cluster goes read-only.

### What goes wrong without quorum

- Can't start or migrate guests.
- Can't edit `/etc/pve/*` (it becomes read-only via pmxcfs).
- `pct`/`qm` config changes fail.
- Already-running guests keep running, but they're frozen at their current config.

### What a QDevice changes

After adding a QDevice:
```
Expected votes:   3
Highest expected: 3
Total votes:      3
Quorum:           2
```

The QDevice provides one extra vote. Now quorum is still 2, but **any 2 of {pve, pve2, qdevice}** are enough — losing one node still leaves 2 votes (the survivor + the QDevice), and the cluster stays quorate.

---

## 3. Pick a host for the QDevice

### Requirements

- Always-on, on the same network as the cluster (low latency to both nodes).
- Linux with `apt` (Debian/Ubuntu) or compatible — the package is `corosync-qnetd`.
- ~50 MB RAM and negligible CPU. A Raspberry Pi Zero W2 will do.
- Reachable from both pve and pve2 over **TCP 5403** (default qnetd port).
- **NOT** itself a PVE node — that defeats the point.

### Good candidates on the existing network

Looking at the LAN inventory:

| Candidate | IP | Why it could work | Why it might not |
|---|---|---|---|
| **A new Raspberry Pi 4/5** (recommended) | _to be assigned, e.g. 10.10.10.50_ | Cheap, always-on, dedicated role, easy to replace | Have to buy one |
| **CT 108 slievemore** (Backup CT on pve2) | 10.10.10.22 | Already running, low load | Lives on pve2 — if pve2 dies, you lose **both** pve2's vote *and* the QDevice. **Defeats the purpose.** Do not do this. |
| **CT 109 knockbrinnea** (Docker host on pve2) | 10.10.10.23 | Already running | Same problem as CT 108 |
| **Fedora desktop** | _local LAN_ | Always on during the day | Not always on, gets rebooted often → cluster will flap between quorate and not. |

**Recommendation:** Raspberry Pi 4 or 5 with 2 GB RAM, on a wired ethernet port to the same switch, with a static IP outside the DHCP pool. £35 of hardware that solves the entire problem.

### Network requirements

- The QDevice must reach pve and pve2 on **TCP 5403** (qnetd).
- pve and pve2 must reach the QDevice on **TCP 5403**.
- If a firewall sits between them, open the port both ways.
- DNS is helpful but not required — IP addresses work fine.

---

## 4. Phase 1 — Add a QDevice

### Step 1 — Install Raspberry Pi OS (or Debian) on the new box

Use Raspberry Pi OS Lite (64-bit) or Debian 12+. After first boot:

```bash
# On the Pi
sudo apt update && sudo apt full-upgrade -y
sudo hostnamectl set-hostname rcc-qdevice
sudo apt install -y corosync-qnetd
# Confirm the service is listening
sudo systemctl status corosync-qnetd
sudo ss -tlnp | grep 5403
```

Set a static IP — either via DHCP reservation on the router, or in `/etc/network/interfaces.d/eth0`:

```ini
auto eth0
iface eth0 inet static
    address 10.10.10.50/24
    gateway 10.10.10.1
    dns-nameservers 10.10.10.10 10.10.10.11
```

### Step 2 — Allow SSH from cluster nodes

The PVE side talks to qnetd over a secured channel after initial setup, but the *setup itself* uses SSH. Make sure root@pve and root@pve2 can SSH into the Pi (preferably with key auth, not passwords):

```bash
# On each PVE node
ssh-copy-id root@10.10.10.50
ssh root@10.10.10.50 'echo ok'
```

**Heads-up:** Raspberry Pi OS disables root SSH by default. You'll need to either:
- Enable root SSH (`PermitRootLogin yes` in `/etc/ssh/sshd_config`, restart sshd), OR
- Set up the qdevice as a regular user with passwordless sudo, and use that account for the setup. The PVE docs assume root.

### Step 3 — Install the qdevice package on each PVE node

```bash
# On pve
apt install -y corosync-qdevice

# On pve2
apt install -y corosync-qdevice
```

### Step 4 — Set up the QDevice from one PVE node

Run **only from one node** — it propagates to the cluster:

```bash
# On pve (it doesn't matter which node you start from)
pvecm qdevice setup 10.10.10.50 -f
```

This command:
1. SSHes to 10.10.10.50, generates a key pair on the QNetd side.
2. Copies the certificates back to /etc/corosync/qdevice/ on both PVE nodes.
3. Rewrites `/etc/pve/corosync.conf` to add the qdevice block and bump `expected_votes` from 2 to 3.
4. Reloads corosync on both nodes.

### Step 5 — Verify

```bash
pvecm status
```

You should now see:

```
Quorum information
------------------
Date:             ...
Quorum provider:  corosync_votequorum
Nodes:            2
Node ID:          0x00000001
Ring ID:          1.xxx
Quorate:          Yes

Votequorum information
----------------------
Expected votes:   3              ← was 2
Highest expected: 3              ← was 2
Total votes:      3              ← was 2
Quorum:           2
Flags:            Quorate Qdevice

Membership information
----------------------
    Nodeid      Votes    Qdevice Name
0x00000001          1    A,V,NMW 10.10.10.30 (local)
0x00000002          1    A,V,NMW 10.10.10.20
0x00000000          1            Qdevice
```

Key things to read:
- **Expected votes: 3** — the QDevice is counted.
- **Quorum: 2** — still need 2, but now there are 3 to draw from.
- **Qdevice column: `A,V,NMW`** — qdevice is **A**live, has a **V**ote, and is in **NM**aster **W**ait state. All good.

---

## 5. Phase 2 — Verify and stress-test

Don't trust the setup until you've simulated a node failure. **Schedule a quiet hour for this** — it shouldn't break anything, but if it does, you want time to fix it.

### Test 1 — Reboot pve2 and confirm pve stays quorate

```bash
# On a workstation, not on pve2 itself
ssh root@pve 'pvecm status' > before.txt

# Reboot pve2
ssh root@pve2 'reboot'

# Wait ~30 seconds, then check on pve
ssh root@pve 'pvecm status'
```

**Expected behaviour with the QDevice in place:**
- `Total votes: 2` (pve + qdevice; pve2 is gone).
- `Quorate: Yes`.
- You can still edit configs, start guests, etc. on pve.

**Expected behaviour without the QDevice (i.e. today):**
- `Total votes: 1`.
- `Quorate: No`.
- pve refuses to do anything cluster-wide.

### Test 2 — Stop corosync on the QDevice itself

The cluster should remain quorate (2 nodes, no qdevice = 2 votes, quorum 2, still OK):

```bash
ssh root@10.10.10.50 'systemctl stop corosync-qnetd'
ssh root@pve 'pvecm status'   # should still show Quorate: Yes
ssh root@10.10.10.50 'systemctl start corosync-qnetd'
```

### Test 3 — Worst case: both node + qdevice on one side

Cut the **management network** between pve2 and the rest, but leave pve2 itself running. This simulates a switch port failure. pve2 should leave the cluster cleanly and refuse to start new guests; pve + qdevice should keep going.

(In practice this is hard to simulate without unplugging the cable. Worth doing if you can take a maintenance window — leave it 10 minutes, reconnect, watch pve2 rejoin.)

---

## 6. Phase 3 — (Optional) Configure HA rules

HA is what makes guests **automatically restart on the other node** when their original node dies. It's separate from quorum, but it requires quorum to function.

⚠ **Read this section twice before enabling HA.** It changes the failure mode: instead of "guest is offline until you intervene", it becomes "guest restarts somewhere — but only if the storage is available there". For our 2-node, no-shared-storage cluster, **only guests whose disks live on a shared/replicated dataset can fail over cleanly**.

### What can be HA in our current setup

Look at where each guest's rootfs lives:

| Guest | Rootfs storage | Eligible for HA? | Why |
|---|---|---|---|
| CT 101 oriel | `local-lvm` on pve | ❌ | Local disk on pve; pve2 has no copy |
| CT 102 slemish | `local-lvm` on pve | ❌ | Same |
| CT 103 iveagh | `vmstorage` (tank) on pve | ❌ | `tank` doesn't exist on pve2 |
| CT 106 commedagh | `vmstorage` (tank) on pve | ❌ | Same |
| CT 104 donard | `vmstorage2` (tank2) on pve2 | ❌ | `tank2` doesn't exist on pve |
| CT 108 / 109 / 112 | various pve2-only storage | ❌ | Same |
| VM 111 mweelrea | `local-lvm` on pve | ❌ | Local |
| VM 113 breifne | `vmstorage2` on pve2 | ❌ | pve2-only |

**Result: no guest is currently HA-eligible without first setting up storage replication.**

### Two paths to HA-eligible storage

**Path A — ZFS replication (the lightweight option).** Proxmox can periodically `zfs send` a guest's dataset from one node to the other. If the source node dies, HA kicks in and starts the guest on the destination using the most recent replicated snapshot — losing only whatever changed since the last replication run (typically 15 minutes).

**Path B — Shared storage (the heavy option).** A separate box hosting iSCSI/NFS, or Ceph between the nodes. Overkill for two MicroServers.

Path A is the right fit. Once a guest is replicated, you can add it to an HA group.

### Setting up ZFS replication for one guest (example: CT 106 commedagh, Pi-hole)

Pi-hole is a great first candidate — small, stateful enough that an automatic restart matters, and currently has no failover.

**Pre-req:** pve2 needs a dataset name on `tank2` that mirrors what `tank` looks like to PVE. Already true via the `vmstorage2` storage ID.

```bash
# On pve (or via the GUI: Datacenter → Replication → Add)
pvesr create-local-job 106-0 pve2 \
  --schedule '*/15' \
  --comment "Replicate Pi-hole every 15 minutes"
```

Check it runs:
```bash
pvesr list                # see the job
pvesr run --id 106-0      # force a run now
pvesr status              # see last sync time and any errors
```

After the first run, on pve2:
```bash
zfs list -r tank2 | grep '106'
# should show subvol-106-disk-0 mirrored from pve
```

### Add the guest to HA

```bash
# Once replication is running:
ha-manager add ct:106 --state started --max_restart 1 --max_relocate 1
ha-manager status
```

Or via the GUI: Datacenter → HA → Add → resource `ct:106`.

### Now test the failover

```bash
# Simulate pve dying
ssh root@pve 'shutdown -h now'

# Watch on pve2
watch -n 2 'ha-manager status'
# After ~2 minutes (HA's stale-detection window), pve2 will:
#  1. Fence pve (mark it dead)
#  2. Recover ct:106 from the replicated dataset
#  3. Start it on pve2
```

Once pve boots back up:
- It rejoins the cluster.
- HA notices pve has come back.
- Depending on `relocate` policy, ct:106 either stays on pve2 or migrates back.

---

## 7. Day-to-day operations

### Checking quorum health

```bash
# Standard health check
pvecm status

# Just the Qdevice line
pvecm status | grep -i qdevice
```

### Checking HA state (only relevant after Phase 3)

```bash
ha-manager status
# Service state legend:
#   started   — running on the listed node
#   stopped   — explicitly stopped (not a failure)
#   error     — failed to start, manual intervention required
#   fence     — being fenced (only briefly during failover)
```

### Planned maintenance on a single node (with QDevice)

This is the workflow QDevice enables:

```bash
# On the node you want to take down (e.g. pve2 for hardware maintenance)
ha-manager set ct:106 --state ignored   # for any HA-managed guests
# Or move them off:
pct migrate 106 pve --restart           # for non-HA guests

# Now reboot/shutdown
reboot

# Cluster stays quorate via pve + qdevice
# When pve2 comes back, HA picks the guests back up (if `relocate` allows)
```

### Adding a new node later (becoming a 3-node cluster)

If a third PVE box arrives, you have a choice:
- Keep the QDevice (3 nodes + 1 qdevice = 4 votes, quorum 3) — survives any single failure, no change needed.
- Remove the QDevice (3 nodes = 3 votes, quorum 2) — works fine, but loses the "any one box gone" property if you ever drop back to 2 nodes.

Most homelabs keep the QDevice indefinitely. The cost is £0/month and 50 MB of RAM.

---

## 8. Failure & recovery scenarios

### Scenario A — QDevice is unreachable but both nodes are up

What you see in `pvecm status`:

```
Membership information
----------------------
    Nodeid      Votes    Qdevice Name
0x00000001          1    NR      10.10.10.30
0x00000002          1    NR      10.10.10.20
0x00000000          0            Qdevice (votes: 0)
```

`NR` = **N**ot **R**egistered. Vote count drops to 2 (the two nodes), quorum is still 2, **cluster is still quorate**. No action needed beyond fixing the QDevice.

To debug:
```bash
# On a PVE node
systemctl status corosync-qdevice
journalctl -u corosync-qdevice -n 50
# On the QDevice
systemctl status corosync-qnetd
journalctl -u corosync-qnetd -n 50
# Test connectivity
nc -zv 10.10.10.50 5403   # from a PVE node
```

### Scenario B — One PVE node dies, QDevice survives

This is the scenario QDevice exists to handle.

`pvecm status` on the survivor:
```
Total votes:      2          ← survivor (1) + qdevice (1)
Quorum:           2
Quorate:          Yes
```

Everything keeps working. Guests on the failed node are unavailable until either (a) it comes back, or (b) you restore them from vzdump on the surviving node (see the backup runbook §8 Scenario B). With HA configured (Phase 3) and replication in place, the eligible guests auto-recover.

### Scenario C — Both PVE nodes survive but QDevice + one node die

Total votes drops to 1 (the one surviving PVE node). Quorum is 2. **Cluster goes read-only.** This is the rare edge case where you still need `pvecm expected 1`.

In practice this means a power blip that kills the QDevice's UPS-less Raspberry Pi at the same moment one node fails. Unlikely but possible. Mitigation: put the QDevice on the same UPS as the PVE nodes.

### Scenario D — Split brain (cluster network partitioned between pve and pve2)

Without a QDevice this is a nightmare — each node thinks the other is dead. With a QDevice it resolves cleanly: whichever side can talk to the QDevice keeps its vote, the other side becomes non-quorate. The QDevice acts as an external arbiter.

---

## 9. Rollback — removing the QDevice

If for any reason the QDevice causes issues (rare, but possible if its network keeps flapping):

```bash
# On any PVE node
pvecm qdevice remove

# Verify
pvecm status
# Expected votes should return to 2

# On the QDevice itself (optional cleanup)
systemctl stop corosync-qnetd
apt remove --purge corosync-qnetd
```

The QDevice is a clean add-on, not a re-architecture — removing it leaves the cluster exactly as it was before.

---

## 10. Appendix — corosync.conf walkthrough

After Phase 1, `/etc/pve/corosync.conf` will gain a `quorum.device` section. Don't edit this file by hand; let `pvecm qdevice setup`/`remove` manage it. But it's useful to know what to expect.

Before:

```
quorum {
  provider: corosync_votequorum
}
```

After:

```
quorum {
  device {
    model: net
    net {
      algorithm: ffsplit
      host: 10.10.10.50
      tls: on
    }
    votes: 1
  }
  provider: corosync_votequorum
}
```

Key parameters explained:
- **`model: net`** — uses the network-based QNetd protocol (the only model PVE supports out of the box).
- **`algorithm: ffsplit`** — "fifty-fifty split": designed for 2-node clusters where the QDevice picks a winner in even splits. This is the default and the right choice here.
- **`host: 10.10.10.50`** — the QDevice IP.
- **`tls: on`** — communication is TLS-encrypted (certificates were exchanged during setup).
- **`votes: 1`** — the QDevice contributes one vote.

The `totem` section's `config_version: N` increments — corosync needs this bumped on every config change, which `pvecm` handles automatically.

---

## Quick reference card

```
# Setup
ssh root@<qdevice> 'apt install -y corosync-qnetd'
apt install -y corosync-qdevice  # on each PVE node
pvecm qdevice setup <qdevice-ip> -f

# Verify
pvecm status | grep -E 'Expected|Quorum|Qdevice'

# Maintenance with QDevice in place
# (no special commands — just reboot a node and the cluster stays up)

# Remove
pvecm qdevice remove

# Replication (precursor to HA)
pvesr create-local-job <vmid>-0 <target-node> --schedule '*/15'
pvesr run --id <vmid>-0
pvesr list

# HA management
ha-manager add ct:<id> --state started
ha-manager status
ha-manager remove ct:<id>

# Manual quorum override (emergency only)
pvecm expected 1
```

---

## References

- [Proxmox VE — Cluster Manager (pvecm)](https://pve.proxmox.com/wiki/Cluster_Manager)
- [Proxmox VE — External vote support (QDevice)](https://pve.proxmox.com/wiki/Cluster_Manager#_corosync_external_vote_support)
- [Proxmox VE — High availability](https://pve.proxmox.com/wiki/High_Availability)
- [Proxmox VE — Storage replication (pvesr)](https://pve.proxmox.com/wiki/Storage_Replication)
- [corosync-qnetd(8) man page](https://manpages.debian.org/bookworm/corosync-qnetd/corosync-qnetd.8.en.html)
- [Proxmox VE 9 release notes — HA rules](https://pve.proxmox.com/wiki/Roadmap#Proxmox_VE_9.0) (HA groups → HA rules migration)

*Update this playbook after the QDevice is installed — convert "Phase 1 procedure" sections into "as-built" history, and keep the day-to-day reference at the front.*
