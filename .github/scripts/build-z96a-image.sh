#!/usr/bin/env bash
set -euo pipefail

# Run on a native AArch64 CI runner with a clean bootstrap-alarm.sh rootfs.
root=$(realpath "${1:?usage: build-z96a-image.sh ALARM_ROOT BSP_PACKAGE OUTPUT_DIR}")
package=$(realpath "${2:?missing BSP package}")
output=$(realpath "${3:?missing output directory}")
[[ "$root" == "${RUNNER_TEMP:?}/alarm-root" && -d "$root/work" ]]
[[ "$package" == "$GITHUB_WORKSPACE"/dist/linux-rockchip-z96a-*.pkg.tar.xz ]]
mountpoint -q "$root/work"
mkdir -p "$output"
work=$(mktemp -d "$RUNNER_TEMP/z96a-image.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

boot_lba=190464
boot_sectors=524288
root_lba=714752
root_sectors=7340032
sector_bytes=512
release=$(bsdtar -xOf "$package" usr/share/doc/linux-rockchip-z96a/kernelrelease)
image="z96a-archarm-${release}-boot-root.img"

sudo chroot "$root" /bin/bash -s -- "/work/dist/${package##*/}" <<'CHROOT'
set -euo pipefail
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm --needed mkinitcpio linux-firmware-realtek networkmanager sudo
pacman -U --noconfirm "$1"
if pacman -Q linux-aarch64 >/dev/null 2>&1; then
  pacman -R --noconfirm linux-aarch64
fi
mkinitcpio -p linux-rockchip-z96a
pacman -Q > /usr/share/z96a-image-packages.txt
pacman -Scc --noconfirm
if id alarm >/dev/null 2>&1; then userdel -r alarm; fi
passwd -l root
CHROOT

sudo systemctl --root="$root" disable sshd.service
sudo systemctl --root="$root" enable NetworkManager.service serial-getty@ttyS0.service
sudo install -d "$root/etc/systemd/system/systemd-firstboot.service.d"
sudo tee "$root/etc/systemd/system/systemd-firstboot.service.d/z96a-root-password.conf" >/dev/null <<'FIRSTBOOT'
[Service]
ExecStart=
ExecStart=systemd-firstboot --force --prompt-root-password --mute-console=yes
FIRSTBOOT
printf 'uninitialized\n' | sudo tee "$root/etc/machine-id" >/dev/null
printf 'z96a\n' | sudo tee "$root/etc/hostname" >/dev/null
if [[ -d "$root/etc/ssh" ]]; then
  sudo find "$root/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -delete
fi
sudo rm -rf "$root/etc/pacman.d/gnupg" "$root/var/log/journal"
sudo rm -f "$root/var/lib/systemd/random-seed" "$root/etc/resolv.conf"
sudo touch "$root/etc/resolv.conf"
sudo install -d "$root/var/lib/dbus"
sudo ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
sudo find "$root/var/log" -type f -delete
sudo tee "$root/etc/fstab" >/dev/null <<'FSTAB'
/dev/disk/by-partlabel/ROOT / ext4 defaults,x-systemd.growfs 0 1
/dev/disk/by-partlabel/BOOT /boot vfat defaults,umask=022 0 2
FSTAB

bsp="$root/usr/lib/linux-rockchip-z96a-bsp61"
dtb=rk3568-sunniwell-z96a-typec-bsp61.dtb
initrd="$root/var/lib/linux-rockchip-z96a/initramfs-linux-rockchip-z96a-bsp61.img"
boot="$work/boot"
mkdir -p "$boot/extlinux" "$boot/dtbs"
install -m0644 "$bsp/Image-rockchip-z96a-bsp61" "$boot/Image"
sudo install -m0644 -o "$(id -u)" -g "$(id -g)" "$initrd" "$boot/initramfs.img"
install -m0644 "$bsp/dtbs-rockchip-z96a-bsp61/$dtb" "$boot/dtbs/$dtb"
install -m0644 "$boot/dtbs/$dtb" "$boot/dtbs/z96a-bsp61-recovery.dtb"
fdtput -t s "$boot/dtbs/z96a-bsp61-recovery.dtb" /npu@fde40000 status disabled
fdtput -t s "$boot/dtbs/z96a-bsp61-recovery.dtb" /iommu@fde4b000 status disabled
cat > "$boot/extlinux/extlinux.conf" <<'EXTLINUX'
timeout 50
default linux-bsp61
menu title Sunniwell Z96A

label linux-bsp61
        menu label Arch Linux ARM (Rockchip BSP)
        kernel /Image
        initrd /initramfs.img
        devicetree /dtbs/rk3568-sunniwell-z96a-typec-bsp61.dtb
        append earlycon=uart8250,mmio32,0xfe660000 console=tty0 console=ttyS0,1500000n8 root=PARTLABEL=ROOT rootwait rw

label linux-bsp61-recovery
        menu label Arch Linux ARM (Rockchip BSP, NPU disabled)
        kernel /Image
        initrd /initramfs.img
        devicetree /dtbs/z96a-bsp61-recovery.dtb
        append earlycon=uart8250,mmio32,0xfe660000 console=tty0 console=ttyS0,1500000n8 root=PARTLABEL=ROOT rootwait rw systemd.unit=multi-user.target
EXTLINUX

# Keep all CI mounts and host device nodes out of the filesystem image.
for mount in work dev/pts dev proc sys; do sudo umount "$root/$mount"; done
sudo umount "$root"
sudo find "$root/boot" -mindepth 1 -delete

[[ $((boot_lba + boot_sectors)) -eq "$root_lba" ]]
truncate -s "$((boot_sectors * sector_bytes))" "$work/BOOT.img"
mkfs.fat -F 32 -n BOOT "$work/BOOT.img"
mcopy -i "$work/BOOT.img" -s "$boot"/* ::/
truncate -s "$((root_sectors * sector_bytes))" "$work/ROOT.img"
sudo mkfs.ext4 -q -F -L ROOT -O '^orphan_file' -E nodiscard,lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$work/ROOT.img"

fsck.fat -vn "$work/BOOT.img"
e2fsck -fn "$work/ROOT.img"
mkdir "$work/verified-boot"
mcopy -i "$work/BOOT.img" -s ::/ "$work/verified-boot/"
diff -r "$boot" "$work/verified-boot"
for path in /usr/lib/modules/"$release"/modules.dep.bin /etc/fstab /usr/share/z96a-image-packages.txt; do
  debugfs -R "stat $path" "$work/ROOT.img" 2>/dev/null | grep '^Inode:'
done
debugfs -R 'cat /etc/shadow' "$work/ROOT.img" 2>/dev/null | awk -F: '$1=="root" && $2 ~ /^!/ { locked=1 } $1=="alarm" { exit 1 } END { if (!locked) exit 1 }'
debugfs -R 'cat /etc/machine-id' "$work/ROOT.img" 2>/dev/null | grep -Fx uninitialized
[[ "$(fdtget -t s "$boot/dtbs/$dtb" /npu@fde40000 status)" == okay ]]
[[ "$(fdtget -t s "$boot/dtbs/z96a-bsp61-recovery.dtb" /npu@fde40000 status)" == disabled ]]

cat "$work/BOOT.img" "$work/ROOT.img" | zstd -T2 -6 -q -o "$output/$image.zst"
zstd -t "$output/$image.zst"
raw_sha=$(cat "$work/BOOT.img" "$work/ROOT.img" | sha256sum | cut -d' ' -f1)
raw_bytes=$(((boot_sectors + root_sectors) * sector_bytes))
actual_sha=$(zstd -dc "$output/$image.zst" | sha256sum | cut -d' ' -f1)
[[ "$actual_sha" == "$raw_sha" ]]
printf '%s  %s\n' "$raw_sha" "$image" > "$output/RAW-SHA256SUMS"
cp "$GITHUB_WORKSPACE/core/linux-rockchip-z96a/flash-image.zh-CN.md" "$output/README.zh-CN.md"
cp "$GITHUB_WORKSPACE/core/linux-rockchip-z96a/check-flash-layout.py" "$output/"
cp "$boot/extlinux/extlinux.conf" "$output/extlinux.conf"
cp "$root/usr/share/z96a-image-packages.txt" "$output/PACKAGES"
cat > "$output/layout.json" <<LAYOUT
{
  "board": "Sunniwell Z96A / Rockchip RK3568",
  "packaging_commit": "${GITHUB_SHA:?}",
  "kernel_release": "$release",
  "kernel_build_run_id": "${KERNEL_BUILD_RUN_ID:?}",
  "image": "$image",
  "sector_bytes": $sector_bytes,
  "flash_start_lba": $boot_lba,
  "raw_bytes": $raw_bytes,
  "boot": {"partlabel": "BOOT", "start_lba": $boot_lba, "sectors": $boot_sectors},
  "root": {"partlabel": "ROOT", "start_lba": $root_lba, "image_sectors": $root_sectors}
}
LAYOUT
(cd "$output" && sha256sum "$image.zst" RAW-SHA256SUMS layout.json extlinux.conf PACKAGES README.zh-CN.md check-flash-layout.py > SHA256SUMS)
