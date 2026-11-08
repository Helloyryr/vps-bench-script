#!/usr/bin/env bash
#
# Description : Modernized Cross-Platform System Info, I/O & Network Benchmark Script
# Based on    : Superbench.sh by Oldking & Bench.sh by Teddysun
# License     : MIT License
# Version     : v2.2.0
#

# 开启管道错误传递，未定义变量在关键处手动校验以保证兼容性
set -o pipefail

# ======================== 颜色与基础配置 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

VERSION="2.2.0"
SPEEDTEST_VER="1.2.0"
START_TIME=$(date +%s)

# 全局目录与文件变量（由 benchinit 动态安全分配）
WORK_DIR=""
IO_DIR=""
LOG_FILE=""
SPEED_LOG=""
SUDO_CMD=""
HAS_ROOT=0

# ======================== 权限与目录安全初始化 ========================

check_privilege() {
    if [[ $EUID -eq 0 ]]; then
        HAS_ROOT=1
        SUDO_CMD=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        HAS_ROOT=1
        SUDO_CMD="sudo"
    else
        HAS_ROOT=0
        echo -e "${YELLOW}[提示] 当前非 Root 用户且无免密 sudo，将跳过系统级依赖安装，以用户态运行。${PLAIN}"
    fi
}

# 寻找既【可写】又【允许执行二进制 (非 noexec)】的临时工作目录
find_exec_dir() {
    local candidates=("/tmp" "/var/tmp" "${HOME:-/tmp}/.cache" "$PWD")
    local dir test_dir test_bin

    for dir in "${candidates[@]}"; do
        [[ -z "$dir" ]] && continue
        mkdir -p "$dir" 2>/dev/null || continue
        [[ ! -w "$dir" ]] && continue

        find "$dir" -maxdepth 1 -type d -name "superbench.*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

        test_dir=$(mktemp -d "$dir/superbench.XXXXXX" 2>/dev/null) || continue
        chmod 700 "$test_dir" 2>/dev/null

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

    IO_DIR="$WORK_DIR"
}

# 安全初始化日志文件（结果日志保存在 /tmp/superbench.log 供跑完查阅，不污染当前目录）
init_log_file() {
    if [[ -w "/tmp" ]]; then
        LOG_FILE="/tmp/superbench.log"
    else
        LOG_FILE="$IO_DIR/superbench.log"
    fi
    SPEED_LOG="$WORK_DIR/speedtest.log"
    : > "$LOG_FILE"
    : > "$SPEED_LOG"
    chmod 600 "$LOG_FILE" "$SPEED_LOG" 2>/dev/null
}

# 安全退出清理函数
cleanup() {
    trap - EXIT INT TERM HUP QUIT

    pkill -P $$ >/dev/null 2>&1 || true

    [[ -n "$IO_DIR" && -d "$IO_DIR" ]] && rm -f "$IO_DIR"/sb_io_test_$$_* 2>/dev/null

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR" 2>/dev/null || {
            sleep 0.2
            rm -rf "$WORK_DIR" 2>/dev/null
        }
    fi
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
trap cancel INT TERM HUP QUIT

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

download_file() {
    local url=$1
    local output=$2
    local timeout_sec=${3:-45}
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL -A "$ua" --retry 1 --connect-timeout 6 --max-time "$timeout_sec" -o "$output" "$url" 2>/dev/null \
            || curl -fsSL -A "$ua" --retry 1 --connect-timeout 6 --max-time "$timeout_sec" -o "$output" "$url" 2>/dev/null
    else
        wget -q -U "$ua" --tries=2 --timeout=10 -O "$output" "$url" 2>/dev/null
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
    if [[ -n "${LOG_FILE:-}" && -w "${LOG_FILE:-}" ]]; then
        printf "%-70s\n" "-" | sed 's/\s/-/g' | tee -a "$LOG_FILE"
    else
        printf "%-70s\n" "-" | sed 's/\s/-/g'
    fi
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

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local sdv
        sdv=$(systemd-detect-virt 2>/dev/null)
        if [[ -n "$sdv" && "$sdv" != "none" ]]; then
            virtual="$sdv"
            return
        fi
    fi

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

calc_disk_info() {
    local df_out
    df_out=$(LC_ALL=C df -kP 2>/dev/null | grep -wvE '^Filesystem|none|tmpfs|devtmpfs|overlay|shm|udev|squashfs|efivarfs|iso9660' | awk '!seen[$1]++')
    disk_total_size=$(echo "$df_out" | awk '{sum += $2} END {printf "%.1f", sum / 1048576}')
    disk_used_size=$(echo "$df_out" | awk '{sum += $3} END {printf "%.1f", sum / 1048576}')
}

get_system_info() {
    cname=""
    if command -v lscpu >/dev/null 2>&1; then
        cname=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Model name:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    fi
    if [[ -z "$cname" ]]; then
        cname=$(awk -F: '/model name|Processor|cpu model/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    fi
    [[ -z "$cname" ]] && cname="Unknown CPU"

    cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$cores" || "$cores" -eq 0 ]]; then
        cores=$(nproc 2>/dev/null || echo 1)
    fi

    freq=$(awk -F: '/cpu MHz/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%.0f", $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$freq" && -r /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        freq=$(awk '{printf "%.0f", $1 / 1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    fi
    if [[ -z "$freq" ]] && command -v lscpu >/dev/null 2>&1; then
        freq=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/CPU max MHz|CPU MHz/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%.0f", $2; exit}')
    fi
    [[ -z "$freq" ]] && freq="N/A"

    corescache=$(awk -F: '/cache size/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
    if [[ -z "$corescache" ]] && command -v lscpu >/dev/null 2>&1; then
        corescache=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/L3 cache|L2 cache/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    fi
    [[ -z "$corescache" ]] && corescache="N/A"

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

    up=$(awk '{a=$1/86400; b=($1%86400)/3600; c=($1%3600)/60} {printf("%d days %d hour %d min\n",a,b,c)}' /proc/uptime 2>/dev/null)
    load=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)
    opsy=$(get_opsy)
    arch=$(uname -m)
    lbit=$(getconf LONG_BIT 2>/dev/null || echo "64")
    kern=$(uname -r)

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

json_extract() {
    local json=$1
    local key=$2
    echo "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed -E "s/\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/"
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
# 1. 国际/本地基准：Speedtest Default + Fast.com (Netflix) + Cloudflare CDN
# 2. 中国四区回程：接入每日更新的 speedtest.cn 节点库 (西安 / 北京 / 上海 / 广东)
#    采用 6 线程并发毫秒级探活 + 原生 HTTP 多线程上传/下载，彻底解决跨国锁区与节点失效

install_speedtest() {
    local st_bin="$WORK_DIR/speedtest"
    [[ -x "$st_bin" ]] && return 0

    local arch_tag=""
    case "$(uname -m)" in
        x86_64|amd64)   arch_tag="x86_64" ;;
        aarch64|arm64)  arch_tag="aarch64" ;;
        armv7l|armhf)   arch_tag="armhf" ;;
        i386|i686)      arch_tag="i386" ;;
        *)              return 1 ;;
    esac

    local url="https://install.speedtest.net/app/cli/ookla-speedtest-${SPEEDTEST_VER}-linux-${arch_tag}.tgz"
    local tgz="$WORK_DIR/speedtest.tgz"

    if download_file "$url" "$tgz" 30; then
        tar -xzf "$tgz" -C "$WORK_DIR" >/dev/null 2>&1
        chmod 700 "$st_bin" 2>/dev/null
        rm -f "$tgz"
        [[ -x "$st_bin" ]] && return 0
    fi
    return 1
}

# 纯 Bash 实现 Fast.com (Netflix OCA CDN) 3 线程并发测速
speed_fast_com() {
    command -v curl >/dev/null 2>&1 || return 1

    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    local js_name token=""

    js_name=$(curl -4 -fsSL -A "$ua" --max-time 5 "https://fast.com" 2>/dev/null | grep -oE 'app-[a-f0-9]+\.js' | head -n1)
    if [[ -n "$js_name" ]]; then
        token=$(curl -4 -fsSL -A "$ua" --max-time 5 "https://fast.com/${js_name}" 2>/dev/null | grep -oE 'token:"[^"]+"' | head -n1 | cut -d'"' -f2)
    fi
    [[ -z "$token" ]] && token="YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm"

    local api_json urls first_url
    api_json=$(curl -4 -fsSL -A "$ua" --max-time 6 "https://api.fast.com/netflix/speedtest/v2?https=true&token=${token}&urlCount=3" 2>/dev/null)
    urls=$(echo "$api_json" | grep -oE 'https://[^"]+' | head -n 3)
    first_url=$(echo "$urls" | head -n 1)
    [[ -z "$first_url" ]] && return 1

    local lat_sec lat_ms="N/A"
    lat_sec=$(curl -4 -o /dev/null -s -w "%{time_connect}" --connect-timeout 5 "$first_url" 2>/dev/null)
    if [[ -n "$lat_sec" ]]; then
        lat_ms=$(awk -v s="$lat_sec" 'BEGIN {if (s>0) printf "%.2f ms", s * 1000; else print "N/A"}')
    fi

    local total_bps dl_mbps="0.00"
    total_bps=$(echo "$urls" | xargs -P 3 -I {} curl -4 -sSL -A "$ua" -w "%{speed_download}\n" --connect-timeout 5 --max-time 8 -o /dev/null "{}" 2>/dev/null | awk '{sum += $1} END {print sum}')
    if [[ -n "$total_bps" ]]; then
        dl_mbps=$(awk -v bps="$total_bps" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')
    fi

    if [[ $(awk -v m="$dl_mbps" 'BEGIN {print (m > 0) ? 1 : 0}') -eq 1 ]]; then
        printf "${YELLOW}%-22s${GREEN}%-16s${RED}%-18s${SKYBLUE}%-12s${PLAIN}\n" " Fast.com (Netflix)" "N/A (DL Only)" "${dl_mbps} Mbit/s" "${lat_ms}" | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

# 纯 Curl 测量 Cloudflare CDN（真实延迟、上传、下载）
speed_cloudflare_cdn() {
    command -v curl >/dev/null 2>&1 || return 1

    local lat_sec lat_ms
    lat_sec=$(curl -4 -o /dev/null -s -w "%{time_connect}" --connect-timeout 5 "https://speed.cloudflare.com/__down?bytes=0" 2>/dev/null)
    if [[ -n "$lat_sec" ]]; then
        lat_ms=$(awk -v s="$lat_sec" 'BEGIN {if (s>0) printf "%.2f ms", s * 1000; else print "N/A"}')
    else
        lat_ms="N/A"
    fi

    local dl_bps dl_mbps="0.00"
    dl_bps=$(curl -4 -sSL -w "%{speed_download}" --connect-timeout 5 --max-time 10 -o /dev/null "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null)
    if [[ -n "$dl_bps" ]]; then
        dl_mbps=$(awk -v bps="$dl_bps" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')
    fi

    local up_bps up_mbps="0.00"
    up_bps=$(dd if=/dev/zero bs=1M count=10 2>/dev/null | curl -4 -sSL -w "%{speed_upload}" --connect-timeout 5 --max-time 10 -o /dev/null --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)
    if [[ -n "$up_bps" ]]; then
        up_mbps=$(awk -v bps="$up_bps" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')
    fi

    if [[ $(awk -v m="$dl_mbps" 'BEGIN {print (m > 0) ? 1 : 0}') -eq 1 ]]; then
        printf "${YELLOW}%-22s${GREEN}%-16s${RED}%-18s${SKYBLUE}%-12s${PLAIN}\n" " Cloudflare CDN" "${up_mbps} Mbit/s" "${dl_mbps} Mbit/s" "${lat_ms}" | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

# Ookla Speedtest 测速执行器（用于本地最优节点）
speed_test_ookla() {
    local node_id=$1
    local node_name=$2
    local st_bin="$WORK_DIR/speedtest"
    [[ ! -x "$st_bin" ]] && return 1

    local cmd_prefix=()
    command -v timeout >/dev/null 2>&1 && cmd_prefix=(timeout 35)

    if [[ -z "$node_id" ]]; then
        HOME="$WORK_DIR" "${cmd_prefix[@]}" "$st_bin" -p no --accept-license --accept-gdpr > "$SPEED_LOG" 2>&1
    else
        HOME="$WORK_DIR" "${cmd_prefix[@]}" "$st_bin" -p no -s "$node_id" --accept-license --accept-gdpr > "$SPEED_LOG" 2>&1
    fi

    local dl up lat current_url
    dl=$(grep -oE 'Download:[[:space:]]*[0-9.]+' "$SPEED_LOG" 2>/dev/null | tail -n1 | awk -F: '{gsub(/ /, "", $2); print $2}')
    up=$(grep -oE 'Upload:[[:space:]]*[0-9.]+' "$SPEED_LOG" 2>/dev/null | tail -n1 | awk -F: '{gsub(/ /, "", $2); print $2}')
    lat=$(grep -oE 'Latency:[[:space:]]*[0-9.]+' "$SPEED_LOG" 2>/dev/null | tail -n1 | awk -F: '{gsub(/ /, "", $2); print $2}')
    current_url=$(grep -oE 'https://www\.speedtest\.net/result/[a-zA-Z0-9/-]+' "$SPEED_LOG" 2>/dev/null | tail -n1)

    if [[ -n "$current_url" ]]; then
        if [[ -z "$node_id" || -z "${RESULT_SPEED:-}" ]]; then
            RESULT_SPEED="$current_url"
        fi
    fi

    if [[ -n "$dl" ]]; then
        printf "${YELLOW}%-22s${GREEN}%-16s${RED}%-18s${SKYBLUE}%-12s${PLAIN}\n" " ${node_name:0:20}" "${up:-0.00} Mbit/s" "${dl} Mbit/s" "${lat:-N/A} ms" | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

# 下载每日自动更新的 speedtest.cn 中国大陆三网节点库 (telecom / unicom / mobile)
init_cn_node_db() {
    local db_file="$WORK_DIR/cn_nodes_all.csv"
    [[ -s "$db_file" ]] && return 0

    local mirrors=(
        "https://raw.githubusercontent.com/spiritLHLS/speedtest.cn-CN-ID/main"
        "https://cdn.jsdelivr.net/gh/spiritLHLS/speedtest.cn-CN-ID@main"
        "https://cdn.spiritlhl.net/https://raw.githubusercontent.com/spiritLHLS/speedtest.cn-CN-ID/main"
    )

    local isp_files=("telecom.csv:CT" "unicom.csv:CU" "mobile.csv:CM")
    : > "$db_file"

    local item fname isp_tag mirror tmp_csv
    for item in "${isp_files[@]}"; do
        fname="${item%%:*}"
        isp_tag="${item#*:}"
        tmp_csv="$WORK_DIR/$fname"

        for mirror in "${mirrors[@]}"; do
            if download_file "${mirror}/${fname}" "$tmp_csv" 10 && [[ -s "$tmp_csv" ]]; then
                # 解析 CSV 行，提取：ISP|省市|pingUrl|downloadUrl|uploadUrl
                awk -F',' -v isp="$isp_tag" '
                NR > 1 {
                    prov=$8; city=$9;
                    gsub(/^[ \t\r"]+|[ \t\r"]+$/, "", prov);
                    gsub(/^[ \t\r"]+|[ \t\r"]+$/, "", city);
                    ping=""; dl=""; ul="";
                    for (i=1; i<=NF; i++) {
                        gsub(/^[ \t\r"]+|[ \t\r"]+$/, "", $i);
                        if ($i ~ /^https?:\/\/.*\/hello$/) ping=$i;
                        else if ($i ~ /^https?:\/\/.*\/download$/) dl=$i;
                        else if ($i ~ /^https?:\/\/.*\/upload$/) ul=$i;
                    }
                    if (ping != "" && dl != "" && ul != "") {
                        printf "%s|%s|%s|%s|%s|%s\n", isp, prov, city, ping, dl, ul;
                    }
                }' "$tmp_csv" >> "$db_file"
                rm -f "$tmp_csv"
                break
            fi
        done
    done

    # 生成 4MB 标准上传载荷文件（使 curl 携带准确的 Content-Length 头，解决 :8080/upload 0.00 速率问题）
    dd if=/dev/zero of="$WORK_DIR/upload_payload.bin" bs=256K count=16 >/dev/null 2>&1 || true

    # 生成单节点并发探活小脚本（在 WORK_DIR 内安全执行，彻底规避复杂的引号转义）
    cat << 'EOF' > "$WORK_DIR/probe_cn.sh"
#!/usr/bin/env bash
IFS='|' read -r isp prov city ping_u dl_u ul_u <<< "$1"
[[ -z "$ping_u" ]] && exit 0
res=$(curl -4 -k -s -o /dev/null -w "%{http_code} %{time_connect}" --connect-timeout 2 --max-time 3 "$ping_u" 2>/dev/null)
code=${res%% *}
tconn=${res#* }
if [[ "$code" == "200" || "$code" == "204" ]]; then
    printf "%s|%s|%s|%s|%s|%s\n" "$isp" "$prov" "$city" "$tconn" "$dl_u" "$ul_u"
fi
EOF
    chmod 700 "$WORK_DIR/probe_cn.sh"

    [[ -s "$db_file" ]] && return 0 || return 1
}

# 对单个通过探活的国内 speedtest.cn 节点执行 HTTP 多线程下载与上传测速
run_cn_http_test() {
    local display_name=$1
    local tconn=$2
    local dl_u=$3
    local ul_u=$4

    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    local payload="$WORK_DIR/upload_payload.bin"

    local lat_ms
    lat_ms=$(awk -v s="$tconn" 'BEGIN {if (s>0) printf "%.2f", s * 1000; else print "N/A"}')

    # 1. 双线程并发下载测速 (请求 25MB 数据流，限时 8 秒)
    local dl_stats total_bytes total_bps dl_mbps="0.00"
    dl_stats=$(printf "%s\n%s\n" "${dl_u}?size=25000000" "${dl_u}?size=25000000" | xargs -P 2 -I {} curl -4 -k -sSL -A "$ua" -w "%{size_download} %{speed_download}\n" --connect-timeout 3 --max-time 8 -o /dev/null "{}" 2>/dev/null)
    total_bytes=$(echo "$dl_stats" | awk '{sum += $1} END {print sum+0}')
    total_bps=$(echo "$dl_stats" | awk '{sum += $2} END {print sum+0}')

    # 校验实际下载字节数 > 64KB，排除假 200 拦截页
    if [[ "$total_bytes" -lt 65536 ]]; then
        return 1
    fi
    dl_mbps=$(awk -v bps="$total_bps" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')
    [[ $(awk -v m="$dl_mbps" 'BEGIN {print (m > 0.05) ? 1 : 0}') -eq 0 ]] && return 1

    # 2. 双线程并发上传测速 (发送带 Content-Length 的 4MB 载荷，限时 7 秒)
    local ul_stats up_bps up_mbps="0.00"
    if [[ -f "$payload" ]]; then
        ul_stats=$(printf "%s\n%s\n" "$ul_u" "$ul_u" | xargs -P 2 -I {} curl -4 -k -sSL -A "$ua" -w "%{speed_upload}\n" --connect-timeout 3 --max-time 7 -o /dev/null -H "Content-Type: application/octet-stream" --data-binary @"$payload" "{}" 2>/dev/null)
        up_bps=$(echo "$ul_stats" | awk '{sum += $1} END {print sum+0}')
        up_mbps=$(awk -v bps="$up_bps" 'BEGIN {printf "%.2f", (bps * 8) / 1000000}')
    fi

    printf "${YELLOW}%-22s${GREEN}%-16s${RED}%-18s${SKYBLUE}%-12s${PLAIN}\n" " ${display_name:0:20}" "${up_mbps} Mbit/s" "${dl_mbps} Mbit/s" "${lat_ms} ms" | tee -a "$LOG_FILE"
    return 0
}

# 按大区测试中国节点：先匹配核心城市，若该市节点对海外 IP 封锁则自动扩充同大区邻近省份
# 参数: $1=区域展示标签, $2=首选城市正则, $3=同大区替补省市正则, $4=期望测速成功数
test_cn_region_http() {
    local region_label=$1
    local primary_regex=$2
    local fallback_regex=$3
    local max_success=${4:-2}
    local db_file="$WORK_DIR/cn_nodes_all.csv"
    [[ ! -s "$db_file" ]] && return 1

    # 从 CT/CU/CM 中均匀抽取候选节点（首选城市在前，同大区替补在后）
    local raw_candidates=""
    local isp
    for isp in CT CU CM; do
        raw_candidates+=$(grep "^${isp}|" "$db_file" | grep -E "$primary_regex" | head -n 5)$'\n'
    done
    for isp in CT CU CM; do
        raw_candidates+=$(grep "^${isp}|" "$db_file" | grep -E "$fallback_regex" | head -n 4)$'\n'
    done

    raw_candidates=$(echo "$raw_candidates" | awk 'NF > 0 && !seen[$0]++')
    [[ -z "$raw_candidates" ]] && return 1

    # 6 线程并发对候选节点进行 2 秒快速 HTTP 探活，瞬间滤除死节点或锁区节点
    local alive_nodes
    alive_nodes=$(echo "$raw_candidates" | head -n 24 | xargs -P 6 -I {} "$WORK_DIR/probe_cn.sh" "{}" 2>/dev/null)
    [[ -z "$alive_nodes" ]] && return 1

    local success_count=0
    local tested_isps=" "
    local tested_urls=" "
    local line c_isp c_prov c_city c_tconn c_dl c_ul label

    # 第一轮：优先测试不同运营商 (CT / CU / CM)
    while IFS='|' read -r c_isp c_prov c_city c_tconn c_dl c_ul; do
        [[ -z "$c_dl" ]] && continue
        [[ $success_count -ge $max_success ]] && break
        [[ "$tested_isps" == *" $c_isp "* ]] && continue

        label=$(printf "%-13s %s" "$region_label" "$c_isp")
        tested_urls+="$c_dl "
        if run_cn_http_test "$label" "$c_tconn" "$c_dl" "$c_ul"; then
            tested_isps+="$c_isp "
            ((++success_count))
        fi
    done <<< "$alive_nodes"

    # 第二轮：若未达到期望节点数，从剩余存活节点中补齐
    while IFS='|' read -r c_isp c_prov c_city c_tconn c_dl c_ul; do
        [[ -z "$c_dl" ]] && continue
        [[ $success_count -ge $max_success ]] && break
        [[ "$tested_urls" == *" $c_dl "* ]] && continue

        label=$(printf "%-13s %s" "$region_label" "$c_isp")
        tested_urls+="$c_dl "
        if run_cn_http_test "$label" "$c_tconn" "$c_dl" "$c_ul"; then
            ((++success_count))
        fi
    done <<< "$alive_nodes"

    [[ $success_count -gt 0 ]] && return 0 || return 1
}

# 运行中国四大重点区域（西安、北京、上海、广东）测速
run_china_speedtest() {
    local nodes_per_region=${1:-2}
    local total_cn_success=0

    if init_cn_node_db; then
        # 1. 西安 / 西北节点 (首选陕西/西安，同区替补甘肃/宁夏/河南/四川)
        test_cn_region_http "CN Xi'an"     "西安|咸阳|陕西"           "兰州|甘肃|银川|宁夏|郑州|河南|成都|重庆" "$nodes_per_region" && ((++total_cn_success))

        # 2. 北京 / 华北节点 (首选北京，同区替补天津/河北/山东/辽宁)
        test_cn_region_http "CN Beijing"   "北京"                     "天津|石家庄|河北|保定|济南|青岛|山东|沈阳" "$nodes_per_region" && ((++total_cn_success))

        # 3. 上海 / 华东节点 (首选上海，同区替补江苏苏州/南京/镇江/浙江杭州/宁波)
        test_cn_region_http "CN Shanghai"  "上海"                     "苏州|南京|镇江|无锡|昆山|江苏|杭州|宁波|浙江|合肥" "$nodes_per_region" && ((++total_cn_success))

        # 4. 广东 / 华南节点 (首选广州/深圳/广东，同区替补福建/湖南/广西)
        test_cn_region_http "CN Guangdong" "广州|深圳|东莞|佛山|广东" "福州|厦门|泉州|福建|长沙|湖南|南宁|广西" "$nodes_per_region" && ((++total_cn_success))
    fi

    # 若遇到极端情况 CSV 下载失败，回退尝试 Ookla 仅存的国内大区节点
    if [[ $total_cn_success -eq 0 && -x "$WORK_DIR/speedtest" ]]; then
        speed_test_ookla "43752" "CN Beijing    CU" && ((++total_cn_success))
        speed_test_ookla "24447" "CN Shanghai   CU" && ((++total_cn_success))
        speed_test_ookla "5396"  "CN Suzhou     CT" && ((++total_cn_success))
        speed_test_ookla "59387" "CN Ningbo     CT" && ((++total_cn_success))
    fi

    [[ $total_cn_success -gt 0 ]] && return 0 || return 1
}

print_speedtest() {
    printf "%-22s%-16s%-18s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency" | tee -a "$LOG_FILE"

    # 1. 海外与国际主流 CDN 测速 (本地最优 + Fast.com + Cloudflare CDN)
    if install_speedtest; then
        speed_test_ookla '' 'Speedtest Default' || true
    fi
    speed_fast_com || true
    speed_cloudflare_cdn || true

    # 2. 中国四大核心区域测速 (西安 / 北京 / 上海 / 广东，标准模式每区测 2 个不同运营商节点)
    run_china_speedtest 2 || true
}

print_speedtest_fast() {
    printf "%-22s%-16s%-18s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency" | tee -a "$LOG_FILE"

    # 1. 海外与国际主流 CDN 测速
    if install_speedtest; then
        speed_test_ookla '' 'Speedtest Default' || true
    fi
    speed_fast_com || true
    speed_cloudflare_cdn || true

    # 2. 中国四大核心区域快速测速 (西安 / 北京 / 上海 / 广东，快速模式每区测 1 个节点)
    run_china_speedtest 1 || true
}

# ======================== 时间统计与结果分享 ========================

print_intro() {
    printf " Superbench.sh -- Modernized Edition v%s\n" "$VERSION" | tee -a "$LOG_FILE"
    printf " Thanks  : Special thanks to ${SKYBLUE}Oldking${PLAIN} (oldking.net) & ${SKYBLUE}Teddysun${PLAIN} (teddysun.com)\n" | tee -a "$LOG_FILE"
    printf " Mode    : ${GREEN}%s${PLAIN}    WorkDir : ${SKYBLUE}%s${PLAIN}\n" "${MODE_NAME:-Standard}" "$WORK_DIR" | tee -a "$LOG_FILE"
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
    sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" "$LOG_FILE" > "$clean_log" 2>/dev/null

    local share_link=""
    case "${1:-paste_rs}" in
        'clbin')
            share_link=$(curl -fsSL --max-time 10 -F 'clbin=<-' https://clbin.com < "$clean_log" 2>/dev/null | tr -d '\r\n ')
            ;;
        *)
            share_link=$(curl -fsSL --max-time 10 --data-binary @"$clean_log" https://paste.rs 2>/dev/null | tr -d '\r\n ')
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
