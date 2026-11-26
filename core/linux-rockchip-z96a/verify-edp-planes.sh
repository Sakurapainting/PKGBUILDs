#!/usr/bin/env bash
set -euo pipefail

dtb=${1:?usage: verify-edp-planes.sh DTB}
ports=/vop@fe040000/ports

check() {
  local port=$1 property=$2 expected=$3 actual
  actual=$(fdtget -t x "$dtb" "$ports/port@$port" "$property")
  if [[ "$actual" != "$expected" ]]; then
    printf '%s: VP%s %s = <%s>, expected <%s>\n' "$dtb" "$port" "$property" "$actual" "$expected" >&2
    return 1
  fi
}

check 0 rockchip,plane-mask 2a
check 0 rockchip,primary-plane 5 # Smart1
check 1 rockchip,plane-mask 15
check 1 rockchip,primary-plane 4 # Smart0 on eDP
