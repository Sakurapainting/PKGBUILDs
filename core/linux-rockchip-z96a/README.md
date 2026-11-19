# Z96A Rockchip BSP Kernel

This package builds Rockchip BSP Linux `6.1.172` from the Sakurapainting
`rockchip-linux-kernel` fork, pinned to commit
`77168c8d5ab82399f65a80e9f807b50ba37cf483`. RKNPU is built into the kernel
with the BSP's Rockchip CMA DMA heap, IOMMU and 64 MiB CMA configuration, but
the NPU, MMU and bus nodes remain disabled in the Z96A DTB pending confirmation
of the board's PMIC and NPU rail mapping.
The `crypto_lz4` module is included for the systemd-based mkinitcpio hooks used
by the Z96A image.

The BSP DTS variant uses the Z96A board definitions and BSP RK3568 SoC topology.
The board DTS was ported to the BSP SoC's labels and graph, including its USB
and HDMI endpoints; the mainline DTS patch is not applied verbatim. It keeps
the RK3568 RKNPU nodes disabled pending board-level power confirmation.
The BSP DTS preserves the Z96A regulator declaration, adds no initial voltage,
does not attach that regulator to the NPU, and leaves the NPU, MMU and bus
disabled until board-level PMIC and rail constraints are confirmed. Its NPU
OPP table is capped at 600 MHz and the 800 MHz RK3568J overdrive OPP remains
disabled, but those settings do not enable the device.

## Isolation

The package is named `linux-rockchip-z96a`. It installs only:

- `/usr/lib/linux-rockchip-z96a-bsp61/Image-rockchip-z96a-bsp61`
- `/usr/lib/linux-rockchip-z96a-bsp61/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb`
- `/usr/lib/modules/6.1.172-1-z96a-bsp61/`, including a `vmlinuz` symlink
  to the staged image for mkinitcpio discovery
- `/etc/mkinitcpio.d/linux-rockchip-z96a.preset`, which generates
  `/boot/initramfs-linux-rockchip-z96a-bsp61.img`

The package contains no `/boot` files and does not modify `/boot`, the mainline
modules, or the mainline DTB. It also contains no `/usr/lib/initcpio` trigger,
because the system-wide mkinitcpio hook would rebuild every preset. Generate
the BSP initramfs explicitly to a staging path, check that the Image, DTB and
initramfs fit, then copy all three to uniquely named `/boot` paths. The
mainline initramfs and extlinux configuration remain untouched until the
separate manual boot-entry step. The BSP workflow uploads a package artifact
and never deploys it to a device.

## Recovery Gate

Device deployment is not yet authorized. The current board's `/boot` usage,
mount layout, and exact files have not been measured in this workspace, and the
FT232RL adapter has not arrived. Do not install the staging package before the
UART recovery and backup checks. Do not copy anything to `/boot`, edit extlinux
or reboot into BSP until the final capacity check below passes.

1. Record `findmnt -T /boot` and `df -B1 -T /boot`. Inspect the package's
   uncompressed Image and DTB sizes. Do not use the previously reported 49 MiB
   free as a current measurement, and do not delete existing files to make
   room. The package stages its Image and DTB under `/usr/lib`, not `/boot`.
2. Keep the current mainline files in place and record their hashes. Make and
   verify exact copies of the mainline Image, initramfs, DTB and extlinux
   configuration outside `/boot` or on external storage. If there is no
   suitable backup location, stop; do not delete files to make one. Do not
   overwrite any mainline file. The current mainline extlinux stanza uses
   `/Image`, `/initramfs-linux.img`, and
   `/dtbs/rockchip/rk3568-sunniwell-z96a-typec.dtb`.
3. Before connecting the adapter to the board, verify its VCCIO circuitry and
   jumper settings; measure TXD idle near 1.8 V, confirm RXD recognizes the
   board's 1.78 V TX and that the adapter supports 1.5 Mbps. Do not connect
   board VCC, 3.3 V or 5 V. Wire board TX to adapter RXD, board RX to adapter
   TXD, and common GND only. Use 1500000 baud, 8N1, no hardware flow control.
4. First passively record a complete mainline boot. Then verify that the
   console can interrupt U-Boot, show its menu/command line, and manually boot
   the existing mainline entry. Until this succeeds, UART is not a recovery
   path and BSP must not be tested.
5. Only after the UART and backup checks, install the BSP package. This does
   not write to `/boot` or invoke `mkinitcpio -P`. Generate the initramfs to a
   non-`/boot` staging path, then compare all three file sizes with current
   `/boot` availability, reserving at least 1 MiB for filesystem allocation:

   ```sh
   stage=/usr/lib/linux-rockchip-z96a-bsp61
   image="$stage/Image-rockchip-z96a-bsp61"
   dtb="$stage/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb"
   initrd=/var/tmp/initramfs-linux-rockchip-z96a-bsp61.img
   sudo mkinitcpio -k 6.1.172-1-z96a-bsp61 \
     -g "$initrd"
   required=$(stat -c %s "$image" "$dtb" "$initrd" |
     awk '{ total += $1 } END { print total + 1048576 }')
   available=$(df -B1 --output=avail /boot | tail -n 1 | tr -d ' ')
   printf 'required=%s available=%s\n' "$required" "$available"
   test "$available" -ge "$required"
   ```

   If the test fails, do not copy anything to `/boot`, edit extlinux, or reboot.
   Uninstall only the staging package with `sudo pacman -R linux-rockchip-z96a`
   and leave the CI artifact as the deliverable; existing mainline files remain
   untouched. If it fits, copy the three staged files to their unique `/boot`
   paths:

   ```sh
   sudo install -Dm644 "$image" /boot/Image-rockchip-z96a-bsp61
   sudo install -Dm644 "$dtb" \
     /boot/dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb
   sudo install -Dm644 "$initrd" \
     /boot/initramfs-linux-rockchip-z96a-bsp61.img
   ```

   Then add the manual stanza below. Keep `default linux` and the existing
   timeout unchanged. Do not change U-Boot environment or flash a bootloader.

Manual extlinux stanza, to be appended only after the gate passes:

```text
label linux-bsp61
        kernel /Image-rockchip-z96a-bsp61
        initrd /initramfs-linux-rockchip-z96a-bsp61.img
        devicetree /dtbs-rockchip-z96a-bsp61/rk3568-sunniwell-z96a-typec-bsp61.dtb
        append earlycon=uart8250,mmio32,0xfe660000 root=PARTLABEL=ROOT rootwait rw
```

The BSP entry is a one-time manual selection. If BSP fails, reset or power
cycle, interrupt U-Boot using the already verified UART, and select `linux`;
the unchanged default is also `linux`. Restore the saved extlinux configuration
to remove the temporary entry. The original mainline paths stay untouched, so
the recovery does not depend on SSH or on BSP booting successfully. This is a
designed recovery path, not a hardware-validated one yet.

## Build Verification

The `Z96A Rockchip BSP kernel` Actions workflow runs only for changes under this
package, its own workflow, manual dispatch, or the dedicated `z96a-bsp-v*` tag.
It builds the pinned kernel package, checks its staged paths, config and DTB
with `verify-package.sh`, exercises package/initramfs generation in a
disposable CI rootfs, then uploads the package. It does not install anything
on the Z96A.

The verifier checks that RKNPU is `=y`, the CMA heap and IOMMU are enabled,
clock/reset/power-domain/OPP/IOMMU properties are present, the NPU, MMU and bus
stay disabled without an attached supply, no NPU OPP above 600 MHz or enabled
RK3568J overdrive node is present, and the package contains no mainline boot
path or `rknpu.ko`.

## Device Acceptance

No hardware boot or NPU inference has been performed by this package change.
The current DTB deliberately does not probe RKNPU. Confirm the PMIC part and
NPU rail routing from a Z96A schematic or safe electrical measurement before
preparing a later DTB that enables it. After that evidence and the recovery
gate pass, boot the BSP and check `uname -r`, `dmesg` for RKNPU probe/IOMMU
messages, `/dev/rknpu`, `/sys/kernel/debug/rknpu/`, and `/proc/rknpu/`. The BSP
driver implements `version`, `load`, `power`, `freq`, `volt`, `delayms`, and
`reset` under its debugfs/procfs directories.

For inference, use the official RKNN Runtime/Lite2 build for RK3568 and a
compatible RKNN model. Record NPU `load`/`freq` and driver logs during the
vision example, and verify that utilization/frequency changes during the run;
a successful output alone does not prove execution on NPU. Do not report NPU
validation until that hardware test is complete.
