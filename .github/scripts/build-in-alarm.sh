#!/usr/bin/bash
set -euo pipefail

workspace=/work
builder=builder

prepare_builder() {
  pacman-key --init
  pacman-key --populate archlinuxarm
  pacman -Syu --noconfirm
  pacman -S --needed --noconfirm base-devel git sudo

  if ! id "$builder" >/dev/null 2>&1; then
    useradd --create-home --gid users --shell /bin/bash "$builder"
  fi

  install -d -m0750 /etc/sudoers.d
  printf '%s\n' 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/builder
  chmod 0440 /etc/sudoers.d/builder
  visudo -cf /etc/sudoers.d/builder

  install -d -o "$builder" -g users "$workspace/dist"
}

build_package() {
  local package=$1
  shift
  printf 'Building %s\n' "$package"
  chown -R "$builder:users" "$workspace/$package"
  runuser -u "$builder" -- env \
    HOME=/home/builder \
    MAKEFLAGS=-j2 \
    PACKAGER='Z96A GitHub Actions <actions@users.noreply.github.com>' \
    PKGDEST="$workspace/dist" \
    makepkg "$@" --noconfirm --cleanbuild --clean --dir "$workspace/$package"

  find "$workspace" -type f -name '*.pkg.tar.zst' \
    ! -path "$workspace/dist/*" \
    -exec install -m0644 -t "$workspace/dist" -- {} +

  if ! compgen -G "$workspace/dist/*.pkg.tar.zst" >/dev/null; then
    printf 'No package archive found after building %s\n' "$package" >&2
    exit 1
  fi
}

case "${1:-}" in
  prepare) prepare_builder ;;
  desktop) build_package alarm/z96a-niri-profile --syncdeps ;;
  validate-desktop)
    pacman -U --noconfirm "$workspace"/dist/z96a-niri-profile-*.pkg.tar.zst
    runuser -u "$builder" -- env \
      HOME=/home/builder \
      niri validate --config /usr/share/z96a-niri-profile/niri/config.kdl
    ;;
  kernel) build_package core/linux-aarch64 --syncdeps ;;
  board) build_package alarm/z96a-typec-post-install --nodeps ;;
  *)
    printf 'Usage: %s {prepare|desktop|validate-desktop|kernel|board}\n' "$0" >&2
    exit 2
    ;;
esac
