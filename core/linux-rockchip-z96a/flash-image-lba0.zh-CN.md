# Sunniwell Z96A Arch Linux ARM 完整 eMMC 镜像（LBA0）

这是给 Rockchip RK3568 / Sunniwell Z96A 使用的**整盘原始镜像**。解压后的 `.img` 从 LBA0 开始，大小为 61,071,360 × 512 = 31,268,536,320 字节（约 31.27 GB / 29.11 GiB），包含 GPT、启动固件区、BOOT 和 ROOT。请确认目标 eMMC 容量至少为该大小；此镜像按 Z96A 已核对的 32 GB eMMC 几何制作。

## 重要：会清空整颗 eMMC

这不是只更新 Arch 分区的镜像。向 LBA0 烧写会覆盖 GPT 和整颗 eMMC，包括原有 Android/厂商分区、设备内可能存在的安全数据和用户文件。镜像刻意不带原设备的 `security`、`proinfo`、Android `boot`、`dtbo`、`vbmeta` 等数据；这些分区在新 GPT 中保留布局但内容清零。请先确认已保存需要的文件，并仅在能接受抹除原系统的设备上操作。不要把本镜像写到电脑硬盘、SD 卡或其他容量不足的设备。

预设普通用户为 `alarm`，初始密码为 `alarm`。首次登录后请立即改密。Niri 桌面版预装 SDDM、Niri、Panfrost、Foot 和 Fuzzel；镜像没有个人 Wi-Fi 配置。root 首启锁定并由串口流程设置密码，SSH 默认关闭。

## 校验并解压

先在包含下载产物的目录中核对 SHA-256，再解压。注意解压后的完整 `.img` 约 31.27 GB；烧录工具不能直接把 `.xz` 当作裸盘镜像写入。

```sh
sha256sum -c SHA256SUMS
xz -dk -- *.img.xz
sha256sum -c RAW-SHA256SUMS
```

## Windows 瑞芯微开发工具（RKDevTool）

1. 进入目标 Z96A 的 Rockusb Loader 或 Maskrom 模式，并确认工具识别的是这块板。
2. 若处于 Maskrom，使用你已验证适用于 RK3568 的 `MiniLoaderAll.bin` 作为独立的 Boot/Loader 下载项（常见地址 `0xCCCCCCCC`），让工具先把 loader 下载到 RAM 并切入 Rockusb。这个 Boot 项是临时 loader，不是本镜像中的 GPT/分区，也不要把它与下方 system 镜像混成一项。已经在 Loader 模式时不需要重复下载。
3. 将解压得到的 `z96a-archarm-*-lba0.img` 设为 `system` 裸镜像，地址 `0x00000000`。勾选并写入 system 项；它必须是解压后的 `.img`，不要选 `.xz`。
4. 执行前再确认目标是 Z96A 的 eMMC、system 地址为 `0x00000000`、文件名带 `lba0`，且接受清除原 eMMC 全盘数据。写入结束后重启板子。

如工具弹出容量、分区或写入范围不匹配，不要强行继续；先取消并核对 eMMC 容量和文件是否完整。

## 镜像布局与离线校验

镜像使用标准 GPT，分区起始 LBA 与 Z96A 板上已核对的布局相同：`security` 8192、`uboot` 16384、`trust` 24576、`misc` 32768、`proinfo` 40960、`dtbo` 49152、`vbmeta` 57344、`boot` 59392、`BOOT` 190464、`ROOT` 714752。GPT 主、备表均位于镜像中；BOOT/ROOT 与只写分区镜像使用相同的文件系统映像。

Actions 会将压缩产物解压并模拟从 LBA0 写入一份与目标容量相同的稀疏虚拟磁盘，然后校验解压数据 SHA-256、GPT 两份 CRC 与分区边界、启动固件前缀、OEM/Android 分区清零，以及 BOOT/ROOT 在目标偏移上的逐字节一致性。该自动化验证不等同于在实体 Z96A 上完成一次烧录和冷启动验收；首次实际使用前仍应保留可恢复的整盘备份。
