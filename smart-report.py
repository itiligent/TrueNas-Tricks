cat > "$HOME/smart-report.py" <<'EOF'
#!/usr/bin/env python3
"""
TrueNAS SMART full email report for HDD, SATA SSD and NVMe drives.

What it does:
- Discovers drives using smartctl --scan-open
- Reads SMART data using smartctl JSON output
- Builds a full report containing:
    - top summary
    - flagged findings
    - full per-drive output
- Prints the full report to the console
- Writes the full report locally
- Sends the full report in one email using the TrueNAS Python WebSocket API client

This script avoids the midclt command-line payload size problem.

Instructions:
    1. Create a new API key in the TrueNAS GUI.
    2. Run the companion script: sudo bash smart-report-api-key-setup.sh
    3. When prompted, paste the new API key.
    4. The setup script will save the key to /root/smart-report-api-key. The SMART report script used this to make API calls to TrueNAS.

Default recipient:
    youremail@gmail.com

Default API key path:
    /root/smart-report-api-key

Run as root.
"""

import argparse
import datetime
import html
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys


DEFAULT_TO = ["youremail@gmail.com"]
DEFAULT_API_KEY_PATH = "/root/smart-report-api-key"


def which_or_die(cmd):
    path = shutil.which(cmd)
    if not path:
        print(f"ERROR: Required command not found: {cmd}", file=sys.stderr)
        sys.exit(2)
    return path


SMARTCTL = which_or_die("smartctl")


def run_cmd(cmd):
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def as_int(value):
    if value is None or isinstance(value, bool):
        return None

    if isinstance(value, int):
        return value

    if isinstance(value, float):
        return int(value)

    match = re.search(r"-?\d+", str(value))
    return int(match.group(0)) if match else None


def any_nonzero(value):
    if value is None:
        return False

    nums = [int(x) for x in re.findall(r"-?\d+", str(value))]
    return any(n != 0 for n in nums)


def fmt_unknown(value, suffix=""):
    if value is None or value == "":
        return "unknown"
    return f"{value}{suffix}"


def fmt_bytes(num):
    num = as_int(num)
    if num is None:
        return "unknown"

    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    n = float(num)

    for unit in units:
        if n < 1000 or unit == units[-1]:
            if unit == "B":
                return f"{int(n):,} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1000


def fmt_count(num, label=""):
    """
    Format large command/event counts.

    Example:
      362547192 -> 362.55M commands (362,547,192)
    """
    num = as_int(num)
    if num is None:
        return "unknown"

    units = [
        (1_000_000_000_000, "T"),
        (1_000_000_000, "B"),
        (1_000_000, "M"),
        (1_000, "K"),
    ]

    for factor, suffix in units:
        if abs(num) >= factor:
            short = f"{num / factor:.2f}{suffix}"
            break
    else:
        short = str(num)

    if label:
        return f"{short} {label} ({num:,})"

    return f"{short} ({num:,})"


def fmt_duration_hours(hours):
    hours = as_int(hours)
    if hours is None:
        return "unknown"

    years = hours // 8760
    rem = hours % 8760
    days = rem // 24
    hrs = rem % 24

    parts = []
    if years:
        parts.append(f"{years}y")
    if days:
        parts.append(f"{days}d")
    if hrs or not parts:
        parts.append(f"{hrs}h")

    return f"{' '.join(parts)} ({hours:,} h)"


def fmt_duration_minutes(minutes):
    minutes = as_int(minutes)
    if minutes is None:
        return "unknown"

    days = minutes // 1440
    rem = minutes % 1440
    hours = rem // 60
    mins = rem % 60

    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    if mins or not parts:
        parts.append(f"{mins}m")

    return f"{' '.join(parts)} ({minutes:,} min)"


def fmt_nvme_data_units(units):
    """
    NVMe SMART data_units_read/data_units_written are 512,000-byte units.
    """
    units = as_int(units)
    if units is None:
        return "unknown"

    return fmt_bytes(units * 512000)


def scan_devices():
    result = run_cmd([SMARTCTL, "--scan-open"])
    devices = []

    for line in result.stdout.splitlines():
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        pre_comment = line.split("#", 1)[0].strip()
        if not pre_comment:
            continue

        tokens = shlex.split(pre_comment)
        if not tokens:
            continue

        dev = tokens[0]
        dtype = None

        if "-d" in tokens:
            idx = tokens.index("-d")
            if idx + 1 < len(tokens):
                dtype = tokens[idx + 1]

        devices.append(
            {
                "dev": dev,
                "dtype": dtype,
                "scan_line": line,
            }
        )

    return devices


def read_smart(dev, dtype=None):
    cmd = [SMARTCTL, "-j", "-a"]

    if dtype:
        cmd.extend(["-d", dtype])

    cmd.append(dev)

    result = run_cmd(cmd)

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {
            "read_error": True,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
            "returncode": result.returncode,
        }

    data["_smartctl_returncode"] = result.returncode
    data["_smartctl_stderr"] = result.stderr.strip()

    return data


def ata_attr(data, names):
    table = data.get("ata_smart_attributes", {}).get("table", [])

    for name in names:
        for attr in table:
            if attr.get("name") == name:
                raw = attr.get("raw", {})

                if "value" in raw:
                    return raw.get("value")

                if "string" in raw:
                    return raw.get("string")

    return None


def get_temperature(data):
    temp = data.get("temperature", {})

    if isinstance(temp, dict):
        val = as_int(temp.get("current"))
        if val is not None:
            return val

    nvme = data.get("nvme_smart_health_information_log", {})
    val = as_int(nvme.get("temperature"))
    if val is not None:
        return val

    return as_int(
        ata_attr(
            data,
            [
                "Temperature_Celsius",
                "Airflow_Temperature_Cel",
                "Drive_Temperature",
            ],
        )
    )


def get_power_on_hours(data):
    hours = data.get("power_on_time", {}).get("hours")
    if hours is not None:
        return hours

    nvme = data.get("nvme_smart_health_information_log", {})
    hours = nvme.get("power_on_hours")
    if hours is not None:
        return hours

    return ata_attr(
        data,
        [
            "Power_On_Hours",
            "Power_On_Hours_and_Msec",
        ],
    )


def get_power_cycles(data):
    cycles = data.get("power_cycle_count")
    if cycles is not None:
        return cycles

    nvme = data.get("nvme_smart_health_information_log", {})
    cycles = nvme.get("power_cycles")
    if cycles is not None:
        return cycles

    return ata_attr(data, ["Power_Cycle_Count"])


def latest_self_test(data):
    table = (
        data.get("ata_smart_self_test_log", {})
        .get("standard", {})
        .get("table", [])
    )

    if not table:
        return "unknown"

    latest = table[0]
    test_type = latest.get("type", {}).get("string", "test")
    status = latest.get("status", {}).get("string", "unknown status")
    hours = latest.get("lifetime_hours")

    if hours is not None:
        return f"{test_type}: {status} at {fmt_duration_hours(hours)}"

    return f"{test_type}: {status}"


def ata_error_count(data):
    return data.get("ata_smart_error_log", {}).get("summary", {}).get("count")


def smart_passed(data):
    passed = data.get("smart_status", {}).get("passed")

    if passed is True:
        return "PASSED"

    if passed is False:
        return "FAILED"

    return "UNKNOWN"


def device_identity(dev, dtype, data):
    device = data.get("device", {}) if isinstance(data, dict) else {}

    model = (
        data.get("model_name")
        or data.get("model_family")
        or data.get("scsi_model_name")
        or device.get("name")
        or "unknown"
    )

    serial = (
        data.get("serial_number")
        or data.get("wwn", {}).get("naa")
        or "unknown"
    )

    firmware = (
        data.get("firmware_version")
        or data.get("scsi_revision")
        or "unknown"
    )

    protocol = (
        device.get("protocol")
        or dtype
        or "unknown"
    )

    capacity = data.get("user_capacity", {}).get("bytes")

    return {
        "dev": dev,
        "dtype": dtype,
        "model": model,
        "serial": serial,
        "firmware": firmware,
        "protocol": protocol,
        "capacity": capacity,
    }


def summarise_device(devinfo):
    dev = devinfo["dev"]
    dtype = devinfo.get("dtype")
    data = read_smart(dev, dtype)

    if data.get("read_error"):
        return {
            "dev": dev,
            "summary": {
                "status": "ERROR",
                "model": "unknown",
                "serial": "unknown",
                "protocol": dtype or "unknown",
                "capacity": "unknown",
                "temp": "unknown",
                "power_on": "unknown",
                "finding": "CRITICAL: could not read SMART data",
            },
            "details": [
                f"Device: {dev}",
                f"Type: {dtype or 'unknown'}",
                "SMART read: FAILED",
                f"smartctl return code: {data.get('returncode')}",
                f"stderr: {data.get('stderr') or 'none'}",
                f"stdout: {data.get('stdout') or 'none'}",
            ],
            "severity": "CRITICAL",
            "findings": [("CRITICAL", "Could not read SMART data")],
        }

    ident = device_identity(dev, dtype, data)
    protocol = str(ident["protocol"]).upper()

    is_nvme = "NVME" in protocol or "nvme_smart_health_information_log" in data
    is_ata = "ata_smart_attributes" in data

    findings = []

    def add(sev, text):
        findings.append((sev, text))

    status = smart_passed(data)

    if status == "FAILED":
        add("CRITICAL", "SMART overall health reports FAILED")
    elif status == "UNKNOWN":
        add("WARNING", "SMART overall health status is unknown")

    temp_c = get_temperature(data)

    if temp_c is not None:
        if is_nvme:
            if temp_c >= 75:
                add("CRITICAL", f"NVMe temperature is high: {temp_c} °C")
            elif temp_c >= 65:
                add("WARNING", f"NVMe temperature is elevated: {temp_c} °C")
        else:
            if temp_c >= 55:
                add("CRITICAL", f"Drive temperature is high: {temp_c} °C")
            elif temp_c >= 45:
                add("WARNING", f"Drive temperature is elevated: {temp_c} °C")

    power_hours = get_power_on_hours(data)
    power_cycles = get_power_cycles(data)

    detail_lines = [
        f"Device: {dev}",
        f"Type/protocol: {ident['protocol']}",
        f"Model: {ident['model']}",
        f"Serial: {ident['serial']}",
        f"Firmware: {ident['firmware']}",
        f"Capacity: {fmt_bytes(ident['capacity'])}",
        f"SMART overall: {status}",
        f"Temperature: {fmt_unknown(temp_c, ' °C')}",
        f"Power-on time: {fmt_duration_hours(power_hours)}",
        f"Power cycles: {fmt_count(power_cycles, 'cycles')}",
    ]

    smartctl_rc = data.get("_smartctl_returncode")
    smartctl_stderr = data.get("_smartctl_stderr")

    if smartctl_rc not in (0, None):
        add("NOTE", f"smartctl returned code {smartctl_rc}; review detailed output")

    if is_ata:
        reallocated = ata_attr(data, ["Reallocated_Sector_Ct"])
        pending = ata_attr(data, ["Current_Pending_Sector"])
        offline_unc = ata_attr(data, ["Offline_Uncorrectable"])
        reported_unc = ata_attr(data, ["Reported_Uncorrect"])
        crc = ata_attr(data, ["UDMA_CRC_Error_Count"])
        cmd_timeout = ata_attr(data, ["Command_Timeout"])
        spin_retry = ata_attr(data, ["Spin_Retry_Count"])
        load_cycle = ata_attr(data, ["Load_Cycle_Count"])
        start_stop = ata_attr(data, ["Start_Stop_Count"])
        error_count = ata_error_count(data)

        if any_nonzero(reallocated):
            add("WARNING", f"Reallocated sectors non-zero: {reallocated}")

        if any_nonzero(pending):
            add("CRITICAL", f"Current pending sectors non-zero: {pending}")

        if any_nonzero(offline_unc):
            add("CRITICAL", f"Offline uncorrectable sectors non-zero: {offline_unc}")

        if any_nonzero(reported_unc):
            add("WARNING", f"Reported uncorrectable errors non-zero: {reported_unc}")

        if any_nonzero(crc):
            add("NOTE", f"UDMA CRC errors non-zero: {crc}; often cable/backplane related")

        if any_nonzero(cmd_timeout):
            add("WARNING", f"Command timeouts non-zero: {cmd_timeout}")

        if any_nonzero(spin_retry):
            add("WARNING", f"Spin retry count non-zero: {spin_retry}")

        if any_nonzero(error_count):
            add("WARNING", f"ATA SMART error log count non-zero: {error_count}")

        detail_lines.extend(
            [
                "",
                "ATA/SATA key attributes:",
                f"  Reallocated sectors: {fmt_unknown(reallocated)}",
                f"  Current pending sectors: {fmt_unknown(pending)}",
                f"  Offline uncorrectable: {fmt_unknown(offline_unc)}",
                f"  Reported uncorrectable: {fmt_unknown(reported_unc)}",
                f"  UDMA CRC errors: {fmt_unknown(crc)}",
                f"  Command timeouts: {fmt_unknown(cmd_timeout)}",
                f"  Spin retry count: {fmt_unknown(spin_retry)}",
                f"  Load cycle count: {fmt_count(load_cycle, 'cycles')}",
                f"  Start/stop count: {fmt_count(start_stop, 'cycles')}",
                f"  ATA SMART error log count: {fmt_count(error_count, 'errors')}",
                f"  Latest self-test: {latest_self_test(data)}",
            ]
        )

    if is_nvme:
        nvme = data.get("nvme_smart_health_information_log", {})

        critical_warning = nvme.get("critical_warning")
        spare = nvme.get("available_spare")
        spare_threshold = nvme.get("available_spare_threshold")
        percentage_used = nvme.get("percentage_used")
        media_errors = nvme.get("media_errors")
        err_entries = nvme.get("num_err_log_entries")
        unsafe_shutdowns = nvme.get("unsafe_shutdowns")
        controller_busy_time = nvme.get("controller_busy_time")
        data_read = nvme.get("data_units_read")
        data_written = nvme.get("data_units_written")
        host_reads = nvme.get("host_reads")
        host_writes = nvme.get("host_writes")

        if any_nonzero(critical_warning):
            add("CRITICAL", f"NVMe critical warning non-zero: {critical_warning}")

        spare_i = as_int(spare)
        spare_threshold_i = as_int(spare_threshold)

        if spare_i is not None:
            if spare_threshold_i is not None and spare_i <= spare_threshold_i:
                add(
                    "CRITICAL",
                    f"Available spare at/below threshold: {spare}% <= {spare_threshold}%",
                )
            elif spare_i < 20:
                add("WARNING", f"Available spare is low: {spare}%")

        used_i = as_int(percentage_used)

        if used_i is not None:
            if used_i >= 90:
                add("CRITICAL", f"NVMe percentage used is high: {used_i}%")
            elif used_i >= 80:
                add("WARNING", f"NVMe percentage used is elevated: {used_i}%")

        if any_nonzero(media_errors):
            add("CRITICAL", f"NVMe media/data integrity errors non-zero: {media_errors}")

        if any_nonzero(err_entries):
            add("NOTE", f"NVMe error log entries non-zero: {err_entries}")

        if any_nonzero(unsafe_shutdowns):
            add("NOTE", f"Unsafe shutdown count non-zero: {unsafe_shutdowns}")

        detail_lines.extend(
            [
                "",
                "NVMe key attributes:",
                f"  Critical warning: {fmt_unknown(critical_warning)}",
                f"  Available spare: {fmt_unknown(spare, '%')}",
                f"  Available spare threshold: {fmt_unknown(spare_threshold, '%')}",
                f"  Percentage used: {fmt_unknown(percentage_used, '%')}",
                f"  Media/data integrity errors: {fmt_count(media_errors, 'errors')}",
                f"  Error log entries: {fmt_count(err_entries, 'entries')}",
                f"  Unsafe shutdowns: {fmt_count(unsafe_shutdowns, 'shutdowns')}",
                f"  Controller busy time: {fmt_duration_minutes(controller_busy_time)}",
                f"  Data read: {fmt_nvme_data_units(data_read)}",
                f"  Data written: {fmt_nvme_data_units(data_written)}",
                f"  Host read commands: {fmt_count(host_reads, 'commands')}",
                f"  Host write commands: {fmt_count(host_writes, 'commands')}",
            ]
        )

    messages = data.get("smartctl", {}).get("messages", [])

    if smartctl_stderr:
        detail_lines.append("")
        detail_lines.append("smartctl stderr:")
        detail_lines.append(f"  {smartctl_stderr}")

    if messages:
        detail_lines.append("")
        detail_lines.append("smartctl messages:")

        for msg in messages:
            text = msg.get("string") or str(msg)
            severity = msg.get("severity")
            detail_lines.append(f"  {severity or 'info'}: {text}")

    if any(sev == "CRITICAL" for sev, _ in findings):
        severity = "CRITICAL"
    elif any(sev == "WARNING" for sev, _ in findings):
        severity = "WARNING"
    elif any(sev == "NOTE" for sev, _ in findings):
        severity = "NOTE"
    else:
        severity = "OK"

    if not findings:
        finding_summary = "OK"
        detail_lines.extend(
            [
                "",
                "Findings: OK - no obvious concerns in selected SMART fields.",
            ]
        )
    else:
        finding_summary = "; ".join([f"{sev}: {text}" for sev, text in findings])

        detail_lines.append("")
        detail_lines.append("Findings:")

        for sev, text in findings:
            detail_lines.append(f"  {sev}: {text}")

    return {
        "dev": dev,
        "summary": {
            "status": status,
            "model": ident["model"],
            "serial": ident["serial"],
            "protocol": ident["protocol"],
            "capacity": fmt_bytes(ident["capacity"]),
            "temp": fmt_unknown(temp_c, " °C"),
            "power_on": fmt_duration_hours(power_hours),
            "finding": finding_summary,
        },
        "details": detail_lines,
        "severity": severity,
        "findings": findings,
    }


def pad(value, width):
    s = str(value)

    if len(s) > width:
        return s[: width - 1] + "…"

    return s.ljust(width)


def status_counts(results):
    return {
        "CRITICAL": sum(1 for r in results if r["severity"] == "CRITICAL"),
        "WARNING": sum(1 for r in results if r["severity"] == "WARNING"),
        "NOTE": sum(1 for r in results if r["severity"] == "NOTE"),
        "OK": sum(1 for r in results if r["severity"] == "OK"),
    }


def overall_status(results):
    counts = status_counts(results)

    if counts["CRITICAL"]:
        return "CRITICAL"

    if counts["WARNING"]:
        return "WARNING"

    if counts["NOTE"]:
        return "NOTE"

    return "OK"


def build_summary_table(results):
    lines = []

    lines.append("Summary:")
    lines.append(
        f"{pad('Device', 12)} "
        f"{pad('SMART', 8)} "
        f"{pad('Temp', 9)} "
        f"{pad('Power-on', 18)} "
        f"{pad('Model', 32)} "
        "Finding"
    )
    lines.append("-" * 120)

    for r in results:
        s = r["summary"]

        lines.append(
            f"{pad(r['dev'], 12)} "
            f"{pad(s['status'], 8)} "
            f"{pad(s['temp'], 9)} "
            f"{pad(s['power_on'], 18)} "
            f"{pad(s['model'], 32)} "
            f"{s['finding']}"
        )

    return lines


def build_flagged_findings(results):
    lines = []
    flagged = [r for r in results if r["severity"] != "OK"]

    if not flagged:
        lines.append("No warnings or critical findings in selected SMART fields.")
    else:
        for r in flagged:
            s = r["summary"]
            lines.append("")
            lines.append(f"{r['dev']} - {s['model']} - {s['serial']}")
            for sev, text in r["findings"]:
                lines.append(f"  {sev}: {text}")

    return lines


def build_full_report(results):
    host = socket.gethostname()
    now = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    counts = status_counts(results)
    overall = overall_status(results)

    lines = []

    lines.append(f"TrueNAS SMART Report - {overall}")
    lines.append(f"Host: {host}")
    lines.append(f"Generated: {now}")
    lines.append(f"Drives checked: {len(results)}")
    lines.append(
        f"Status counts: OK={counts['OK']}, NOTE={counts['NOTE']}, "
        f"WARNING={counts['WARNING']}, CRITICAL={counts['CRITICAL']}"
    )
    lines.append("")

    if not results:
        lines.append("No SMART-capable devices were discovered by smartctl --scan-open.")
        return overall, "\n".join(lines)

    lines.append("=" * 120)
    lines.append("Top summary")
    lines.append("=" * 120)
    lines.extend(build_summary_table(results))

    lines.append("")
    lines.append("=" * 120)
    lines.append("Flagged findings")
    lines.append("=" * 120)
    lines.extend(build_flagged_findings(results))

    lines.append("")
    lines.append("=" * 120)
    lines.append("Full per-drive output")
    lines.append("=" * 120)

    for r in results:
        lines.append("")
        lines.append("-" * 120)
        lines.extend(r["details"])

    lines.append("")
    lines.append("Notes:")
    lines.append("- Pending sectors, offline uncorrectable sectors, failed SMART status, NVMe media errors, or NVMe critical warnings should be treated as urgent.")
    lines.append("- UDMA CRC errors often point to cabling, backplane, power, or connection issues rather than the disk surface itself.")
    lines.append("- SMART is useful early-warning data, but it is not a substitute for tested backups and ZFS scrub monitoring.")

    return overall, "\n".join(lines)


def write_full_report(path, report):
    with open(path, "w", encoding="utf-8") as f:
        f.write(report)
        f.write("\n")


def html_pre(body):
    return (
        "<html><body>"
        "<pre style='font-family: monospace; white-space: pre-wrap;'>"
        + html.escape(body)
        + "</pre>"
        "</body></html>"
    )


def send_full_report_via_api(to_addrs, subject, report, api_key_path):
    """
    Send the full SMART report in a single email using the TrueNAS
    WebSocket API client.

    This avoids the midclt command-line payload size problem.
    """

    try:
        from truenas_api_client import Client
    except Exception as e:
        raise RuntimeError(
            "Could not import truenas_api_client. "
            "This script expects to run on TrueNAS SCALE with the API client available."
        ) from e

    with open(api_key_path, "r", encoding="utf-8") as f:
        api_key = f.read().strip()

    if not api_key:
        raise RuntimeError(f"API key file is empty: {api_key_path}")

    html_body = html_pre(report)

    with Client() as c:
        login_ok = c.call("auth.login_with_api_key", api_key)

        if login_ok is not True:
            raise RuntimeError("TrueNAS API login_with_api_key did not return True")

        job_id = c.call(
            "mail.send",
            {
                "subject": subject,
                "to": to_addrs,
                "html": html_body,
            },
        )

        try:
            job_result = c.call("core.job_wait", job_id)
        except Exception:
            return {
                "job_id": job_id,
                "job_wait": "not available or failed, but mail.send job was submitted",
            }

        return {
            "job_id": job_id,
            "job_result": job_result,
        }


def main():
    parser = argparse.ArgumentParser(
        description="Generate and email a full TrueNAS SMART report."
    )

    parser.add_argument(
        "--no-email",
        action="store_true",
        help="Print report only; do not email it.",
    )

    parser.add_argument(
        "--to",
        action="append",
        help="Recipient email address. Can be used multiple times.",
    )

    parser.add_argument(
        "--api-key-path",
        default=DEFAULT_API_KEY_PATH,
        help=f"TrueNAS API key path. Default: {DEFAULT_API_KEY_PATH}",
    )

    args = parser.parse_args()

    if os.geteuid() != 0:
        print("ERROR: Run this as root so smartctl can read all disks and the API key.", file=sys.stderr)
        sys.exit(1)

    to_addrs = args.to if args.to else DEFAULT_TO

    devices = scan_devices()
    results = [summarise_device(d) for d in devices]

    overall, full_report = build_full_report(results)

    print(full_report)

    if args.no_email:
        return

    host = socket.gethostname()
    subject = f"{overall}: SMART report for {host} ({len(results)} drives)"

    email_result = send_full_report_via_api(
        to_addrs=to_addrs,
        subject=subject,
        report=full_report,
        api_key_path=args.api_key_path,
    )

    print("")

    job_id = email_result.get("job_id")
    job_result = email_result.get("job_result")
    job_wait = email_result.get("job_wait")

    if job_wait:
        print("Email status: submitted, but completion could not be confirmed.")
        print(f"Details: {job_wait}")
    else:
        print("Email status: sent successfully.")
        print(f"Recipient(s): {', '.join(to_addrs)}")
        print(f"Subject: {subject}")

    print()

if __name__ == "__main__":
    main()
    .    .
EOF


chmod 700 "$HOME/smart-report.py"

echo "alias smart-report='sudo python3 ~/smart-report.py'" >> ~/.zshrc
source ~/.zshrc
