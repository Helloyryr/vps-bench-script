#!/usr/bin/env bash
#
# Description : Modernized Cross-Platform System Info, I/O & Network Benchmark Script
# Based on    : Superbench.sh by Oldking & Bench.sh by Teddysun
# License     : MIT License
# Version     : v2.1.0
#

# 开启管道错误传递，未定义变量在关键处手动校验以保证兼容性
set -o pipefail

# ======================== 颜色与基础配置 ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

VERSION="2.1.0"
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

        # 顺手清理可能因历史断电/强杀遗留超过 1 天的旧临时目录
        find "$dir" -maxdepth 1 -type d -name "superbench.*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

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

# 安全退出清理函数（先杀子进程释放文件锁，再彻底删除隔离目录）
cleanup() {
    # 卸载 trap 防止重复触发
    trap - EXIT INT TERM HUP QUIT

    # 终止可能还在后台写文件的子进程（如 speedtest / dd）
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
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fsSL -A "$ua" --retry 2 --connect-timeout 10 --max-time 60 -o "$output" "$url" 2>/dev/null \
            || curl -fsSL -A "$ua" --retry 1 --connect-timeout 10 --max-time 60 -o "$output" "$url" 2>/dev/null
    else
        wget -q -U "$ua" --tries=2 --timeout=15 -O "$output" "$url" 2>/dev/null
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
# 策略：海外/国际采用 Fast.com (Netflix) + Cloudflare CDN + 本地最优节点
#       国内采用 西安 / 北京 / 上海 / 广东 四大区域动态搜索 + 多节点容灾池

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
            echo -e "${YELLOW}[提示] 当前架构 $(uname -m) 无官方 Speedtest 二进制包，将使用 HTTP 测速。${PLAIN}"
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

# 纯 Bash 实现 Fast.com (Netflix OCA CDN) 多线程并发测速（无需 Python）
speed_fast_com() {
    command -v curl >/dev/null 2>&1 || return 1

    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    local js_name token=""

    # 1. 动态获取 Fast.com JS Token，失败则回退到官方固定 Public Token
    js_name=$(curl -4 -fsSL -A "$ua" --max-time 5 "https://fast.com" 2>/dev/null | grep -oE 'app-[a-f0-9]+\.js' | head -n1)
    if [[ -n "$js_name" ]]; then
        token=$(curl -4 -fsSL -A "$ua" --max-time 5 "https://fast.com/${js_name}" 2>/dev/null | grep -oE 'token:"[^"]+"' | head -n1 | cut -d'"' -f2)
    fi
    [[ -z "$token" ]] && token="YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm"

    # 2. 请求 Netflix Speedtest v2 接口获取分配的 OCA 测速节点 URL
    local api_json urls first_url
    api_json=$(curl -4 -fsSL -A "$ua" --max-time 6 "https://api.fast.com/netflix/speedtest/v2?https=true&token=${token}&urlCount=3" 2>/dev/null)
    urls=$(echo "$api_json" | grep -oE 'https://[^"]+' | head -n 3)
    first_url=$(echo "$urls" | head -n 1)
    [[ -z "$first_url" ]] && return 1

    # 3. 测量到 Netflix CDN 节点的真实连接延迟
    local lat_sec lat_ms="N/A"
    lat_sec=$(curl -4 -o /dev/null -s -w "%{time_connect}" --connect-timeout 5 "$first_url" 2>/dev/null)
    if [[ -n "$lat_sec" ]]; then
        lat_ms=$(awk -v s="$lat_sec" 'BEGIN {if (s>0) printf "%.2f ms", s * 1000; else print "N/A"}')
    fi

    # 4. 3 线程并发拉取 Netflix OCA 流并汇总下载速率
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

# 单节点 Ookla Speedtest 测速执行器
speed_test() {
    local node_id=$1
    local node_name=$2
    local st_bin="$WORK_DIR/speedtest"
    [[ ! -x "$st_bin" ]] && return 1

    local cmd_prefix=()
    command -v timeout >/dev/null 2>&1 && cmd_prefix=(timeout 40)

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

# 根据 Sponsor / Host 自动识别中国三大运营商标识 (CT/CU/CM)
detect_cn_isp_tag() {
    local raw_info=$1
    local info_lc
    info_lc=$(echo "$raw_info" | tr '[:upper:]' '[:lower:]')

    if [[ "$info_lc" == *"telecom"* || "$info_lc" == *"chinanet"* || "$info_lc" == *"163"* || "$info_lc" == *"189"* || "$raw_info" == *"电信"* ]]; then
        echo "CT"
    elif [[ "$info_lc" == *"unicom"* || "$info_lc" == *"10010"* || "$raw_info" == *"联通"* ]]; then
        echo "CU"
    elif [[ "$info_lc" == *"mobile"* || "$info_lc" == *"cmcc"* || "$info_lc" == *"10086"* || "$raw_info" == *"移动"* ]]; then
        echo "CM"
    else
        echo "5G"
    fi
}

# 动态从 Ookla 官方搜索 API 获取指定中国城市的实时可用节点，并合并内置容灾节点池
# 参数: $1=展示城市名, $2=搜索关键词列表(逗号分隔), $3=内置兜底列表(ID:ISP格式,空格分隔), $4=期望成功测速节点数
test_cn_region() {
    local region_label=$1
    local search_keys=$2
    local fallback_list=$3
    local max_success=${4:-2}

    local candidates=()
    local seen_ids=" "
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    # 1. 实时查询 Speedtest 官方 API 获取当前在线的该地区节点
    if command -v curl >/dev/null 2>&1; then
        local kw api_res line sid sponsor host isp_tag
        IFS=',' read -ra kw_arr <<< "$search_keys"
        for kw in "${kw_arr[@]}"; do
            api_res=$(curl -4 -fsSL -A "$ua" --max-time 5 "https://www.speedtest.net/api/js/servers?engine=js&https_functional=true&limit=15&search=${kw}" 2>/dev/null)
            [[ -z "$api_res" ]] && continue

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                sid=$(echo "$line" | grep -oE '"id"[[:space:]]*:[[:space:]]*"?[0-9]+"?' | head -n1 | grep -oE '[0-9]+')
                [[ -z "$sid" || "$seen_ids" == *" $sid "* ]] && continue

                sponsor=$(echo "$line" | grep -oE '"sponsor"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/"sponsor"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')
                host=$(echo "$line" | grep -oE '"host"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/"host"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')
                isp_tag=$(detect_cn_isp_tag "$sponsor $host")

                seen_ids+="$sid "
                candidates+=("${sid}:${isp_tag}")
            done < <(echo "$api_res" | sed 's/},{/}\n{/g' | grep '"cc":"CN"')
        done
    fi

    # 2. 追加内置的多运营商静态备用节点池（防止 API 限流或搜索为空）
    local item fb_id fb_isp
    for item in $fallback_list; do
        fb_id="${item%%:*}"
        fb_isp="${item#*:}"
        if [[ -n "$fb_id" && "$seen_ids" != *" $fb_id "* ]]; then
            seen_ids+="$fb_id "
            candidates+=("${fb_id}:${fb_isp}")
        fi
    done

    # 3. 优先挑选不同运营商 (CT/CU/CM) 进行测速，失败则自动顺延尝试下一个候选节点
    local success_count=0
    local tested_isps=" "
    local tested_ids=" "
    local entry cid cisp display_name

    # 第一轮：优先覆盖不同运营商
    for entry in "${candidates[@]}"; do
        [[ $success_count -ge $max_success ]] && break
        cid="${entry%%:*}"
        cisp="${entry#*:}"
        [[ "$tested_isps" == *" $cisp "* ]] && continue

        display_name=$(printf "%-12s %s" "$region_label" "$cisp")
        tested_ids+="$cid "
        if speed_test "$cid" "$display_name"; then
            tested_isps+="$cisp "
            ((++success_count))
        fi
    done

    # 第二轮：若未达到目标数量，继续从剩余节点补齐
    for entry in "${candidates[@]}"; do
        [[ $success_count -ge $max_success ]] && break
        cid="${entry%%:*}"
        cisp="${entry#*:}"
        [[ "$tested_ids" == *" $cid "* ]] && continue

        display_name=$(printf "%-12s %s" "$region_label" "$cisp")
        tested_ids+="$cid "
        if speed_test "$cid" "$display_name"; then
            ((++success_count))
        fi
    done

    return $(( success_count > 0 ? 0 : 1 ))
}

# 运行中国四大重点区域（西安、北京、上海、广东）测速
run_china_speedtest() {
    local nodes_per_region=${1:-2}
    local st_bin="$WORK_DIR/speedtest"
    [[ ! -x "$st_bin" ]] && return 1

    local total_cn_success=0

    # 1. 西安节点 (西北枢纽: 陕西移动 / 西安联通 / 陕西电信)
    test_cn_region "CN Xi'an"     "Xian,Shaanxi"            "29105:CM 4863:CU 5292:CM 3633:CT"          "$nodes_per_region" && ((++total_cn_success))

    # 2. 北京节点 (华北枢纽: 北京联通 / 北京移动 / 北京电信)
    test_cn_region "CN Beijing"   "Beijing"                 "43752:CU 25858:CM 5145:CU 4751:CT 4713:CM" "$nodes_per_region" && ((++total_cn_success))

    # 3. 上海节点 (华东枢纽: 上海联通5G / 上海电信 / 上海移动)
    test_cn_region "CN Shanghai"  "Shanghai"                "24447:CU 5083:CU 3633:CT 25637:CM"         "$nodes_per_region" && ((++total_cn_success))

    # 4. 广东节点 (华南枢纽: 广州/深圳 电信 / 移动 / 联通)
    test_cn_region "CN Guangdong" "Guangzhou,Shenzhen"      "60584:CT 60794:CM 27594:CT 26678:CU 17251:CT" "$nodes_per_region" && ((++total_cn_success))

    [[ $total_cn_success -gt 0 ]] && return 0 || return 1
}

# 当 Ookla 完全不可用时，使用开源 LibreSpeed CLI 兜底
run_librespeed_fallback() {
    local ls_bin="$WORK_DIR/librespeed-cli"
    local ls_ver="1.0.11"
    local arch_tag=""

    case "$(uname -m)" in
        x86_64|amd64)   arch_tag="amd64" ;;
        aarch64|arm64)  arch_tag="arm64" ;;
        armv7l|armhf)   arch_tag="armv7" ;;
        i386|i686)      arch_tag="386" ;;
        *)              return 1 ;;
    esac

    if [[ ! -x "$ls_bin" ]]; then
        local url="https://github.com/librespeed/speedtest-cli/releases/download/v${ls_ver}/librespeed-cli_${ls_ver}_linux_${arch_tag}.tar.gz"
        local tgz="$WORK_DIR/librespeed.tgz"
        if download_file "$url" "$tgz"; then
            tar -xzf "$tgz" -C "$WORK_DIR" >/dev/null 2>&1
            chmod 700 "$ls_bin" 2>/dev/null
            rm -f "$tgz"
        fi
    fi

    [[ ! -x "$ls_bin" ]] && return 1

    local cmd_prefix=()
    command -v timeout >/dev/null 2>&1 && cmd_prefix=(timeout 60)

    local out
    out=$("${cmd_prefix[@]}" "$ls_bin" --csv --concurrent 3 2>/dev/null)
    [[ -z "$out" ]] && return 1

    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # 先将双引号内的逗号替换为空格，防止城市名带逗号导致 awk 列错位
        local clean_line sname lat dl up
        clean_line=$(echo "$line" | awk -F'"' -v OFS='' '{for (i=2; i<=NF; i+=2) gsub(/,/, " ", $i)} 1')
        sname=$(echo "$clean_line" | awk -F',' '{print substr($2, 1, 20)}')
        lat=$(echo "$clean_line"   | awk -F',' '{print $5}')
        dl=$(echo "$clean_line"    | awk -F',' '{print $7}')
        up=$(echo "$clean_line"    | awk -F',' '{print $8}')
        if [[ -n "$dl" && "$dl" =~ ^[0-9.]+$ ]]; then
            printf "${YELLOW}%-22s${GREEN}%-16s${RED}%-18s${SKYBLUE}%-12s${PLAIN}\n" " ${sname:-LibreSpeed}" "${up:-0.00} Mbit/s" "${dl} Mbit/s" "${lat:-N/A} ms" | tee -a "$LOG_FILE"
            ((++count))
        fi
    done <<< "$out"

    [[ $count -gt 0 ]] && return 0 || return 1
}

print_speedtest() {
    printf "%-22s%-16s%-18s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency" | tee -a "$LOG_FILE"

    local has_ookla=0
    install_speedtest && has_ookla=1

    # 1. 海外与国际主流 CDN 测速 (本地最优 + Fast.com + Cloudflare CDN)
    if [[ $has_ookla -eq 1 ]]; then
        speed_test '' 'Speedtest Default' || true
    fi
    speed_fast_com || true
    speed_cloudflare_cdn || true

    # 2. 中国四大核心区域测速 (西安 / 北京 / 上海 / 广东，标准模式每区测 2 个节点)
    if [[ $has_ookla -eq 1 ]]; then
        run_china_speedtest 2 || run_librespeed_fallback || true
    else
        run_librespeed_fallback || true
    fi
}

print_speedtest_fast() {
    printf "%-22s%-16s%-18s%-12s\n" " Node Name" "Upload Speed" "Download Speed" "Latency" | tee -a "$LOG_FILE"

    local has_ookla=0
    install_speedtest && has_ookla=1

    # 1. 海外与国际主流 CDN 测速
    if [[ $has_ookla -eq 1 ]]; then
        speed_test '' 'Speedtest Default' || true
    fi
    speed_fast_com || true
    speed_cloudflare_cdn || true

    # 2. 中国四大核心区域快速测速 (西安 / 北京 / 上海 / 广东，快速模式每区测 1 个节点)
    if [[ $has_ookla -eq 1 ]]; then
        run_china_speedtest 1 || true
    fi
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
