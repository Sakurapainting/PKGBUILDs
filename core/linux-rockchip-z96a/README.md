# Z96A Rockchip BSP Kernel

This package builds Rockchip BSP Linux `6.1.172` from the Sakurapainting
`rockchip-linux-kernel` fork, pinned to commit
`77168c8d5ab82399f65a80e9f807b50ba37cf483`. The kernel includes Rockchip RKNPU,
its CMA DMA heap, and the Rockchip IOMMU.

Release `6.1.172-8` enables the NPU and its IOMMU with the on-board RK809
DCDC_REG4 (`vdd_npu`). The board's original DTB identifies the same regulator
and specifies the default 875 mV at 600 MHz. The BSP DTS keeps the NPU OPPs
through 600 MHz and the separate bus voltage scaler disabled. The RK3568J
800 MHz overdrive OPP stays disabled. This configuration matches the DTB
used for the 2026-11-25 RKNN hardware trial.

## Isolation

The package is named `linux-rockchip-z96a`. It installs only:

- `/usr/lib/linux-rockchip-z96a-bsp61/Image-rockchip-z96a-bsp61`
- `/usr/lib/linux-rockchip-z96a-bsp61/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb`
- `/usr/lib/modules/6.1.172-8-z96a-bsp61/`
- `/etc/mkinitcpio.d/linux-rockchip-z96a.preset`
- `/var/lib/linux-rockchip-z96a/` for the generated initramfs
- `/usr/share/doc/linux-rockchip-z96a/` for the config and build metadata

Release `6.1.172-1` included a `vmlinuz` symlink under the BSP module directory.
The Arch Linux ARM pacman hook matched it and generated the BSP initramfs in
`/boot` during `pacman -U`. Release `6.1.172-2` and later omit the hook
trigger and set the preset output to
`/var/lib/linux-rockchip-z96a/initramfs-linux-rockchip-z96a-bsp61.img`.
CI checks the BSP-only transaction with mkinitcpio already installed. Keep
mkinitcpio and other package changes out of the device staging transaction
so unrelated hooks cannot change the mainline files.

## Recovery Gate

On 2026-11-24 the FT232R captured DDR initialization and U-Boot at 1.5 Mbaud.
`Ctrl+C` at autoboot opened the U-Boot prompt. `run bootcmd` loaded the `linux`
entry and booted `7.2.10-1-aarch64-ARCH` to the serial login prompt. The Linux
getty responded at 115200 baud in that test. When the firmware printed
`wait power key press down`, pressing the device power key advanced the boot.

Board TX idle measured about 1.78 V. This FT232R's 3.3 V jumper position worked
for interactive login and U-Boot input. Adapter TXD measured 1.8 V unloaded
and about 0.5 V connected to board RX in the 1.8 V position. An earlier test
measured about 2.2 V connected in the 3.3 V position. The connector's input
rating and the adapter's VCCIO remain unverified.

1. Record `findmnt -T /boot` and `df -B1 -T /boot`. Inspect the package's
   uncompressed Image and DTB sizes. Do not use the previously reported 49 MiB
   free as a current measurement, and do not delete existing files to make
   room. The package stages its Image and DTB under `/usr/lib`, not `/boot`.
2. Keep the current mainline files in place and record their hashes. Make and
   verify exact copies of the mainline Image, initramfs, DTB and extlinux
   configuration outside `/boot` or on external storage. If there is no
   suitable backup location, stop; do not delete files to make one. Do not
   overwrite any mainline file. If recovery depends on booting the backup
   from another partition or medium, test that path from U-Boot first.
   The current mainline extlinux stanza uses
   `/Image`, `/initramfs-linux.img`, and
   `/dtbs/rockchip/rk3568-sunniwell-z96a-typec.dtb`.
3. The board DTS assigns the RK3568 UART2 M0 I/O domain, `PMUIO2`, to a
   1.8 V regulator. Verify the external Debug connector's RX input rating
   and the adapter's TXD voltage separately before choosing a jumper setting
   for another adapter. Wire board TX to adapter RXD and board RX to adapter
   TXD, with common GND. Leave all power pins disconnected. Use 1500000 baud,
   8N1, no hardware flow control.
4. Use `Ctrl+C` at the U-Boot autoboot prompt. Verify that you can reach the
   menu or command line and manually boot the existing `linux` entry to the
   mainline login prompt. Complete this recovery test before testing BSP.
5. After CI verifies `6.1.172-8`, confirm mkinitcpio and
   `linux-firmware-realtek` are installed. Use `pacman -U` for the BSP package,
   then run `mkinitcpio -p linux-rockchip-z96a` and confirm it produces the
   staged initramfs. Compare the `/boot` file hashes before installation,
   after `pacman -U`, and after running the preset.
6. On the verified eMMC layout, stage the Image, DTB, initramfs and a separate
   extlinux configuration together on the ext4 root partition, `/dev/mmcblk0p10`.
   Run the following as root after confirming `/` is that partition.

   ```sh
   stage=/var/lib/linux-rockchip-z96a/bootcheck-6.1.172-8
   src=/usr/lib/linux-rockchip-z96a-bsp61
   install -Dm644 "$src/Image-rockchip-z96a-bsp61" "$stage/Image"
   install -m644 "$src/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb" "$stage/board.dtb"
   install -m644 /var/lib/linux-rockchip-z96a/initramfs-linux-rockchip-z96a-bsp61.img "$stage/initramfs.img"
   cat > "$stage/extlinux.conf" <<CFG
   timeout 10
   default linux-bsp61

   label linux-bsp61
           kernel $stage/Image
           initrd $stage/initramfs.img
           devicetree $stage/board.dtb
           append earlycon=uart8250,mmio32,0xfe660000 root=PARTLABEL=ROOT rootwait rw
   CFG
   sync
   ```

7. Interrupt the vendor U-Boot from the serial console and run this command
   for the one-time BSP boot. This U-Boot uses hexadecimal partition numbers,
   so `0:a` selects partition 10 on eMMC device 0.

   ```text
   sysboot mmc 0:a any 0x00c00000 /var/lib/linux-rockchip-z96a/bootcheck-6.1.172-8/extlinux.conf
   ```

   If the BSP stops before login, select the saved `linux` entry in the regular
   extlinux menu. The BSP trial uses its own config on the root filesystem.
8. After the trial passes, back up the existing BSP files and extlinux config
   outside `/boot`. Install the tested BSP Image, initramfs and DTB into their
   matching BSP paths on the FAT partition. Check the mainline file hashes,
   set `default linux-bsp61` in `/boot/extlinux/extlinux.conf`, and verify the
   default through a normal U-Boot boot. The `linux` menu entry remains the
   installed system's mainline recovery entry.

## Build Verification

The `Z96A Rockchip BSP kernel` Actions workflow runs only for changes under this
package, the BSP workflow and image scripts, manual dispatch, or a dedicated
`z96a-bsp-v*` tag.
It builds the pinned kernel package, checks its staged paths, config and DTB
with `verify-package.sh`, and exercises installation and explicit preset
execution with `verify-install.sh` in a disposable Arch Linux ARM rootfs. The
workflow compares `/boot` manifests before install, after `pacman -U`, and
after `mkinitcpio -p linux-rockchip-z96a`. It inspects the staged archive for
the expected BSP release before uploading the package. It checks that the
RTL8822CS SDIO alias resolves to the driver and its three dependency modules.
It checks that both firmware files are installed and that the Mali GPU
modalias resolves to Panfrost with its DRM dependencies.

On 2026-11-24 the install and boot-file isolation checks passed on the
Z96A for `6.1.172-2` with mkinitcpio `42.2-1`.
The generated initramfs was 15,194,025 bytes. The BSP boot files were copied
to their separate paths, and the original mainline Image, initramfs, and DTB
still matched their recorded hashes. The extlinux default is `linux`.

The verifier checks that RKNPU is `=y`, the CMA heap and IOMMU are enabled,
clock/reset/power-domain/OPP/IOMMU properties are present, the NPU and IOMMU
are enabled with the DCDC_REG4 supply, the separate bus scaler is disabled,
no OPP above 600 MHz is enabled, and the package contains no mainline boot
path or `rknpu.ko`. It also checks that the RK808 clock driver is built in
and that the VOP clock assignments and parents are present without forced
clock rates.

### Actions artifacts

- `z96a-rockchip-bsp61` contains the verified package and its SHA-256 digest.
- `z96a-bsp-patches` includes the numbered package patches, DTS and config
  inputs, and `bsp-to-z96a.patch`, the complete diff against the pinned BSP
  commit, including the rtw88 import.
- `z96a-rockchip-flash-image` contains the raw BOOT/ROOT image, compressed with
  Zstandard, with layout, hashes and the [Rockchip flashing guide](flash-image.zh-CN.md).
- `z96a-rockchip-flash-image-niri` is the same flash layout with SDDM and Niri
  preinstalled. Select `image_profile=niri` when dispatching the BSP workflow.
  To rebuild only the image, also set `kernel_run_id` to a run whose `build`
  job passed and whose `z96a-rockchip-bsp61` artifact has not expired.

## Device Acceptance

The vendor U-Boot log reports `PMIC: RK8090` and `vdd_npu init 900000 uV`.
The DTB extracted from this board’s original Android boot partition confirms
DCDC_REG4. The trial used RKNN Runtime 2.3.2 with a known-output FP16 model and
measured RKNPU utilization. Some initial image-model runs on the default DMA
heap returned incorrect classifications, while sustained image-model tests
passed with a process-local switch to the uncached heap.

The first `6.1.172-2` hardware boot on 2026-11-24 loaded all three BSP boot
files through `sysboot -p` and entered the kernel. During `rockchip_drm_init`,
`of_clk_set_defaults` led to a PLL lock timeout. The PLL driver recursively
retried restoring its saved parameters until the kernel stack overflowed.
The test ended before mounting the root filesystem.

A second boot reused the same BSP Image and initramfs, using a separate
extlinux configuration and a DTB with only the VOP node's
`assigned-clock-rates` property removed. The original DTB requested 132 MHz
for VPLL and DCLK_VOP1. The diagnostic boot showed no PLL lock timeouts, bound
the VOP and HDMI DRM components, mounted `/dev/mmcblk0p10` read/write, and
reached an interactive serial login at 1.5 Mbaud with systemd `running`.
The board had only a loopback network interface; the SDIO power-sequence
device and MMC host both reported deferred probes.

The RK809 MFD creates a clock child named `rk817-clkout` that the BSP clock
driver did not match. Temporarily binding that child to the existing driver
restored the 32.768 kHz clock for `sdio-pwrseq` and let `fe2c0000.mmc`
enumerate SDIO function `024C:C822` (Realtek RTL8822CS). This fixed SDIO
enumeration, not Wi-Fi: the pinned BSP rtw88 does not support this SDIO part,
and the test still showed only loopback.

Release `6.1.172-3` boots with the VOP clock change and the `rk817-clkout`
match. On 2026-11-25 it reached serial login, mounted the eMMC root read/write,
and enumerated RTL8822CS without a manual clock-driver override. Temporarily
loaded rtw88 modules then brought up `wlan0`, obtained an IPv4 address, and
allowed SSH over Wi-Fi. Release `6.1.172-4` booted from the eMMC root and
loaded the packaged modules automatically, but repeatedly logged
`unsupported rf path (1)` and failed to associate. Reloading the packaged
modules restored Wi-Fi. Hardware acceptance for `6.1.172-5` checks whether
NetworkManager reconnects automatically after initial driver probe. On
2026-11-25 the eDP DTB for `6.1.172-6` was tested with the `6.1.172-5` CI
Image and initramfs. The 1920-by-1080 SDDM greeter was visible after a
controlled modeset. A second boot automatically started the greeter,
attached the Xorg framebuffer to VP1 and established Wi-Fi. The native
`6.1.172-6` package also booted to a visible SDDM greeter, but Niri had no
usably accelerated renderer. A separate test kernel with the Panfrost
configuration and GPU DTB for `6.1.172-7` reached a visible Niri Wayland
desktop at 1920×1080 at 60.024 Hz. The Niri process opened the Mali-G52
render node and Wi-Fi connected automatically.
Physical HDMI output has yet to be verified.

For RKNPU smoke testing, confirm the BSP release, the driver and IOMMU probe
messages, and `/dev/rknpu`. Use a known-output model and the official RKNN
Runtime for RK3568 to compare inference with CPU reference values while reading
`load` and `freq` under `/sys/kernel/debug/rknpu/` or `/proc/rknpu/`.
