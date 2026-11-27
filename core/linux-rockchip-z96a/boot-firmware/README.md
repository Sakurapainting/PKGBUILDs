# Z96A LBA0 boot components

The LBA0 builder uses `uboot-fitfix-v3-p1` from alkaid-ops. Both assets match the bytes at the corresponding LBAs in the reference Z96A Devuan image. [Upstream release](https://github.com/alkaid-ops/z96a-devuan-image/releases/tag/uboot-fitfix-v3-p1)

| Asset | Start LBA | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| `idbloader.bin` | 64 | 204800 | `35c368f3ad8d84acd756e4bb45bcbff56912b9b4a8892ac605ff35809bf683ac` |
| `u-boot.bin` | 16384 | 1288192 | `56398fb629f0cafa05cea2c930c8562ce6969325b3ce45e197086118cb2b691f` |

The image starts with a newly generated GPT. Outside the two assets, LBA 34 through 190463 are zero-filled, including Rockchip vendor storage at LBA 7168–7679 and the OEM/Android partitions. The Arch `BOOT` and `ROOT` offsets remain 190464 and 714752.

The upstream release describes `idbloader.bin` as a prebuilt DDR 1560 v1.13 and SPL combination. The FIT uses alkaid-ops' U-Boot build. The DDR component is a binary and the exact SPL source provenance is unverified.

For a local build, set `Z96A_LBA0_IDBLOADER` and `Z96A_LBA0_UBOOT_FIT` to the corresponding files and supply an LBA0 output directory to the image builder. The builder checks both hashes before writing the prefix. The BOOT/ROOT filesystem image can be built without the two assets. Actions downloads them only when the repository's image job is enabled.
