#!/usr/bin/env bash
set -euo pipefail

# Run as root in the disposable Arch Linux ARM CI chroot.
package=${1:?usage: verify-install.sh PACKAGE}
export LC_ALL=C
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

pkgbase=linux-rockchip-z96a
initrd=/var/lib/${pkgbase}/initramfs-linux-rockchip-z96a-bsp61.img
kernel_release=$(bsdtar -xOf "$package" "usr/share/doc/$pkgbase/kernelrelease")

snapshot_boot() {
  # Capture nanosecond timestamps and file contents without recording atimes.
  find /boot -printf '%y %m %U:%G %T@ %C@ %p -> %l\0' | sort -z
  find /boot -type f -print0 | sort -z | xargs -0r sha256sum -z
}

pacman -S --needed --noconfirm mkinitcpio
# Require an existing mainline initramfs so the test covers a populated /boot.
test -s /boot/initramfs-linux.img
test ! -e "$initrd"
snapshot_boot > "$workdir/boot.before"

pacman -U --noconfirm "$package" | tee "$workdir/pacman.log"
snapshot_boot > "$workdir/boot.after-install"
printf 'SHA-256 of /boot manifests before and after pacman -U:\n'
sha256sum "$workdir/boot.before" "$workdir/boot.after-install"
cmp "$workdir/boot.before" "$workdir/boot.after-install"
if grep -F 'Updating linux initcpios' "$workdir/pacman.log"; then
  printf '%s\n' 'Installing the BSP package triggered mkinitcpio.' >&2
  exit 1
fi
test ! -e "$initrd"
test -s "/usr/lib/modules/$kernel_release/modules.dep.bin"

mkinitcpio -p "$pkgbase"
test -s "$initrd"
lsinitcpio "$initrd" > "$workdir/initramfs.contents"
grep -Fx "usr/lib/modules/$kernel_release/modules.dep.bin" "$workdir/initramfs.contents"
stat -c 'BSP initramfs: %n (%s bytes)' "$initrd"
snapshot_boot > "$workdir/boot.after-preset"
sha256sum "$workdir/boot.after-preset"
cmp "$workdir/boot.before" "$workdir/boot.after-preset"
printf 'Verified that package installation and explicit BSP initramfs generation preserve /boot.\n'
sha256sum "$package"
