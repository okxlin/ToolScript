#!/bin/bash

set -o pipefail

TIMEZONE="Asia/Shanghai"
CHRONY_MARKER_BEGIN="# BEGIN ToolScript timesync"
CHRONY_MARKER_END="# END ToolScript timesync"
NTP_SERVERS=(
    "ntp.aliyun.com"
    "ntp.tencent.com"
    "cn.pool.ntp.org"
    "time.cloudflare.com"
    "time.apple.com"
    "time.google.com"
    "pool.ntp.org"
)
HTTP_TIME_URLS=(
    "https://www.apple.com/"
    "https://www.baidu.com/"
    "https://www.qq.com/"
    "https://www.cloudflare.com/"
)

log() {
    echo "$*"
}

warn() {
    echo "警告：$*" >&2
}

die() {
    echo "错误：$*" >&2
    exit 1
}

# 检查是否以root身份运行脚本
check_root() {
    if [ "$EUID" -ne 0 ]; then
        die "请以root身份或使用sudo运行此脚本"
    fi
}

# 检测包管理器
detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        die "不支持的Linux发行版，无法确定包管理器类型"
    fi
}

# 更新软件包缓存。yum/dnf 只刷新缓存，避免把所有包都升级一遍。
update_package_list() {
    case "$PKG_MANAGER" in
        apt)
            apt-get update
            ;;
        dnf)
            dnf makecache -y
            ;;
        yum)
            yum makecache -y
            ;;
    esac
}

install_package() {
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
    esac
}

# 检查并安装基础依赖。NTP客户端安装失败时仍可使用HTTP Date头兜底。
install_packages() {
    local missing_packages=()

    if ! command -v curl >/dev/null 2>&1; then
        missing_packages+=("curl")
    else
        log "curl 已经可用，跳过安装步骤。"
    fi

    if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        missing_packages+=("tzdata")
    else
        log "tzdata 已经可用，跳过安装步骤。"
    fi

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        update_package_list
        install_package "${missing_packages[@]}" || die "安装基础依赖失败：${missing_packages[*]}"
    fi

    if ! command -v ntpdate >/dev/null 2>&1 &&
       ! command -v sntp >/dev/null 2>&1 &&
       ! command -v chronyc >/dev/null 2>&1; then
        log "未找到NTP客户端，尝试安装chrony。"
        update_package_list
        install_package chrony || install_package ntpdate || install_package ntpsec-ntpdate || warn "未能安装NTP客户端，将使用HTTP时间头兜底。"
    fi
}

# 调整时区到上海。非systemd环境使用/etc/localtime兜底。
adjust_timezone() {
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1; then
        log "时区已设置为$TIMEZONE"
        return 0
    fi

    if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        echo "$TIMEZONE" >/etc/timezone 2>/dev/null || true
        log "时区已设置为$TIMEZONE"
        return 0
    fi

    warn "无法设置时区为$TIMEZONE，请确认tzdata已正确安装。"
    return 1
}

sync_hardware_clock() {
    if command -v hwclock >/dev/null 2>&1; then
        hwclock --systohc --utc >/dev/null 2>&1 || warn "写入硬件时钟失败，可能是VPS或容器环境不支持。"
    fi
}

enable_timedatectl_ntp() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1
        return $?
    fi

    return 1
}

install_chrony() {
    if command -v chronyc >/dev/null 2>&1; then
        log "chrony 已经可用，跳过安装步骤。"
        return 0
    fi

    log "正在安装chrony用于后续自动同步时间..."
    update_package_list
    install_package chrony
}

chrony_config_path() {
    if [ -f /etc/chrony/chrony.conf ]; then
        echo "/etc/chrony/chrony.conf"
        return 0
    fi

    if [ -f /etc/chrony.conf ]; then
        echo "/etc/chrony.conf"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            echo "/etc/chrony/chrony.conf"
            ;;
        dnf|yum)
            echo "/etc/chrony.conf"
            ;;
        *)
            return 1
            ;;
    esac
}

configure_chrony_sources() {
    local config
    local tmp_file
    local server

    config=$(chrony_config_path) || return 1
    mkdir -p "$(dirname "$config")" || return 1
    touch "$config" || return 1

    tmp_file=$(mktemp) || return 1
    awk -v begin="$CHRONY_MARKER_BEGIN" -v end="$CHRONY_MARKER_END" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "$config" >"$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    {
        echo ""
        echo "$CHRONY_MARKER_BEGIN"
        echo "# 使用多个时间源，保留发行版默认配置作为兜底。"
        for server in "${NTP_SERVERS[@]}"; do
            echo "server $server iburst"
        done
        echo "$CHRONY_MARKER_END"
    } >>"$tmp_file"

    cp "$config" "$config.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    cat "$tmp_file" >"$config" || {
        rm -f "$tmp_file"
        return 1
    }
    rm -f "$tmp_file"

    log "chrony时间源已写入：$config"
}

chrony_service_name() {
    local service

    if command -v systemctl >/dev/null 2>&1; then
        for service in chrony chronyd; do
            if systemctl list-unit-files "$service.service" 2>/dev/null | grep -q "^$service.service"; then
                echo "$service"
                return 0
            fi
        done
    fi

    for service in chrony chronyd; do
        if [ -x "/etc/init.d/$service" ]; then
            echo "$service"
            return 0
        fi
    done

    case "$PKG_MANAGER" in
        apt)
            echo "chrony"
            ;;
        dnf|yum)
            echo "chronyd"
            ;;
        *)
            return 1
            ;;
    esac
}

restart_chrony_service() {
    local service

    service=$(chrony_service_name) || return 1

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl enable --now "$service" >/dev/null 2>&1; then
            log "chrony服务已启用：$service"
            return 0
        fi
        warn "systemctl启用$service失败，尝试传统service命令。"
    fi

    if command -v service >/dev/null 2>&1; then
        if service "$service" restart >/dev/null 2>&1; then
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$service" defaults >/dev/null 2>&1 || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig "$service" on >/dev/null 2>&1 || true
            fi
            log "chrony服务已启动：$service"
            return 0
        fi
    fi

    warn "无法启动chrony服务，请手动检查chrony/chronyd服务状态。"
    return 1
}

setup_persistent_time_sync() {
    log "正在配置后续自动同步时间..."

    if install_chrony && configure_chrony_sources && restart_chrony_service; then
        chronyc -a makestep >/dev/null 2>&1 || true
        log "已启用chrony持续自动同步时间。"
        return 0
    fi

    warn "chrony配置失败，尝试使用systemd-timesyncd。"
    if enable_timedatectl_ntp; then
        log "已启用systemd-timesyncd自动同步时间。"
        return 0
    fi

    warn "无法启用自动同步时间，请手动安装并启用chrony。"
    return 1
}

enable_persistent_ntp() {
    setup_persistent_time_sync
}

sync_with_chrony() {
    if ! command -v chronyc >/dev/null 2>&1; then
        return 1
    fi

    log "正在尝试通过chrony同步系统时间..."
    chronyc -a makestep >/dev/null 2>&1
}

sync_with_ntpdate() {
    local server

    if ! command -v ntpdate >/dev/null 2>&1; then
        return 1
    fi

    for server in "${NTP_SERVERS[@]}"; do
        log "正在尝试NTP服务器：$server"
        if timeout 20 ntpdate -u "$server"; then
            return 0
        fi
    done

    return 1
}

sync_with_sntp() {
    local server

    if ! command -v sntp >/dev/null 2>&1; then
        return 1
    fi

    for server in "${NTP_SERVERS[@]}"; do
        log "正在尝试SNTP服务器：$server"
        if timeout 20 sntp -S "$server"; then
            return 0
        fi
    done

    return 1
}

# 优先使用NTP同步。成功后不再用HTTP Date头覆盖时间。
sync_time() {
    log "正在同步系统时间..."

    if sync_with_chrony || sync_with_ntpdate || sync_with_sntp; then
        sync_hardware_clock
        enable_persistent_ntp
        log "NTP同步成功。"
        return 0
    fi

    warn "NTP同步失败，将尝试使用HTTP Date头设置时间。"
    return 1
}

get_http_timestamp() {
    local url="$1"
    local http_date

    http_date=$(curl -fsSI --insecure --connect-timeout 5 --max-time 10 "$url" 2>/dev/null |
        awk '/^[Dd][Aa][Tt][Ee]:/ {sub(/\r$/, ""); sub(/^[Dd][Aa][Tt][Ee]:[[:space:]]*/, ""); print; exit}')

    if [ -z "$http_date" ]; then
        return 1
    fi

    LC_ALL=C date -u -d "$http_date" '+%s' 2>/dev/null
}

set_system_clock() {
    local timestamp="$1"

    if date -u -s "@$timestamp" >/dev/null 2>&1; then
        sync_hardware_clock
        return 0
    fi

    warn "设置系统时间失败，请确认当前环境允许修改系统时间（容器需要CAP_SYS_TIME）。"
    return 1
}

# HTTP Date头是UTC时间，直接按UTC时间戳设置系统时钟；不要手动+8小时。
set_system_time_from_http() {
    local url
    local timestamp

    for url in "${HTTP_TIME_URLS[@]}"; do
        log "正在尝试HTTP时间源：$url"
        timestamp=$(get_http_timestamp "$url") || continue

        if set_system_clock "$timestamp"; then
            log "HTTP时间同步成功。"
            return 0
        fi
    done

    return 1
}

# 主函数
main() {
    check_root
    detect_package_manager
    install_packages
    adjust_timezone

    if ! sync_time; then
        set_system_time_from_http || die "所有时间同步方式均失败"
        enable_persistent_ntp
    fi

    log "时间同步操作完成。当前时间：$(date)"
}

# 执行主函数
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
