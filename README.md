## 💤 TrueNAS Spindown Patch Helper

️`spindown-fix.sh` provides a safe, reversible way to apply the TrueNAS HDD spindown patch **without directly modifying the read-only TrueNAS filesystem**.

- Automatically copies selected TrueNAS middleware files into a new writable overlay
- Applies `spindown.patch.fixed` to the overlay file copies
- Bind-mounts the patched overaly files over the original files (leaving original TrueNAS system files untouched)
- Upgrade friendly - This script can be run multiple times to roll back and reapply after updates.

⚠️ **Important note:**  
The original [spindown.patch](https://forums.truenas.com/uploads/short-url/lz8ZYr42jE7608gFx5TVQG2reex.txt) from the TrueNAS Community Forum formats the device path before the `-n standby` option, creating a potential race condition where smartctl may touch the disk before a standby check is honoured.

`spindown.patch.fixed` resolves this by passing `-n standby` before the device path, allowing standby checks to complete without inadvertently waking disks.

---

## 🔎 TrueNAS HDD Wake Trace

`hdd-wake-trace.sh` is an advanced diagnostic tool for TrueNAS SCALE that helps identify **what is waking HDDs from standby** in a ZFS pool.

The script monitors rotational disks in a selected TrueNAS pool. When one or more disks transition from `standby` or `sleeping` to `active/idle`, it creates detailed wake-event logs and correlates system activity across a configurable time window before and after the wake event.

It can help trace recurring wake causes across areas such as:

- SMB access
- SMART polling
- ZFS activity
- TrueNAS middleware jobs
- Process I/O
- System timers
- Block-level disk activity

By analysing repeated wake events over time, the script builds a much higher-confidence picture of the likely root cause than reviewing isolated logs manually.

Built-in profiles allow different levels of capture detail, from lower-noise monitoring through to deep debug tracing for difficult wake-cause investigations.

📘 Full documentation: [hdd-wake-trace documentation](https://github.com/itiligent/TrueNAS-Tricks/blob/main/hdd-wake-trace-documentation.md)

---

## 📧 TrueNAS Emailed SMART Reports

TrueNAS middleware can be limited when sending large email reports. `smart-report.py` works around this by creating comprehensive disk health reports from `smartctl` output and sending them via Python using the TrueNAS API.

The included companion script, `smart-report-api-key-setup.sh`, helps install a GUI-generated TrueNAS API key that the python script will call.


## 💾 TrueNAS External USB Mount Helper

`external-usb.sh` is an interactive Bash utility for safely mounting and unmounting external USB storage devices on TrueNAS.

The script automatically detects connected USB partitions, presents them in a device selection menu, and mounts the chosen device to a fixed mountpoint (`/mnt/external`) with shared read/write access enabled.  The script also sets compatible permissions and ownership settings for data on the external USB mountpoint to allow for easy compatibiltiy between TrueNAS and any other Linux host. 


