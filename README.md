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
