# Z96A-PD Niri profile

This package adds a small Niri-based Wayland session to the verified Z96A-PD
system. It does not change the kernel, device tree, boot entry, SSH service, or
currently installed desktop packages. It also does not enable greetd or change
the active display manager during installation.

The package supplies configuration and pulls desktop components from the
Arch Linux ARM repositories. It does not compile or bundle their binaries.

## What each component does

| File or component | Role |
| --- | --- |
| `config.kdl` | Niri manages displays, input, and tiled windows. This file enables touchpad tap and natural scrolling, configures window gaps, defines shortcuts, and starts Waybar, Mako, and Swayidle on login. |
| `waybar.jsonc` and `waybar.css` | Waybar is the top status bar. JSON chooses its modules: workspaces and window title on the left; volume, battery, clock, and tray on the right. CSS controls colors, spacing, and warning styles. The volume module can mute the default output via `wpctl`. |
| `greetd.toml` | greetd is the local login service. The example runs the text login screen `tuigreet` on virtual terminal 1 under the `greeter` account. It shows the time, remembers the username, and starts `niri-session` as the authenticated user. It does not log in automatically or handle SSH. |
| Fuzzel, Foot, Mako, and Polkit agent | Fuzzel is the app launcher (`Super+D`), Foot is the terminal (`Super+Enter`), and Mako shows desktop notifications. The Polkit agent displays authorization prompts for desktop actions that need elevated privileges. |
| Swayidle and Swaylock | Swayidle runs Swaylock after 10 minutes of inactivity and before sleep, and turns off the display after 15 minutes of inactivity. Turning the display off is not system suspend. `Super+Alt+L` locks the screen manually. |
| GTK portal and `portals.conf` | The portal broker lets apps request desktop UI such as file pickers. The optional example selects GTK and is shipped under `/usr/share/z96a-niri-profile/`; it is not active by itself. The package does not overwrite Niri's packaged portal config or set up screen sharing. |
| XWayland and XWayland Satellite | Compatibility for older X11 applications under the Wayland session. |
| PipeWire and WirePlumber | PipeWire handles media, `pipewire-pulse` provides PulseAudio compatibility for clients such as the Waybar volume module, and WirePlumber manages audio devices and routing. |
| `journald.conf` and `journal-tmpfiles.conf` | Keep system logs across reboots and ensure the persistent journal directory exists, so logs can be inspected over SSH. |

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

Both workflows use an Arch Linux ARM AArch64 rootfs on a GitHub-hosted ARM
runner. Neither installs anything on the device.

| Trigger | Result |
| --- | --- |
| Changes to this profile or its CI files on `z96a-niri` | `z96a-niri.yml` builds and test-installs the profile, runs `niri validate`, and uploads the `z96a-niri-profile` artifact without building the kernel. |
| Changes under `core/linux-aarch64/` or `alarm/z96a-typec-post-install/` on `z96a-niri` | `z96a-build.yml` builds the kernel and board packages and uploads the `z96a-aarch64-platform` artifact. |
| Manually run `z96a-build.yml`, or push a `z96a-kernel-ci-*` tag | Run the kernel and board build without creating a Release. Use this to test platform CI changes when the package inputs did not change. |
| Push a `z96a-v*` tag | Build both sets of packages in parallel, upload their separate artifacts, and create a GitHub Release containing both sets after they pass. |

The profile itself does not remove Plasma. Compare idle memory and application
load only after switching sessions, with the same display and workload.
