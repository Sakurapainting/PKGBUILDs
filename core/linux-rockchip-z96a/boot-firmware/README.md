# Z96A sanitized LBA0 boot-firmware prefix

`z96a-preboot-190464lba.bin.xz` is a 190,464-sector (97,517,568-byte) sparse-content prefix used only by the optional full-eMMC LBA0 image builder. It was extracted from the user-provided `ArchLinuxARM-aarch64-260929.img.xz` after comparison with the Z96A's captured GPT and stock U-Boot partition.

The raw prefix SHA-256 is `2168a3cdd9bdf46953ad7d965d465afeb4b75b31a99b8031974c7b0035c0dbbc`; the compressed file SHA-256 is `e9e5f45f6cd503086c1219b8e1a1f658e4fe32b248a2131cb6d78015c3c2f47e`.

It preserves only the RK3568 early boot firmware in LBA 34–8191 and the stock U-Boot/FIT partition at LBA 16384–24575. The latter was byte-compared against the board-captured `stock-uboot-p2.img`. The GPT area at LBA 0–33 is zero in this prefix and generated afresh by Actions. All other included sectors are zero, specifically excluding the source image's `security`, `misc`, `proinfo`, `dtbo`, `vbmeta`, Android `boot`, and trust partition contents. The LBA0 image builder separately verifies this prefix and its output offsets.

This is a prebuilt firmware blob sourced from the user-provided image, not a source-built/reproducible Rockchip bootloader. Its inclusion is disclosed here; users distributing or republishing the resulting image should confirm the applicable Rockchip firmware redistribution terms for their use.
