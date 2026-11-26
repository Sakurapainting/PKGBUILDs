# Sunniwell Z96A Arch Linux ARM 烧录镜像

镜像用于 RK3568 Z96A 的 eMMC。它包含 Arch Linux ARM 基础系统、Realtek 固件、NetworkManager 和 Actions 构建的 BSP 内核。开机默认进入 `linux-bsp61`，该启动项带 `movablecore=256M`，用于规避 RKNPU 在这块板上使用高地址内存时出现的推理超时。菜单另有禁用 NPU 的 BSP 救援项。系统提供内屏及串口登录。首启在控制台设置 root 密码，SSH 默认关闭。`layout.json` 中的 `profile` 标记镜像类型：`minimal` 不预装桌面，`niri` 预装 SDDM、Niri、Panfrost（Mesa）、Foot 和 Fuzzel。两种镜像使用相同的 BOOT/ROOT 位置和烧录方法。

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

通过 USB 进入 Rockusb Loader 后，确认只连了一台目标设备，并用 `rfi` 核对存储为 eMMC。用 `rl` 只读提取 GPT，再用镜像附带的脚本核验分区名、起始 LBA、长度及写入范围。若设备显示为 Maskrom，先用该板适用的 Loader 进入 Rockusb。镜像不包含 Loader。

```sh
sudo rkdeveloptool ld
sudo rkdeveloptool rfi
sudo rkdeveloptool rl 0 128 gpt.bin
python3 check-flash-layout.py layout.json gpt.bin
```

布局全部匹配后，在已解压镜像的目录中按 `0x2E800` 写入，然后重启。使用 RKDevTool 图形界面时选择同一裸镜像和同一扇区地址。LBA `0` 对应 GPT 所在区域。

```sh
sudo rkdeveloptool wl 0x2E800 ./*.img
sudo rkdeveloptool rd
```

首次启动可连接内屏键盘或 UART（Linux 控制台 `ttyS0`，1500000 8N1），按提示设置 root 密码。如果固件提示 `wait power key press down`，短按板子电源键。首次使用 pacman 前执行 `pacman-key --init` 和 `pacman-key --populate archlinuxarm`。

## Niri 桌面版首次登录

桌面版自动启动 SDDM，不预设桌面账号密码，也不包含个人 Wi-Fi 配置。完成 root 首启设置后，在串口或按 `Ctrl+Alt+F3` 打开的文本控制台以 root 登录，创建桌面用户并设置密码：

```sh
useradd -m -g users -s /bin/bash alarm
passwd alarm
```

在内屏切回 SDDM（若使用了 `Ctrl+Alt+F3`，按 `Ctrl+Alt+F2` 返回登录界面），选择 **Niri** 会话并用 `alarm` 登录。`Super+Enter` 打开 Foot，`Super+D` 打开 Fuzzel。NPU 禁用的恢复启动项仍进入文本模式，不会启动 SDDM。

## 首启工具和 RKNN 离线自检

镜像自带 `fastfetch`、`iw`、`lsusb` 和 `fsck.fat`。首启登录后即可查看系统、无线网卡和 USB 设备状态。检查 BOOT 文件系统时先卸载该分区。

在默认 BSP 下，以 root 运行 `z96a-rknn-selftest`。它用随镜像安装的 Rockchip RKNN Runtime 2.3.2 运行 RK3568 FP16 卷积，每次将 14,400 个输出与 CPU 参考值逐一比对。成功时打印 `PASS`，同时报告通过次数和最大偏差。默认运行 5 秒，可用 `z96a-rknn-selftest 30` 延长到 30 秒。普通用户可用 `sudo z96a-rknn-selftest`。

运行库来自 Rockchip 的 RKNN Model Zoo `v2.3.2`，授权文本位于 `/usr/share/licenses/z96a-rknn/LICENSE`。自检模型的生成脚本在 BSP 源码的 `rknn-selftest/` 目录中。

已装 Arch Linux ARM 且希望保留当前系统和用户数据的设备，可以安装 `layout.json` 中 `kernel_build_run_id` 所对应的 BSP 内核包，并在使用 RKNPU 的 BSP 启动项的 `append` 行添加 `movablecore=256M`。

Rockchip 工具源代码和命令说明见 `https://github.com/rockchip-linux/rkdeveloptool`。
