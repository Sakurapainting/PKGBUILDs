#!/usr/bin/env bash
set -euo pipefail

package_source=$(realpath "${1:?usage: export-patches.sh PACKAGE_SOURCE PREPARED_KERNEL OUTPUT_DIR}")
kernel_tree=$(realpath "${2:?missing prepared kernel tree}")
output=$(realpath "${3:?missing output directory}")
mkdir -p "$output"

base=$(git -C "$kernel_tree" rev-parse HEAD)
revision=$(git -C "$package_source" rev-parse HEAD)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bundle="$work/z96a-bsp-patches"
mkdir -p "$bundle/packaging"

cat > "$bundle/README.txt" <<MANIFEST
Original BSP: https://github.com/rockchip-linux/kernel.git
Packaging source mirror: https://github.com/Sakurapainting/rockchip-linux-kernel.git
Base commit: $base
Packaging revision: $revision

bsp-to-z96a.patch contains the complete kernel source changes applied by prepare(),
including the board DTS files, rtw88 v6.4 import and subsequent SDIO fix, and the
Kconfig fragment. Apply it to the exact base commit with git apply. To configure
after applying it, run:

  make ARCH=arm64 rockchip_linux_defconfig
  scripts/kconfig/merge_config.sh -m .config z96a-bsp61.config
  make ARCH=arm64 olddefconfig

packaging/ includes PKGBUILD, the original numbered patches, the DTS sources,
the preset and the verification scripts. Follow PKGBUILD prepare() if using these
individual inputs instead of bsp-to-z96a.patch. PKGBUILD pins the rtw88 import.
SHA256SUMS covers the files in this archive.
MANIFEST

git -C "$package_source" ls-files -z -- . |
  tar --null -C "$package_source" -T - -cf - |
  tar -C "$bundle/packaging" -xf -

# Mark newly imported paths only in an isolated Git index.
export GIT_INDEX_FILE="$work/index"
git -C "$kernel_tree" read-tree HEAD
git -C "$kernel_tree" add -N -f -- \
  arch/arm64/boot/dts/rockchip/rk3568-sunniwell-z96a-typec-board.dtsi \
  arch/arm64/boot/dts/rockchip/rk3568-sunniwell-z96a-typec-bsp61.dts \
  drivers/net/wireless/realtek/rtw88 z96a-bsp61.config localversion.10-pkgrel
git -C "$kernel_tree" diff --no-ext-diff --binary HEAD > "$bundle/bsp-to-z96a.patch"
test -s "$bundle/bsp-to-z96a.patch"
git -C "$kernel_tree" apply --check --reverse "$bundle/bsp-to-z96a.patch"
git -C "$kernel_tree" apply --stat "$bundle/bsp-to-z96a.patch"
(cd "$bundle" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$work/SHA256SUMS"
mv "$work/SHA256SUMS" "$bundle/"
tar -C "$work" -cJf "$output/z96a-bsp-patches.tar.xz" z96a-bsp-patches
