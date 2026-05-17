#!/usr/bin/env bash

set -euo pipefail

clear

MOUNTPOINT="/mnt/external"

get_usb_sources() {
  {
    for link in /dev/disk/by-id/usb-*-part*; do
      [[ -e "$link" ]] || continue
      readlink -f "$link"
    done

    lsblk -rnpo NAME,TYPE,TRAN 2>/dev/null | awk '$2=="part" && $3=="usb" {print $1}'
  } | sort -u
}

show_sources() {
  mapfile -t SOURCES < <(get_usb_sources)

  if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "No USB partitions found."
    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,TRAN
    return 1
  fi

  echo "Available USB partitions:"
  echo

  for i in "${!SOURCES[@]}"; do
    dev="${SOURCES[$i]}"
    printf "%2d) %s\n" "$((i+1))" "$dev"
    lsblk -no SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$dev" | sed 's/^/    /'
    echo
  done
}

choose_source() {
  mapfile -t SOURCES < <(get_usb_sources)

  if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "No USB partitions found." >&2
    echo >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,TRAN >&2
    exit 1
  fi

  echo "Available USB partitions:" >&2
  echo >&2

  for i in "${!SOURCES[@]}"; do
    dev="${SOURCES[$i]}"
    printf "%2d) %s\n" "$((i+1))" "$dev" >&2
    lsblk -no SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL "$dev" | sed 's/^/    /' >&2
    echo >&2
  done

  read -rp "Select device number to mount: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SOURCES[@]} )); then
    echo "Invalid choice." >&2
    exit 1
  fi

  echo "${SOURCES[$((choice-1))]}"
}

make_mount_world_writable() {
  echo "Setting $MOUNTPOINT to read/write for all users..."
  sudo chmod 0777 "$MOUNTPOINT"
}

set_apps_root_access() {
  if findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
    echo "Changing ownership of all files and folders under $MOUNTPOINT to apps:root..."
    sudo find "$MOUNTPOINT" -xdev -exec chown -h apps:root {} +

    echo "Making all files and folders read/write/execute for everyone..."
    sudo find "$MOUNTPOINT" -xdev ! -type l -exec chmod 0777 {} +

    echo "Ownership changed to apps:root and permissions changed to 0777."
  fi
}

case "${1:-}" in
  mount)
    if findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
      echo "$MOUNTPOINT is already mounted:"
      findmnt "$MOUNTPOINT"
      exit 0
    fi

    DEVICE="$(choose_source)"

    sudo mkdir -p "$MOUNTPOINT"

    echo "Mounting $DEVICE at $MOUNTPOINT..."
    sudo mount -o rw "$DEVICE" "$MOUNTPOINT"

    make_mount_world_writable
    set_apps_root_access

    echo "Mounted $DEVICE at $MOUNTPOINT"
    ;;

  unmount|umount)
    cd /

    if ! findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
      echo "$MOUNTPOINT is not mounted."
      exit 0
    fi

    set_apps_root_access

    sync

    if sudo umount "$MOUNTPOINT"; then
      echo "Unmounted $MOUNTPOINT"
    else
      echo
      echo "Unmount failed because $MOUNTPOINT is busy."
      echo
      echo "Processes using it:"
      sudo fuser -vm "$MOUNTPOINT" || true
      echo
      echo "Close anything using the mount, then run:"
      echo "  external unmount"
      echo
      echo "Or use lazy unmount:"
      echo "  external unmount-lazy"
      exit 1
    fi
    ;;

  unmount-lazy|umount-lazy)
    cd /

    if ! findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
      echo "$MOUNTPOINT is not mounted."
      exit 0
    fi

    set_apps_root_access

    sync

    sudo umount -l "$MOUNTPOINT"
    echo "Lazy unmounted $MOUNTPOINT"
    ;;

fix)
  if ! findmnt -rn "$MOUNTPOINT" >/dev/null 2>&1; then
    echo "$MOUNTPOINT is not mounted."
    exit 1
  fi

  set_apps_root_access
  sync
  ;;

  status|list)
    show_sources || true
    echo "Current mount status:"
    findmnt "$MOUNTPOINT" || echo "$MOUNTPOINT is not mounted."
    ;;

  *)
    echo "Usage:"
    echo "  $0 list"
    echo "  $0 status"
    echo "  $0 mount"
    echo "  $0 unmount"
    echo "  $0 unmount-lazy"
    echo "  $0 fix"
    echo
    exit 1
    ;;
esac
