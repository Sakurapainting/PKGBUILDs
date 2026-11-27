#!/usr/bin/env bash
set -euo pipefail

# Run on a native AArch64 CI runner with a clean bootstrap-alarm.sh rootfs.
root=$(realpath "${1:?usage: build-z96a-image.sh ALARM_ROOT BSP_PACKAGE OUTPUT_DIR [minimal|niri]}")
package=$(realpath "${2:?missing BSP package}")
output=$(realpath "${3:?missing output directory}")
profile=${4:-minimal}
lba0_output=${5:-}
if [[ -n "$lba0_output" ]]; then
  lba0_output=$(realpath "$lba0_output")
fi
case "$profile" in
  minimal) image_suffix= ;;
  niri) image_suffix=-niri ;;
  *) printf 'Unknown Z96A image profile: %s\n' "$profile" >&2; exit 2 ;;
esac
[[ "$root" == "${RUNNER_TEMP:?}/alarm-root" && -d "$root/work" ]]
[[ "$package" == "$GITHUB_WORKSPACE"/dist/linux-rockchip-z96a-*.pkg.tar.xz ]]
mountpoint -q "$root/work"
mkdir -p "$output"
if [[ -n "$lba0_output" ]]; then
  [[ -d "$lba0_output" ]]
fi
work=$(mktemp -d "$RUNNER_TEMP/z96a-image.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

boot_lba=190464
boot_sectors=524288
root_lba=714752
root_sectors=7340032
sector_bytes=512
release=$(bsdtar -xOf "$package" usr/share/doc/linux-rockchip-z96a/kernelrelease)
image="z96a-archarm-${release}${image_suffix}-boot-root.img"

board_files="$GITHUB_WORKSPACE/core/linux-rockchip-z96a"
selftest="$board_files/rknn-selftest"
# Rockchip's v2.3.2 model zoo carries the same Linux runtime tested on Z96A.
rknn_upstream=https://raw.githubusercontent.com/airockchip/rknn_model_zoo/bad6c7334531becaf90a561988519b7bec34d0ab
rknn_files="$work/rknn"
mkdir "$rknn_files"
curl --fail --silent --show-error --location --retry 4 --max-time 60 \
  "$rknn_upstream/3rdparty/rknpu2/Linux/aarch64/librknnrt.so" -o "$rknn_files/librknnrt.so"
curl --fail --silent --show-error --location --retry 4 --max-time 60 \
  "$rknn_upstream/3rdparty/rknpu2/include/rknn_api.h" -o "$rknn_files/rknn_api.h"
curl --fail --silent --show-error --location --retry 4 --max-time 60 \
  "$rknn_upstream/LICENSE" -o "$rknn_files/LICENSE"
(
  cd "$rknn_files"
  sha256sum --check --strict <<'SHA256'
d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8  librknnrt.so
c48e11a6f41b451a5fd1e4ad774ea60252d3d94f78bee9b21ea3d21b21deba9a  rknn_api.h
c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4  LICENSE
SHA256
)
printf '%s  %s\n' 782e083e826d9b92cdc3f0ba914ea1c86ea35f55c69e8709bcfc5caf09e83846 \
  "$selftest/conv.rknn" | sha256sum --check --strict
cc -std=c11 -O2 -Wall -Wextra -I "$rknn_files" "$selftest/conv-check.c" \
  -L "$rknn_files" -Wl,-rpath-link,"$rknn_files" -lrknnrt -lm -o "$rknn_files/conv-check"

sudo chroot "$root" /bin/bash -s -- "/work/dist/${package##*/}" "$profile" <<'CHROOT'
set -euo pipefail
pacman-key --init
pacman-key --populate archlinuxarm
packages=(mkinitcpio linux-firmware-realtek networkmanager sudo fastfetch iw dosfstools usbutils libstdc++)
if [[ "$2" == niri ]]; then
  packages+=(sddm niri mesa xorg-server xwayland-satellite foot fuzzel xdg-desktop-portal-gtk)
fi
pacman -Syu --noconfirm --needed "${packages[@]}"
pacman -U --noconfirm "$1"
if pacman -Q linux-aarch64 >/dev/null 2>&1; then
  pacman -R --noconfirm linux-aarch64
fi
mkinitcpio -p linux-rockchip-z96a
pacman -Q > /usr/share/z96a-image-packages.txt
pacman -Scc --noconfirm
CHROOT

sudo install -Dm0644 "$rknn_files/librknnrt.so" "$root/usr/lib/librknnrt.so"
sudo install -Dm0755 "$rknn_files/conv-check" "$root/usr/lib/z96a-rknn/conv-check"
sudo install -Dm0644 "$selftest/conv.rknn" "$root/usr/share/z96a-rknn/conv.rknn"
sudo install -Dm0755 "$selftest/z96a-rknn-selftest" "$root/usr/bin/z96a-rknn-selftest"
sudo install -Dm0644 "$rknn_files/LICENSE" "$root/usr/share/licenses/z96a-rknn/LICENSE"
sudo chroot "$root" /bin/bash -eu <<'CHROOT'
for tool in fastfetch iw fsck.fat lsusb z96a-rknn-selftest; do
  command -v "$tool"
done
fastfetch --version
z96a-rknn-selftest --help
dependencies=$(ldd /usr/lib/z96a-rknn/conv-check)
printf '%s\n' "$dependencies"
[[ "$dependencies" == *'librknnrt.so => '* && "$dependencies" != *'not found'* ]]
# With no arguments the native executable validates its CLI without using a device.
if usage=$(/usr/lib/z96a-rknn/conv-check 2>&1); then
  exit 1
fi
[[ "$usage" == 'Usage: /usr/lib/z96a-rknn/conv-check model.rknn duration_seconds' ]]
CHROOT

if [[ "$profile" == niri ]]; then
  niri_config=/etc/skel/.config/niri/config.kdl
  sudo install -Dm0644 "$board_files/niri-image.kdl" "$root$niri_config"
  sudo chroot "$root" /bin/bash -se -- "$niri_config" <<'CHROOT'
for tool in sddm niri-session niri Xorg Xwayland xwayland-satellite foot fuzzel; do
  command -v "$tool"
done
niri --version
niri validate --config "$1"
grep -Fx 'Exec=niri-session' /usr/share/wayland-sessions/niri.desktop
test -e /usr/lib/dri/panfrost_dri.so
CHROOT
  sudo systemctl --root="$root" enable sddm.service
  sudo systemctl --root="$root" set-default graphical.target
fi

# useradd copies /etc/skel only when creating the home directory. Install the
# image's desktop defaults above so the pre-created account receives them too.
sudo chroot "$root" /bin/bash -se -- "$profile" <<'CHROOT'
if id alarm >/dev/null 2>&1; then userdel -r alarm; fi
useradd -m -g users -s /bin/bash alarm
printf 'alarm:alarm\n' | chpasswd
passwd -l root
if [[ "$1" == niri ]]; then
  config=.config/niri/config.kdl
  cmp "/etc/skel/$config" "/home/alarm/$config"
  [[ "$(stat -c '%u:%g' "/home/alarm/$config")" == "$(id -u alarm):$(id -g alarm)" ]]
fi
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
        append earlycon=uart8250,mmio32,0xfe660000 console=tty0 console=ttyS0,1500000n8 root=PARTLABEL=ROOT rootwait rw movablecore=256M

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
for boot_dtb in "$dtb" z96a-bsp61-recovery.dtb; do
  bash "$board_files/verify-edp-planes.sh" "$work/verified-boot/dtbs/$boot_dtb"
done
bash "$board_files/verify-npu-power.sh" "$work/verified-boot/dtbs/$dtb" okay
bash "$board_files/verify-npu-power.sh" "$work/verified-boot/dtbs/z96a-bsp61-recovery.dtb" disabled
for path in /usr/lib/modules/"$release"/modules.dep.bin /etc/fstab /usr/share/z96a-image-packages.txt \
            /usr/bin/fastfetch /usr/bin/iw /usr/bin/fsck.fat /usr/bin/lsusb; do
  debugfs -R "stat $path" "$work/ROOT.img" 2>/dev/null | grep '^Inode:'
done
for path in /usr/bin/z96a-rknn-selftest /usr/lib/librknnrt.so /usr/lib/z96a-rknn/conv-check \
            /usr/share/z96a-rknn/conv.rknn /usr/share/licenses/z96a-rknn/LICENSE; do
  debugfs -R "dump $path $work/verified-rknn-file" "$work/ROOT.img"
  cmp "$root$path" "$work/verified-rknn-file"
done
debugfs -R 'cat /etc/passwd' "$work/ROOT.img" 2>/dev/null |
  awk -F: '$1=="alarm" && $6=="/home/alarm" && $7=="/bin/bash" { found++ } END { if (found != 1) exit 1 }'
debugfs -R 'cat /etc/shadow' "$work/ROOT.img" 2>/dev/null |
  awk -F: '$1=="root" && $2 ~ /^!/ { locked=1 } $1=="alarm" && $2 != "" && $2 !~ /^[!*]/ { configured=1 } END { if (!locked || !configured) exit 1 }'
debugfs -R 'cat /etc/machine-id' "$work/ROOT.img" 2>/dev/null | grep -Fx uninitialized
if [[ "$profile" == niri ]]; then
  for path in "$niri_config" /home/alarm/.config/niri/config.kdl; do
    debugfs -R "cat $path" "$work/ROOT.img" | cmp "$board_files/niri-image.kdl" -
  done
  debugfs -R 'stat /etc/systemd/system/display-manager.service' "$work/ROOT.img" 2>/dev/null |
    grep -Fx 'Fast link dest: "/usr/lib/systemd/system/sddm.service"'
  debugfs -R 'stat /etc/systemd/system/default.target' "$work/ROOT.img" 2>/dev/null |
    grep -Fx 'Fast link dest: "/usr/lib/systemd/system/graphical.target"'
  for path in /usr/bin/sddm /usr/bin/niri /usr/share/wayland-sessions/niri.desktop /usr/lib/dri/panfrost_dri.so; do
    debugfs -R "stat $path" "$work/ROOT.img" 2>/dev/null | grep '^Inode:'
  done
fi
cat "$work/BOOT.img" "$work/ROOT.img" | xz -T2 -6 -c > "$output/$image.xz"
xz -t "$output/$image.xz"
raw_sha=$(cat "$work/BOOT.img" "$work/ROOT.img" | sha256sum | cut -d' ' -f1)
raw_bytes=$(((boot_sectors + root_sectors) * sector_bytes))
actual_sha=$(xz -dc "$output/$image.xz" | sha256sum | cut -d' ' -f1)
[[ "$actual_sha" == "$raw_sha" ]]
printf '%s  %s\n' "$raw_sha" "$image" > "$output/RAW-SHA256SUMS"
cp "$board_files/flash-image.zh-CN.md" "$output/README.zh-CN.md"
cp "$board_files/check-flash-layout.py" "$output/"
cp "$boot/extlinux/extlinux.conf" "$output/extlinux.conf"
cp "$root/usr/share/z96a-image-packages.txt" "$output/PACKAGES"
cat > "$output/layout.json" <<LAYOUT
{
  "board": "Sunniwell Z96A / Rockchip RK3568",
  "packaging_commit": "${GITHUB_SHA:?}",
  "kernel_release": "$release",
  "profile": "$profile",
  "kernel_build_run_id": "${KERNEL_BUILD_RUN_ID:?}",
  "image": "$image",
  "sector_bytes": $sector_bytes,
  "flash_start_lba": $boot_lba,
  "raw_bytes": $raw_bytes,
  "boot": {"partlabel": "BOOT", "start_lba": $boot_lba, "sectors": $boot_sectors},
  "root": {"partlabel": "ROOT", "start_lba": $root_lba, "image_sectors": $root_sectors}
}
LAYOUT
(cd "$output" && sha256sum "$image.xz" RAW-SHA256SUMS layout.json extlinux.conf PACKAGES README.zh-CN.md check-flash-layout.py > SHA256SUMS)

if [[ -n "$lba0_output" ]]; then
  disk_sectors=61071360
  disk_bytes=$((disk_sectors * sector_bytes))
  prefix_xz="$board_files/boot-firmware/z96a-preboot-190464lba.bin.xz"
  prefix_raw="$work/z96a-preboot-190464lba.bin"
  full_raw="$work/z96a-archarm-${release}${image_suffix}-lba0.img"
  full_image="$(basename "$full_raw")"
  full_xz="$lba0_output/$full_image.xz"

  printf '%s  %s\n' e9e5f45f6cd503086c1219b8e1a1f658e4fe32b248a2131cb6d78015c3c2f47e "$prefix_xz" |
    sha256sum --check --strict
  xz -t "$prefix_xz"
  xz -dc "$prefix_xz" > "$prefix_raw"
  [[ "$(stat -c %s "$prefix_raw")" -eq $((190464 * sector_bytes)) ]]
  printf '%s  %s\n' 2168a3cdd9bdf46953ad7d965d465afeb4b75b31a99b8031974c7b0035c0dbbc "$prefix_raw" |
    sha256sum --check --strict

  # A sparse whole-eMMC image: only the sanitized Rockchip boot firmware, the
  # generated GPT and the tested BOOT/ROOT payloads occupy nonzero sectors.
  truncate -s "$disk_bytes" "$full_raw"
  dd if="$prefix_raw" of="$full_raw" bs=4M conv=sparse,notrunc status=none
  dd if="$work/BOOT.img" of="$full_raw" bs="$sector_bytes" seek="$boot_lba" conv=sparse,notrunc status=none
  dd if="$work/ROOT.img" of="$full_raw" bs="$sector_bytes" seek="$root_lba" conv=sparse,notrunc status=none
  python3 "$board_files/write-z96a-gpt.py" "$full_raw" --sectors "$disk_sectors"

  # Validate GPT geometry/CRCs independently with util-linux, then produce the
  # downloadable compressed image and simulate a raw LBA0 write to a sparse disk.
  sfdisk --verify "$full_raw"
  raw_sha=$(sha256sum "$full_raw" | cut -d' ' -f1)
  xz -T2 -6 -c "$full_raw" > "$full_xz"
  # Reuse the sparse build file as the virtual flash destination so CI does not
  # need a second full-disk copy alongside both compressed artifacts.
  truncate -s 0 "$full_raw"
  truncate -s "$disk_bytes" "$full_raw"
  xz -dc "$full_xz" | dd of="$full_raw" bs=4M conv=sparse status=none
  virtual_sha=$(sha256sum "$full_raw" | cut -d' ' -f1)
  [[ "$virtual_sha" == "$raw_sha" ]]
  python3 "$board_files/verify-z96a-lba0-image.py" "$full_raw" \
    --prefix "$prefix_raw" --boot "$work/BOOT.img" --root "$work/ROOT.img"
  sfdisk --verify "$full_raw"

  printf '%s  %s\n' "$raw_sha" "$full_image" > "$lba0_output/RAW-SHA256SUMS"
  cp "$board_files/flash-image-lba0.zh-CN.md" "$lba0_output/README.zh-CN.md"
  cp "$board_files/verify-z96a-lba0-image.py" "$lba0_output/verify-z96a-lba0-image.py"
  cp "$boot/extlinux/extlinux.conf" "$lba0_output/extlinux.conf"
  cp "$root/usr/share/z96a-image-packages.txt" "$lba0_output/PACKAGES"
  cat > "$lba0_output/layout.json" <<LAYOUT
{
  "board": "Sunniwell Z96A / Rockchip RK3568",
  "packaging_commit": "${GITHUB_SHA:?}",
  "kernel_release": "$release",
  "profile": "$profile",
  "kernel_build_run_id": "${KERNEL_BUILD_RUN_ID:?}",
  "image": "$full_image",
  "sector_bytes": $sector_bytes,
  "disk_sectors": $disk_sectors,
  "flash_start_lba": 0,
  "raw_bytes": $disk_bytes,
  "gpt": {"primary_header_lba": 1, "backup_header_lba": $((disk_sectors - 1)), "partition_count": 10},
  "boot": {"partlabel": "BOOT", "start_lba": $boot_lba, "sectors": $boot_sectors},
  "root": {"partlabel": "ROOT", "start_lba": $root_lba, "image_sectors": $root_sectors},
  "verification": "xz decompression streamed to a sparse virtual flash disk; SHA-256, primary/backup GPT, firmware prefix, zeroed OEM regions and BOOT/ROOT offsets verified"
}
LAYOUT
  (cd "$lba0_output" && sha256sum "$full_image.xz" RAW-SHA256SUMS layout.json extlinux.conf PACKAGES README.zh-CN.md verify-z96a-lba0-image.py > SHA256SUMS)
fi
