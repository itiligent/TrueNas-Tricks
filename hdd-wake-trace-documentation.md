## How Wake Events Are Captured

`hdd-wake-trace.sh` uses two layers of capture:

1. **Wake detection** — identifies when one or more disks wake from standby.
2. **Evidence collection** — captures surrounding system activity to help identify the likely cause.

---

## Wake Detection Methods

### 1. Pool Disk Discovery

The script discovers the physical disks in the selected ZFS pool using:

```bash
zpool status -P "$POOL"
````

It then resolves ZFS member paths back to parent block devices such as `/dev/sdb`, `/dev/sdc`, etc. using `readlink` and `lsblk`.

When `ROTATIONAL_ONLY=1`, the script only monitors rotational disks reported by `lsblk`, avoiding SSDs, NVMe devices, and special/metadata vdevs.

---

### 2. HDD Power-State Polling

The script checks each monitored disk with:

```bash
hdparm -C /dev/sdX
```

It records whether each disk is in one of the following states:

```text
standby
sleeping
active/idle
unknown
```

---

### 3. Standby-to-Active Transition Detection

Each disk’s previous state is stored in memory. A wake event is detected when a disk changes from:

```text
standby / sleeping
```

to:

```text
active/idle
```

The initial baseline poll is not treated as a wake event.

---

### 4. Wake Event Classification

Detected wakes are classified as:

```text
pool-wide wake
partial disk wake
partial wake - pool now active
```

This helps distinguish between a single disk waking, multiple disks waking, or the whole monitored pool becoming active.

---

### 5. Detection Window Tracking

The script records the previous poll time and current poll time so each event includes the wake detection uncertainty window.

Example:

```text
Previous poll: 2026-05-15 17:51:17
Current poll:  2026-05-15 17:51:20
Uncertainty:   3 seconds
```

This is important because the physical spin-up occurred sometime inside that polling window.

---

### 6. Duplicate Event Suppression

`EVENT_COOLDOWN` suppresses duplicate full event captures when disks wake in a sequence or state reporting flaps.

Additional disks waking during the cooldown period are appended to the previous event log rather than creating noisy duplicate captures.

---

## Evidence Capture Methods

When a wake event is detected, the script captures a detailed event log.

### 1. Wake Event Header

Each event records:

```text
wake type
detected time
wake epoch
pool name
script path
event log path
selected profile
effective capture settings
```

---

### 2. Triggered Disk List

The script records exactly which disks transitioned from standby or sleeping to active/idle.

Example:

```text
/dev/sdc     8:32     WDC_WD40EFPX-68C6CN0_WD-WX32D954ATCL
```

---

### 3. Human-Readable Disk Labels

The script maps `/dev/sdX` devices to stable `/dev/disk/by-id` names where possible.

This makes logs easier to interpret by showing disk model and serial details instead of only Linux device names.

---

### 4. Major/Minor Block Device Mapping

The script captures major/minor device IDs with `lsblk`.

Example:

```text
/dev/sdc     8:32     WDC_WD40EFPX-68C6CN0_WD-WX32D954ATCL
```

This allows Linux block trace entries such as:

```text
8,32
```

to be mapped back to the real disk.

---

### 5. Current Disk Power States

After the wake is detected, the script captures the current power state of every monitored disk.

This shows whether the event remained isolated to one disk or expanded into a broader pool wake.

---

### 6. Immediate Process I/O Delta

The script samples `/proc/[pid]/io` before and after a short window.

This identifies processes that performed read/write I/O immediately after the wake.

Example:

```text
pid=2963 read_delta=704512 write_delta=19135748 syslog-ng
pid=705  read_delta=0      write_delta=10805048 systemd-journal
```

---

### 7. PID Context

For the highest I/O processes, the script captures:

```text
process name
command line
current working directory
executable path
cgroup
open file descriptors under /mnt/$POOL
```

This helps distinguish real causes from follow-on logging or audit activity.

---

### 8. SMB/Samba Context

The script checks for SMB activity using:

```bash
smbstatus
```

It captures:

```text
active SMB sessions
connected clients
share connections
locked files
SMB/Samba open files under the pool
SMB audit/session journal entries around the wake
```

This is useful for identifying Windows clients, mapped drives, Explorer browsing, network discovery, indexing, or other SMB activity waking the pool.

---

### 9. SMART and Disk Polling Context

The script looks for SMART and disk polling activity, including:

```text
smartctl
smartd
disk.query
disk.temperature
middlewared disk polling
```

It captures both currently visible processes and relevant journal activity around the wake window.

---

### 10. ZFS Context

The script captures ZFS-related activity such as:

```text
z_wr_iss
z_wr_int
z_rd_iss
z_rd_int
z_metaslab
txg_sync
flush-zfs
arc_prune
arc_flush
arc_evict
```

It also captures:

```bash
zpool events
zpool history
```

This helps identify when ZFS is executing reads, writes, metadata work, transaction group sync, or pool-level activity.

---

### 11. Optional ZFS Dirty / TXG Context

With `ZFS_DIRTY_CONTEXT=1`, the script captures ZFS transaction group and dirty-data context from:

```bash
/proc/spl/kstat/zfs
```

This is useful for deeper ZFS investigations, especially when the evidence suggests metadata or transaction group activity.

The context can be scoped to the monitored pool only or expanded to all pools.

---

### 12. Optional Block I/O Trace

With `BLOCK_TRACE=1`, the script uses Linux tracefs block events:

```text
block_rq_issue
block_bio_queue
```

The event log can include:

```text
first block I/O lines in the trace buffer
block I/O matching initially triggered disks
block I/O matching monitored pool disks
last block I/O lines in the trace buffer
```

This helps identify whether block I/O was issued by processes such as:

```text
smbd
smartctl
middlewared
z_wr_iss
z_wr_int
txg_sync
syslog-ng
```

---

### 13. Correlated Journal Window

The script searches journal entries within a configurable time window before and after the wake event.

Each matching line is shown with a delta from the detected wake time.

Example:

```text
delta=-2s   SMB authentication from 172.17.9.77
delta=+11s  smartctl -x /dev/sdd -jc
```

This helps determine whether an activity likely caused the wake or happened afterward as a side effect.

---

### 14. Broad Recent Journal Activity

In addition to the tight correlation window, the script captures a broader recent journal section for relevant services and subsystems, including:

```text
middlewared
SMART
SMB
NFS
ZFS
zpool
scrub
snapshot
replication
Docker
containerd
k3s
cron
systemd
sysstat
rsync
rclone
cloud sync
```

---

### 15. Recent Sudo/Admin Activity

The script captures recent `sudo` and admin command activity.

This helps identify manual commands or shell activity that may have touched the pool.

---

### 16. Recently Started Processes

The script lists processes started near the wake event.

This can reveal short-lived tasks that may not appear in later process snapshots.

---

### 17. Relevant System Timers

The script captures systemd timers related to storage, reporting, scheduled jobs, and application activity.

This helps identify periodic wake patterns caused by timers or background tasks.

---

### 18. Open Files Under Mounted Pool Datasets

The script checks mounted datasets for open files or active users using `lsof` or `fuser`.

This helps identify services or clients holding active references to the pool.

---

### 19. Processes by Total Read/Write Bytes

The script records the highest process read/write counters since boot.

This provides broader context for processes with significant system I/O.

---

### 20. Recurrence Tracking

Each wake event is written to a TSV index:

```text
wake-events.tsv
```

The script calculates the time since the previous wake and highlights recurring patterns, such as hourly or 90-minute wake cycles.

---

### 21. Ranked Wake Analysis Summary

The script scores captured evidence and produces a ranked summary of likely cause categories, including:

```text
SMB
SMART
ZFS
middleware
backup/sync
scheduled tasks
logging side effects
block trace evidence
recurrence patterns
```

---

### 22. Human-Readable Interpretation

Each event log includes a plain-English interpretation of the evidence.

This helps separate likely root causes from follow-on activity such as:

```text
syslog-ng
systemd-journal
auditd
ZFS writeback after the wake
SMART polling after the disk is already active
```

---

## Summary

`hdd-wake-trace.sh` does not rely on a single signal. It combines disk power-state polling, process I/O sampling, journal correlation, SMB inspection, SMART detection, ZFS context, optional block tracing, open-file checks, timer review, and recurrence analysis.

This layered approach makes it much easier to determine whether a wake event was caused by a client connection, middleware task, SMART polling, ZFS metadata activity, scheduled job, application, or another background process.

```
```

