#!/usr/bin/env bash

set -euo pipefail

# This script addresses a "feature" where HDDs are constanly woken from standby for various system default checks every 90 mins or so.
#
# This script creates a persistent overlay for selected TrueNas SCALE middleware files.
# It copies the original files into a user-defined overlay directory, applies the spindown.patch
# to the new overlay copies, and then bind mounts these patched files over the originals.
#
# This scipt allows TrueNas to run the patched middleware files whilst leaving the underlying orignal 
# read-only system files untouched.
#
# The script can also generate the required TrueNaS PREINIT commands so the overlay
# bind mounts are automatically restored after boot.

# Instructions
#
# 1. Save the script, for example:
#      /home/truenas_admin/spindown-fix.sh

# 2. Make it executable:
#      chmod +x /home/truenas_admin/spindown-fix.sh
#
# 3. Confirm the patch file exists at the configurable patch location below:
    PATCH="/home/truenas_admin/spindown.patch" # Download patch at https://forums.truenas.com/uploads/short-url/lz8ZYr42jE7608gFx5TVQG2reex.txt
#     
# 4. Choose a TrueNas location/dataset where tyou want to create your overlay, keep this off spinning disks
    OVERLAY="/mnt/tank/overlay"

### Now we can run the script! ###
# 5. To create the new overlay copies of the selected TrueNas middleware files:
#      bash spindown-fix.sh copy
#
# 6. Next test whether the patch will apply cleanly and there are no issues:
#      bash spindown-fix.sh dry-run   # if all is good, continue to next step
#
# 7. Now we can apply the patch to the new overlay file copies. This will also automatically create and mount the new overlay bind mounts
#      bash spindown-fix.sh apply
#
# 8. Check the current overlay path and bind-mount status:
#      bash spindown-fix.sh status
#
# 9. To make the bind mounts persistent after reboot, genernate the necessesay PREINIT commands 
# add these under System | Advanced Init/Shutdown scripts
# bash spindown-fix.sh init-commmands

# Before updating TrueNas, to avoid potential issues you should set everything back to standard 
#   a. Disabling the PREINIT scripts and unmount the overaly
#   b. bash spindown-fix.sh unmount | or reboot
#   After a TrueNas update, re-run copy and dry-run before applying the patch again.
#
# Script workflow:#
# - Run copy before dry-run or apply.
# - Run dry-run before apply to confirm the patch matches the current files.
# - The original read-only TrueNas system files are not modified.
# - The patched versions are kept under the configured OVERLAY path.

MODE="${1:-}"

FILES=(
  "/usr/lib/python3/dist-packages/middlewared/plugins/pool_/dataset_encryption_info.py"
  "/usr/lib/python3/dist-packages/middlewared/utils/disks_/disk_class.py"
  "/usr/lib/python3/dist-packages/middlewared/alert/source/smart.py"
  "/usr/lib/python3/dist-packages/middlewared/plugins/disk.py"
)

SCRIPT_PATH="$(readlink -f "$0")"

usage() {
  echo "Usage: $0 <copy|dry-run|apply|mount|unmount|status|init-commands>"
}

clear 

show_help() {
  usage
  echo
  echo "Arguments:"
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
  echo "  init-commands  Print TrueNas PREINIT commands for persistent bind mounts."
  echo
  echo "Typical workflow:"
  echo "  sudo bash $0 copy"
  echo "  sudo bash $0 dry-run"
  echo "  sudo bash $0 apply"
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

print_init_commands() {
  echo
  echo "Add these commands to TruNAS GUI PREINIT Scripts."
  echo
  echo "Type: Command"
  echo "When: PREINIT"
  echo "Enabled: Yes"
  echo
  echo "Commands:"
  echo

  for f in "${FILES[@]}"; do
    echo "mount --bind \"$OVERLAY$f\" \"$f\""
  done
  echo

}

if [[ -z "$MODE" ]]; then
  show_help
  exit 0
fi

case "$MODE" in
  copy|dry-run|apply|mount|unmount|status|init-commands)
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

    echo "Restarting middlewared..."
    systemctl restart middlewared

    echo
    echo "Patch applied, overlay files bind-mounted, and middlewared restarted."
    echo
    echo "Next step:"
    echo "Run this to create the PREINIT overlay startup commands for the TrueNas GUI:"
    echo "  sudo bash \"$SCRIPT_PATH\" init-commands"
    ;;

  mount)
    require_root "$@"
    check_overlay_files_exist

    mount_overlay_files

    echo "Restarting middlewared..."
    systemctl restart middlewared

    echo
    echo "Overlay files bind-mounted and middlewared restarted."
    ;;

  unmount)
    require_root "$@"

    unmount_overlay_files

    echo "Restarting middlewared..."
    systemctl restart middlewared

    echo
    echo "Bind mounts removed and middlewared restarted."
    ;;

  status)
    show_status
    ;;

  init-commands)
    print_init_commands
    ;;
esac
