#!/usr/bin/bash
set -euo pipefail

workspace=/work
builder=builder
packages=(
  alarm/z96a-niri-profile
  core/linux-aarch64
  alarm/z96a-typec-post-install
)

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
chown -R "$builder:users" "$workspace"

for package in "${packages[@]}"; do
  printf 'Building %s\n' "$package"
  if [[ "$package" == alarm/z96a-typec-post-install ]]; then
    runuser -u "$builder" -- env \
      HOME=/home/builder \
      MAKEFLAGS=-j2 \
      PACKAGER='Z96A GitHub Actions <actions@users.noreply.github.com>' \
      PKGDEST="$workspace/dist" \
      makepkg --nodeps --noconfirm --cleanbuild --clean \
      --dir "$workspace/$package"
  else
    runuser -u "$builder" -- env \
      HOME=/home/builder \
      MAKEFLAGS=-j2 \
      PACKAGER='Z96A GitHub Actions <actions@users.noreply.github.com>' \
      PKGDEST="$workspace/dist" \
      makepkg --syncdeps --noconfirm --cleanbuild --clean \
      --dir "$workspace/$package"
  fi

  if [[ "$package" == alarm/z96a-niri-profile ]]; then
    runuser -u "$builder" -- env \
      HOME=/home/builder \
      niri validate --config "$workspace/alarm/z96a-niri-profile/config.kdl"
  fi
done
