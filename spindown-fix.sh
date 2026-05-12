#!/usr/bin/env bash

set -Eeuo pipefail

clear

# TrueNAS SCALE spindown patch helper.
#
# This script creates a persistent overlay for selected TrueNAS SCALE middleware files.
# It copies the original files into a user-defined overlay directory, applies the
# spindown patch to those overlay copies, and bind-mounts the patched files over
# the original system paths.
#
# This lets TrueNAS run the patched middleware files while leaving the underlying
# read-only system files untouched.
#
# The script can also generate a single boot helper 'script.spindown-overlay-mount.sh'
# Add that helper as a TrueNAS Post Init command so the overlay is mounted at boot 
# and middlewared is restarted after the bind mounts are in place.

MODE="${1:-}"

# Location where patched overlay copies will be stored.
# Keep this off spinning disks if possible.
OVERLAY="/mnt/tank_pool/overlay"

# Resolve the real path of this script.
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Patch file must be in the same directory as this script.
PATCH="$SCRIPT_DIR/spindown.patch.fixed"

# Boot helper script will also be generated in the same directory as this script.
BOOT_SCRIPT="$SCRIPT_DIR/spindown-overlay-mount.sh"

FILES=(
  "/usr/lib/python3/dist-packages/middlewared/plugins/pool_/dataset_encryption_info.py"
  "/usr/lib/python3/dist-packages/middlewared/utils/disks_/disk_class.py"
  "/usr/lib/python3/dist-packages/middlewared/alert/source/smart.py"
  "/usr/lib/python3/dist-packages/middlewared/plugins/disk.py"
)

usage() {
  echo "Usage: $0 <copy|dry-run|apply|mount|unmount|status|boot-script|init-command>"
}

show_help() {
  usage
  echo
  echo "Arguments:"
  echo
  echo "  copy           Unmount existing bind mounts, then copy fresh source files"
  echo "                 into the overlay. Does not patch, mount, or restart middlewared."
  echo
  echo "  dry-run        Test the patch against the existing overlay files only."
  echo "                 Does not copy files, bind-mount files, or restart middlewared."
  echo
  echo "  apply          Apply the patch to the existing overlay files,"
  echo "                 bind-mount the overlay files, and restart middlewared."
  echo
  echo "  mount          Bind-mount the existing overlay files and restart middlewared."
  echo
  echo "  unmount        Remove the bind mounts and restart middlewared."
  echo
  echo "  status         Show whether overlay files exist and whether each file"
  echo "                 is currently bind-mounted."
  echo
  echo "  boot-script    Generate a single boot helper script and print the one"
  echo "                 TrueNAS Post Init command needed to run it at boot."
  echo
  echo "  init-command   Show startup commmands for boot-script."
  echo
  echo "Typical workflow:"
  echo "  sudo bash $0 copy"
  echo "  sudo bash $0 dry-run"
  echo "  sudo bash $0 apply"
  echo "  sudo bash $0 boot-script"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script needs sudo/root permission."
    echo "Re-running with sudo now..."
    exec sudo -- bash "$SCRIPT_PATH" "$@"
  fi
}

check_patch() {
  if [[ ! -f "$PATCH" ]]; then
    echo "ERROR: Patch file not found:"
    echo "  $PATCH"
    exit 1
  fi
}

is_bind_mounted() {
  findmnt -rn --mountpoint "$1" >/dev/null 2>&1
}

restart_middleware() {
  echo "Restarting middlewared..."
  systemctl restart middlewared.service
}

check_overlay_files_exist() {
  local missing="no"

  for f in "${FILES[@]}"; do
    local overlay_file="$OVERLAY$f"

    if [[ ! -f "$overlay_file" ]]; then
      echo "ERROR: Overlay file missing:"
      echo "  $overlay_file"
      missing="yes"
    fi
  done

  if [[ "$missing" == "yes" ]]; then
    echo
    echo "Run this first:"
    echo "  sudo bash \"$SCRIPT_PATH\" copy"
    exit 1
  fi
}

unmount_overlay_files() {
  echo "Removing existing bind mounts..."
  echo

  for f in "${FILES[@]}"; do
    if is_bind_mounted "$f"; then
      echo "Unmounting:"
      echo "  $f"
      umount "$f"
    else
      echo "Not bind-mounted, skipping:"
      echo "  $f"
    fi

    echo
  done
}

copy_fresh_overlay_files() {
  echo "Copying fresh files into overlay..."
  echo

  for f in "${FILES[@]}"; do
    local overlay_file="$OVERLAY$f"
    local overlay_dir
    overlay_dir="$OVERLAY$(dirname "$f")"

    if [[ ! -f "$f" ]]; then
      echo "ERROR: Source file does not exist:"
      echo "  $f"
      exit 1
    fi

    mkdir -p "$overlay_dir"

    if [[ -f "$overlay_file" ]]; then
      echo "Replacing existing overlay file:"
      echo "  $overlay_file"
      rm -f "$overlay_file"
    fi

    echo "Copying:"
    echo "  $f"
    echo "  -> $overlay_file"

    cp -a "$f" "$overlay_file"

    echo
  done
}

mount_overlay_files() {
  echo "Creating bind mounts..."
  echo

  for f in "${FILES[@]}"; do
    local overlay_file="$OVERLAY$f"

    if [[ ! -f "$overlay_file" ]]; then
      echo "ERROR: Overlay file does not exist:"
      echo "  $overlay_file"
      echo
      echo "Run this first:"
      echo "  sudo bash \"$SCRIPT_PATH\" copy"
      exit 1
    fi

    if is_bind_mounted "$f"; then
      echo "Existing bind mount found, unmounting first:"
      echo "  $f"
      umount "$f"
    fi

    echo "Bind mounting:"
    echo "  $overlay_file"
    echo "  -> $f"

    mount --bind "$overlay_file" "$f"

    if ! is_bind_mounted "$f"; then
      echo "ERROR: Mount verification failed:"
      echo "  $f"
      exit 1
    fi

    echo
  done
}

show_status() {
  echo "Overlay status:"
  echo

  for f in "${FILES[@]}"; do
    local overlay_file="$OVERLAY$f"

    echo "File:"
    echo "  $f"

    if [[ -f "$overlay_file" ]]; then
      echo "Overlay:"
      echo "  present: $overlay_file"
    else
      echo "Overlay:"
      echo "  missing: $overlay_file"
    fi

    if is_bind_mounted "$f"; then
      echo "Mount:"
      findmnt -rn --mountpoint "$f" -o TARGET,SOURCE,FSTYPE,OPTIONS
    else
      echo "Mount:"
      echo "  not bind-mounted"
    fi

    echo
  done
}

generate_boot_script() {
  require_root "$@"
  check_overlay_files_exist

  mkdir -p "$(dirname "$BOOT_SCRIPT")"

  {
    cat <<'BOOT_HEADER'
#!/usr/bin/env bash

set -Eeuo pipefail

TAG="spindown-overlay"
BOOT_HEADER

    printf 'OVERLAY=%q\n' "$OVERLAY"

    echo 'FILES=(' 
    for f in "${FILES[@]}"; do
      printf '  %q\n' "$f"
    done
    echo ')'

    cat <<'BOOT_BODY'

log() {
  echo "[$TAG] $*"
  logger -t "$TAG" -- "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

is_bind_mounted() {
  findmnt -rn --mountpoint "$1" >/dev/null 2>&1
}

[[ "$(id -u)" -eq 0 ]] || fail "This script must be run as root."

log "Starting TrueNAS spindown overlay boot mount"

for f in "${FILES[@]}"; do
  overlay_file="$OVERLAY$f"

  [[ -f "$overlay_file" ]] || fail "Missing overlay file: $overlay_file"
  [[ -f "$f" ]] || fail "Missing system target file: $f"
done

for f in "${FILES[@]}"; do
  overlay_file="$OVERLAY$f"

  if is_bind_mounted "$f"; then
    log "Existing bind mount found, unmounting first: $f"
    umount "$f" || fail "Could not unmount existing bind mount: $f"
  fi

  log "Bind mounting $overlay_file -> $f"
  mount --bind "$overlay_file" "$f" || fail "Bind mount failed: $f"

  is_bind_mounted "$f" || fail "Mount verification failed: $f"
done

log "All overlay files mounted successfully"

log "Restarting middlewared so patched Python files are imported"
systemctl restart middlewared.service || fail "Failed to restart middlewared"

if systemctl is-active --quiet middlewared.service; then
  log "middlewared restarted successfully"
else
  systemctl status middlewared.service --no-pager || true
  fail "middlewared is not active after restart"
fi

log "Spindown overlay boot mount complete"
BOOT_BODY
  } > "$BOOT_SCRIPT"

  chmod 755 "$BOOT_SCRIPT"

  echo
  echo "Generated boot helper script:"
  echo "  $BOOT_SCRIPT"
  echo
  echo "Add this single entry in the TrueNAS GUI:"
  echo
  echo "Type: Command"
  echo "When: Post Init"
  echo "Enabled: Yes"
  echo "Timeout: 60 seconds or higher"
  echo
  echo "Command:"
  printf '  bash %q\n' "$BOOT_SCRIPT"
  echo
}

if [[ -z "$MODE" ]]; then
  show_help
  exit 0
fi

case "$MODE" in
  copy|dry-run|apply|mount|unmount|status|boot-script|init-command)
    ;;
  *)
    echo "ERROR: Invalid argument: $MODE"
    echo
    show_help
    exit 1
    ;;
esac

case "$MODE" in
  copy)
    require_root "$@"

    # Important:
    # Unmount first so the copied files come from the real OS files,
    # not from an older overlay that is currently bind-mounted.
    unmount_overlay_files
    copy_fresh_overlay_files

    echo
    echo "Fresh files copied into overlay."
    echo "No patch was applied."
    echo "No bind mounts were created."
    echo
    echo "Next step:"
    echo "  sudo bash \"$SCRIPT_PATH\" dry-run"
    ;;

  dry-run)
    require_root "$@"
    check_patch
    check_overlay_files_exist

    echo "Running patch dry run against existing overlay files only..."
    echo

    patch --dry-run --verbose -N -d "$OVERLAY" -p1 -i "$PATCH"

    echo
    echo "Dry run complete."
    echo "No files were copied."
    echo "No bind mounts were changed."
    echo
    echo "Next step:"
    echo "  sudo bash \"$SCRIPT_PATH\" apply"
    ;;

  apply)
    require_root "$@"
    check_patch
    check_overlay_files_exist

    echo "Applying patch to existing overlay files..."
    echo

    patch --verbose -N -d "$OVERLAY" -p1 -i "$PATCH"

    echo
    mount_overlay_files

    restart_middleware

    echo
    echo "Patch applied, overlay files bind-mounted, and middlewared restarted."
    echo
    echo "Next step:"
    echo "Generate the single Post Init boot helper command:"
    echo "  sudo bash \"$SCRIPT_PATH\" boot-script"
    ;;

  mount)
    require_root "$@"
    check_overlay_files_exist

    mount_overlay_files
    restart_middleware

    echo
    echo "Overlay files bind-mounted and middlewared restarted."
    ;;

  unmount)
    require_root "$@"

    unmount_overlay_files
    restart_middleware

    echo
    echo "Bind mounts removed and middlewared restarted."
    ;;

  status)
    show_status
    ;;

  boot-script|init-command)
    generate_boot_script "$@"
    ;;
esac
