#!/usr/bin/env bash
#
# Description : Modernized Cross-Platform System Info, I/O & Network Benchmark Script
# Based on    : Superbench.sh by Oldking & Bench.sh by Teddysun
# License     : MIT License
# Version     : v2.0.0
#

# 开启管道错误传递，未定义变量在关键处手动校验以保证兼容性
set -o pipefail

# ======================== 颜色与基础配置 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

VERSION="2.0.0"
SPEEDTEST_VER="1.2.0"
START_TIME=$(date +%s)

# 全局目录与文件变量（由 init_environment 动态安全分配）
WORK_DIR=""
IO_DIR=""
LOG_FILE=""
SPEED_LOG=""
SUDO_CMD=""
HAS_ROOT=0

# ======================== 权限与目录安全初始化 ========================

# 检查 Root 或免密 sudo 权限
check_privilege() {
    if [[ $EUID -eq 0 ]]; then
        HAS_ROOT=1
        SUDO_CMD=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        HAS_ROOT=1
        SUDO_CMD="sudo"
    else
        HAS_ROOT=0
        echo -e "${YELLOW}[提示] 当前非 Root 用户且无免密 sudo，将跳过系统级依赖安装与 SMART 检测，以用户态运行。${PLAIN}"
    fi
}

# 寻找既【可写】又【允许执行二进制 (非 noexec)】的临时工作目录
find_exec_dir() {
    local candidates=("/var/tmp" "${HOME:-/tmp}/.cache" "/tmp" "$PWD")
    local dir test_dir test_bin

    for dir in "${candidates[@]}"; do
        [[ -z "$dir" ]] && continue
        mkdir -p "$dir" 2>/dev/null || continue
        [[ ! -w "$dir" ]] && continue

        test_dir=$(mktemp -d "$dir/superbench.XXXXXX" 2>/dev/null) || continue
        chmod 700 "$test_dir" 2>/dev/null

        # 实际写入微型脚本并执行，100% 规避 noexec 挂载限制
        test_bin="$test_dir/.exec_check.sh"
        printf "#!/bin/sh\nexit 0\n" > "$test_bin" 2>/dev/null
        chmod 700 "$test_bin" 2>/dev/null

        if "$test_bin" >/dev/null 2>&1; then
            rm -f "$test_bin"
            WORK_DIR="$test_dir"
            return 0
        fi
        rm -rf "$test_dir" 2>/dev/null
    done

    echo -e "${RED}[错误] 无法找到任何可写且允许执行程序的临时目录（可能全盘只读或受 noexec 限制）！${PLAIN}"
    exit 1
}

# 寻找既【可写】又【非内存盘 (非 tmpfs/ramfs)】的真实磁盘目录用于 I/O 测试
find_io_dir() {
    local candidates=("$PWD" "${HOME:-}" "/var/tmp" "/var/cache" "/tmp")
    local dir fstype

    for dir in "${candidates[@]}"; do
        [[ -z "$dir" || ! -d "$dir" || ! -w "$dir" ]] && continue
        # 获取目录所在挂载点的文件系统类型
        fstype=$(df -PT "$dir" 2>/dev/null | awk 'NR==2 {print $2}')
        case "$fstype" in
            tmpfs|ramfs|devtmpfs|squashfs|iso9660|overlay)
                continue
                ;;
            *)
                IO_DIR="$dir"
                return 0
                ;;
        esac
    done

    # 若所有可写目录均为 overlay/tmpfs（如部分精简容器环境），兜底使用 WORK_DIR
    IO_DIR="$WORK_DIR"
}

# 安全初始化日志文件（兼容当前目录只读的情况）
init_log_file() {
    local candidates=("$PWD" "${HOME:-}" "$WORK_DIR")
    local dir
    for dir in "${candidates[@]}"; do
        if [[ -n "$dir" && -d "$dir" && -w "$dir" ]]; then
            LOG_FILE="$dir/superbench.log"
            if : > "$LOG_FILE" 2>/dev/null; then
                chmod 600 "$LOG_FILE" 2>/dev/null
                break
            fi
        fi
    done
    SPEED_LOG="$WORK_DIR/speedtest.log"
    : > "$SPEED_LOG"
}

# 安全退出清理函数（仅清理隔离目录与带 PID 的测试文件，绝不误删用户文件）
cleanup() {
    [[ -n "$IO_DIR" && -d "$IO_DIR" ]] && rm -f "$IO_DIR"/sb_io_test_$$_* 2>/dev/null
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR" 2>/dev/null
}

cancel() {
    echo ""
    next
    echo " 收到中断信号，正在安全清理临时文件..."
    cleanup
    echo " 清理完成，已退出。"
    exit 130
}

trap cleanup EXIT
trap cancel INT TERM

# ======================== 跨平台依赖管理 ========================

install_pkg() {
    local pkg=$1
    [[ $HAS_ROOT -eq 0 ]] && return 1

    if command -v apt-get >/dev/null 2>&1; then
        $SUDO_CMD apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive $SUDO_CMD apt-get install -y "$pkg" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO_CMD dnf install -y "$pkg" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        $SUDO_CMD yum install -y "$pkg" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        $SUDO_CMD apk add --no-cache "$pkg" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO_CMD pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO_CMD zypper --non-interactive install "$pkg" >/dev/null 2>&1
    fi
}

benchinit() {
    check_privilege
    find_exec_dir
    find_io_dir
    init_log_file

    # 检查并按需安装基础工具（移除 Python 依赖）
    for cmd in curl wget tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo " 正在安装基础组件: $cmd ..."
            install_pkg "$cmd"
        fi
    done

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo -e "${RED}[错误] 系统中未找到 curl 或 wget，且无法自动安装！${PLAIN}"
        exit 1
    fi
}

# 通用文件下载封装（强制校验证书，支持超时与重试）
download_file() {
    local url=$1
    local output=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 -o "$output" "$url" 2>/dev/null
    else
        wget -q --tries=2 --timeout=15 -O "$output" "$url" 2>/dev/null
    fi
}

# ======================== 系统与硬件信息采集 ========================

about() {
    echo ""
    echo " ========================================================= "
    echo " \                 Superbench.sh  Script                 / "
    echo " \       Basic system info, I/O test and speedtest       / "
    echo " \                   v${VERSION} (Modernized)                / "
    echo " ========================================================= "
    echo ""
}

next() {
    printf "%-70s\n" "-" | sed 's/\s/-/g' | tee -a "$LOG_FILE"
}

get_opsy() {
    if [[ -f /etc/os-release ]]; then
        awk -F'=' '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release
    elif [[ -f /etc/redhat-release ]]; then
        cat /etc/redhat-release
    elif [[ -f /etc/lsb-release ]]; then
        awk -F'=' '/^DISTRIB_DESCRIPTION=/{gsub(/"/, "", $2); print $2; exit}' /etc/lsb-release
    else
        uname -s -r
    fi
}

virt_check() {
    virtual="Dedicated"

    # 1. 优先使用现代 systemd-detect-virt
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local sdv
        sdv=$(systemd-detect-virt 2>/dev/null)
        if [[ -n "$sdv" && "$sdv" != "none" ]]; then
            virtual="$sdv"
            return
        fi
    fi

    # 2. 容器环境特征文件检测（兼容 cgroup v1/v2）
    if [[ -f /.dockerenv ]]; then
        virtual="Docker"; return
    elif [[ -f /run/.containerenv ]]; then
        virtual="Podman"; return
    elif grep -qaE 'docker|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        virtual="Docker/Container"; return
    elif grep -qa 'lxc' /proc/1/cgroup 2>/dev/null || grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then
        virtual="LXC"; return
    elif [[ -f /proc/user_beancounters ]]; then
        virtual="OpenVZ"; return
    fi

    # 3. 免 Root 读取 /sys/class/dmi/id 识别硬件虚拟化
    local sys_vendor="" product_name=""
    [[ -r /sys/class/dmi/id/sys_vendor ]] && sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
    [[ -r /sys/class/dmi/id/product_name ]] && product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null)

    local dmi_info="${sys_vendor} ${product_name}"
    if [[ "$dmi_info" == *"KVM"* || "$dmi_info" == *"QEMU"* ]]; then
        virtual="KVM"
    elif [[ "$dmi_info" == *"VMware"* ]]; then
        virtual="VMware"
    elif [[ "$dmi_info" == *"VirtualBox"* ]]; then
        virtual="VirtualBox"
    elif [[ "$dmi_info" == *"Microsoft Corporation"* && "$dmi_info" == *"Virtual Machine"* ]]; then
        virtual="Hyper-V"
    elif [[ "$dmi_info" == *"Amazon EC2"* ]]; then
        virtual="KVM (AWS Nitro/Xen)"
    elif [[ "$dmi_info" == *"Google"* ]]; then
        virtual="KVM (Google Cloud)"
    elif [[ -e /proc/xen ]]; then
        virtual="Xen"
    fi
}

# 使用 POSIX 标准 1K 块精确汇总磁盘容量（消除原版单位换算 Bug）
calc_disk_info() {
    local df_out
    df_out=$(LC_ALL=C df -kP 2>/dev/null | grep -wvE '^Filesystem|none|tmpfs|devtmpfs|overlay|shm|udev|squashfs|efivarfs|iso9660')
    disk_total_size=$(echo "$df_out" | awk '{sum += $2} END {printf "%.1f", sum / 1048576}')
    disk_used_size=$(echo "$df_out" | awk '{sum += $3} END {printf "%.1f", sum / 1048576}')
}

get_system_info() {
    # 1. 兼容 x86_64 与 ARM64 的 CPU 型号识别
    cname=""
    if command -v lscpu >/dev/null 2>&1; then
        cname=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Model name:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    fi
    if [[ -z "$cname" ]]; then
        cname=$(awk -F: '/model name|Processor|cpu model/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    fi
    [[ -z "$cname" ]] && cname="Unknown CPU"

    # 2. CPU 核心数识别
    cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$cores" || "$cores" -eq 0 ]]; then
        cores=$(nproc 2>/dev/null || echo 1)
    fi

    # 3. 兼容 ARM 与动态调频的 CPU 频率获取
    freq=$(awk -F: '/cpu MHz/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%.0f", $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$freq" && -r /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        freq=$(awk '{printf "%.0f", $1 / 1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    fi
    if [[ -z "$freq" ]] && command -v lscpu >/dev/null 2>&1; then
        freq=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/CPU max MHz|CPU MHz/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%.0f", $2; exit}')
    fi
    [[ -z "$freq" ]] && freq="N/A"

    # 4. CPU 缓存大小识别
    corescache=$(awk -F: '/cache size/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$corescache" ]] && command -v lscpu >/dev/null 2>&1; then
        corescache=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/L3 cache|L2 cache/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    fi
    [[ -z "$corescache" ]] && corescache="N/A"

    # 5. 内存与 Swap 统计（直接读取 /proc/meminfo 兼容所有发行版）
    tram=$(awk '/^MemTotal:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    tram=${tram:-0}
    local mavail mfree mbuff mcached
    mavail=$(awk '/^MemAvailable:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    mfree=$(awk '/^MemFree:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    mbuff=$(awk '/^Buffers:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    mcached=$(awk '/^Cached:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    bram=$(( ${mbuff:-0} + ${mcached:-0} ))
    if [[ -n "$mavail" ]]; then
        uram=$(( tram - mavail ))
    else
        uram=$(( tram - ${mfree:-0} - bram ))
    fi
    [[ $uram -lt 0 ]] && uram=0

    swap=$(awk '/^SwapTotal:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    swap=${swap:-0}
    local sfree
    sfree=$(awk '/^SwapFree:/ {printf "%.0f", $2 / 1024}' /proc/meminfo 2>/dev/null)
    uswap=$(( swap - ${sfree:-0} ))
    [[ $uswap -lt 0 ]] && uswap=0

    # 6. 运行时间、负载与系统架构信息
    up=$(awk '{a=$1/86400; b=($1%86400)/3600; c=($1%3600)/60} {printf("%d days %d hour %d min\n",a,b,c)}' /proc/uptime 2>/dev/null)
    load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    opsy=$(get_opsy)
    arch=$(uname -m)
    lbit=$(getconf LONG_BIT 2>/dev/null || echo "64")
    kern=$(uname -r)

    # 7. 磁盘容量、TCP 拥塞控制与虚拟化检测
    calc_disk_info

    tcpctrl="N/A"
    if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        tcpctrl=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
    fi

    virt_check
}

print_system_info() {
    echo -e " CPU Model            : ${SKYBLUE}$cname${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " CPU Cores            : ${YELLOW}$cores Cores ${SKYBLUE}($freq MHz, $arch)${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " CPU Cache            : ${SKYBLUE}$corescache${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " OS                   : ${SKYBLUE}$opsy ($lbit Bit) ${YELLOW}$virtual${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " Kernel               : ${SKYBLUE}$kern${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " Total Space          : ${SKYBLUE}$disk_used_size GB / ${YELLOW}$disk_total_size GB${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " Total RAM            : ${SKYBLUE}$uram MB / ${YELLOW}$tram MB ${SKYBLUE}($bram MB Buff/Cache)${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " Total SWAP           : ${SKYBLUE}$uswap MB / $swap MB${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " Uptime               : ${SKYBLUE}$up${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " Load Average         : ${SKYBLUE}$load${PLAIN}" | tee -a "$LOG_FILE"
    echo -e " TCP CC               : ${YELLOW}$tcpctrl${PLAIN}" | tee -a "$LOG_FILE"
}

# ======================== 纯 Bash 双栈网络与归属地检测 ========================

# 纯 Bash 提取 JSON 字符串键值（无需 Python 或 jq）
json_extract() {
    local json=$1
    local key=$2
    echo "$json" | tr ',' '\n' | awk -F'"' -v k="$key" '$2 == k {print $4; exit}'
}

ip_info() {
    local ip4_json=""
    if command -v curl >/dev/null 2>&1; then
        ip4_json=$(curl -4 -fsSL --max-time 6 "https://ipinfo.io/json" 2>/dev/null)
        [[ -z "$ip4_json" ]] && ip4_json=$(curl -4 -fsSL --max-time 6 "https://api.ip.sb/geoip" 2>/dev/null)
    else
        ip4_json=$(wget -4 -qO- --timeout=6 "https://ipinfo.io/json" 2>/dev/null)
    fi

    if [[ -n "$ip4_json" ]]; then
        local org city region country
        org=$(json_extract "$ip4_json" "org")
        [[ -z "$org" ]] && org=$(json_extract "$ip4_json" "isp")
        city=$(json_extract "$ip4_json" "city")
        region=$(json_extract "$ip4_json" "region")
        country=$(json_extract "$ip4_json" "country")

        echo -e " IPv4 ASN & ISP       : ${SKYBLUE}${org:-Unknown}${PLAIN}" | tee -a "$LOG_FILE"
        echo -e " IPv4 Location        : ${SKYBLUE}${city:-Unknown}, ${region:-Unknown} / ${YELLOW}${country:-Unknown}${PLAIN}" | tee -a "$LOG_FILE"
    else
        echo -e " IPv4 Status          : ${RED}Offline or API Blocked${PLAIN}" | tee -a "$LOG_FILE"
    fi

    # 新增 IPv6 连通性检测
    local ipv6_check=""
    if command -v curl >/dev/null 2>&1; then
        ipv6_check=$(curl -6 -fsSL --max-time 4 "https://api64.ipify.org" 2>/dev/null)
    fi
    if [[ -n "$ipv6_check" && "$ipv6_check" == *":"* ]]; then
        echo -e " IPv6 Status          : ${GREEN}Online${PLAIN}" | tee -a "$LOG_FILE"
    else
        echo -e " IPv6 Status          : ${YELLOW}Offline${PLAIN}" | tee -a "$LOG_FILE"
    fi
}

# ======================== 安全磁盘 I/O 测试 ========================

freedisk() {
    # 检测选定的真实磁盘目录 IO_DIR 剩余空间（MB）
    local freespace
    freespace=$(df -mP "$IO_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$freespace" || ! "$freespace" =~ ^[0-9]+$ ]]; then
        printf "1"
        return
    fi

    if [[ $freespace -gt 2048 ]]; then
        printf "%s" $((1024 * 2))
    elif [[ $freespace -gt 1024 ]]; then
        printf "%s" $((512 * 2))
    elif [[ $freespace -gt 512 ]]; then
        printf "%s" $((256 * 2))
    elif [[ $freespace -gt 256 ]]; then
        printf "%s" $((128 * 2))
    else
        printf "1"
    fi
}

io_test() {
    local count=$1
    local test_file="$IO_DIR/sb_io_test_$$_$RANDOM"
    (LC_ALL=C dd if=/dev/zero of="$test_file" bs=512K count="$count" conv=fdatasync && rm -f "$test_file") 2>&1 \
        | awk -F, '/copied/ {io=$NF} END {print io}' \
        | sed 's/^[ \t]*//;s/[ \t]*$//'
    rm -f "$test_file" 2>/dev/null
}

# 将 dd 输出统一转换为 MB/s 浮点数
parse_io_mb() {
    local io_str=$1
    local val unit
    val=$(echo "$io_str" | awk '{print $1}')
    unit=$(echo "$io_str" | awk '{print $2}')
    [[ -z "$val" ]] && { echo "0"; return; }
    case "$unit" in
        GB/s|GB/秒) awk -v v="$val" 'BEGIN {printf "%.2f", v * 1024}' ;;
        kB/s|KB/s)  awk -v v="$val" 'BEGIN {printf "%.2f", v / 1024}' ;;
        *)          awk -v v="$val" 'BEGIN {printf "%.2f", v}' ;;
    esac
}

print_io() {
    local writemb
    if [[ "${1:-}" == "fast" ]]; then
        local check_space
        check_space=$(freedisk)
        [[ "$check_space" == "1" ]] && writemb="1" || writemb=$((128 * 2))
    else
        writemb=$(freedisk)
    fi

    local writemb_size="$(( writemb / 2 ))MB"
    [[ "$writemb_size" == "1024MB" ]] && writemb_size="1.0GB"

    if [[ "$writemb" != "1" ]]; then
        echo -e " I/O Test Directory   : ${SKYBLUE}$IO_DIR${PLAIN}" | tee -a "$LOG_FILE"
        echo -n " I/O Speed( $writemb_size )   : " | tee -a "$LOG_FILE"
        local io1
        io1=$(io_test "$writemb")
        echo -e "${YELLOW}${io1:-Failed}${PLAIN}" | tee -a "$LOG_FILE"

        echo -n " I/O Speed( $writemb_size )   : " | tee -a "$LOG_FILE"
        local io2
        io2=$(io_test "$writemb")
        echo -e "${YELLOW}${io2:-Failed}${PLAIN}" | tee -a "$LOG_FILE"

        echo -n " I/O Speed( $writemb_size )   : " | tee -a "$LOG_FILE"
        local io3
        io3=$(io_test "$writemb")
        echo -e "${YELLOW}${io3:-Failed}${PLAIN}" | tee -a "$LOG_FILE"

        local ioraw1 ioraw2 ioraw3 ioavg
        ioraw1=$(parse_io_mb "$io1")
        ioraw2=$(parse_io_mb "$io2")
        ioraw3=$(parse_io_mb "$io3")
        ioavg=$(awk -v a="$ioraw1" -v b="$ioraw2" -v c="$ioraw3" 'BEGIN {printf "%.1f", (a + b + c) / 3}')
        echo -e " Average I/O Speed    : ${YELLOW}$ioavg MB/s${PLAIN}" | tee -a "$LOG_FILE"
    else
        echo -e " ${RED}[警告] 磁盘目录 ($IO_DIR) 剩余可用空间不足 256MB，已跳过 I/O 测试！${PLAIN}" | tee -a "$LOG_FILE"
    fi
}

# ======================== 现代化网络测速模块 ========================

install_speedtest() {
    local st_bin="$WORK_DIR/speedtest"
    [[ -x "$st_bin" ]] && return 0

    local arch_tag=""
    case "$(uname -m)" in
        x86_64|amd64)   arch_tag="x86_64" ;;
        aarch64|arm64)  arch_tag="aarch64" ;;
        armv7l|armhf)   arch_tag="armhf" ;;
        i386|i686)      arch_tag="i386" ;;
        *)
            echo -e "${YELLOW}[提示] 当前架构 $(uname -m) 无官方 Speedtest 二进制包，将使用 HTTP 测速兜底。${PLAIN}"
            return 1
            ;;
    esac

    local url="https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VER}-linux-${arch_tag}.tgz"
    local tgz="$WORK_DIR/speedtest.tgz"

    if download_file "$url" "$tgz"; then
        tar -xzf "$tgz" -C "$WORK_DIR" >/dev/null 2>&1
        chmod 700 "$st_bin" 2>/dev/null
        rm -f "$tgz"
        [[ -x "$st_bin" ]] && return 0
    fi
    return 1
}

# 纯 Curl 测速兜底（替代原版失效的 Python fast_com.py）
speed_cloudflare_fallback() {
    command -v curl >/dev/null 2>&1 || return
    local dl_bps
    dl_bps=$(curl -4 -sSL -w "%{speed_download}" --connect-timeout 5 --max-time 12 -o /dev/null "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)
    if [[ -n "$dl_bps" ]]; then
        local dl_mbps
        dl_mbps=$(awk -v bps="$dl_bps" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')
        if [[ $(awk -v m="$dl_mbps" 'BEGIN {print (m > 0) ? 1 : 0}') -eq 1 ]]; then
            printf "${YELLOW}%-18s${GREEN}%-18s${RED}%-20s${SKYBLUE}%-12s${PLAIN}\n" " Cloudflare CDN" "N/A" "${dl_mbps} Mbit/s" "-" | tee -a "$LOG_FILE"
        fi
    fi
}
speed_test() {
    local node_id=$1
    local node_name=$2
    local st_bin="$WORK_DIR/speedtest"
    [[ ! -x "$st_bin" ]] && return

    if [[ -z "$node_id" ]]; then
        "$st_bin" -p no --accept-license --accept-gdpr > "$SPEED_LOG" 2>&1
    else
        "$st_bin" -p no -s "$node_id" --accept-license --accept-gdpr > "$SPEED_LOG" 2>&1
    fi

    if grep -q "Upload:" "$SPEED_LOG" 2>/dev/null; then
        local dl up lat current_url
        dl=$(awk '/Download:/ {print $2}' "$SPEED_LOG")
        up=$(awk '/Upload:/ {print $2}' "$SPEED_LOG")
        lat=$(awk '/Idle Latency:|Latency:/ {print $2; exit}' "$SPEED_LOG")
        current_url=$(awk '/Result URL:/ {print $3}' "$SPEED_LOG")

        # 优先锁定默认主节点的 Speedtest 官方结果链接；若主节点未生成则用后续成功节点兜底
        if [[ -n "$current_url" ]]; then
            if [[ -z "$node_id" || -z "${RESULT_SPEED:-}" ]]; then
                RESULT_SPEED="$current_url"
            fi
        fi

        if [[ -n "$dl" ]]; then
            printf "${YELLOW}%-18s${GREEN}%-18s${RED}%-20s${SKYBLUE}%-12s${PLAIN}\n" " ${node_name}" "${up} Mbit/s" "${dl} Mbit/s" "${lat:-N/A} ms" | tee -a "$LOG_FILE"
        fi
    fi
}

print_speedtest() {
    printf "%-18s%-18s%-20s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency" | tee -a "$LOG_FILE"
    if install_speedtest; then
        speed_test '' 'Speedtest Auto'
        speed_test '3633'  'Shanghai     CT'
        speed_test '27594' 'Guangzhou 5G CT'
        speed_test '24447' 'Shanghai 5G  CU'
        speed_test '26678' 'Guangzhou 5G CU'
        speed_test '25637' 'Shanghai 5G  CM'
        speed_test '26850' 'Wuxi 5G      CM'
    fi
    speed_cloudflare_fallback
}

print_speedtest_fast() {
    printf "%-18s%-18s%-20s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency" | tee -a "$LOG_FILE"
    if install_speedtest; then
        speed_test '' 'Speedtest Auto'
        speed_test '3633'  'Shanghai     CT'
        speed_test '24447' 'Shanghai 5G  CU'
    fi
    speed_cloudflare_fallback
}

# ======================== 时间统计与结果分享 ========================

print_intro() {
    printf " Superbench.sh -- Modernized Edition v%s\n" "$VERSION" | tee -a "$LOG_FILE"
    printf " Mode  : ${GREEN}%s${PLAIN}    WorkDir : ${SKYBLUE}%s${PLAIN}\n" "${MODE_NAME:-Standard}" "$WORK_DIR" | tee -a "$LOG_FILE"
}

print_end_time() {
    local end time min sec bj_time
    end=$(date +%s)
    time=$(( end - START_TIME ))
    if [[ $time -gt 60 ]]; then
        min=$(( time / 60 ))
        sec=$(( time % 60 ))
        echo -ne " Finished in  : ${min} min ${sec} sec\n" | tee -a "$LOG_FILE"
    else
        echo -ne " Finished in  : ${time} sec\n" | tee -a "$LOG_FILE"
    fi

    bj_time=$(TZ='Asia/Shanghai' date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u "+%Y-%m-%d %H:%M:%S UTC")
    echo " Timestamp    : $bj_time (GMT+8)" | tee -a "$LOG_FILE"
    echo " Results Log  : $LOG_FILE"
}

sharetest() {
    command -v curl >/dev/null 2>&1 || return
    local clean_log="$WORK_DIR/superbench_clean.log"
    # 剥离 ANSI 颜色字符，保证在线预览排版整洁
    sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" "$LOG_FILE" > "$clean_log" 2>/dev/null

    local share_link=""
    case "${1:-paste_rs}" in
        'clbin')
            share_link=$(curl -fsSL --max-time 10 -F 'clbin=<-' https://clbin.com < "$clean_log" 2>/dev/null | tr -d '\r\n ')
            ;;
        *)
            share_link=$(curl -fsSL --max-time 10 --data-binary @"$clean_log" https://paste.rs 2>/dev/null | tr -d '\r\n ')
            # 若 paste.rs 网络超时，自动切换 clbin.com 兜底
            if [[ -z "$share_link" ]]; then
                share_link=$(curl -fsSL --max-time 10 -F 'clbin=<-' https://clbin.com < "$clean_log" 2>/dev/null | tr -d '\r\n ')
            fi
            ;;
    esac

    echo " Share result:" | tee -a "$LOG_FILE"
    if [[ -n "${RESULT_SPEED:-}" ]]; then
        echo " · Speedtest : $RESULT_SPEED" | tee -a "$LOG_FILE"
        echo " · SpeedPic  : ${RESULT_SPEED}.png" | tee -a "$LOG_FILE"
    fi
    if [[ -n "$share_link" ]]; then
        echo " · Log Paste : $share_link" | tee -a "$LOG_FILE"
    fi
    next
}

# ======================== 主流程编排 ========================

bench_all() {
    MODE_NAME="Standard"
    benchinit
    clear 2>/dev/null || true
    next
    print_intro
    next
    get_system_info
    print_system_info
    ip_info
    next
    print_io
    next
    print_speedtest
    next
    print_end_time
    next
    sharetest "${1:-paste_rs}"
}

fast_bench() {
    MODE_NAME="Fast"
    benchinit
    clear 2>/dev/null || true
    next
    print_intro
    next
    get_system_info
    print_system_info
    ip_info
    next
    print_io fast
    next
    print_speedtest_fast
    next
    print_end_time
    next
    sharetest "${1:-paste_rs}"
}

# ======================== CLI 参数路由 ========================

ACTION="${1:-all}"
case "$ACTION" in
    'info'|'-i'|'--info')
        benchinit; next; get_system_info; print_system_info; next ;;
    'version'|'-v'|'--version')
        next; about; next ;;
    'io'|'-io'|'--io')
        benchinit; next; print_io; next ;;
    'speed'|'-speed'|'--speed')
        benchinit; next; print_speedtest; next; sharetest ;;
    'ip'|'-ip'|'--ip')
        benchinit; next; ip_info; next ;;
    'fast'|'-f'|'--fast')
        fast_bench "${2:-paste_rs}" ;;
    'share'|'-s'|'--share')
        bench_all "${2:-paste_rs}" ;;
    'bench'|'-a'|'--all'|*)
        bench_all "${2:-paste_rs}" ;;
esac
