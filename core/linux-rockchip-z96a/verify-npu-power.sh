#!/usr/bin/env bash
set -euo pipefail

dtb=${1:?usage: verify-npu-power.sh DTB okay-or-disabled}
status=${2:?specify the expected NPU and IOMMU status}
npu=/npu@fde40000
iommu=/iommu@fde4b000
pmu=/power-management@fdd90000/power-controller
rail=/i2c@fdd40000/pmic@20/regulators/DCDC_REG4

expect() {
  local node=$1 prop=$2 type=$3 expected=$4 actual
  actual=$(fdtget -t "$type" "$dtb" "$node" "$prop")
  if [[ "$actual" != "$expected" ]]; then
    printf '%s: %s %s = <%s>, expected <%s>\n' "$dtb" "$node" "$prop" "$actual" "$expected" >&2
    return 1
  fi
}

expect "$rail" regulator-name s vdd_npu
expect "$rail" regulator-min-microvolt u 850000
expect "$rail" regulator-max-microvolt u 1350000
fdtget "$dtb" "$rail" regulator-boot-on >/dev/null
fdtget "$dtb" "$rail" regulator-always-on >/dev/null
phandle=$(fdtget -t x "$dtb" "$rail" phandle)
expect "$pmu" npu-supply x "$phandle"
expect "$npu" rknpu-supply x "$phandle"
expect "$npu" status s "$status"
expect "$iommu" status s "$status"
