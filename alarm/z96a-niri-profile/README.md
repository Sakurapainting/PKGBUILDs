# Z96A-PD Niri profile

This package adds a small Niri-based Wayland session to the verified Z96A-PD
system. It does not change the kernel, device tree, boot entry, SSH service, or
currently installed desktop packages. It also does not enable greetd or change
the active display manager during installation.

The package contains Niri, Waybar, Fuzzel, Mako, Swaylock, Swayidle, GTK
desktop portals, a Polkit authentication agent, XWayland Satellite, Foot, and
Greetd/Tuigreet configuration. Regular applications remain installable from
the Arch Linux ARM repositories.

## Install and configure

Install only the `z96a-niri-profile` package from the Actions artifact. Keep the
known-working kernel and `z96a-typec-post-install` package as they are. Then
copy the example session files for the user who will log in:

```sh
install -Dm644 /usr/share/z96a-niri-profile/niri/config.kdl \
  "$HOME/.config/niri/config.kdl"
install -Dm644 /usr/share/z96a-niri-profile/waybar/config.jsonc \
  "$HOME/.config/waybar/config.jsonc"
install -Dm644 /usr/share/z96a-niri-profile/waybar/style.css \
  "$HOME/.config/waybar/style.css"
```

Before changing the display manager, verify that SSH works after reboot and
that `sshd.service` is enabled. Copy the greetd example only if no local greetd
configuration already exists:

```sh
sudo test -e /etc/greetd/config.toml || \
  sudo install -Dm644 /usr/share/z96a-niri-profile/greetd/config.toml \
  /etc/greetd/config.toml
# If the file already exists, set default_session.command to:
# tuigreet --time --remember --cmd niri-session
sudo systemctl enable sshd.service
sudo systemctl disable sddm.service
sudo systemctl enable greetd.service
sudo reboot
```

For SSH-only recovery if Niri does not start:

```sh
sudo systemctl disable greetd.service
sudo systemctl enable sddm.service
sudo reboot
```

The existing kernel boot entry remains unchanged. Persistent journald storage
is enabled by the profile for post-reboot diagnosis; inspect `journalctl -b`
and `journalctl -b -u greetd.service` over SSH.

## Build and release

`.github/workflows/z96a-build.yml` builds the verified kernel package, the
Z96A hardware package, and this profile in an Arch Linux ARM AArch64 rootfs on
a GitHub-hosted ARM runner and validates the Niri configuration. Each push to
`z96a-niri` publishes an Actions artifact. Pushing a tag named `z96a-v*` also
creates a GitHub Release with the package files.

The profile itself does not remove Plasma. Compare idle memory and application
load only after switching sessions, with the same display and workload.
