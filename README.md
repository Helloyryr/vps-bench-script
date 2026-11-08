# Superbench v2.0 (Modernized Edition)

![Version](https://img.shields.io/badge/version-v2.0.0-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20(x86__64%20%7C%20ARM64%20%7C%20ARMv7%20%7C%20i386)-lightgrey.svg)
![Shell](https://img.shields.io/badge/shell-Bash-4EAA25.svg)

**Superbench v2.0** 是一款现代化的 Linux 服务器综合性能评测脚本。本项目基于经典的 `Superbench.sh` 与 `Bench.sh` 进行全面重构，彻底移除了过时的 Python 2 依赖，针对现代 Linux 发行版（Cgroup v2、ARM64 架构、安全加固环境）进行了深度适配，重点强化了**目录权限安全**与**测试准确性**。

## 核心特性 (Key Features)

* **严密的目录权限自适应**：
  * **绕过 `noexec` 限制**：自动探测并实际执行微型探针脚本，从 `/var/tmp`、`~/.cache`、`/tmp` 等候选路径中选出真正支持二进制执行的隔离目录，彻底解决安全加固服务器 `/tmp` 挂载 `noexec` 导致的 `Permission denied` 报错。
  * **防 `tmpfs` 内存盘干扰**：在进行 `dd` 磁盘测试前，自动校验挂载点文件系统类型，主动过滤 `tmpfs`、`ramfs`、`devtmpfs` 与只读目录，确保测出真实的物理块设备 I/O 性能。
  * **非 Root 权限优雅降级**：支持普通用户运行（自动识别免密 `sudo` 或降级为用户态测试），无需强制 Root 即可完成系统信息采集、I/O 读写与网络测速。
* **纯 Bash 零外部脚本依赖**：彻底告别已淘汰的 Python 2 与第三方解析脚本，完全使用原生 Bash 与 POSIX `awk`/`sed` 完成 JSON 解析与硬件识别。
* **全平台与多架构支持**：
  * **CPU 架构**：原生适配 `x86_64`、`aarch64` (ARM64)、`armv7l`、`i386`。
  * **发行版与包管理**：支持 Debian、Ubuntu、CentOS、Rocky Linux、AlmaLinux、Fedora、Alpine Linux (`apk`)、Arch Linux (`pacman`) 及 openSUSE (`zypper`)。
* **双栈网络与现代测速**：集成官方最新 Ookla Speedtest CLI (1.2.x) 与 Cloudflare HTTP 测速兜底，支持 IPv4/IPv6 双栈连通性及 ASN 归属地检测。
* **零残留安全清理**：基于 `mktemp -d` 独立工作区与 `trap` 信号捕获机制，无论正常结束还是 `Ctrl+C` 中断，均精准清理临时文件，绝不误删用户当前目录文件。

## 快速开始 (Quick Start)

### 1. 标准完整测试（推荐）

使用 `curl` 一键运行：

```bash
curl -fsSL [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh | bash
```

或者使用 `wget` 一键运行：

```bash
wget -qO- [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh | bash
```

### 2. 指定测试模式（管道传参）

```bash
# 快速测试模式（小文件 I/O + 精简测速节点）
curl -fsSL [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- fast

# 仅查看系统与硬件信息（秒级输出）
curl -fsSL [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- info

# 仅测试磁盘 I/O 性能
curl -fsSL [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- io

# 仅执行国内外网络测速
curl -fsSL [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh | bash -s -- speed
```

### 3. 下载到本地运行

```bash
curl -fsSLO [https://raw.githubusercontent.com/](https://raw.githubusercontent.com/)Helloyryr/vps-bench-script/main/superbench.sh
chmod +x superbench.sh
./superbench.sh
```

## 命令参数说明 (CLI Arguments)

| 参数选项 | 简写 | 运行模式 | 功能说明 |
| :--- | :--- | :--- | :--- |
| `all` | `-a` | 标准模式 | 默认模式，依次执行硬件信息、双栈 IP、磁盘 I/O 与完整网络测速 |
| `fast` | `-f` | 快速模式 | 采用 128MB 数据块进行快速 I/O 测试，并精简测速节点数量 |
| `info` | `-i` | 仅系统信息 | 仅采集并输出 CPU、内存、磁盘、虚拟化架构与内核信息 |
| `io` | `-io` | 仅磁盘测试 | 仅执行三次真实块设备连续写入测试并计算平均速度 |
| `speed` | `-speed` | 仅网络测速 | 仅执行 Ookla Speedtest 多节点与 Cloudflare 兜底测速 |
| `ip` | `-ip` | 仅网络信息 | 仅检测 IPv4 ASN/ISP、地理位置及 IPv6 在线状态 |
| `share` | `-s` | 结果分享 | 完成标准测试后，自动脱敏控制字符并生成在线日志分享链接 |
| `version` | `-v` | 版本信息 | 查看当前脚本版本号与项目说明 |

## 运行输出示例 (Sample Output)

```text
----------------------------------------------------------------------
 Superbench.sh -- Modernized Edition v2.0.0
 Mode  : Standard    WorkDir : /var/tmp/superbench.8Kx92a
----------------------------------------------------------------------
 CPU Model            : AMD EPYC 7763 64-Core Processor
 CPU Cores            : 4 Cores (2445 MHz, x86_64)
 CPU Cache            : 512 KB
 OS                   : Debian GNU/Linux 12 (bookworm) (64 Bit) KVM
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
 Node Name         Upload Speed      Download Speed      Latency     
 Speedtest Auto    942.15 Mbit/s     958.40 Mbit/s       1.82 ms     
 Shanghai     CT   412.60 Mbit/s     680.12 Mbit/s       148.50 ms   
 Guangzhou 5G CT   385.10 Mbit/s     620.45 Mbit/s       162.11 ms   
 Shanghai 5G  CU   490.88 Mbit/s     790.30 Mbit/s       139.20 ms   
 Shanghai 5G  CM   510.22 Mbit/s     815.60 Mbit/s       142.05 ms   
 Cloudflare CDN    N/A               884.50 Mbit/s       -           
----------------------------------------------------------------------
 Finished in  : 1 min 18 sec
 Timestamp    : 2026-11-08 19:36:00 (GMT+8)
 Results Log  : /root/superbench.log
----------------------------------------------------------------------
```

## 安全性与工程设计说明 (Security & Design)

1. **绝不盲目升级系统软件**：修复了旧版脚本在缺失依赖时执行全量 `yum update` 导致生产环境卡死或意外升级内核的隐患，仅针对缺失的基础工具（`curl`/`wget`/`tar`）进行静默按需安装。
2. **强制 HTTPS 证书校验**：移除了原版所有的 `--no-check-certificate` 不安全参数，防止在下载测速组件时遭受中间人攻击（MITM）。
3. **沙箱化临时目录与进程隔离**：所有临时组件均下载至权限为 `700` 的 `mktemp -d` 随机目录中，I/O 测试文件均带有当前进程 PID (`$$`) 与随机数标识，退出时仅清理自身产生的文件。

## 致谢与开源协议 (Credits & License)

* 灵感与早期版本致谢：
  * [Oldking - Superbench.sh](https://www.oldking.net/350.html)
  * [Teddysun - Bench.sh](https://teddysun.com/444.html)
* 本项目采用 [MIT License](LICENSE) 开源协议发布，欢迎提交 Issue 与 Pull Request 共同维护测速节点与新特性。
