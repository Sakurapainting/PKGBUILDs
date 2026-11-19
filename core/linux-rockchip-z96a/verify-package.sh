#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "Package verification failed at line %s: %s (exit %s)\\n" "$LINENO" "$BASH_COMMAND" "$status" >&2; exit "$status"' ERR

package=${1:?usage: verify-package.sh PACKAGE}
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

members=$(bsdtar -tf "$package")
require_member() {
  grep -Fxq "$1" <<<"$members"
}

kernel_release=$(bsdtar -xOf "$package" usr/share/doc/linux-rockchip-z96a/kernelrelease)
[[ "$kernel_release" == 6.1.172-1-z96a-bsp61 ]]

require_member usr/lib/linux-rockchip-z96a-bsp61/Image-rockchip-z96a-bsp61
require_member usr/lib/linux-rockchip-z96a-bsp61/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb
require_member "etc/mkinitcpio.d/linux-rockchip-z96a.preset"
require_member "usr/lib/modules/${kernel_release}/vmlinuz"
grep -Fq "usr/lib/modules/${kernel_release}/" <<<"$members"
grep -Eq "^usr/lib/modules/${kernel_release}/kernel/crypto/lz4\\.ko(\\.(gz|xz|zst))?$" <<<"$members"

if grep -Eq '^boot/' <<<"$members"; then
  printf '%s\n' 'BSP package must stage boot files outside /boot.' >&2
  exit 1
fi

if grep -Eq '^usr/lib/initcpio/' <<<"$members"; then
  printf '%s\n' 'BSP package must not trigger the global mkinitcpio -P hook.' >&2
  exit 1
fi

for forbidden in \
  boot/Image \
  boot/Image.gz \
  boot/initramfs-linux.img \
  boot/extlinux/extlinux.conf \
  boot/dtbs/rockchip/rk3568-sunniwell-z96a-typec.dtb; do
  if grep -Fxq "$forbidden" <<<"$members"; then
    printf 'BSP package overlaps the mainline boot path: %s\n' "$forbidden" >&2
    exit 1
  fi
done

bsdtar -xOf "$package" usr/share/doc/linux-rockchip-z96a/config > "$tmpdir/config"
for symbol in \
  CONFIG_ROCKCHIP_RKNPU=y \
  CONFIG_ROCKCHIP_RKNPU_DMA_HEAP=y \
  CONFIG_ROCKCHIP_RKNPU_DEBUG_FS=y \
  CONFIG_ROCKCHIP_RKNPU_PROC_FS=y \
  CONFIG_ROCKCHIP_IOMMU=y \
  CONFIG_DEBUG_FS=y \
  CONFIG_PROC_FS=y \
  CONFIG_CMA=y \
  CONFIG_CMA_SIZE_SEL_MBYTES=y \
  CONFIG_CMA_SIZE_MBYTES=64 \
  CONFIG_CRYPTO_LZ4=m \
  CONFIG_DMABUF_HEAPS=y \
  CONFIG_DMABUF_HEAPS_ROCKCHIP=y \
  CONFIG_DMABUF_HEAPS_ROCKCHIP_CMA_HEAP=y \
  'CONFIG_LOCALVERSION="-z96a-bsp61"'; do
  if ! grep -Fxq "$symbol" "$tmpdir/config"; then
    printf 'Missing expected config option: %s\n' "$symbol" >&2
    exit 1
  fi
done
grep -Fxq '# CONFIG_ROCKCHIP_RKNPU_DRM_GEM is not set' "$tmpdir/config"
grep -Fxq '# CONFIG_LOCALVERSION_AUTO is not set' "$tmpdir/config"

preset=$(bsdtar -xOf "$package" etc/mkinitcpio.d/linux-rockchip-z96a.preset)
grep -Fxq "ALL_kver=\"${kernel_release}\"" <<<"$preset"
grep -Fxq 'default_image="/boot/initramfs-linux-rockchip-z96a-bsp61.img"' <<<"$preset"

bsdtar -xOf "$package" \
  usr/lib/linux-rockchip-z96a-bsp61/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb \
  > "$tmpdir/z96a.dtb"

npu=/npu@fde40000
npu_mmu=/iommu@fde4b000
compatible=$(fdtget -t s "$tmpdir/z96a.dtb" "$npu" compatible)
grep -qw 'rockchip,rk3568-rknpu' <<<"$compatible"
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu" status)" == okay ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu_mmu" status)" == okay ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu_mmu" compatible)" == rockchip,iommu-v2 ]]

for property in clocks resets power-domains iommus operating-points-v2 rknpu-supply; do
  fdtget -t x "$tmpdir/z96a.dtb" "$npu" "$property" >/dev/null
done

vdd_node=$(fdtget -t s "$tmpdir/z96a.dtb" /__symbols__ vdd_npu)
npu_supply=$(fdtget -t x "$tmpdir/z96a.dtb" "$npu" rknpu-supply)
vdd_phandle=$(fdtget -t x "$tmpdir/z96a.dtb" "$vdd_node" phandle)
[[ "$npu_supply" == "$vdd_phandle" ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$vdd_node" regulator-name)" == vdd_npu ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-min-microvolt)" == 500000 ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-init-microvolt)" == 900000 ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-max-microvolt)" == 1350000 ]]

opp_table=$(fdtget -t s "$tmpdir/z96a.dtb" /__symbols__ npu_opp_table)
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$opp_table" rockchip,init-freq)" == 600000 ]]
opp_nodes=$(fdtget -l "$tmpdir/z96a.dtb" "$opp_table")
for forbidden_opp in \
  opp-700000000 \
  opp-800000000 \
  opp-900000000 \
  opp-1000000000 \
  opp-m-900000000; do
  if grep -Fxq "$forbidden_opp" <<<"$opp_nodes"; then
    printf 'Unexpected NPU OPP is present: %s\n' "$forbidden_opp" >&2
    exit 1
  fi
done

od_opp=/npu-opp-table/opp-j-od-800000000
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$od_opp" status)" == disabled ]]

bus_npu=$(fdtget -t s "$tmpdir/z96a.dtb" /__symbols__ bus_npu)
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$bus_npu" status)" == okay ]]
for property in bus-supply pvtm-supply; do
  fdtget -t x "$tmpdir/z96a.dtb" "$bus_npu" "$property" >/dev/null
done

if grep -Eq '/rknpu\.ko$' <<<"$members"; then
  printf '%s\n' 'RKNPU must be built into the kernel, not packaged as a module.' >&2
  exit 1
fi

printf 'Verified BSP package: %s\n' "$package"
printf 'Kernel release: %s\n' "$kernel_release"
