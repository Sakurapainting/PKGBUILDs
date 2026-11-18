#!/usr/bin/bash
set -euo pipefail

ALARM_ROOT="${RUNNER_TEMP}/alarm-root"
export GNUPGHOME="${RUNNER_TEMP}/gnupg"
archive="${RUNNER_TEMP}/alarm-rootfs.tar.gz"

sudo apt-get clean
if ! command -v bsdtar >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y libarchive-tools
fi
df -h "$GITHUB_WORKSPACE"

mkdir -m 0700 -p "$GNUPGHOME"
curl --fail --location --retry 5 --output "$archive" \
  http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
curl --fail --location --retry 5 --output "$archive.sig" \
  http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.sig
gpg --batch --import "$GITHUB_WORKSPACE/core/archlinuxarm-keyring/archlinuxarm.gpg"
gpg --batch --verify "$archive.sig" "$archive"

sudo mkdir -p "$ALARM_ROOT"
sudo bsdtar --numeric-owner --xattrs --acls -xpf "$archive" -C "$ALARM_ROOT"
rm -- "$archive" "$archive.sig"

# Give pacman a mount point for the rootfs and its package cache.
sudo mount --bind "$ALARM_ROOT" "$ALARM_ROOT"
sudo cp --remove-destination /etc/resolv.conf "$ALARM_ROOT/etc/resolv.conf"
sudo mkdir -p "$ALARM_ROOT/work"
sudo mount --bind /dev "$ALARM_ROOT/dev"
sudo mount --bind /dev/pts "$ALARM_ROOT/dev/pts"
sudo mount -t proc proc "$ALARM_ROOT/proc"
sudo mount -t sysfs sysfs "$ALARM_ROOT/sys"
sudo mount --bind "$GITHUB_WORKSPACE" "$ALARM_ROOT/work"
df -h "$GITHUB_WORKSPACE"
echo "ALARM_ROOT=$ALARM_ROOT" >> "$GITHUB_ENV"
