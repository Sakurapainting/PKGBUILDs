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
[[ "$(basename "$package")" == "linux-rockchip-z96a-${kernel_release%-z96a-bsp61}-aarch64.pkg.tar.xz" ]]
[[ "$kernel_release" == *-z96a-bsp61 ]]

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
  CONFIG_DRM_PANFROST=m \
  CONFIG_DRM_SCHED=m \
  CONFIG_DRM_GEM_SHMEM_HELPER=m \
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

drm_dir="usr/lib/modules/${kernel_release}/kernel/drivers/gpu/drm"
panfrost_module="$drm_dir/panfrost/panfrost.ko"
require_member "$panfrost_module"
require_member "$drm_dir/scheduler/gpu-sched.ko"
require_member "$drm_dir/drm_shmem_helper.ko"
bsdtar -xf "$package" -C "$tmpdir" "$panfrost_module"
vermagic=$(modinfo -F vermagic "$tmpdir/$panfrost_module")
[[ "${vermagic%% *}" == "$kernel_release" ]]
modinfo -F alias "$tmpdir/$panfrost_module" | grep -Fx 'of:N*T*Carm,mali-bifrost'

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
bash "$(dirname -- "${BASH_SOURCE[0]}")/verify-edp-planes.sh" "$dtb"

for symbol in edp edp_phy edp_in_vp1 pwm9; do
  [[ "$(fdtget -t s "$dtb" "$(dtb_node "$symbol")" status)" == okay ]]
done
panel="$(dtb_node edp)/aux-bus/panel"
[[ "$(fdtget -t s "$dtb" "$panel" compatible)" == edp-panel ]]
[[ "$(fdtget -t x "$dtb" "$panel" power-supply)" == "$(dtb_phandle vcc3v3_lcd0_n)" ]]
[[ "$(fdtget -t x "$dtb" "$panel" backlight)" == "$(dtb_phandle backlight)" ]]
[[ "$(fdtget -t x "$dtb" "$(dtb_node edp_in_vp1)" remote-endpoint)" == "$(dtb_phandle vp1_out_edp)" ]]
[[ "$(fdtget -t x "$dtb" "$(dtb_node edp_out_panel)" remote-endpoint)" == "$(dtb_phandle panel_in_edp)" ]]

gpu=$(dtb_node gpu)
gpu_opp_table=$(dtb_node z96a_gpu_opp_table)
[[ "$(fdtget -t s "$dtb" "$gpu" status)" == okay ]]
[[ "$(fdtget -t s "$dtb" "$gpu" compatible)" == 'rockchip,rk3568-mali arm,mali-bifrost' ]]
[[ "$(fdtget -t s "$dtb" "$gpu" interrupt-names)" == 'job mmu gpu' ]]
[[ "$(fdtget -t u "$dtb" "$gpu" interrupts)" == '0 40 4 0 41 4 0 39 4' ]]
[[ "$(fdtget -t s "$dtb" "$gpu" clock-names)" == 'gpu bus' ]]
[[ "$(fdtget -t x "$dtb" "$gpu" mali-supply)" == "$(dtb_phandle vdd_gpu)" ]]
[[ "$(fdtget -t x "$dtb" "$gpu" operating-points-v2)" == "$(dtb_phandle z96a_gpu_opp_table)" ]]
[[ "$(fdtget -t s "$dtb" "$gpu_opp_table" compatible)" == operating-points-v2 ]]
gpu_opps=$(fdtget -l "$dtb" "$gpu_opp_table" | sort)
[[ "$gpu_opps" == $'opp-200000000\nopp-300000000\nopp-400000000\nopp-600000000' ]]
for freq in 200000000 300000000 400000000 600000000; do
  opp_node="$gpu_opp_table/opp-$freq"
  voltage=850000
  if [[ "$freq" == 600000000 ]]; then voltage=900000; fi
  [[ "$(fdtget -t u "$dtb" "$opp_node" opp-hz)" == "0 $freq" ]]
  [[ "$(fdtget -t u "$dtb" "$opp_node" opp-microvolt)" == "$voltage $voltage 1000000" ]]
  if fdtget -t x "$dtb" "$opp_node" opp-supported-hw >/dev/null 2>&1; then
    printf 'Unexpected GPU hardware mask in %s\n' "$opp_node" >&2
    exit 1
  fi
done

npu=/npu@fde40000
npu_mmu=/iommu@fde4b000
compatible=$(fdtget -t s "$tmpdir/z96a.dtb" "$npu" compatible)
grep -qw 'rockchip,rk3568-rknpu' <<<"$compatible"
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu" status)" == okay ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu_mmu" status)" == okay ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$npu_mmu" compatible)" == rockchip,iommu-v2 ]]

for property in clocks resets power-domains iommus operating-points-v2; do
  fdtget -t x "$tmpdir/z96a.dtb" "$npu" "$property" >/dev/null
done
[[ "$(fdtget -t x "$dtb" "$npu" iommus)" == "$(dtb_phandle rknpu_mmu)" ]]
[[ "$(fdtget -t x "$dtb" "$npu" rknpu-supply)" == "$(dtb_phandle vdd_npu)" ]]
vdd_node=$(dtb_node vdd_npu)
[[ "$vdd_node" == /i2c@fdd40000/pmic@20/regulators/DCDC_REG4 ]]
[[ "$(fdtget -t s "$tmpdir/z96a.dtb" "$vdd_node" regulator-name)" == vdd_npu ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-min-microvolt)" == 500000 ]]
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-max-microvolt)" == 1350000 ]]
if fdtget -t u "$tmpdir/z96a.dtb" "$vdd_node" regulator-init-microvolt >/dev/null 2>&1; then
  printf '%s\n' 'Do not assign an NPU rail voltage before board-level verification.' >&2
  exit 1
fi

opp_table=$(fdtget -t s "$tmpdir/z96a.dtb" /__symbols__ npu_opp_table)
[[ "$(fdtget -t u "$tmpdir/z96a.dtb" "$opp_table" rockchip,init-freq)" == 600000 ]]
[[ "$(fdtget -t u "$dtb" "$opp_table/opp-600000000" opp-microvolt)" == '875000 875000 1000000' ]]
while read -r node; do
  if [[ "$node" == opp-j-od-800000000 ]]; then continue; fi
  read -r high low <<<"$(fdtget -t u "$dtb" "$opp_table/$node" opp-hz)"
  [[ "$high" == 0 && "$low" -le 600000000 ]]
done < <(fdtget -l "$dtb" "$opp_table")

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
