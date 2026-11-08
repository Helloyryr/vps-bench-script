
# Superbench v2.0 (Modernized Edition)

![Version](https://img.shields.io/badge/version-v2.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20(x86__64%20%7C%20ARM64%20%7C%20ARMv7%20%7C%20i386)-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-Bash-4EAA25.svg)

**Superbench v2.0** 是一款现代化的 Linux 服务器综合性能评测脚本。本项目基于经典的 `Superbench.sh` 与 `Bench.sh` 进行全面重构，彻底移除了过时的 Python 2 与外部解析脚本依赖，针对现代 Linux 发行版（Cgroup v2、ARM64 架构、容器及安全加固环境）进行了深度适配，重点强化了**目录权限安全**、**测试准确性**与**零残留清理机制**。

## 核心特性 (Key Features)

* **严密的目录权限自适应**：
  * **绕过 `noexec` 限制**：按 `/tmp`、`/var/tmp`、`~/.cache`、`$PWD` 优先级自动探测并实际执行微型探针脚本，选出真正支持二进制执行的隔离目录，彻底解决安全加固服务器 `/tmp` 挂载 `noexec` 导致的 `Permission denied` 报错。
  * **防 `tmpfs` 内存盘干扰**：在进行 `dd` 磁盘测试前，自动校验挂载点文件系统类型，主动过滤 `tmpfs`、`ramfs`、`devtmpfs`、`overlay`、`squashfs` 与只读目录，确保测出真实的物理块设备 I/O 性能。
  * **非 Root 权限优雅降级**：支持普通用户运行（自动识别免密 `sudo` 或降级为用户态测试），无需强制 Root 即可完成系统信息采集、I/O 读写与网络测速。
* **纯 Bash 零外部脚本依赖**：彻底告别已淘汰的 Python 2 与第三方解析工具（如 `jq`），完全使用原生 Bash 与 POSIX `awk`/`sed` 完成 JSON 解析与硬件识别。
* **全平台与多架构支持**：
  * **CPU 架构**：原生适配 `x86_64`、`aarch64` (ARM64)、`armv7l` (`armhf`)、`i386`。
  * **发行版与包管理**：支持 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux、Fedora、Alpine Linux (`apk`)、Arch Linux (`pacman`) 及 openSUSE (`zypper`)。
* **动态网络测速与全功能兜底**：
  * **智能动态节点**：集成官方最新 Ookla Speedtest CLI (1.2.0)，自动测试默认最优节点并动态拉取周边就近节点，彻底告别传统脚本硬编码节点频繁失效的问题（内置 45 秒超时保护防卡死）。
  * **全功能 Cloudflare 兜底**：当无对应架构二进制包或节点受阻时，自动回退至纯 `curl` 的 Cloudflare CDN 测速，支持**真实连接延迟、下载速度与上传速度**全项测试。
  * **双栈连通性检测**：支持 IPv4 ASN/ISP、地理位置识别及 IPv6 在线状态检测。
* **零残留安全清理与自动云端分享**：
  * 测试日志全程保存在 `mktemp -d` 隔离工作区中，测试结束后自动剥离 ANSI 颜色控制符并上传至 `paste.rs`（内置 `clbin.com` 自动故障转移）生成在线预览链接。
  * 基于 `trap` 信号捕获与子进程精准回收机制（`pkill -P $$`），无论正常结束还是 `Ctrl+C` 中断，均彻底销毁临时工作区，不在当前目录遗留任何文件。

## 快速开始 (Quick Start)

### 1. 标准完整测试（推荐）

使用 `curl` 一键运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash
```

或者使用 `wget` 一键运行：

```bash
wget -qO- https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash
```

### 2. 指定测试模式（管道传参）

```bash
# 快速测试模式（128MB 快速 I/O + 精简动态测速节点）
curl -fsSL https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- fast

# 仅查看系统与硬件信息（秒级输出）
curl -fsSL https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- info

# 仅测试磁盘 I/O 性能
curl -fsSL https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- io

# 仅执行网络测速并生成分享链接
curl -fsSL https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- speed

# 仅检测 IPv4/IPv6 双栈网络与 ASN 归属地信息
curl -fsSL https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- ip
```

### 3. 下载到本地运行

```bash
curl -fsSLO https://raw.githubusercontent.com/Helloyryr/vps-bench-script/main/superbench.sh
chmod +x superbench.sh
./superbench.sh
```

## 命令参数说明 (CLI Arguments)

| 参数选项 | 简写 | 运行模式 | 功能说明 |
| :--- | :--- | :--- | :--- |
| `all` / `bench` | `-a` | 标准模式 | **默认模式**，依次执行硬件信息、双栈 IP、磁盘 I/O、多节点测速并生成云端日志链接 |
| `fast` | `-f` | 快速模式 | 采用 128MB 数据块进行快速 I/O 测试，精简测速节点数量并生成分享链接 |
| `info` | `-i` | 仅系统信息 | 仅采集并输出 CPU、内存、磁盘、虚拟化架构、TCP 拥塞控制与内核信息 |
| `io` | `-io` | 仅磁盘测试 | 仅在真实物理磁盘目录执行三次连续写入测试并计算平均速度 |
| `speed` | `-speed` | 仅网络测速 | 仅执行 Ookla Speedtest 动态就近节点与 Cloudflare 兜底测速，并生成分享链接 |
| `ip` | `-ip` | 仅网络信息 | 仅检测 IPv4 ASN/ISP、地理位置及 IPv6 在线状态 |
| `share` | `-s` | 结果分享 | 等同于标准模式，支持附加第 2 参数指定剪贴板服务（默认 `paste_rs`，可选 `clbin`） |
| `version` | `-v` | 版本信息 | 查看当前脚本版本号与项目说明 |

## 运行输出示例 (Sample Output)

```text
----------------------------------------------------------------------
 Superbench.sh -- Modernized Edition v2.0.0
 Thanks  : Special thanks to Oldking (oldking.net) & Teddysun (teddysun.com)
 Mode    : Standard    WorkDir : /tmp/superbench.8Kx92a
----------------------------------------------------------------------
 CPU Model            : AMD EPYC 7763 64-Core Processor
 CPU Cores            : 4 Cores (2445 MHz, x86_64)
 CPU Cache            : 512 KB
 OS                   : Debian GNU/Linux 12 (bookworm) (64 Bit) kvm
 Kernel               : 6.1.0-18-amd64
 Total Space          : 6.8 GB / 49.1 GB
 Total RAM            : 412 MB / 3918 MB (890 MB Buff/Cache)
 Total SWAP           : 0 MB / 1024 MB
 Uptime               : 14 days 6 hour 22 min
 Load Average         : 0.08, 0.03, 0.01
 TCP CC               : bbr
 IPv4 ASN & ISP       : AS13335 Cloudflare, Inc.
 IPv4 Location        : Los Angeles, California / US
 IPv6 Status          : Online
----------------------------------------------------------------------
 I/O Test Directory   : /root
 I/O Speed( 1.0GB )   : 1.2 GB/s
 I/O Speed( 1.0GB )   : 1.4 GB/s
 I/O Speed( 1.0GB )   : 1.3 GB/s
 Average I/O Speed    : 1331.2 MB/s
----------------------------------------------------------------------
 Node Name             Upload Speed    Download Speed    Latency     
 Speedtest Default     942.15 Mbit/s   958.40 Mbit/s     1.82 ms     
 Frontier   Los Angel  885.40 Mbit/s   912.30 Mbit/s     3.45 ms     
 Spectrum   Los Angel  810.22 Mbit/s   890.15 Mbit/s     4.12 ms     
 GSL Networks  Los An  920.10 Mbit/s   945.80 Mbit/s     2.10 ms     
----------------------------------------------------------------------
 Finished in  : 1 min 12 sec
 Timestamp    : 2026-11-08 21:53:00 (GMT+8)
 Results Log  : /tmp/superbench.8Kx92a/superbench.log
----------------------------------------------------------------------
 Share result:
 · Speedtest : https://www.speedtest.net/result/c/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
 · SpeedPic  : https://www.speedtest.net/result/c/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.png
 · Log Paste : https://paste.rs/xxxxx
----------------------------------------------------------------------
```

## 安全性与工程设计说明 (Security & Design)

1. **绝不盲目升级系统软件**：修复了旧版脚本在缺失依赖时执行全量 `yum update` 导致生产环境卡死或意外升级内核的隐患，仅针对缺失的基础工具（`curl`/`wget`/`tar`）进行静默按需安装。
2. **强制 HTTPS 证书校验**：移除了原版所有的 `--no-check-certificate` 与 `curl -k` 不安全参数，防止在下载测速组件时遭受中间人攻击（MITM）。
3. **沙箱化临时目录与残留自愈**：
   * 所有临时组件与日志均存放在权限为 `700` 的 `mktemp -d` 随机目录中，I/O 测试文件带有当前进程 PID (`$$`) 与随机数标识。
   * 退出时先通过 `pkill -P $$` 终止可能锁死文件的后台子进程，再彻底删除工作区；同时自动清理超过 1 天（`-mtime +1`）因历史断电或强杀遗留的旧临时目录。

## 致谢与开源协议 (Credits & License)

* 灵感与早期版本致谢：
  * [Oldking - Superbench.sh](https://www.oldking.net/350.html)
  * [Teddysun - Bench.sh](https://teddysun.com/444.html)
* 本项目采用 [MIT License](LICENSE) 开源协议发布，欢迎提交 Issue 与 Pull Request 共同完善脚本特性与跨平台兼容性。
