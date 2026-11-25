# Sunniwell Z96A Arch Linux ARM 烧录镜像

镜像用于 RK3568 Z96A 的 eMMC。它包含干净的 Arch Linux ARM 基础系统、Realtek 固件、NetworkManager 和本次 Actions 构建的 BSP 内核。开机默认进入 `linux-bsp61`，另有禁用 NPU 的 BSP 救援项。系统提供内屏及串口登录。首启在控制台设置 root 密码，SSH 默认关闭。RKNN 用户态 Runtime 和桌面环境单独安装。

## 适用分区布局

设备需要已有能从 eMMC FAT 分区读取 extlinux 的 Z96A 固件，以及下表的 GPT 布局。`layout.json` 记录起始扇区、镜像大小和内核版本。烧录会覆盖现有 Arch Linux BOOT 和 ROOT 的内容。请先备份这两个分区中的文件。GPT、U-Boot、trust 和原厂 Android 分区位于写入范围之外。空白盘和其他布局需要先准备相应固件和分区。

| GPT 分区名（区分大小写） | 起始 LBA（512 字节扇区） | 所需大小 |
| --- | --- | --- |
| `BOOT` | `0x2E800`（190464） | 正好 524288 扇区（256 MiB） |
| `ROOT` | `0xAE800`（714752） | 至少 7340032 扇区（3584 MiB） |

镜像解压后是从 `BOOT` 开始的连续原始数据，长度为 4026531840 字节。`ROOT` 按 GPT 分区大小在首启自动扩展。它是按地址写入的原始镜像，适用于 Rockchip `rkdeveloptool wl`，以及支持按 LBA 写入原始文件的 RKDevTool。它不使用 Rockchip `update.img` 固件升级容器。

## Rockchip rkdeveloptool

先校验下载文件并解压。目录内只有一个 `.img.zst` 文件。

```sh
sha256sum -c SHA256SUMS
zstd -d -- *.img.zst
sha256sum -c RAW-SHA256SUMS
```

通过 USB 进入 Rockusb Loader 后，确认只连了一台目标设备，并核对目标存储为 eMMC、GPT 名称、起始 LBA 和长度。使用 `rkdeveloptool` 的 `ld`、`rfi` 和 `ppt`。如果目标显示为 Maskrom，先用该板适用的已验证 Loader 进入 Rockusb，再检查布局。镜像不包含 Loader。

```sh
sudo rkdeveloptool ld
sudo rkdeveloptool rfi
sudo rkdeveloptool ppt
```

布局全部匹配后，在已解压镜像的目录中按 `0x2E800` 写入，然后重启。使用 RKDevTool 图形界面时选择同一裸镜像和同一扇区地址。LBA `0` 对应 GPT 所在区域。

```sh
sudo rkdeveloptool wl 0x2E800 ./*.img
sudo rkdeveloptool rd
```

首次启动可连接内屏键盘或 UART（Linux 控制台 `ttyS0`，115200 8N1），按提示设置 root 密码。如果固件提示 `wait power key press down`，短按板子电源键。首次使用 pacman 前执行 `pacman-key --init` 和 `pacman-key --populate archlinuxarm`。

已装 Arch Linux ARM 且希望保留当前系统和用户数据的设备，可以安装同一次 Actions 的 BSP 内核包并单独更新启动项。

Rockchip 工具源代码和命令说明见 `https://github.com/rockchip-linux/rkdeveloptool`。
