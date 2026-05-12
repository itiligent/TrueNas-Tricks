## 💤 TrueNAS Spindown Patch Helper

️`spindown-fix.sh` provides a safe, reversible way to apply the TrueNAS HDD spindown patch **without directly modifying the read-only system filesystem**.

Instead of changing TrueNAS system files in place, the script:

- Copies selected TrueNAS middleware files into a writable overlay directory
- Applies `spindown.patch` to the overlay copies
- Bind-mounts the patched files over the original system paths
- Leaves the original TrueNAS system files untouched

This method lets TrueNAS run the patched middleware while keeping the underlying OS clean. It also makes the patch easier to test, roll back, reapply after updates, or remove cleanly.

⚠️ **Important note:**  
The original `spindown.patch` shared on the TrueNAS Community Forum contains a smartctl race/command-order issue. It formats the device path before the `-n standby` option, meaning smartctl may touch the disk before the standby check is honoured.

`spindown.patch.fixed` corrects this by always passing `-n standby` before the device path, allowing standby checks to complete without inadvertently waking disks.

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

📘 Full documentation: [hdd-wake-trace documentation](https://github.com/itiligent/TrueNas-Tricks/blob/main/hdd-wake-trace-documentation.md)

---

## 📧 TrueNAS Emailed SMART Reports

TrueNAS middleware can be limited when sending large email reports. `smart-report.py` works around this by creating comprehensive disk health reports from `smartctl` output and sending them via Python using the TrueNAS API.

The included companion script, `smart-report-api-key-setup.sh`, helps install a GUI-generated TrueNAS API key into:
