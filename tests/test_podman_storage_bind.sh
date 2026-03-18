#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$ROOT_DIR/package/podman-storage-bind"
MAKEFILE="$PKG_DIR/Makefile"
INIT_SCRIPT="$PKG_DIR/files/podman-storage-bind.init"
UCI_DEFAULTS="$PKG_DIR/files/99-podman-storage-bind"
GENERAL_CONFIG="$ROOT_DIR/Config/GENERAL.txt"

[ -f "$MAKEFILE" ] || { echo "missing package Makefile"; exit 1; }
[ -f "$INIT_SCRIPT" ] || { echo "missing init script"; exit 1; }
[ -f "$UCI_DEFAULTS" ] || { echo "missing uci-defaults helper"; exit 1; }

grep -q 'CONFIG_PACKAGE_podman-storage-bind=y' "$GENERAL_CONFIG" || {
  echo "missing podman-storage-bind config toggle"
  exit 1
}

grep -q '/mnt/emmc/podman_storage' "$MAKEFILE" || {
  echo "missing podman storage source directory"
  exit 1
}

for path in \
  '/mnt/emmc' \
  '/mnt/emmc/bin' \
  '/mnt/emmc/project' \
  '/mnt/emmc/share' \
  '/mnt/emmc/podman_storage' \
  '/var/lib/containers/storage'
do
  grep -q "$path" "$MAKEFILE" || {
    echo "missing install path: $path"
    exit 1
  }
done

grep -q '/etc/init.d/podman-storage-bind enable' "$UCI_DEFAULTS" || {
  echo "missing init enable command"
  exit 1
}

grep -q 'mount --bind /mnt/emmc/podman_storage /var/lib/containers/storage' "$INIT_SCRIPT" || {
  echo "missing bind mount logic"
  exit 1
}

echo "podman storage bind package test passed"
