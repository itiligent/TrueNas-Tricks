#!/usr/bin/env bash

set -euo pipefail
clear 2>/dev/null || true

# -----------------------------------------------------------------------------
# Profile and variable block
# -----------------------------------------------------------------------------
# Select a profile with one of:
#   bash hdd-wake-trace.sh --profile balanced HDD_TANK
#   bash hdd-wake-trace.sh --profile low-noise HDD_TANK
#   bash hdd-wake-trace.sh --profile debug HDD_TANK
#   bash hdd-wake-trace.sh --profile super-debug HDD_TANK
#
# Short aliases also work:
#   bash hdd-wake-trace.sh --balanced HDD_TANK
#   bash hdd-wake-trace.sh --low-noise HDD_TANK
#   bash hdd-wake-trace.sh --debug HDD_TANK
#   bash hdd-wake-trace.sh --super-debug HDD_TANK
#
# You can still override any individual value by exporting it, or by prefixing
# the command and using sudo -E. Environment overrides win over profile defaults.
# Example:
#   CORRELATION_BEFORE=120 PROCESS_IO_SAMPLE_SECONDS=3 \
#   sudo -E ./hdd-wake-trace.sh --profile balanced HDD_TANK
#
# Keep LOGDIR on SSD/NVMe storage. Do not write logs to the HDD pool being

# Default pool name used when no pool argument is supplied.
DEFAULT_POOL="${DEFAULT_POOL:-HDD_TANK}"

# Directory for the main polling log. Optionally separate the per-event capture logs.
DEFAULT_LOGDIR="/mnt/ROOT_NVME/hdd-wake-trace-logs"
DEFAULT_EVENTDIR="${DEFAULT_LOGDIR}"

# When set to 1, only rotational disks reported by lsblk are monitored.
# This avoids SSD/NVMe devices, including special/metadata vdevs, skewing HDD
# wake detection. Set to 0 to include all pool block devices or if your HBA or USB bridge reports disks incorrectly.
DEFAULT_ROTATIONAL_ONLY=1

# Safety guard: 0 = refuse to log inside the monitored pool unless explicitly allowed.
# Writing logs to the HDD pool being watched can itself cause disk wake events.
DEFAULT_ALLOW_LOGDIR_ON_POOL=0

# Default profile used when no profile is supplied.
# Valid profiles: balanced, low-noise, debug, super-debug
PROFILE="${PROFILE:-balanced}"
SHOW_HELP=0
ORIGINAL_ARGS=("$@")
POSITIONAL_ARGS=()

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      SHOW_HELP=1
      shift
      ;;
    -p|--profile)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --profile requires one of: balanced, low-noise, debug, super-debug" >&2
        exit 2
      fi
      PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      shift
      ;;
    --balanced)
      PROFILE="balanced"
      shift
      ;;
    --low-noise|--low_noise|--lownoise)
      PROFILE="low-noise"
      shift
      ;;
    --debug)
      PROFILE="debug"
      shift
      ;;
    --super-debug|--super_debug|--superdebug)
      PROFILE="super-debug"
      shift
      ;;
    --)
      shift
      while (( $# > 0 )); do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      echo "Use --help to show valid options." >&2
      exit 2
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if (( ${#POSITIONAL_ARGS[@]} > 1 )); then
  echo "ERROR: too many positional arguments: ${POSITIONAL_ARGS[*]}" >&2
  echo "Usage: sudo $0 [--profile balanced|low-noise|debug|super-debug] [POOL_NAME]" >&2
  exit 2
fi

# Normalise profile spelling.
PROFILE="$(printf '%s' "$PROFILE" | tr '[:upper:]_' '[:lower:]-')"
[[ "$PROFILE" == "superdebug" ]] && PROFILE="super-debug"

# Pool to monitor. This is normally supplied as the final script argument.
# Example: bash hdd-wake-trace.sh --profile balanced HDD_TANK
POOL="${POSITIONAL_ARGS[0]:-$DEFAULT_POOL}"

# Apply profile defaults. Individual environment variables still override these.
case "$PROFILE" in
  balanced)
    PROFILE_DESCRIPTION="Balanced: good wake-cause visibility without excessive noise."
    DEFAULT_INTERVAL=5
    DEFAULT_EVENT_COOLDOWN=60
    DEFAULT_JOURNAL_LOOKBACK="45 seconds ago"
    DEFAULT_JOURNAL_LINES=60
    DEFAULT_SUDO_LOOKBACK="45 seconds ago"
    DEFAULT_SUDO_LINES=20
    DEFAULT_PROCESS_LINES=25
    DEFAULT_PROCESS_IO_LINES=30
    DEFAULT_PROCESS_IO_SAMPLE_SECONDS=2
    DEFAULT_ZPOOL_IOSTAT_INTERVAL=1
    DEFAULT_ZPOOL_IOSTAT_COUNT=1
    DEFAULT_CORRELATION_BEFORE=60
    DEFAULT_CORRELATION_AFTER=20
    DEFAULT_CORRELATION_LINES=120
    DEFAULT_PID_CONTEXT_COUNT=8
    DEFAULT_BLOCK_TRACE=0
    DEFAULT_BLOCK_TRACE_LINES=300
    DEFAULT_BLOCK_TRACE_FIRST_LINES=80
    DEFAULT_BLOCK_TRACE_MATCH_LINES=160
    DEFAULT_ZFS_DIRTY_CONTEXT=0
    DEFAULT_ZFS_DIRTY_SCOPE="pool"
    DEFAULT_ZFS_TXG_LINES=40
    DEFAULT_ZFS_ARC_LINES=80
    DEFAULT_RECURRENCE_LINES=10
    ;;
  low-noise)
    PROFILE_DESCRIPTION="Low noise: cleaner logs with only the most likely wake-cause evidence."
    DEFAULT_INTERVAL=5
    DEFAULT_EVENT_COOLDOWN=90
    DEFAULT_JOURNAL_LOOKBACK="30 seconds ago"
    DEFAULT_JOURNAL_LINES=40
    DEFAULT_SUDO_LOOKBACK="30 seconds ago"
    DEFAULT_SUDO_LINES=10
    DEFAULT_PROCESS_LINES=15
    DEFAULT_PROCESS_IO_LINES=20
    DEFAULT_PROCESS_IO_SAMPLE_SECONDS=2
    DEFAULT_ZPOOL_IOSTAT_INTERVAL=1
    DEFAULT_ZPOOL_IOSTAT_COUNT=1
    DEFAULT_CORRELATION_BEFORE=45
    DEFAULT_CORRELATION_AFTER=15
    DEFAULT_CORRELATION_LINES=80
    DEFAULT_PID_CONTEXT_COUNT=5
    DEFAULT_BLOCK_TRACE=0
    DEFAULT_BLOCK_TRACE_LINES=200
    DEFAULT_BLOCK_TRACE_FIRST_LINES=40
    DEFAULT_BLOCK_TRACE_MATCH_LINES=100
    DEFAULT_ZFS_DIRTY_CONTEXT=0
    DEFAULT_ZFS_DIRTY_SCOPE="pool"
    DEFAULT_ZFS_TXG_LINES=30
    DEFAULT_ZFS_ARC_LINES=50
    DEFAULT_RECURRENCE_LINES=8
    ;;
  debug)
    PROFILE_DESCRIPTION="Debug: targeted wake-cause tracing without excessive raw dumps."
    DEFAULT_INTERVAL=3
    DEFAULT_EVENT_COOLDOWN=45
    DEFAULT_JOURNAL_LOOKBACK="120 seconds ago"
    DEFAULT_JOURNAL_LINES=120
    DEFAULT_SUDO_LOOKBACK="120 seconds ago"
    DEFAULT_SUDO_LINES=30
    DEFAULT_PROCESS_LINES=35
    DEFAULT_PROCESS_IO_LINES=30
    DEFAULT_PROCESS_IO_SAMPLE_SECONDS=3
    DEFAULT_ZPOOL_IOSTAT_INTERVAL=1
    DEFAULT_ZPOOL_IOSTAT_COUNT=1
    DEFAULT_CORRELATION_BEFORE=120
    DEFAULT_CORRELATION_AFTER=30
    DEFAULT_CORRELATION_LINES=160
    DEFAULT_PID_CONTEXT_COUNT=6
    DEFAULT_BLOCK_TRACE=1
    DEFAULT_BLOCK_TRACE_LINES=800
    DEFAULT_BLOCK_TRACE_FIRST_LINES=80
    DEFAULT_BLOCK_TRACE_MATCH_LINES=300
    DEFAULT_ZFS_DIRTY_CONTEXT=0
    DEFAULT_ZFS_DIRTY_SCOPE="pool"
    DEFAULT_ZFS_TXG_LINES=60
    DEFAULT_ZFS_ARC_LINES=80
    DEFAULT_RECURRENCE_LINES=20
    ;;
  super-debug)
    PROFILE_DESCRIPTION="Super-debug: deep wake-cause tracing with pool-focused ZFS dirty/txg context."
    DEFAULT_INTERVAL=3
    DEFAULT_EVENT_COOLDOWN=45
    DEFAULT_JOURNAL_LOOKBACK="180 seconds ago"
    DEFAULT_JOURNAL_LINES=220
    DEFAULT_SUDO_LOOKBACK="180 seconds ago"
    DEFAULT_SUDO_LINES=60
    DEFAULT_PROCESS_LINES=60
    DEFAULT_PROCESS_IO_LINES=60
    DEFAULT_PROCESS_IO_SAMPLE_SECONDS=3
    DEFAULT_ZPOOL_IOSTAT_INTERVAL=1
    DEFAULT_ZPOOL_IOSTAT_COUNT=3
    DEFAULT_CORRELATION_BEFORE=180
    DEFAULT_CORRELATION_AFTER=60
    DEFAULT_CORRELATION_LINES=300
    DEFAULT_PID_CONTEXT_COUNT=12
    DEFAULT_BLOCK_TRACE=1
    DEFAULT_BLOCK_TRACE_LINES=3000
    DEFAULT_BLOCK_TRACE_FIRST_LINES=160
    DEFAULT_BLOCK_TRACE_MATCH_LINES=800
    DEFAULT_ZFS_DIRTY_CONTEXT=1
    DEFAULT_ZFS_DIRTY_SCOPE="pool"
    DEFAULT_ZFS_TXG_LINES=120
    DEFAULT_ZFS_ARC_LINES=120
    DEFAULT_RECURRENCE_LINES=25
    ;;
  *)
    echo "ERROR: invalid profile: $PROFILE" >&2
    echo "Valid profiles: balanced, low-noise, debug, super-debug" >&2
    exit 2
    ;;
esac

# Directory for the main polling log and per-event capture logs.
LOGDIR="${LOGDIR:-$DEFAULT_LOGDIR}"
EVENTDIR="${EVENTDIR:-$DEFAULT_EVENTDIR}"

# When set to 1, only rotational disks reported by lsblk are monitored.
# This avoids SSD/NVMe devices, including special/metadata vdevs, skewing HDD
# wake detection. Set to 0 to include all pool block devices.
ROTATIONAL_ONLY="${ROTATIONAL_ONLY:-$DEFAULT_ROTATIONAL_ONLY}"

# Safety guard. When 0, the script refuses to run if LOGDIR resolves under any mounted dataset for the monitored pool.
# Set to 1 only if you intentionally want to log to the monitored pool.
ALLOW_LOGDIR_ON_POOL="${ALLOW_LOGDIR_ON_POOL:-$DEFAULT_ALLOW_LOGDIR_ON_POOL}"

# Seconds between hdparm power-state polls.
# Lower values detect wakes closer to the real event but produce more polling log output.
INTERVAL="${INTERVAL:-$DEFAULT_INTERVAL}"

# Seconds to suppress duplicate wake captures after an event.
# This reduces duplicate logs when disks wake in sequence or state reporting flaps.
EVENT_COOLDOWN="${EVENT_COOLDOWN:-$DEFAULT_EVENT_COOLDOWN}"

# General journal lookback used in the broad recent-activity section.
# This is intentionally shorter than the correlation window to reduce noise.
JOURNAL_LOOKBACK="${JOURNAL_LOOKBACK:-$DEFAULT_JOURNAL_LOOKBACK}"

# Maximum number of lines to keep from the broad recent journal section.
JOURNAL_LINES="${JOURNAL_LINES:-$DEFAULT_JOURNAL_LINES}"

# Recent sudo/admin lookback window.
# Useful for catching manual commands that may have touched the pool.
SUDO_LOOKBACK="${SUDO_LOOKBACK:-$DEFAULT_SUDO_LOOKBACK}"

# Maximum number of sudo/admin lines to include.
SUDO_LINES="${SUDO_LINES:-$DEFAULT_SUDO_LINES}"

# Number of recently started processes to show in an event capture.
PROCESS_LINES="${PROCESS_LINES:-$DEFAULT_PROCESS_LINES}"

# Number of process I/O rows to show in both immediate delta and since-boot views.
PROCESS_IO_LINES="${PROCESS_IO_LINES:-$DEFAULT_PROCESS_IO_LINES}"

# Seconds over which to measure immediate process I/O after wake detection.
# This helps identify processes that are actively doing I/O near the wake event.
PROCESS_IO_SAMPLE_SECONDS="${PROCESS_IO_SAMPLE_SECONDS:-$DEFAULT_PROCESS_IO_SAMPLE_SECONDS}"

# Seconds between zpool iostat samples during an event capture.
ZPOOL_IOSTAT_INTERVAL="${ZPOOL_IOSTAT_INTERVAL:-$DEFAULT_ZPOOL_IOSTAT_INTERVAL}"

# Number of zpool iostat samples to capture.
ZPOOL_IOSTAT_COUNT="${ZPOOL_IOSTAT_COUNT:-$DEFAULT_ZPOOL_IOSTAT_COUNT}"

# Seconds before the detected wake timestamp to search in the correlated journal window.
# This is the most important wake-cause setting because the trigger can happen before
# the script notices the standby -> active transition.
CORRELATION_BEFORE="${CORRELATION_BEFORE:-$DEFAULT_CORRELATION_BEFORE}"

# Seconds after the detected wake timestamp to search in the correlated journal window.
CORRELATION_AFTER="${CORRELATION_AFTER:-$DEFAULT_CORRELATION_AFTER}"

# Maximum number of correlated journal lines to show around the wake event.
CORRELATION_LINES="${CORRELATION_LINES:-$DEFAULT_CORRELATION_LINES}"

# Number of high-I/O PIDs to expand with cwd/exe/cgroup/fd context.
PID_CONTEXT_COUNT="${PID_CONTEXT_COUNT:-$DEFAULT_PID_CONTEXT_COUNT}"

# Optional tracefs block I/O capture. Disabled by default because it can be noisy.
# Set BLOCK_TRACE=1 to keep a rolling block trace and append a snapshot to each event.
BLOCK_TRACE="${BLOCK_TRACE:-$DEFAULT_BLOCK_TRACE}"
BLOCK_TRACE_LINES="${BLOCK_TRACE_LINES:-$DEFAULT_BLOCK_TRACE_LINES}"

# Number of earliest block trace lines to show. This helps catch the first I/O rather than only the busy tail.
BLOCK_TRACE_FIRST_LINES="${BLOCK_TRACE_FIRST_LINES:-$DEFAULT_BLOCK_TRACE_FIRST_LINES}"

# Number of block trace lines to show when filtering to triggered/monitored disks.
BLOCK_TRACE_MATCH_LINES="${BLOCK_TRACE_MATCH_LINES:-$DEFAULT_BLOCK_TRACE_MATCH_LINES}"

# Include ZFS dirty-data, txg and ARC context in event captures.
ZFS_DIRTY_CONTEXT="${ZFS_DIRTY_CONTEXT:-$DEFAULT_ZFS_DIRTY_CONTEXT}"

# Scope for ZFS dirty/txg capture.
#   pool = only /proc/spl/kstat/zfs/$POOL/txgs
#   all  = every /proc/spl/kstat/zfs/*/txgs
ZFS_DIRTY_SCOPE="${ZFS_DIRTY_SCOPE:-$DEFAULT_ZFS_DIRTY_SCOPE}"

# Number of txg and ARC lines to include when ZFS_DIRTY_CONTEXT=1.
ZFS_TXG_LINES="${ZFS_TXG_LINES:-$DEFAULT_ZFS_TXG_LINES}"
ZFS_ARC_LINES="${ZFS_ARC_LINES:-$DEFAULT_ZFS_ARC_LINES}"

# Number of previous wake events to show in the recurrence section.
RECURRENCE_LINES="${RECURRENCE_LINES:-$DEFAULT_RECURRENCE_LINES}"

# TSV index used for recurrence analysis.
EVENT_INDEX="${EVENT_INDEX:-$EVENTDIR/wake-events.tsv}"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

# TrueNAS/ZFS/app/service activity patterns worth correlating with wake events.
RELEVANT_ACTIVITY_RE='middlewared|middleware|zettarepl|autorepl|smart|smartd|smartctl|smartmontools|smb|smbd|samba|nmbd|winbind|wsdd|avahi|nfs|nfsd|zfs|zpool|zfs-zed|zedlet|scrub|snapshot|replication|resilver|trim|pool\.dataset|disk\.query|disk\.temperature|enclosure|reporting|rrdcached|collectd|netdata|sysstat|ix-app|ixsystems|app_lifecycle|catalog|docker|container|containerd|k3s|iscsi|iscsid|cron|systemd|cloud|rsync|rclone'

regex_escape() {
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g'
}

SCRIPT_NAME_RE="$(regex_escape "$SCRIPT_NAME")"
SCRIPT_PATH_RE="$(regex_escape "$SCRIPT_PATH")"

# Filter out log noise generated by this monitor itself.
MONITOR_EXCLUDE_RE="SUDO_COMMAND=.*(${SCRIPT_NAME_RE}|${SCRIPT_PATH_RE})|${SCRIPT_NAME_RE}|${SCRIPT_PATH_RE}|/sbin/hdparm.*-C|/usr/sbin/hdparm.*-C|\"/sbin/hdparm\",\"-C\"|\"/usr/sbin/hdparm\",\"-C\"|/bin/readlink|/usr/bin/readlink|/bin/basename|/usr/bin/basename|/bin/awk|/usr/bin/awk|/bin/tee|/usr/bin/tee|Cannot find unit for notify message"

usage() {
  cat <<EOF2
Usage:
  sudo $0 [--profile balanced|low-noise|debug|super-debug] [POOL_NAME]

Profile shortcuts:
  sudo $0 --balanced HDD_TANK
  sudo $0 --low-noise HDD_TANK
  sudo $0 --debug HDD_TANK
  sudo $0 --super-debug HDD_TANK

Examples:
  sudo $0
  sudo $0 HDD_TANK
  sudo $0 --profile balanced HDD_TANK
  sudo $0 --profile low-noise HDD_TANK
  sudo $0 --profile debug HDD_TANK
  sudo $0 --profile super-debug HDD_TANK

  # Environment overrides still work and win over profile defaults.
EOF2

  printf '  CORRELATION_BEFORE=120 PROCESS_IO_SAMPLE_SECONDS=3 \\\n'
  printf '  sudo -E %s --profile balanced HDD_TANK\n\n' "$0"

  cat <<EOF2
Current selected profile:
  PROFILE                   $PROFILE
  Description               $PROFILE_DESCRIPTION

Current effective run block:
EOF2

  printf '  LOGDIR="%s" \\\n' "$LOGDIR"
  printf '  ROTATIONAL_ONLY=%s \\\n' "$ROTATIONAL_ONLY"
  printf '  ALLOW_LOGDIR_ON_POOL=%s \\\n' "$ALLOW_LOGDIR_ON_POOL"
  printf '  INTERVAL=%s \\\n' "$INTERVAL"
  printf '  EVENT_COOLDOWN=%s \\\n' "$EVENT_COOLDOWN"
  printf '  JOURNAL_LOOKBACK="%s" \\\n' "$JOURNAL_LOOKBACK"
  printf '  JOURNAL_LINES=%s \\\n' "$JOURNAL_LINES"
  printf '  SUDO_LOOKBACK="%s" \\\n' "$SUDO_LOOKBACK"
  printf '  SUDO_LINES=%s \\\n' "$SUDO_LINES"
  printf '  PROCESS_LINES=%s \\\n' "$PROCESS_LINES"
  printf '  PROCESS_IO_LINES=%s \\\n' "$PROCESS_IO_LINES"
  printf '  PROCESS_IO_SAMPLE_SECONDS=%s \\\n' "$PROCESS_IO_SAMPLE_SECONDS"
  printf '  ZPOOL_IOSTAT_INTERVAL=%s \\\n' "$ZPOOL_IOSTAT_INTERVAL"
  printf '  ZPOOL_IOSTAT_COUNT=%s \\\n' "$ZPOOL_IOSTAT_COUNT"
  printf '  CORRELATION_BEFORE=%s \\\n' "$CORRELATION_BEFORE"
  printf '  CORRELATION_AFTER=%s \\\n' "$CORRELATION_AFTER"
  printf '  CORRELATION_LINES=%s \\\n' "$CORRELATION_LINES"
  printf '  PID_CONTEXT_COUNT=%s \\\n' "$PID_CONTEXT_COUNT"
  printf '  BLOCK_TRACE=%s \\\n' "$BLOCK_TRACE"
  printf '  BLOCK_TRACE_LINES=%s \\\n' "$BLOCK_TRACE_LINES"
  printf '  BLOCK_TRACE_FIRST_LINES=%s \\\n' "$BLOCK_TRACE_FIRST_LINES"
  printf '  BLOCK_TRACE_MATCH_LINES=%s \\\n' "$BLOCK_TRACE_MATCH_LINES"
  printf '  ZFS_DIRTY_CONTEXT=%s \\\n' "$ZFS_DIRTY_CONTEXT"
  printf '  ZFS_DIRTY_SCOPE=%s \\\n' "$ZFS_DIRTY_SCOPE"
  printf '  ZFS_TXG_LINES=%s \\\n' "$ZFS_TXG_LINES"
  printf '  ZFS_ARC_LINES=%s \\\n' "$ZFS_ARC_LINES"
  printf '  RECURRENCE_LINES=%s \\\n' "$RECURRENCE_LINES"
  printf '  sudo -E %s --profile %s %s\n\n' "$0" "$PROFILE" "$POOL"

  cat <<EOF2
Built-in profiles:
  balanced
    General-purpose defaults. Best first choice for wake-cause troubleshooting.
    INTERVAL=5, EVENT_COOLDOWN=60, JOURNAL_LOOKBACK="45 seconds ago",
    CORRELATION_BEFORE=60, CORRELATION_AFTER=20, CORRELATION_LINES=120.

  low-noise
    Smaller output. Best for overnight or long-running monitoring where logs need
    to stay readable.
    INTERVAL=5, EVENT_COOLDOWN=90, JOURNAL_LOOKBACK="30 seconds ago",
    CORRELATION_BEFORE=45, CORRELATION_AFTER=15, CORRELATION_LINES=80.

  debug
    Targeted deep tracing without excessive raw dumps. Best when balanced mode
    is not catching enough context.
    INTERVAL=3, EVENT_COOLDOWN=45, JOURNAL_LOOKBACK="120 seconds ago",
    CORRELATION_BEFORE=120, CORRELATION_AFTER=30, CORRELATION_LINES=160,
    BLOCK_TRACE=1, ZFS_DIRTY_CONTEXT=0.

  super-debug
    Full deep tracing. Enables pool-focused ZFS dirty/txg context and larger
    block trace windows. Use for short, targeted runs.
    INTERVAL=3, EVENT_COOLDOWN=45, JOURNAL_LOOKBACK="180 seconds ago",
    CORRELATION_BEFORE=180, CORRELATION_AFTER=60, CORRELATION_LINES=300,
    BLOCK_TRACE=1, ZFS_DIRTY_CONTEXT=1, ZFS_DIRTY_SCOPE=pool.

Purpose:
  Watches disks in a ZFS pool and logs when individual disks, or the whole
  monitored set, wake from standby to active/idle.

Notes:
  Put LOGDIR on SSD/NVMe storage, not on the HDD pool being monitored.
  By default, ROTATIONAL_ONLY=1 monitors only rotational HDDs in the pool.
  Set ROTATIONAL_ONLY=0 if you also want to include SSD/NVMe devices.
  The initial baseline poll is not treated as a wake event.
  Environment variables override the selected profile defaults.
  By default, ALLOW_LOGDIR_ON_POOL=0 prevents accidental logging to mounted datasets for the monitored pool.

Output:
  Normal polling output:
    \$LOGDIR/power-state.log

  Wake event captures:
    \$EVENTDIR

  Output is written to both terminal and log files.

Current effective values:
  POOL_NAME                  $POOL
  PROFILE                    $PROFILE
  LOGDIR                     $LOGDIR
  ROTATIONAL_ONLY            $ROTATIONAL_ONLY
  ALLOW_LOGDIR_ON_POOL       $ALLOW_LOGDIR_ON_POOL
  INTERVAL                   $INTERVAL
  EVENT_COOLDOWN             $EVENT_COOLDOWN
  JOURNAL_LOOKBACK           $JOURNAL_LOOKBACK
  JOURNAL_LINES              $JOURNAL_LINES
  SUDO_LOOKBACK              $SUDO_LOOKBACK
  SUDO_LINES                 $SUDO_LINES
  PROCESS_LINES              $PROCESS_LINES
  PROCESS_IO_LINES           $PROCESS_IO_LINES
  PROCESS_IO_SAMPLE_SECONDS  $PROCESS_IO_SAMPLE_SECONDS
  ZPOOL_IOSTAT_INTERVAL      $ZPOOL_IOSTAT_INTERVAL
  ZPOOL_IOSTAT_COUNT         $ZPOOL_IOSTAT_COUNT
  CORRELATION_BEFORE         $CORRELATION_BEFORE
  CORRELATION_AFTER          $CORRELATION_AFTER
  CORRELATION_LINES          $CORRELATION_LINES
  PID_CONTEXT_COUNT          $PID_CONTEXT_COUNT
  BLOCK_TRACE                $BLOCK_TRACE
  BLOCK_TRACE_LINES          $BLOCK_TRACE_LINES
  BLOCK_TRACE_FIRST_LINES    $BLOCK_TRACE_FIRST_LINES
  BLOCK_TRACE_MATCH_LINES    $BLOCK_TRACE_MATCH_LINES
  ZFS_DIRTY_CONTEXT          $ZFS_DIRTY_CONTEXT
  ZFS_DIRTY_SCOPE            $ZFS_DIRTY_SCOPE
  ZFS_TXG_LINES              $ZFS_TXG_LINES
  ZFS_ARC_LINES              $ZFS_ARC_LINES
  RECURRENCE_LINES           $RECURRENCE_LINES
  EVENT_INDEX                $EVENT_INDEX

Variable descriptions:
  POOL_NAME
    ZFS pool to monitor. Supplied as the final argument. Default: $DEFAULT_POOL

  PROFILE
    Selects default values. Valid values: balanced, low-noise, debug, super-debug.

  LOGDIR
    Directory for power-state and wake-event logs. Keep this on SSD/NVMe.

  ROTATIONAL_ONLY
    1 = monitor only rotational disks from lsblk ROTA=1.
    0 = monitor all block devices discovered in the pool.

  ALLOW_LOGDIR_ON_POOL
    0 = refuse to run if LOGDIR resolves under any mounted dataset for the monitored pool.
    1 = allow logging to the monitored pool. Not recommended for wake testing.

  INTERVAL
    Seconds between hdparm -C polling checks.

  EVENT_COOLDOWN
    Seconds to suppress duplicate wake captures after an event.

  JOURNAL_LOOKBACK / JOURNAL_LINES
    Broad recent journal context included in each event log.

  SUDO_LOOKBACK / SUDO_LINES
    Recent sudo/admin activity context included in each event log.

  PROCESS_LINES
    Number of recently started processes to show.

  PROCESS_IO_LINES
    Number of process I/O rows to show in delta and since-boot I/O sections.

  PROCESS_IO_SAMPLE_SECONDS
    Duration of the immediate process I/O delta sample after wake detection.

  ZPOOL_IOSTAT_INTERVAL / ZPOOL_IOSTAT_COUNT
    Frequency and count of zpool iostat samples captured after wake detection.

  CORRELATION_BEFORE / CORRELATION_AFTER / CORRELATION_LINES
    Journal correlation window around the detected wake timestamp.
    CORRELATION_BEFORE is usually the most important value.

  PID_CONTEXT_COUNT
    Number of high-I/O PIDs to expand with cwd/exe/cgroup/open-file context.

  BLOCK_TRACE / BLOCK_TRACE_LINES / BLOCK_TRACE_FIRST_LINES / BLOCK_TRACE_MATCH_LINES
    Optional tracefs block I/O tracing. Set BLOCK_TRACE=1 for deeper evidence.
    FIRST_LINES shows earliest trace entries; MATCH_LINES shows filtered triggered/monitored disk entries.

  ZFS_DIRTY_CONTEXT / ZFS_DIRTY_SCOPE / ZFS_TXG_LINES / ZFS_ARC_LINES
    ZFS_DIRTY_CONTEXT=1 includes /proc/spl/kstat ZFS txg/dirty/ARC context.
    ZFS_DIRTY_SCOPE=pool captures only /proc/spl/kstat/zfs/$POOL/txgs.
    ZFS_DIRTY_SCOPE=all captures every /proc/spl/kstat/zfs/*/txgs and is very noisy.

  RECURRENCE_LINES / EVENT_INDEX
    Number of indexed wake events to show and TSV file used for recurrence analysis.
EOF2
}

if [[ "$SHOW_HELP" == "1" ]]; then
  usage
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "Re-running as root..."
  exec sudo --preserve-env=PROFILE,LOGDIR,EVENTDIR,ROTATIONAL_ONLY,ALLOW_LOGDIR_ON_POOL,INTERVAL,EVENT_COOLDOWN,JOURNAL_LOOKBACK,JOURNAL_LINES,SUDO_LOOKBACK,SUDO_LINES,PROCESS_LINES,PROCESS_IO_LINES,PROCESS_IO_SAMPLE_SECONDS,ZPOOL_IOSTAT_INTERVAL,ZPOOL_IOSTAT_COUNT,CORRELATION_BEFORE,CORRELATION_AFTER,CORRELATION_LINES,PID_CONTEXT_COUNT,BLOCK_TRACE,BLOCK_TRACE_LINES,BLOCK_TRACE_FIRST_LINES,BLOCK_TRACE_MATCH_LINES,ZFS_DIRTY_CONTEXT,ZFS_DIRTY_SCOPE,ZFS_TXG_LINES,ZFS_ARC_LINES,RECURRENCE_LINES,EVENT_INDEX bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
fi

command -v zpool >/dev/null || { echo "ERROR: zpool not found"; exit 1; }
command -v zfs >/dev/null || { echo "ERROR: zfs not found"; exit 1; }
command -v hdparm >/dev/null || { echo "ERROR: hdparm not found"; exit 1; }
command -v lsblk >/dev/null || { echo "ERROR: lsblk not found"; exit 1; }
command -v journalctl >/dev/null || { echo "ERROR: journalctl not found"; exit 1; }

log() {
  echo "[$(date -Is)] $*" | tee -a "$MAINLOG"
}

main_out() {
  echo "$*" | tee -a "$MAINLOG"
}

main_printf() {
  local fmt="$1"
  shift
  printf "$fmt" "$@" | tee -a "$MAINLOG"
}

require_uint() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: $name must be a non-negative integer without leading zeroes. Current value: $value" >&2
    exit 1
  fi
}

require_positive_uint() {
  local name="$1"
  local value="$2"

  require_uint "$name" "$value"

  if (( 10#$value < 1 )); then
    echo "ERROR: $name must be greater than zero. Current value: $value" >&2
    exit 1
  fi
}

validate_settings() {
  case "$ROTATIONAL_ONLY" in
    0|1) ;;
    *)
      echo "ERROR: ROTATIONAL_ONLY must be 0 or 1. Current value: $ROTATIONAL_ONLY" >&2
      exit 1
      ;;
  esac

  case "$ALLOW_LOGDIR_ON_POOL" in
    0|1) ;;
    *)
      echo "ERROR: ALLOW_LOGDIR_ON_POOL must be 0 or 1. Current value: $ALLOW_LOGDIR_ON_POOL" >&2
      exit 1
      ;;
  esac

  require_positive_uint INTERVAL "$INTERVAL"
  require_uint EVENT_COOLDOWN "$EVENT_COOLDOWN"
  require_positive_uint JOURNAL_LINES "$JOURNAL_LINES"
  require_positive_uint SUDO_LINES "$SUDO_LINES"
  require_positive_uint PROCESS_LINES "$PROCESS_LINES"
  require_positive_uint PROCESS_IO_LINES "$PROCESS_IO_LINES"
  require_positive_uint PROCESS_IO_SAMPLE_SECONDS "$PROCESS_IO_SAMPLE_SECONDS"
  require_positive_uint ZPOOL_IOSTAT_INTERVAL "$ZPOOL_IOSTAT_INTERVAL"
  require_positive_uint ZPOOL_IOSTAT_COUNT "$ZPOOL_IOSTAT_COUNT"
  require_uint CORRELATION_BEFORE "$CORRELATION_BEFORE"
  require_uint CORRELATION_AFTER "$CORRELATION_AFTER"
  require_positive_uint CORRELATION_LINES "$CORRELATION_LINES"
  require_positive_uint PID_CONTEXT_COUNT "$PID_CONTEXT_COUNT"
  require_positive_uint BLOCK_TRACE_LINES "$BLOCK_TRACE_LINES"
  require_positive_uint BLOCK_TRACE_FIRST_LINES "$BLOCK_TRACE_FIRST_LINES"
  require_positive_uint BLOCK_TRACE_MATCH_LINES "$BLOCK_TRACE_MATCH_LINES"
  require_positive_uint RECURRENCE_LINES "$RECURRENCE_LINES"

  case "$BLOCK_TRACE" in
    0|1) ;;
    *)
      echo "ERROR: BLOCK_TRACE must be 0 or 1. Current value: $BLOCK_TRACE" >&2
      exit 1
      ;;
  esac

  case "$ZFS_DIRTY_CONTEXT" in
    0|1) ;;
    *)
      echo "ERROR: ZFS_DIRTY_CONTEXT must be 0 or 1. Current value: $ZFS_DIRTY_CONTEXT" >&2
      exit 1
      ;;
  esac

  case "$ZFS_DIRTY_SCOPE" in
    pool|all) ;;
    *)
      echo "ERROR: ZFS_DIRTY_SCOPE must be pool or all. Current value: $ZFS_DIRTY_SCOPE" >&2
      exit 1
      ;;
  esac

  require_positive_uint ZFS_TXG_LINES "$ZFS_TXG_LINES"
  require_positive_uint ZFS_ARC_LINES "$ZFS_ARC_LINES"
}

pool_mount_paths() {
  zfs list -H -r -o mountpoint,mounted "$POOL" 2>/dev/null \
    | awk -F '\t' '
        $2 == "yes" &&
        $1 != "-" &&
        $1 != "none" &&
        $1 != "legacy" {
          print $1
        }
      ' \
    | sort -u
}

check_logdir_safety() {
  local resolved_logdir mount_path resolved_mount fallback_mount

  [[ "$ALLOW_LOGDIR_ON_POOL" == "1" ]] && return 0

  # readlink -m works even when LOGDIR does not exist yet.
  resolved_logdir="$(readlink -m "$LOGDIR" 2>/dev/null || printf '%s' "$LOGDIR")"

  while IFS= read -r mount_path; do
    [[ -z "$mount_path" ]] && continue
    [[ "$mount_path" == "/" ]] && continue

    resolved_mount="$(readlink -m "$mount_path" 2>/dev/null || printf '%s' "$mount_path")"

    case "$resolved_logdir" in
      "$resolved_mount"|"$resolved_mount"/*)
        echo "ERROR: LOGDIR resolves under a mounted dataset for the monitored pool." >&2
        echo "LOGDIR:       $resolved_logdir" >&2
        echo "Pool mount:   $resolved_mount" >&2
        echo "This can create false wake events because the monitor writes logs while watching the same pool." >&2
        echo "Move LOGDIR to SSD/NVMe storage, or rerun with ALLOW_LOGDIR_ON_POOL=1 if intentional." >&2
        exit 1
        ;;
    esac
  done < <(pool_mount_paths)

  # Fallback guard for the normal TrueNAS layout, even if zfs list returns no mountpoints.
  fallback_mount="$(readlink -m "/mnt/$POOL" 2>/dev/null || printf '/mnt/%s' "$POOL")"

  case "$resolved_logdir" in
    "$fallback_mount"|"$fallback_mount"/*)
      echo "ERROR: LOGDIR resolves under the monitored pool fallback path." >&2
      echo "LOGDIR:       $resolved_logdir" >&2
      echo "Pool path:    $fallback_mount" >&2
      echo "Move LOGDIR to SSD/NVMe storage, or rerun with ALLOW_LOGDIR_ON_POOL=1 if intentional." >&2
      exit 1
      ;;
  esac
}

validate_settings
check_logdir_safety

mkdir -p "$LOGDIR"
mkdir -p "$EVENTDIR"
MAINLOG="$LOGDIR/power-state.log"

safe_filename() {
  local value

  value="$(
    printf '%s' "$*" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
      | cut -c1-140
  )"

  if [[ -z "$value" ]]; then
    echo "unknown"
  else
    echo "$value"
  fi
}

epoch_to_local() {
  local epoch="$1"
  date -d "@$epoch" '+%Y-%m-%d %H:%M:%S'
}

pool_disks() {
  local path real parent disk rota

  zpool status -P "$POOL" \
    | awk '$1 ~ "^/" { print $1 }' \
    | while read -r path; do
        real="$(readlink -f "$path" 2>/dev/null || echo "$path")"

        if [[ -b "$real" ]]; then
          parent="$(lsblk -no PKNAME "$real" 2>/dev/null | head -n1 || true)"

          if [[ -n "$parent" ]]; then
            disk="/dev/$parent"
          else
            disk="$real"
          fi

          if [[ "$ROTATIONAL_ONLY" == "1" ]]; then
            rota="$(lsblk -dn -o ROTA "$disk" 2>/dev/null | awk 'NR == 1 { print $1 }')"
            [[ "$rota" == "1" ]] || continue
          fi

          echo "$disk"
        fi
      done \
    | sort -u
}

disk_label() {
  local disk="$1"
  local link

  for link in /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-* /dev/disk/by-id/wwn-*; do
    [[ -e "$link" ]] || continue

    if [[ "$(readlink -f "$link")" == "$disk" ]]; then
      basename "$link"
      return
    fi
  done

  basename "$disk"
}

short_disk_label() {
  local disk="$1"
  local label

  label="$(disk_label "$disk")"

  label="${label#ata-}"
  label="${label#scsi-}"
  label="${label#wwn-}"

  echo "$label"
}

disk_major_minor() {
  local disk="$1"
  lsblk -dn -o MAJ:MIN "$disk" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

major_minor_regex_escape() {
  # Escape comma for readability and any unexpected regex characters.
  printf '%s' "$1" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g'
}

major_minor_regex_from_disks() {
  local disk mm trace_mm escaped
  local parts=()

  for disk in "$@"; do
    [[ -z "$disk" ]] && continue

    # lsblk reports MAJ:MIN as 8:32.
    # tracefs block events report the same device as 8,32.
    mm="$(disk_major_minor "$disk")"
    [[ -z "$mm" ]] && continue

    trace_mm="${mm/:/,}"

    escaped="(^|[^0-9])$(major_minor_regex_escape "$trace_mm")([^0-9]|$)"
    parts+=("$escaped")
  done

  if (( ${#parts[@]} > 0 )); then
    local IFS='|'
    printf '%s' "${parts[*]}"
  fi
}

major_minor_regex_from_triggered() {
  local item disk
  local disks=()

  for item in "$@"; do
    IFS='|' read -r disk _ <<< "$item"
    [[ -n "$disk" ]] && disks+=("$disk")
  done

  major_minor_regex_from_disks "${disks[@]}"
}

print_monitored_major_minor_map() {
  local disk mm label

  echo "== Monitored block device major:minor mapping =="
  echo "This maps block trace IDs such as 8,80 back to actual disks."
  echo

  for disk in "${DISKS[@]}"; do
    mm="$(disk_major_minor "$disk")"
    label="$(short_disk_label "$disk")"
    printf "%-12s %-8s %s\n" "$disk" "${mm:-unknown}" "$label"
  done
  echo
}

power_state() {
  local disk="$1"
  local out state

  out="$(hdparm -C "$disk" 2>&1 || true)"
  state="$(awk -F: '/drive state is/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2 }' <<< "$out")"

  if [[ -z "$state" ]]; then
    echo "unknown"
  else
    echo "$state"
  fi
}

is_standby() {
  [[ "$1" == *"standby"* || "$1" == *"sleeping"* ]]
}

is_active() {
  [[ "$1" == *"active/idle"* || "$1" == *"idle"* ]]
}

io_snapshot_file() {
  local outfile="$1"
  local p pid comm read_bytes write_bytes

  : > "$outfile"

  for p in /proc/[0-9]*; do
    pid="${p##*/}"

    [[ -r "$p/io" ]] || continue

    comm="$(cat "$p/comm" 2>/dev/null || true)"
    read_bytes="$(awk '$1 == "read_bytes:" { print $2; exit }' "$p/io" 2>/dev/null || echo 0)"
    write_bytes="$(awk '$1 == "write_bytes:" { print $2; exit }' "$p/io" 2>/dev/null || echo 0)"

    read_bytes="${read_bytes:-0}"
    write_bytes="${write_bytes:-0}"

printf "%s\t%s\t%s\t%s\n" "$pid" "$read_bytes" "$write_bytes" "$comm" >> "$outfile"
  done
}

process_io_snapshot() {
  local lines="${1:-50}"
  local p pid comm read_bytes write_bytes total

  for p in /proc/[0-9]*; do
    pid="${p##*/}"

    [[ -r "$p/io" ]] || continue

    comm="$(cat "$p/comm" 2>/dev/null || true)"
    read_bytes="$(awk '$1 == "read_bytes:" { print $2; exit }' "$p/io" 2>/dev/null || echo 0)"
    write_bytes="$(awk '$1 == "write_bytes:" { print $2; exit }' "$p/io" 2>/dev/null || echo 0)"

    read_bytes="${read_bytes:-0}"
     write_bytes="${write_bytes:-0}"

    total=$((read_bytes + write_bytes))

    if (( total > 0 )); then
      printf "%12d  pid=%-8s  read=%-12s  write=%-12s  %s\n" \
        "$total" "$pid" "$read_bytes" "$write_bytes" "$comm"
    fi
  done | sort -nr | head -"$lines"
}

process_io_delta_sample() {
  local sample_seconds="${1:-2}"
  local lines="${2:-30}"
  local before after

  before="$(mktemp /tmp/hddwake-proc-before.XXXXXX)"
  after="$(mktemp /tmp/hddwake-proc-after.XXXXXX)"

  io_snapshot_file "$before"
  sleep "$sample_seconds"
  io_snapshot_file "$after"

  awk -F '\t' '
    NR == FNR {
      r[$1] = $2
      w[$1] = $3
      c[$1] = $4
      next
    }
    {
      pid = $1
      comm = $4
      old_r = (pid in r) ? r[pid] : 0
      old_w = (pid in w) ? w[pid] : 0
      dr = $2 - old_r
      dw = $3 - old_w
      total = dr + dw

      if (total > 0) {
        printf "%12d  pid=%-8s  read_delta=%-12s  write_delta=%-12s  %s\n", total, pid, dr, dw, comm
      }
    }
  ' "$before" "$after" | sort -nr | head -"$lines"

  rm -f "$before" "$after" 2>/dev/null || true
}

journal_filtered() {
  local since="$1"
  local include_re="$2"
  local lines="${3:-300}"

  journalctl --since "$since" --no-pager -o short-iso 2>/dev/null \
    | grep -Ei "$include_re" \
    | grep -Evi "$MONITOR_EXCLUDE_RE" \
    | tail -"$lines" || true
}

correlated_journal_window() {
  local wake_epoch="$1"
  local include_re="$2"
  local before="${3:-60}"
  local after="${4:-20}"
  local lines="${5:-120}"

  local since_epoch until_epoch since_time until_time

  since_epoch=$((wake_epoch - before))
  until_epoch=$((wake_epoch + after))

  since_time="$(epoch_to_local "$since_epoch")"
  until_time="$(epoch_to_local "$until_epoch")"

  echo "Wake epoch:  $wake_epoch"
  echo "Window:      ${before}s before to ${after}s after wake"
  echo "Since:       $since_time"
  echo "Until:       $until_time"
  echo

  journalctl --since "$since_time" --until "$until_time" --no-pager -o short-unix 2>/dev/null \
    | grep -Ei "$include_re" \
    | grep -Evi "$MONITOR_EXCLUDE_RE" \
    | tail -"$lines" \
    | awk -v wake="$wake_epoch" '
        {
          rawts=$1
          ts=rawts
          sub(/\..*/, "", ts)
          delta=ts-wake

          if (delta > 0) {
            d=sprintf("+%ds", delta)
          } else {
            d=sprintf("%ds", delta)
          }

          $1=""
          sub(/^ /, "", $0)
          printf "delta=%-7s %s\n", d, $0
        }
      ' || true
}


# -----------------------------------------------------------------------------
# Analysis helpers
# -----------------------------------------------------------------------------

declare -a ANALYSIS_FINDINGS=()
declare -a TOP_IO_PIDS=()

reset_analysis() {
  ANALYSIS_FINDINGS=()
  TOP_IO_PIDS=()
}

add_finding() {
  local severity="$1"
  local category="$2"
  local detail="$3"
  ANALYSIS_FINDINGS+=("$severity|$category|$detail")
}

print_findings() {
  echo "== Wake analysis summary =="

  if (( ${#ANALYSIS_FINDINGS[@]} == 0 )); then
    echo "No strong suspects identified from the captured evidence."
    echo
    return 0
  fi

  printf '%s\n' "${ANALYSIS_FINDINGS[@]}" \
    | awk -F'|' '
        BEGIN {
          rank["HIGH"] = 1
          rank["MEDIUM"] = 2
          rank["LOW"] = 3
        }
        {
          r = ($1 in rank) ? rank[$1] : 9
          key = $1 "|" $2 "|" $3
          if (!seen[key]++) {
            printf "%d|%s|%s|%s\n", r, $1, $2, $3
          }
        }
      ' \
    | sort -n \
    | cut -d'|' -f2- \
    | awk -F'|' '{ printf "%-8s %-18s %s\n", $1 ":", $2, $3 }'

  echo
}

analyze_process_io_delta() {
  local file="$1"
  local line pid comm
  local saw_zfs=0 saw_smb=0 saw_smart=0 saw_middleware=0 saw_backup=0 saw_logging=0

  TOP_IO_PIDS=()

  while IFS= read -r line; do
    [[ "$line" =~ pid=([0-9]+) ]] || continue
    pid="${BASH_REMATCH[1]}"
    comm="${line##*  }"

    TOP_IO_PIDS+=("$pid")

    if [[ "$line" =~ smbd|samba|winbind|nmbd ]]; then
      saw_smb=1
    elif [[ "$line" =~ smartctl|smartd ]]; then
      saw_smart=1
    elif [[ "$line" =~ middlewared|asyncio_loop ]]; then
      saw_middleware=1
    elif [[ "$line" =~ duplicati|rsync|rclone|cloud|backup ]]; then
      saw_backup=1
    elif [[ "$line" =~ z_wr|z_rd|txg_sync|flush-zfs|z_metaslab|kworker.*zfs ]]; then
      saw_zfs=1
    elif [[ "$line" =~ syslog-ng|systemd-journal|auditd ]]; then
      saw_logging=1
    fi
  done < "$file"

  (( saw_smb == 1 )) && add_finding "HIGH" "SMB" "SMB/Samba process I/O was active immediately after wake detection."
  (( saw_smart == 1 )) && add_finding "MEDIUM" "SMART" "SMART process I/O appeared near the wake."
  (( saw_middleware == 1 )) && add_finding "MEDIUM" "middleware" "TrueNAS middleware I/O appeared near the wake."
  (( saw_backup == 1 )) && add_finding "MEDIUM" "backup/sync" "Backup or sync process I/O appeared near the wake."
  (( saw_zfs == 1 )) && add_finding "MEDIUM" "ZFS" "ZFS kernel worker or txg_sync I/O appeared immediately after wake."
  (( saw_logging == 1 )) && add_finding "LOW" "logging" "syslog-ng/systemd-journal/auditd wrote heavily after the wake; often a side-effect of capture/audit logging."
}

analyze_correlated_journal() {
  local file="$1"

  grep -Eiq 'TNAUDIT_SMB|smbd|samba' "$file" \
    && add_finding "HIGH" "SMB" "SMB audit/session activity was present inside the wake correlation window."

  grep -Eiq 'smartctl|smartd|smartmontools' "$file" \
    && add_finding "MEDIUM" "SMART" "SMART activity was present inside the wake correlation window."

  grep -Eiq 'middlewared|disk\.query|disk\.temperature|pool\.dataset|enclosure|reporting' "$file" \
    && add_finding "MEDIUM" "middleware" "TrueNAS middleware/disk/reporting activity was present inside the wake correlation window."

  grep -Eiq 'zettarepl|replication|snapshot|scrub|resilver|zpool|zfs-zed|zedlet' "$file" \
    && add_finding "MEDIUM" "ZFS tasks" "ZFS/pool task activity was present inside the wake correlation window."

  grep -Eiq 'cron|sysstat|netdata|collectd|rrdcached' "$file" \
    && add_finding "LOW" "scheduled" "Scheduled/reporting activity appeared in the correlation window."
}

pid_context() {
  local pid="$1"

  [[ -d "/proc/$pid" ]] || {
    echo "--- PID $pid context unavailable; process exited ---"
    echo
    return 0
  }

  echo "--- PID $pid context ---"
  echo "comm:    $(cat "/proc/$pid/comm" 2>/dev/null || true)"
  echo "cmdline: $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  echo "cwd:     $(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
  echo "exe:     $(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  echo "cgroup:"
  cat "/proc/$pid/cgroup" 2>/dev/null || true

  echo "open fds under /mnt/$POOL:"
  ls -l "/proc/$pid/fd" 2>/dev/null \
    | grep -F "/mnt/$POOL" \
    | head -50 || true
  echo
}

print_pid_context_from_delta() {
  local count="${1:-8}"
  local printed=0 pid seen=" "

  echo "== PID context for top immediate I/O processes =="

  for pid in "${TOP_IO_PIDS[@]}"; do
    [[ "$seen" == *" $pid "* ]] && continue
    seen="${seen}${pid} "

    pid_context "$pid"

    printed=$((printed + 1))
    (( printed >= count )) && break
  done

  if (( printed == 0 )); then
    echo "No PID context available from immediate I/O delta."
    echo
  fi
}

capture_smb_context() {
  local wake_epoch="$1"
  local before="${2:-60}"
  local after="${3:-20}"
  local since_time until_time output
  local smb_found=0

  since_time="$(epoch_to_local $((wake_epoch - before)))"
  until_time="$(epoch_to_local $((wake_epoch + after)))"

  echo "== SMB wake context =="

  echo "-- smbstatus --"
  if command -v smbstatus >/dev/null 2>&1; then
    smbstatus 2>&1 || true
  else
    echo "smbstatus not available"
  fi
  echo

  echo "-- SMB/Samba open files under /mnt/$POOL --"
  if command -v lsof >/dev/null 2>&1; then
    output="$(lsof -nP 2>/dev/null | grep -Ei 'smbd|samba|winbind|nmbd' | grep -F "/mnt/$POOL" | head -150 || true)"
    if [[ -n "$output" ]]; then
      echo "$output"
      smb_found=1
    else
      echo "No SMB/Samba open files found under /mnt/$POOL at capture time."
    fi
  else
    echo "lsof not available"
  fi
  echo

  echo "-- SMB/Samba journal activity around wake --"
  output="$(journalctl --since "$since_time" --until "$until_time" --no-pager -o short-iso 2>/dev/null \
    | grep -Ei 'TNAUDIT_SMB|smbd|samba|winbind|nmbd' \
    | grep -Evi "$MONITOR_EXCLUDE_RE" \
    | tail -100 || true)"
  if [[ -n "$output" ]]; then
    echo "$output"
    smb_found=1
  else
    echo "No SMB/Samba journal activity found in the wake window."
  fi
  echo

  if (( smb_found == 1 )); then
    add_finding "HIGH" "SMB" "SMB activity/open handles were present around the wake."
  fi
}

capture_smart_context() {
  local wake_epoch="$1"
  local before="${2:-60}"
  local after="${3:-20}"
  local since_time until_time output
  local smart_found=0

  since_time="$(epoch_to_local $((wake_epoch - before)))"
  until_time="$(epoch_to_local $((wake_epoch + after)))"

  echo "== SMART / disk polling context =="

  echo "-- SMART processes currently visible --"
  output="$(ps -eo pid,ppid,user,lstart,comm,args --sort=start_time 2>/dev/null \
    | grep -Ei 'smartctl|smartd|disk\.temperature|disk\.query' \
    | grep -Evi "${SCRIPT_NAME_RE}|${SCRIPT_PATH_RE}|grep -Ei" \
    | tail -50 || true)"
  if [[ -n "$output" ]]; then
    echo "$output"
    smart_found=1
  else
    echo "No SMART/disk polling processes currently visible."
  fi
  echo

  echo "-- SMART/disk polling journal activity around wake --"
  output="$(journalctl --since "$since_time" --until "$until_time" --no-pager -o short-iso 2>/dev/null \
    | grep -Ei 'smartctl|smartd|smartmontools|disk\.temperature|disk\.query|middlewared.*disk' \
    | grep -Evi "$MONITOR_EXCLUDE_RE" \
    | tail -100 || true)"
  if [[ -n "$output" ]]; then
    echo "$output"
    smart_found=1
  else
    echo "No SMART/disk polling journal activity found in the wake window."
  fi
  echo

  if (( smart_found == 1 )); then
    add_finding "MEDIUM" "SMART" "SMART or TrueNAS disk polling activity was seen around the wake. Check whether it appears before or after wake_epoch."
  fi
}

capture_zfs_dirty_context() {
  (( ZFS_DIRTY_CONTEXT == 1 )) || return 0

  local found=0
  local f
  local -a txg_files=()

  echo "== ZFS dirty data / txg context =="
  echo "This helps show whether ZFS had dirty data or txg activity around the wake."
  echo "Scope: $ZFS_DIRTY_SCOPE"
  echo "TXG lines per file: $ZFS_TXG_LINES"
  echo "ARC lines: $ZFS_ARC_LINES"
  echo

  echo "-- txg kstats --"
  case "$ZFS_DIRTY_SCOPE" in
    pool)
      f="/proc/spl/kstat/zfs/$POOL/txgs"
      if [[ -r "$f" ]]; then
        txg_files+=("$f")
      else
        echo "Pool txg file not readable: $f"
        echo "Tip: run with ZFS_DIRTY_SCOPE=all only if you need to inspect every pool."
      fi
      ;;
    all)
      if compgen -G "/proc/spl/kstat/zfs/*/txgs" >/dev/null; then
        for f in /proc/spl/kstat/zfs/*/txgs; do
          [[ -r "$f" ]] || continue
          txg_files+=("$f")
        done
      else
        echo "No /proc/spl/kstat/zfs/*/txgs files found."
      fi
      ;;
  esac

  if (( ${#txg_files[@]} > 0 )); then
    for f in "${txg_files[@]}"; do
      echo "--- $f ---"
      tail -"$ZFS_TXG_LINES" "$f" 2>/dev/null || true
      echo
      found=1
    done
  fi
  echo

  echo "-- ARC dirty/write/meta counters --"
  if [[ -r /proc/spl/kstat/zfs/arcstats ]]; then
    grep -Ei 'dirty|sync|write|meta|demand|prefetch' /proc/spl/kstat/zfs/arcstats 2>/dev/null | tail -"$ZFS_ARC_LINES" || true
    found=1
  else
    echo "/proc/spl/kstat/zfs/arcstats not readable."
  fi
  echo

  if (( found == 1 )); then
    if [[ "$ZFS_DIRTY_SCOPE" == "pool" ]]; then
      add_finding "LOW" "ZFS context" "Pool-focused ZFS txg/ARC dirty-data context was captured; review this with block trace timing."
    else
      add_finding "LOW" "ZFS context" "All-pool ZFS txg/ARC dirty-data context was captured; this is noisy and should be used only for short runs."
    fi
  fi
}

capture_zfs_context() {
  local zfs_found=0 output

  echo "== ZFS wake context =="

  echo "-- ZFS workers from process list --"
  output="$(ps -eo pid,ppid,user,lstart,comm,args --sort=start_time 2>/dev/null \
    | grep -Ei 'z_wr|z_rd|z_metaslab|txg_sync|flush-zfs|arc_|zfs|zpool' \
    | grep -Evi "${SCRIPT_NAME_RE}|${SCRIPT_PATH_RE}|grep -Ei" \
    | tail -100 || true)"
  if [[ -n "$output" ]]; then
    echo "$output"
    zfs_found=1
  else
    echo "No ZFS worker context found in process list."
  fi
  echo

  echo "-- zpool events for $POOL --"
  if zpool events -v >/tmp/hddwake-zpool-events.$$ 2>/dev/null; then
    grep -F "$POOL" /tmp/hddwake-zpool-events.$$ | tail -80 || true
    rm -f /tmp/hddwake-zpool-events.$$ 2>/dev/null || true
  else
    echo "zpool events unavailable or empty."
  fi
  echo

  echo "-- recent zpool history for $POOL --"
  zpool history "$POOL" 2>/dev/null | tail -80 || true
  echo

  capture_zfs_dirty_context || true

  if (( zfs_found == 1 )); then
    add_finding "MEDIUM" "ZFS" "ZFS workers were active around the wake. This shows the executor, but not necessarily the original caller."
  fi
}

trace_dir_path() {
  if [[ -d /sys/kernel/tracing ]]; then
    echo /sys/kernel/tracing
  elif [[ -d /sys/kernel/debug/tracing ]]; then
    echo /sys/kernel/debug/tracing
  else
    echo ""
  fi
}

start_block_trace() {
  (( BLOCK_TRACE == 1 )) || return 0

  local trace_dir
  trace_dir="$(trace_dir_path)"

  if [[ -z "$trace_dir" ]]; then
    log "BLOCK_TRACE=1 requested, but tracefs is not available."
    return 0
  fi

  mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true

  echo 0 > "$trace_dir/tracing_on" 2>/dev/null || true
  : > "$trace_dir/trace" 2>/dev/null || true

  echo 1 > "$trace_dir/events/block/block_rq_issue/enable" 2>/dev/null || true
  echo 1 > "$trace_dir/events/block/block_bio_queue/enable" 2>/dev/null || true
  echo 1 > "$trace_dir/tracing_on" 2>/dev/null || true

  log "BLOCK_TRACE enabled using $trace_dir."
}

capture_block_trace() {
  (( BLOCK_TRACE == 1 )) || return 0

  local triggered_mm_re="${1:-}"
  local monitored_mm_re="${2:-}"
  local trace_dir trace_file
  local all_block first_block triggered_block monitored_block tail_block

  trace_dir="$(trace_dir_path)"

  echo "== Block I/O trace snapshot =="
  if [[ -z "$trace_dir" || ! -r "$trace_dir/trace" ]]; then
    echo "tracefs not available or not readable."
    echo
    return 0
  fi

  trace_file="$(mktemp /tmp/hddwake-trace-snapshot.XXXXXX 2>/dev/null)"
  cat "$trace_dir/trace" > "$trace_file" 2>/dev/null || true

  echo "Trace source: $trace_dir/trace"
  echo "Triggered disk block-trace major,minor regex: ${triggered_mm_re:-none}"
  echo "Monitored disk block-trace major,minor regex: ${monitored_mm_re:-none}"
  echo

  echo "-- First block I/O lines in trace buffer --"
  first_block="$(grep -E 'block_rq_issue|block_bio_queue' "$trace_file" 2>/dev/null | head -"$BLOCK_TRACE_FIRST_LINES" || true)"
  if [[ -n "$first_block" ]]; then
    echo "$first_block"
  else
    echo "No block I/O lines found in trace buffer."
  fi
  echo

  echo "-- Block I/O lines matching initially triggered disk(s) --"
    if [[ -n "$triggered_mm_re" ]]; then
    triggered_block="$(
  grep -E "($triggered_mm_re)" "$trace_file" 2>/dev/null \
    | grep -E 'block_rq_issue|block_bio_queue' \
    | grep -Evi 'hdparm|hdd-wake|hddwake|block_rq_issue: [0-9]+,[0-9]+ N 0 \(\) 0 \+ 0' \
    | tail -"$BLOCK_TRACE_MATCH_LINES" || true
)"
	
    if [[ -n "$triggered_block" ]]; then
      echo "$triggered_block"
      add_finding "HIGH" "block trace" "Block trace contains I/O matching the initially triggered disk major:minor."
    else
      echo "No block I/O lines matched the initially triggered disk major:minor."
      add_finding "LOW" "block trace" "No block trace lines matched the initially triggered disk; captured I/O may be later pool activity or another disk."
    fi
  else
    echo "No triggered disk major:minor mapping available."
  fi
  echo

  echo "-- Block I/O lines matching any monitored pool disk --"
    if [[ -n "$monitored_mm_re" ]]; then
    monitored_block="$(
  grep -E "($monitored_mm_re)" "$trace_file" 2>/dev/null \
    | grep -E 'block_rq_issue|block_bio_queue' \
    | grep -Evi 'hdparm|hdd-wake|hddwake|block_rq_issue: [0-9]+,[0-9]+ N 0 \(\) 0 \+ 0' \
    | tail -"$BLOCK_TRACE_MATCH_LINES" || true
)"    
	if [[ -n "$monitored_block" ]]; then
      echo "$monitored_block"
    else
      echo "No block I/O lines matched monitored pool disks."
    fi
  else
    echo "No monitored disk major:minor mapping available."
  fi
  echo

  echo "-- Last block I/O lines in trace buffer --"
  tail_block="$(grep -E 'block_rq_issue|block_bio_queue' "$trace_file" 2>/dev/null | tail -"$BLOCK_TRACE_LINES" || true)"
  if [[ -n "$tail_block" ]]; then
    echo "$tail_block"

    if grep -Eiq 'smbd|samba' <<< "$tail_block"; then
      add_finding "HIGH" "block trace" "Block trace tail contains SMB/Samba near the wake."
    fi
    if grep -Eiq 'smartctl|smartd' <<< "$tail_block"; then
      add_finding "MEDIUM" "block trace" "Block trace tail contains SMART activity near the wake."
    fi
    if grep -Eiq 'middlewared' <<< "$tail_block"; then
      add_finding "MEDIUM" "block trace" "Block trace tail contains middlewared near the wake."
    fi
    if grep -Eiq 'z_wr|z_rd|txg_sync|flush-zfs|z_null_iss' <<< "$tail_block"; then
      add_finding "MEDIUM" "block trace" "Block trace tail contains ZFS kernel worker I/O near the wake."
    fi
  else
    echo "No block trace tail lines captured."
  fi
  echo

  rm -f "$trace_file" 2>/dev/null || true
}


record_event_index() {
  local wake_epoch="$1"
  local event_type="$2"
  local disks="$3"
  local event_file="$4"
  local previous_epoch previous_delta

  mkdir -p "$(dirname "$EVENT_INDEX")"

  previous_epoch="$(tail -n 1 "$EVENT_INDEX" 2>/dev/null | awk -F'\t' '{print $1}' || true)"

  if [[ "$previous_epoch" =~ ^[0-9]+$ ]]; then
    previous_delta=$((wake_epoch - previous_epoch))
  else
    previous_delta=""
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$wake_epoch" \
    "$(epoch_to_local "$wake_epoch")" \
    "$event_type" \
    "$previous_delta" \
    "$disks" \
    "$event_file" >> "$EVENT_INDEX"

  if [[ "$previous_delta" =~ ^[0-9]+$ ]]; then
    if (( previous_delta >= 5300 && previous_delta <= 5500 )); then
      add_finding "HIGH" "recurrence" "Wake interval is approximately 90 minutes (${previous_delta}s since previous event)."
    elif (( previous_delta >= 3500 && previous_delta <= 3700 )); then
      add_finding "MEDIUM" "recurrence" "Wake interval is approximately 60 minutes (${previous_delta}s since previous event)."
    fi
  fi
}

print_recurrence_analysis() {
  echo "== Recurrence analysis =="
  echo "Index: $EVENT_INDEX"

  if [[ ! -s "$EVENT_INDEX" ]]; then
    echo "No previous event index entries found."
    echo
    return 0
  fi

  tail -n "$RECURRENCE_LINES" "$EVENT_INDEX" 2>/dev/null \
    | awk -F'\t' '
        {
          delta = ($4 == "" ? "n/a" : $4 "s")
          printf "%s  %-28s since_previous=%-8s disks=%s\n", $2, $3, delta, $5
        }
      '
  echo
}

print_human_analysis() {
  echo "== Human-readable interpretation =="

  if (( ${#ANALYSIS_FINDINGS[@]} == 0 )); then
    echo "No single cause was proven. Treat the raw sections below as supporting evidence."
    echo
    return 0
  fi

  if printf '%s\n' "${ANALYSIS_FINDINGS[@]}" | grep -q '^HIGH|SMB|'; then
    echo "- SMB is a strong candidate because SMB activity or open SMB handles were present around the wake."
  fi

  if printf '%s\n' "${ANALYSIS_FINDINGS[@]}" | grep -q '^HIGH|recurrence|'; then
    echo "- The wake cadence is highly regular, which points toward a timer, polling cycle, middleware task, or scheduled client behaviour."
  fi

  if printf '%s\n' "${ANALYSIS_FINDINGS[@]}" | grep -q '|ZFS|'; then
    echo "- ZFS workers were active. This usually means ZFS executed I/O, but it may not be the original initiator."
  fi

  if printf '%s\n' "${ANALYSIS_FINDINGS[@]}" | grep -q '|SMART|'; then
    echo "- SMART or disk polling activity was seen. Check whether it appears before or after the wake timestamp."
  fi

  if printf '%s\n' "${ANALYSIS_FINDINGS[@]}" | grep -q '|middleware|'; then
    echo "- TrueNAS middleware/disk/reporting activity was seen around the wake."
  fi

  if printf '%s\n' "${ANALYSIS_FINDINGS[@]}" | grep -q '|logging|'; then
    echo "- Large syslog-ng/systemd-journal/auditd writes after wake are usually side-effects unless they precede the wake."
  fi

  echo "- The detection time is not the exact spin-up instant; the real trigger may be inside the previous poll interval."
  echo
}


capture_event() {
  local event_type="$1"
  shift

  local wake_epoch="$1"
  shift

  local wake_window_start="$1"
  shift

  local wake_window_end="$1"
  shift

  local timestamp readable_time wake_readable safe_pool safe_event disk_part event_file
  local triggered_mm_re monitored_mm_re
  local triggered=("$@")
  local item disk label
  local labels=()
  local tmpdir tmp_iostat tmp_io_delta tmp_corr tmp_smb tmp_smart tmp_zfs tmp_block
  local mount_path triggered_summary
  local _errexit_was_on=0
  local -a POOL_MOUNT_PATHS=()

  reset_analysis

  # Capture sections are deliberately best-effort. With set -e/pipefail enabled,
  # a harmless no-match grep, a transient /proc read failure, or a command that
  # exits non-zero can otherwise stop the whole long-running monitor and leave
  # hddwake-* scratch files behind.
  case "$-" in
    *e*) _errexit_was_on=1; set +e ;;
  esac

  tmpdir="$(mktemp -d /tmp/hddwake-event.XXXXXX 2>/dev/null)"
  if [[ -z "${tmpdir:-}" || ! -d "$tmpdir" ]]; then
    echo "ERROR: could not create temporary capture directory under /tmp" | tee -a "$MAINLOG"
    if (( _errexit_was_on == 1 )); then set -e; fi
    return 0
  fi

  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  readable_time="$(date '+%Y-%m-%d %H:%M:%S')"
  wake_readable="$(epoch_to_local "$wake_epoch")"

  safe_pool="$(safe_filename "$POOL")"
  safe_event="$(safe_filename "$event_type")"

  if [[ "$event_type" == "pool-wide wake" ]]; then
    disk_part="all-${#DISKS[@]}-disks"
  elif (( ${#triggered[@]} == 1 )); then
    IFS='|' read -r disk label <<< "${triggered[0]}"
    disk_part="$(safe_filename "$label")"
  elif (( ${#triggered[@]} > 1 )); then
    for item in "${triggered[@]}"; do
      IFS='|' read -r disk label <<< "$item"
      labels+=("$(safe_filename "$label")")
    done

    disk_part="${#triggered[@]}-initial-triggered-disks-$(IFS=_; echo "${labels[*]}")"
    disk_part="$(echo "$disk_part" | cut -c1-160)"
  else
    disk_part="unknown-disk"
  fi

  triggered_summary="$(printf '%s ' "${triggered[@]}" | sed -E 's/[|]/=/g; s/[[:space:]]+$//')"
  triggered_mm_re="$(major_minor_regex_from_triggered "${triggered[@]}")"
  monitored_mm_re="$(major_minor_regex_from_disks "${DISKS[@]}")"

  event_file="$EVENTDIR/${timestamp}_${safe_pool}_${safe_event}_${disk_part}.log"
  LAST_EVENT_FILE="$event_file"

  tmp_iostat="$tmpdir/zpool-iostat.log"
  tmp_io_delta="$tmpdir/process-io-delta.log"
  tmp_corr="$tmpdir/correlated-journal.log"
  tmp_smb="$tmpdir/smb-context.log"
  tmp_smart="$tmpdir/smart-context.log"
  tmp_zfs="$tmpdir/zfs-context.log"
  tmp_block="$tmpdir/block-trace.log"

  # Create the event file immediately. If a later capture section misbehaves,
  # the event path still exists and the monitor should keep running.
  : > "$event_file" 2>/dev/null || true

  # Capture early so evidence stays close to the detected wake event.
  {
    echo "== Immediate process I/O delta over ${PROCESS_IO_SAMPLE_SECONDS}s after wake detection =="
    process_io_delta_sample "$PROCESS_IO_SAMPLE_SECONDS" "$PROCESS_IO_LINES" || true
  } > "$tmp_io_delta" 2>&1
  analyze_process_io_delta "$tmp_io_delta" || true

  correlated_journal_window \
    "$wake_epoch" \
    "$RELEVANT_ACTIVITY_RE" \
    "$CORRELATION_BEFORE" \
    "$CORRELATION_AFTER" \
    "$CORRELATION_LINES" > "$tmp_corr" 2>&1
  analyze_correlated_journal "$tmp_corr" || true

  capture_smb_context "$wake_epoch" "$CORRELATION_BEFORE" "$CORRELATION_AFTER" > "$tmp_smb" 2>&1 || true
  capture_smart_context "$wake_epoch" "$CORRELATION_BEFORE" "$CORRELATION_AFTER" > "$tmp_smart" 2>&1 || true
  capture_zfs_context > "$tmp_zfs" 2>&1 || true
  capture_block_trace "$triggered_mm_re" "$monitored_mm_re" > "$tmp_block" 2>&1 || true

  record_event_index "$wake_epoch" "$event_type" "$triggered_summary" "$event_file" || true

  {
    echo
    echo "============================================================"
    echo "Wake event: $event_type"
    echo "Detected:   $readable_time"
    echo "ISO time:   $(date -Is)"
    echo "Wake time:  $wake_readable"
    echo "Wake epoch: $wake_epoch"
    echo "Pool:       $POOL"
    echo "Script:     $SCRIPT_PATH"
    echo "Log file:   $event_file"
    echo "============================================================"
    echo

    echo "Detection window:"
    echo "  Previous poll: $(epoch_to_local "$wake_window_start")"
    echo "  Current poll:  $(epoch_to_local "$wake_window_end")"
    echo "  Uncertainty:   $((wake_window_end - wake_window_start)) seconds"
    echo

    print_findings
    print_human_analysis
    print_recurrence_analysis

    echo "Capture settings:"
    echo "  PROFILE:                   $PROFILE"
    echo "  JOURNAL_LOOKBACK:          $JOURNAL_LOOKBACK"
    echo "  JOURNAL_LINES:             $JOURNAL_LINES"
    echo "  SUDO_LOOKBACK:             $SUDO_LOOKBACK"
    echo "  SUDO_LINES:                $SUDO_LINES"
    echo "  PROCESS_LINES:             $PROCESS_LINES"
    echo "  PROCESS_IO_LINES:          $PROCESS_IO_LINES"
    echo "  PROCESS_IO_SAMPLE_SECONDS: $PROCESS_IO_SAMPLE_SECONDS"
    echo "  PID_CONTEXT_COUNT:         $PID_CONTEXT_COUNT"
    echo "  ZPOOL_IOSTAT_INTERVAL:     $ZPOOL_IOSTAT_INTERVAL"
    echo "  ZPOOL_IOSTAT_COUNT:        $ZPOOL_IOSTAT_COUNT"
    echo "  CORRELATION_BEFORE:        $CORRELATION_BEFORE"
    echo "  CORRELATION_AFTER:         $CORRELATION_AFTER"
    echo "  CORRELATION_LINES:         $CORRELATION_LINES"
    echo "  BLOCK_TRACE:               $BLOCK_TRACE"
    echo "  BLOCK_TRACE_LINES:         $BLOCK_TRACE_LINES"
    echo "  BLOCK_TRACE_FIRST_LINES:   $BLOCK_TRACE_FIRST_LINES"
    echo "  BLOCK_TRACE_MATCH_LINES:   $BLOCK_TRACE_MATCH_LINES"
    echo "  ZFS_DIRTY_CONTEXT:         $ZFS_DIRTY_CONTEXT"
    echo "  ZFS_DIRTY_SCOPE:           $ZFS_DIRTY_SCOPE"
    echo "  ZFS_TXG_LINES:             $ZFS_TXG_LINES"
    echo "  ZFS_ARC_LINES:             $ZFS_ARC_LINES"
    echo "  RECURRENCE_LINES:          $RECURRENCE_LINES"
    echo "  EVENT_COOLDOWN:            $EVENT_COOLDOWN"
    echo "  ROTATIONAL_ONLY:           $ROTATIONAL_ONLY"
    echo "  ALLOW_LOGDIR_ON_POOL:      $ALLOW_LOGDIR_ON_POOL"
    echo

    echo "Initial triggered disks detected as standby -> active/idle:"
    if (( ${#triggered[@]} > 0 )); then
      for item in "${triggered[@]}"; do
        IFS='|' read -r disk label <<< "$item"
        printf "  %-12s %-8s %s\n" "$disk" "$(disk_major_minor "$disk")" "$label"
      done
    else
      echo "  unknown"
    fi
    echo
    print_monitored_major_minor_map

    echo "== Current disk power states =="
    for d in "${DISKS[@]}"; do
      printf "%-12s %-70s %s\n" "$d" "$(short_disk_label "$d")" "$(power_state "$d")"
    done
    echo

    cat "$tmp_io_delta"
    echo

    print_pid_context_from_delta "$PID_CONTEXT_COUNT"

    cat "$tmp_smb"
    cat "$tmp_smart"
    cat "$tmp_zfs"
    cat "$tmp_block"

    echo "== Pool disk mapping =="
    for d in "${DISKS[@]}"; do
      echo "--- $d / $(short_disk_label "$d") ---"
      lsblk -o NAME,KNAME,MAJ:MIN,TYPE,SIZE,ROTA,MODEL,SERIAL,WWN,PARTUUID,MOUNTPOINTS "$d" 2>/dev/null || true
      echo

      if command -v udevadm >/dev/null 2>&1; then
        echo "udev identity:"
        udevadm info --query=property --name="$d" 2>/dev/null \
          | grep -E '^(ID_MODEL=|ID_SERIAL=|ID_SERIAL_SHORT=|ID_WWN=|ID_PART_TABLE_UUID=)' || true
        echo
      fi
    done
    echo

    echo "== zpool status =="
    zpool status -P "$POOL" || true
    echo

    echo "== zpool iostat fresh interval sample =="
    if zpool iostat -v -y "$POOL" "$ZPOOL_IOSTAT_INTERVAL" "$ZPOOL_IOSTAT_COUNT" > "$tmp_iostat" 2>&1; then
      cat "$tmp_iostat"
    else
      echo "zpool iostat -y not supported on this system; falling back to standard output."
      zpool iostat -v "$POOL" "$ZPOOL_IOSTAT_INTERVAL" "$ZPOOL_IOSTAT_COUNT" || true
    fi
    rm -f "$tmp_iostat"
    echo

    echo "== Correlated journal activity around wake event =="
    cat "$tmp_corr"
    echo

    echo "== Recent journal entries since $JOURNAL_LOOKBACK, excluding this monitor script =="
    journal_filtered \
      "$JOURNAL_LOOKBACK" \
      "$RELEVANT_ACTIVITY_RE" \
      "$JOURNAL_LINES"
    echo

    echo "== Cron hourly contents =="
    ls -la /etc/cron.hourly 2>/dev/null || true
    echo

    echo "== Recent sudo activity since $SUDO_LOOKBACK, excluding this monitor script =="
    journal_filtered \
      "$SUDO_LOOKBACK" \
      'sudo|COMMAND|pam_unix' \
      "$SUDO_LINES"
    echo

    echo "== Recently started processes, excluding this monitor script =="
    ps -eo pid,ppid,user,lstart,comm,args --sort=start_time 2>/dev/null \
      | grep -Evi "${SCRIPT_NAME_RE}|${SCRIPT_PATH_RE}|hdparm -C|readlink -f /dev/disk/by-id|basename /dev/disk/by-id|tee -a .*/hdd-wake|ps -eo pid,ppid,user,lstart,comm,args|tail -[0-9]+|sleep ${INTERVAL}$" \
      | tail -"$PROCESS_LINES" || true
    echo

    echo "== Relevant system timers =="
    systemctl list-timers --all --no-pager 2>/dev/null \
      | grep -Ei "$RELEVANT_ACTIVITY_RE" || true
    echo

    echo "== Open files/users under mounted datasets for pool $POOL =="
    echo "Note: nested dataset paths may show the same open file more than once."
    echo

    mapfile -t POOL_MOUNT_PATHS < <(pool_mount_paths)

    if (( ${#POOL_MOUNT_PATHS[@]} == 0 )); then
      echo "No mounted dataset paths discovered for pool $POOL."
    else
      for mount_path in "${POOL_MOUNT_PATHS[@]}"; do
        echo "--- $mount_path ---"

        if command -v lsof >/dev/null 2>&1; then
          lsof -nP 2>/dev/null | grep -F "$mount_path" | head -200 || true
        elif command -v fuser >/dev/null 2>&1; then
          fuser -vm "$mount_path" 2>/dev/null || true
        else
          echo "Neither lsof nor fuser is installed."
        fi

        echo
      done
    fi

    echo "== Processes by total read/write bytes since boot =="
    process_io_snapshot "$PROCESS_IO_LINES" || true
    echo

    echo "============================================================"
    echo "End wake event capture"
    echo "============================================================"
    echo

  } | tee -a "$event_file"

  rm -rf "$tmpdir" 2>/dev/null || true

  log "Captured wake event: $event_file"

  if (( _errexit_was_on == 1 )); then
    set -e
  fi

  return 0
}

mapfile -t DISKS < <(pool_disks)

if (( ${#DISKS[@]} == 0 )); then
  echo "ERROR: no disks discovered for pool: $POOL"
  if [[ "$ROTATIONAL_ONLY" == "1" ]]; then
    echo "Hint: ROTATIONAL_ONLY=1 is enabled. If this pool only has SSD/NVMe devices, retry with ROTATIONAL_ONLY=0."
  fi
  exit 1
fi

log "Monitoring pool: $POOL"
log "Profile: $PROFILE - $PROFILE_DESCRIPTION"
log "Log directory: $LOGDIR"
log "Rotational-only mode: $ROTATIONAL_ONLY"
log "Allow LOGDIR on monitored pool: $ALLOW_LOGDIR_ON_POOL"
log "Main log: $MAINLOG"
log "Interval: $INTERVAL seconds"
log "Event cooldown: $EVENT_COOLDOWN seconds"
log "Script path: $SCRIPT_PATH"
log "Dynamic self-noise filter: enabled"
log "Initial baseline will not be treated as a wake event; monitoring begins from the next poll."
log "Capture settings:"
log "  JOURNAL_LOOKBACK:          $JOURNAL_LOOKBACK"
log "  JOURNAL_LINES:             $JOURNAL_LINES"
log "  SUDO_LOOKBACK:             $SUDO_LOOKBACK"
log "  SUDO_LINES:                $SUDO_LINES"
log "  PROCESS_LINES:             $PROCESS_LINES"
log "  PROCESS_IO_LINES:          $PROCESS_IO_LINES"
log "  PROCESS_IO_SAMPLE_SECONDS: $PROCESS_IO_SAMPLE_SECONDS"
log "  ZPOOL_IOSTAT_INTERVAL:     $ZPOOL_IOSTAT_INTERVAL"
log "  ZPOOL_IOSTAT_COUNT:        $ZPOOL_IOSTAT_COUNT"
log "  CORRELATION_BEFORE:        $CORRELATION_BEFORE"
log "  CORRELATION_AFTER:         $CORRELATION_AFTER"
log "  CORRELATION_LINES:         $CORRELATION_LINES"
log "  PID_CONTEXT_COUNT:         $PID_CONTEXT_COUNT"
log "  BLOCK_TRACE:               $BLOCK_TRACE"
log "  BLOCK_TRACE_LINES:         $BLOCK_TRACE_LINES"
log "  BLOCK_TRACE_FIRST_LINES:   $BLOCK_TRACE_FIRST_LINES"
log "  BLOCK_TRACE_MATCH_LINES:   $BLOCK_TRACE_MATCH_LINES"
log "  ZFS_DIRTY_CONTEXT:         $ZFS_DIRTY_CONTEXT"
log "  ZFS_DIRTY_SCOPE:           $ZFS_DIRTY_SCOPE"
log "  ZFS_TXG_LINES:             $ZFS_TXG_LINES"
log "  ZFS_ARC_LINES:             $ZFS_ARC_LINES"
log "  RECURRENCE_LINES:          $RECURRENCE_LINES"
log "  EVENT_INDEX:               $EVENT_INDEX"
log "  ROTATIONAL_ONLY:           $ROTATIONAL_ONLY"
log "  ALLOW_LOGDIR_ON_POOL:      $ALLOW_LOGDIR_ON_POOL"
log "Discovered disks:"

for d in "${DISKS[@]}"; do
  log "  $d  $(short_disk_label "$d")"
done

start_block_trace

# Must be associative because disk names are /dev/sda, /dev/sdb, etc.
# Without declare -A, Bash treats /dev/sda as an invalid numeric index.
declare -A PREV
LAST_EVENT_EPOCH=0
LAST_EVENT_FILE=""
LAST_POLL_EPOCH=0

while true; do
  poll_epoch="$(date +%s)"
  poll_iso="$(date -Is)"
  woke=()
  active_count=0
  standby_count=0

  main_out ""
  main_out "===== $poll_iso ====="

  for d in "${DISKS[@]}"; do
    state="$(power_state "$d")"
    label="$(short_disk_label "$d")"

    main_printf "%-12s %-70s %s\n" "$d" "$label" "$state"

    if is_active "$state"; then
      ((active_count++)) || true
    elif is_standby "$state"; then
      ((standby_count++)) || true
    fi

    if [[ -z "${PREV[$d]:-}" ]]; then
      main_out "  baseline: $d $label is $state"
    else
      if [[ "${PREV[$d]}" != "$state" ]]; then
        main_out "  state change: $d $label ${PREV[$d]} -> $state"
      fi

      if is_standby "${PREV[$d]}" && is_active "$state"; then
        woke+=("$d|$label")
      fi
    fi

    PREV["$d"]="$state"
  done

  if (( standby_count == ${#DISKS[@]} )); then
    main_out "Pool state: all monitored disks are standby/sleeping"
  elif (( active_count == ${#DISKS[@]} )); then
    main_out "Pool state: all monitored disks are active/idle"
  else
    main_out "Pool state: mixed; active=$active_count standby=$standby_count total=${#DISKS[@]}"
  fi

  if (( ${#woke[@]} > 0 )); then
    wake_epoch="$poll_epoch"

    if (( LAST_POLL_EPOCH > 0 )); then
      wake_window_start="$LAST_POLL_EPOCH"
    else
      wake_window_start="$wake_epoch"
    fi
    wake_window_end="$wake_epoch"

  if (( EVENT_COOLDOWN > 0 && wake_epoch - LAST_EVENT_EPOCH < EVENT_COOLDOWN )); then
    log "Wake detected but skipped because it is within EVENT_COOLDOWN=${EVENT_COOLDOWN}s."

    if [[ -n "${LAST_EVENT_FILE:-}" && -f "$LAST_EVENT_FILE" ]]; then
      {
        echo
        echo "== Additional wake transition during EVENT_COOLDOWN =="
        echo "Detected:   $(date '+%Y-%m-%d %H:%M:%S')"
        echo "ISO time:   $(date -Is)"
        echo "Wake epoch: $wake_epoch"
        echo "Previous poll: $(epoch_to_local "$wake_window_start")"
        echo "Current poll:  $(epoch_to_local "$wake_window_end")"
        echo "Reason:     skipped new capture because EVENT_COOLDOWN=${EVENT_COOLDOWN}s"
        echo
        echo "Additional disks detected as standby -> active/idle:"
        for item in "${woke[@]}"; do
          IFS='|' read -r disk label <<< "$item"
          printf "  %-12s %s\n" "$disk" "$label"
        done
        echo
        echo "Current disk power states after additional wake:"
        for d in "${DISKS[@]}"; do
          printf "%-12s %-70s %s\n" "$d" "$(short_disk_label "$d")" "$(power_state "$d")"
        done
        echo
      } >> "$LAST_EVENT_FILE"
    fi
  else

      LAST_EVENT_EPOCH="$wake_epoch"

      if (( ${#woke[@]} == ${#DISKS[@]} )); then
        log "Detected pool-wide wake from standby at epoch $wake_epoch."
        capture_event "pool-wide wake" "$wake_epoch" "$wake_window_start" "$wake_window_end" "${woke[@]}"
      elif (( active_count == ${#DISKS[@]} )); then
        log "Detected partial disk wake; all disks are now active at epoch $wake_epoch."
        capture_event "partial wake - pool now active" "$wake_epoch" "$wake_window_start" "$wake_window_end" "${woke[@]}"
      else
        log "Detected partial disk wake at epoch $wake_epoch."
        capture_event "partial disk wake" "$wake_epoch" "$wake_window_start" "$wake_window_end" "${woke[@]}"
      fi
    fi
  fi

  LAST_POLL_EPOCH="$poll_epoch"
  sleep "$INTERVAL"
done
