#!/usr/bin/env bash
set -euo pipefail

idbloader=$(realpath -e "${1:?usage: make-prefix.sh IDBLOADER UBOOT_FIT OUTPUT}")
fit=$(realpath -e "${2:?missing U-Boot FIT}")
output=$(realpath -m "${3:?missing output file}")
[[ ! -e "$output" && ! -L "$output" ]]

printf '%s  %s\n' \
  35c368f3ad8d84acd756e4bb45bcbff56912b9b4a8892ac605ff35809bf683ac "$idbloader" \
  56398fb629f0cafa05cea2c930c8562ce6969325b3ce45e197086118cb2b691f "$fit" |
  sha256sum --check --strict

prefix=$(mktemp -- "${output}.XXXXXXXX")
trap 'rm -f -- "$prefix"' EXIT
truncate -s "$((190464 * 512))" "$prefix"
dd if="$idbloader" of="$prefix" bs=512 seek=64 conv=notrunc status=none
dd if="$fit" of="$prefix" bs=512 seek=16384 conv=notrunc status=none
mv -nT -- "$prefix" "$output"
[[ ! -e "$prefix" ]]
