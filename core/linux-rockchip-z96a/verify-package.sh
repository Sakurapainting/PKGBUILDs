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
[[ "$kernel_release" == 6.1.172-6-z96a-bsp61 ]]

require_member usr/lib/linux-rockchip-z96a-bsp61/Image-rockchip-z96a-bsp61
require_member usr/lib/linux-rockchip-z96a-bsp61/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb
require_member "etc/mkinitcpio.d/linux-rockchip-z96a.preset"
require_member var/lib/linux-rockchip-z96a/
require_member "usr/lib/modules/${kernel_release}/modules.order"
grep -Eq "^usr/lib/modules/${kernel_release}/kernel/crypto/lz4\\.ko(\\.(gz|xz|zst))?$" <<<"$members"

if grep -Eq '^boot(/|$)' <<<"$members"; then
  printf '%s\n' 'BSP package must stage boot files outside /boot.' >&2
  exit 1
fi

if grep -E '^(usr/lib/modules/[^/]+/(vmlinuz|extramodules/?)$|usr/lib/initcpio/)' <<<"$members"; then
  printf '%s\n' 'BSP package contains a mkinitcpio hook trigger.' >&2
  exit 1
fi

bsdtar -xOf "$package" usr/share/doc/linux-rockchip-z96a/config > "$tmpdir/config"
for symbol in \
  CONFIG_COMMON_CLK_RK808=y \
  CONFIG_ROCKCHIP_RKNPU=y \
  CONFIG_ROCKCHIP_RKNPU_DMA_HEAP=y \
  CONFIG_ROCKCHIP_RKNPU_DEBUG_FS=y \
  CONFIG_ROCKCHIP_RKNPU_PROC_FS=y \
  CONFIG_ROCKCHIP_IOMMU=y \
  CONFIG_ROCKCHIP_ANALOGIX_DP=y \
  CONFIG_DRM_PANEL_EDP=y \
  CONFIG_PHY_ROCKCHIP_NANENG_EDP=y \
  CONFIG_BACKLIGHT_PWM=y \
  CONFIG_DEBUG_FS=y \
  CONFIG_PROC_FS=y \
  CONFIG_CMA=y \
  CONFIG_CMA_SIZE_SEL_MBYTES=y \
  CONFIG_CMA_SIZE_MBYTES=64 \
  CONFIG_CRYPTO_LZ4=m \
  CONFIG_RTW88=m \
  CONFIG_RTW88_CORE=m \
  CONFIG_RTW88_SDIO=m \
  CONFIG_RTW88_8822C=m \
  CONFIG_RTW88_8822CS=m \
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

rtw88_dir="usr/lib/modules/${kernel_release}/kernel/drivers/net/wireless/realtek/rtw88"
rtw88_modules=(rtw88_core.ko rtw88_sdio.ko rtw88_8822c.ko rtw88_8822cs.ko)
rtw88_members=()
for module in "${rtw88_modules[@]}"; do
  require_member "$rtw88_dir/$module"
  rtw88_members+=("$rtw88_dir/$module")
done
bsdtar -xf "$package" -C "$tmpdir" "${rtw88_members[@]}"
for module in "${rtw88_modules[@]}"; do
  vermagic=$(modinfo -F vermagic "$tmpdir/$rtw88_dir/$module")
  [[ "${vermagic%% *}" == "$kernel_release" ]]
done
modinfo -F alias "$tmpdir/$rtw88_dir/rtw88_8822cs.ko" | grep -Fx 'sdio:c*v024CdC822*'
firmware=$(modinfo -F firmware "$tmpdir/$rtw88_dir/rtw88_8822c.ko")
grep -Fx 'rtw88/rtw8822c_fw.bin' <<<"$firmware"
grep -Fx 'rtw88/rtw8822c_wow_fw.bin' <<<"$firmware"

preset=$(bsdtar -xOf "$package" etc/mkinitcpio.d/linux-rockchip-z96a.preset)
grep -Fxq "ALL_kver=\"${kernel_release}\"" <<<"$preset"
grep -Fxq 'default_image="/var/lib/linux-rockchip-z96a/initramfs-linux-rockchip-z96a-bsp61.img"' <<<"$preset"

bsdtar -xOf "$package" \
  usr/lib/linux-rockchip-z96a-bsp61/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb \
  > "$tmpdir/z96a.dtb"

dtb="$tmpdir/z96a.dtb"
dtb_node() {
  fdtget -t s "$dtb" /__symbols__ "$1"
}
dtb_phandle() {
  fdtget -t x "$dtb" "$(dtb_node "$1")" phandle
}

vop=$(dtb_node vop)
cru=$(dtb_phandle cru)
pmucru=$(dtb_phandle pmucru)
# RK3568 clock IDs for DCLK_VOP0, DCLK_VOP1, PLL_HPLL and PLL_VPLL.
[[ "$(fdtget -t x "$dtb" "$vop" assigned-clocks)" == "$cru df $cru e0" ]]
[[ "$(fdtget -t x "$dtb" "$vop" assigned-clock-parents)" == "$pmucru 2 $cru 5" ]]
vop_properties=$(fdtget -p "$dtb" "$vop")
if grep -Fxq assigned-clock-rates <<<"$vop_properties"; then
  printf '%s\n' 'Do not force VOP clock rates in the BSP DTB.' >&2
  exit 1
fi
[[ "$(fdtget -t x "$dtb" "$vop" iommus)" == "$(dtb_phandle vop_mmu)" ]]
fdtget "$dtb" "$(dtb_node vop_mmu)" rockchip,disable-mmu-reset >/dev/null

for symbol in edp edp_phy edp_in_vp1 pwm9; do
  [[ "$(fdtget -t s "$dtb" "$(dtb_node "$symbol")" status)" == okay ]]
done
panel="$(dtb_node edp)/aux-bus/panel"
[[ "$(fdtget -t s "$dtb" "$panel" compatible)" == edp-panel ]]
[[ "$(fdtget -t x "$dtb" "$panel" power-supply)" == "$(dtb_phandle vcc3v3_lcd0_n)" ]]
[[ "$(fdtget -t x "$dtb" "$panel" backlight)" == "$(dtb_phandle backlight)" ]]
[[ "$(fdtget -t x "$dtb" "$(dtb_node edp_in_vp1)" remote-endpoint)" == "$(dtb_phandle vp1_out_edp)" ]]
[[ "$(fdtget -t x "$dtb" "$(dtb_node edp_out_panel)" remote-endpoint)" == "$(dtb_phandle panel_in_edp)" ]]

npu=/npu@fde40000
npu_mmu=/iommu@fde4b000
compatible=$(fdtget -t s "$tmpdir/z96a.dtb" "$npu" compatible)
grep -qw 'rockchip,rk3568-rknpu' <<<"$compatible"
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu" status)" == disabled ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu_mmu" status)" == disabled ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu_mmu" compatible)" == rockchip,iommu-v2 ]]

for property in clocks resets power-domains iommus operating-points-v2; do
  fdtget -t x "$tmpdir/z96a.dtb" "$npu" "$property" >/dev/null
done
if fdtget -t x "$tmpdir/z96a.dtb" "$npu" rknpu-supply >/dev/null 2>&1; then
  printf '%s\n' 'Do not bind the NPU supply before the Z96A rail mapping is confirmed.' >&2
  exit 1
fi

vdd_node=$(fdtget -t s "$tmpdir/z96a.dtb" /__symbols__ vdd_npu)
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$vdd_node" regulator-name)" == vdd_npu ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-min-microvolt)" == 500000 ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-max-microvolt)" == 1350000 ]]
if fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-init-microvolt >/dev/null 2>&1; then
  printf '%s\n' 'Do not assign an NPU rail voltage before board-level verification.' >&2
  exit 1
fi

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
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$bus_npu" status)" == disabled ]]

if grep -Eq '/rknpu\.ko$' <<<"$members"; then
  printf '%s\n' 'RKNPU must be built into the kernel, not packaged as a module.' >&2
  exit 1
fi

printf 'Verified BSP package: %s\n' "$package"
printf 'Kernel release: %s\n' "$kernel_release"
