#!/bin/bash

set -o pipefail

TIMEZONE="Asia/Shanghai"
DOCKER_COMPOSE_WRAPPER="/usr/local/bin/docker-compose"
DOCKER_DAEMON_JSON="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
CHRONY_MARKER_BEGIN="# BEGIN ToolScript vps-setup timesync"
CHRONY_MARKER_END="# END ToolScript vps-setup timesync"
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
CHINA_DOCKER_REGISTRY_MIRRORS=(
    "docker.1ms.run"
    "docker.m.daocloud.io"
    "docker.1panel.live"
)

log() {
    echo "$*"
}

warn() {
    echo "警告：$* (Warning: $*)" >&2
}

die() {
    echo "错误：$* (Error: $*)" >&2
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
    detect_package_manager

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
    detect_package_manager

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

ensure_time_sync_dependencies() {
    local missing_packages=()

    detect_package_manager

    if ! command -v curl >/dev/null 2>&1; then
        missing_packages+=("curl")
    else
        log "curl 已经可用，跳过安装步骤。(curl is already available, skipping.)"
    fi

    if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        missing_packages+=("tzdata")
    else
        log "tzdata 已经可用，跳过安装步骤。(tzdata is already available, skipping.)"
    fi

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        update_package_list
        install_package "${missing_packages[@]}" || die "安装基础时间同步依赖失败：${missing_packages[*]}"
    fi

    if ! command -v ntpdate >/dev/null 2>&1 &&
       ! command -v sntp >/dev/null 2>&1 &&
       ! command -v chronyc >/dev/null 2>&1; then
        log "未找到NTP客户端，尝试安装chrony。(NTP client not found, installing chrony.)"
        update_package_list
        install_package chrony || install_package ntpdate || install_package ntpsec-ntpdate || warn "未能安装NTP客户端，将使用HTTP时间头兜底。"
    fi
}

# 调整时区到上海
adjust_timezone() {
    log "调整时区... (Adjusting timezone...)"

    if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        log "未找到tzdata，尝试安装... (tzdata not found, attempting to install...)"
        update_package_list
        install_package tzdata || warn "安装tzdata失败，无法可靠设置时区。"
    fi

    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1; then
        log "时区已设置为$TIMEZONE (Timezone set to $TIMEZONE)."
        return 0
    fi

    if [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        echo "$TIMEZONE" >/etc/timezone 2>/dev/null || true
        log "时区已设置为$TIMEZONE (Timezone set to $TIMEZONE)."
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
        log "chrony 已经可用，跳过安装步骤。(chrony is already available, skipping.)"
        return 0
    fi

    log "正在安装chrony用于后续自动同步时间... (Installing chrony for continuous time sync...)"
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

    detect_package_manager
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

    log "chrony时间源已写入：$config (chrony sources written to: $config)"
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

    detect_package_manager
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
            log "chrony服务已启用：$service (chrony service enabled: $service)"
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
            log "chrony服务已启动：$service (chrony service started: $service)"
            return 0
        fi
    fi

    warn "无法启动chrony服务，请手动检查chrony/chronyd服务状态。"
    return 1
}

setup_persistent_time_sync() {
    log "正在配置后续自动同步时间... (Configuring continuous time synchronization...)"

    if install_chrony && configure_chrony_sources && restart_chrony_service; then
        chronyc -a makestep >/dev/null 2>&1 || true
        log "已启用chrony持续自动同步时间。(chrony continuous time sync enabled.)"
        return 0
    fi

    warn "chrony配置失败，尝试使用systemd-timesyncd。"
    if enable_timedatectl_ntp; then
        log "已启用systemd-timesyncd自动同步时间。(systemd-timesyncd time sync enabled.)"
        return 0
    fi

    warn "无法启用自动同步时间，请手动安装并启用chrony。"
    return 1
}

sync_with_chrony() {
    if ! command -v chronyc >/dev/null 2>&1; then
        return 1
    fi

    log "正在尝试通过chrony同步系统时间... (Trying chrony time sync...)"
    chronyc -a makestep >/dev/null 2>&1
}

sync_with_ntpdate() {
    local server

    if ! command -v ntpdate >/dev/null 2>&1; then
        return 1
    fi

    for server in "${NTP_SERVERS[@]}"; do
        log "正在尝试NTP服务器：$server (Trying NTP server: $server)"
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
        log "正在尝试SNTP服务器：$server (Trying SNTP server: $server)"
        if timeout 20 sntp -S "$server"; then
            return 0
        fi
    done

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

set_system_time_from_http() {
    local url
    local timestamp

    for url in "${HTTP_TIME_URLS[@]}"; do
        log "正在尝试HTTP时间源：$url (Trying HTTP time source: $url)"
        timestamp=$(get_http_timestamp "$url") || continue

        if set_system_clock "$timestamp"; then
            log "HTTP时间同步成功。(HTTP time sync succeeded.)"
            return 0
        fi
    done

    return 1
}

# 同步系统时间，并配置后续自动同步
sync_system_time() {
    local current_time

    log "同步系统时间... (Syncing system time...)"
    ensure_time_sync_dependencies
    setup_persistent_time_sync || true

    if sync_with_chrony || sync_with_ntpdate || sync_with_sntp; then
        sync_hardware_clock
        log "NTP同步成功。(NTP time sync succeeded.)"
    else
        warn "NTP同步失败，将尝试使用HTTP Date头设置时间。"
        set_system_time_from_http || die "所有时间同步方式均失败"
    fi

    current_time=$(date)
    log "时间同步操作完成。当前时间：$current_time (Time synchronization completed. Current time: $current_time)"
}

# 内核启动bbr设置
enable_bbr() {
    echo "启用BBR拥塞控制算法... (Enabling BBR congestion control...)"
    kernel_version=$(uname -r | cut -d. -f1)
    if [ "$kernel_version" -gt 4 ] || { [ "$kernel_version" -eq 4 ] && [ "$(uname -r | cut -d. -f2)" -ge 9 ]; }; then
        echo "启用 BBR... (Enabling BBR...)"
        cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system
        echo "BBR 已启用 (BBR enabled)."
    else
        echo "内核版本低于 4.9，当前脚本不会自动执行第三方BBR脚本。请先升级内核或手动使用可信脚本。(Kernel version is less than 4.9. Upgrade the kernel or use a trusted script manually.)"
    fi
}

# 调整主机名
adjust_hostname() {
    echo "调整主机名... (Adjusting hostname...)"
    if command -v lsb_release &>/dev/null; then
        os_name=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
    elif [ -f /etc/os-release ]; then
        os_name=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]')
    else
        os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi

    case $os_name in
        "ubuntu")
            new_hostname="ubuntu"
            ;;
        "debian")
            new_hostname="debian"
            ;;
        "centos")
            new_hostname="centos"
            ;;
        *)
            new_hostname="$os_name"
            ;;
    esac

    hostnamectl set-hostname "$new_hostname"
    echo "主机名已设置为 $new_hostname (Hostname set to $new_hostname)."
}


trim_spaces() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

normalize_docker_ce_source() {
    local source="$1"

    source=$(trim_spaces "$source")
    case "$source" in
        http://*)
            source="${source#http://}"
            ;;
        https://*)
            source="${source#https://}"
            ;;
    esac
    source="${source%/}"

    if [ -z "$source" ] || [[ "$source" == *[!A-Za-z0-9._~:/%+-]* ]]; then
        warn "Docker CE源地址不合法：$1"
        return 1
    fi

    printf 'https://%s\n' "$source"
}

# Docker CE 源。官方源优先保证版本新，镜像源作为访问失败时的兜底。
docker_repo_sources() {
    local custom_source="${DOCKER_CE_SOURCE:-}"
    local normalized_source

    if [ -n "$custom_source" ]; then
        normalized_source=$(normalize_docker_ce_source "$custom_source") || return 1
        printf '%s\n' "$normalized_source"
    fi

    printf '%s\n' \
        "https://download.docker.com" \
        "https://mirrors.aliyun.com/docker-ce" \
        "https://mirrors.tencent.com/docker-ce" \
        "https://mirrors.huaweicloud.com/docker-ce" \
        "https://mirrors.volces.com/docker" \
        "https://mirrors.163.com/docker-ce" \
        "https://mirrors.tuna.tsinghua.edu.cn/docker-ce" \
        "https://mirrors.ustc.edu.cn/docker-ce" \
        "https://mirrors.cernet.edu.cn/docker-ce"
}

docker_install_script_sources() {
    printf '%s\n' \
        "https://get.docker.com" \
        "https://raw.githubusercontent.com/docker/docker-install/master/install.sh" \
        "https://cdn.jsdelivr.net/gh/docker/docker-install@master/install.sh" \
        "https://fastly.jsdelivr.net/gh/docker/docker-install@master/install.sh" \
        "https://gcore.jsdelivr.net/gh/docker/docker-install@master/install.sh" \
        "https://testingcf.jsdelivr.net/gh/docker/docker-install@master/install.sh"
}

os_release_value() {
    local key="$1"
    local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"

    if [ -r "$os_release_file" ]; then
        awk -F= -v key="$key" '$1 == key {gsub(/"/, "", $2); print $2; exit}' "$os_release_file"
    fi
}

start_enable_service() {
    local service="$1"

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl enable --now "$service" >/dev/null 2>&1; then
            echo "$service 服务已启动并设置为开机自启 ($service service enabled and started)."
            return 0
        fi
    fi

    if command -v service >/dev/null 2>&1; then
        if service "$service" start >/dev/null 2>&1; then
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$service" defaults >/dev/null 2>&1 || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig "$service" on >/dev/null 2>&1 || true
            fi
            echo "$service 服务已启动 ($service service started)."
            return 0
        fi
    fi

    warn "无法启动$service服务，请手动检查服务状态。"
    return 1
}

ensure_curl_available() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    echo "未找到curl，尝试安装... (curl not found, attempting to install...)"
    update_package_list
    install_package curl
}

docker_apt_os() {
    local os_id
    local id_like
    local os_name

    os_id=$(os_release_value ID | tr '[:upper:]' '[:lower:]')
    id_like=$(os_release_value ID_LIKE | tr '[:upper:]' '[:lower:]')
    os_name=$(os_release_value NAME)
    case "$os_id" in
        ubuntu|debian|raspbian)
            echo "$os_id"
            ;;
        linuxmint)
            if [[ "$os_name" == *LMDE* ]]; then
                echo "debian"
            else
                echo "ubuntu"
            fi
            ;;
        kali|openkylin)
            echo "debian"
            ;;
        *)
            if [[ " $id_like " == *" ubuntu "* ]]; then
                echo "ubuntu"
            elif [[ " $id_like " == *" debian "* ]]; then
                echo "debian"
            else
                return 1
            fi
            ;;
    esac
}

docker_apt_codename() {
    local docker_os="${1:-}"
    local os_id
    local os_name
    local codename

    if [ -z "$docker_os" ]; then
        docker_os=$(docker_apt_os) || return 1
    fi

    os_id=$(os_release_value ID | tr '[:upper:]' '[:lower:]')
    os_name=$(os_release_value NAME)

    case "$os_id" in
        kali|openkylin)
            echo "trixie"
            return 0
            ;;
    esac

    if [ "$docker_os" = "ubuntu" ]; then
        codename=$(os_release_value UBUNTU_CODENAME)
        [ -n "$codename" ] || codename=$(os_release_value VERSION_CODENAME)
    elif [ "$os_id" = "linuxmint" ] && [[ "$os_name" == *LMDE* ]]; then
        codename=$(os_release_value DEBIAN_CODENAME)
        [ -n "$codename" ] || codename=$(os_release_value VERSION_CODENAME)
        [ -n "$codename" ] || codename="bookworm"
    elif [ "$os_id" = "debian" ] || [ "$os_id" = "raspbian" ]; then
        codename=$(os_release_value VERSION_CODENAME)
        [ -n "$codename" ] || codename=$(os_release_value DEBIAN_CODENAME)
    elif [ "$docker_os" = "debian" ]; then
        codename=$(os_release_value DEBIAN_CODENAME)
        [ -n "$codename" ] || codename="bookworm"
    else
        codename=$(os_release_value VERSION_CODENAME)
    fi

    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs)
    fi

    [ -n "$codename" ] || return 1
    echo "$codename"
}

docker_rpm_repo_os() {
    local os_id

    os_id=$(os_release_value ID)
    case "$os_id" in
        fedora)
            echo "fedora"
            ;;
        *)
            echo "centos"
            ;;
    esac
}

install_docker_with_amazon_linux() {
    local packages=("docker")

    if [ "$(os_release_value ID)" != "amzn" ]; then
        return 1
    fi

    if command -v amazon-linux-extras >/dev/null 2>&1; then
        amazon-linux-extras install -y docker && return 0
    fi

    install_package "${packages[@]}"
}

confirm_docker_install_script() {
    local script_source="$1"
    local script_hash="$2"
    local confirm

    echo "Docker仓库安装失败，将尝试官方安装脚本兜底。"
    echo "来源：$script_source"
    echo "SHA256：$script_hash"
    echo "该脚本将以root权限执行。建议仅在Docker CE仓库不可用时使用。"

    if [ -n "${DOCKER_INSTALL_SCRIPT_SHA256:-}" ] && [ "$script_hash" != "$DOCKER_INSTALL_SCRIPT_SHA256" ]; then
        warn "Docker安装脚本SHA256与DOCKER_INSTALL_SCRIPT_SHA256不匹配，拒绝执行。"
        return 1
    fi

    if [ "${ALLOW_DOCKER_INSTALL_SCRIPT:-0}" = "1" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        warn "非交互环境不会自动执行远程Docker安装脚本。如需启用，请设置 ALLOW_DOCKER_INSTALL_SCRIPT=1。"
        return 1
    fi

    read -r -p "确认执行该Docker安装脚本？请输入 yes 继续: " confirm
    [ "$confirm" = "yes" ]
}

download_docker_install_script() {
    local output_file="$1"
    local source

    for source in $(docker_install_script_sources); do
        echo "正在尝试下载Docker安装脚本：$source" >&2
        if curl -fsSL --retry 2 --connect-timeout 5 --max-time 20 "$source" -o "$output_file"; then
            printf '%s\n' "$source"
            return 0
        fi
    done

    return 1
}

install_docker_with_install_script() {
    local tmp_dir
    local script_file
    local script_source
    local script_hash
    local repo_source

    command -v sha256sum >/dev/null 2>&1 || install_package coreutils >/dev/null 2>&1 || true
    command -v sha256sum >/dev/null 2>&1 || {
        warn "未找到sha256sum，拒绝执行远程Docker安装脚本。"
        return 1
    }

    tmp_dir=$(mktemp -d) || return 1
    script_file="$tmp_dir/docker-install.sh"

    script_source=$(download_docker_install_script "$script_file") || {
        rm -rf "$tmp_dir"
        return 1
    }

    if [ ! -s "$script_file" ] || [ "$(wc -c <"$script_file")" -gt 300000 ]; then
        warn "Docker安装脚本为空或异常过大，拒绝执行。"
        rm -rf "$tmp_dir"
        return 1
    fi

    script_hash=$(sha256sum "$script_file" | awk '{print $1}')
    confirm_docker_install_script "$script_source" "$script_hash" || {
        rm -rf "$tmp_dir"
        return 1
    }

    while IFS= read -r repo_source; do
        [ -n "$repo_source" ] || continue
        echo "使用Docker安装脚本并指定包源：$repo_source"
        if DOWNLOAD_URL="$repo_source" sh "$script_file"; then
            rm -rf "$tmp_dir"
            return 0
        fi
    done < <(docker_repo_sources)

    rm -rf "$tmp_dir"
    return 1
}

docker_registry_mirror_setting() {
    printf '%s\n' "${DOCKER_REGISTRY_MIRROR:-${SOURCE_REGISTRY:-}}"
}

docker_registry_china_mirrors() {
    local mirror

    for mirror in "${CHINA_DOCKER_REGISTRY_MIRRORS[@]}"; do
        printf '%s\n' "$mirror"
    done
}

normalize_docker_registry_mirror() {
    local mirror="$1"

    mirror=$(trim_spaces "$mirror")
    case "$mirror" in
        http://*)
            mirror="${mirror#http://}"
            ;;
        https://*)
            mirror="${mirror#https://}"
            ;;
    esac
    mirror="${mirror%/}"

    if [ -z "$mirror" ] || [[ "$mirror" == *[!A-Za-z0-9._~:/%+-]* ]]; then
        warn "Docker Registry镜像地址不合法：$1"
        return 1
    fi

    printf 'https://%s\n' "$mirror"
}

docker_registry_official_requested() {
    local setting="$1"

    setting=$(trim_spaces "$setting")
    setting="${setting#http://}"
    setting="${setting#https://}"
    setting="${setting%/}"

    case "$setting" in
        ""|off|none|disable|disabled|registry.hub.docker.com)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

docker_registry_mirrors_json() {
    local setting="$1"
    local item
    local normalized
    local result=""
    local separator=""
    local old_ifs="$IFS"
    local items=()

    setting=$(trim_spaces "$setting")
    case "$setting" in
        china|auto|cn)
            while IFS= read -r item; do
                items+=("$item")
            done < <(docker_registry_china_mirrors)
            ;;
        *)
            IFS=','
            read -r -a items <<< "$setting"
            IFS="$old_ifs"
            ;;
    esac

    for item in "${items[@]}"; do
        item=$(trim_spaces "$item")
        [ -n "$item" ] || continue
        normalized=$(normalize_docker_registry_mirror "$item") || return 1
        result="${result}${separator}\"${normalized}\""
        separator=","
    done

    [ -n "$result" ] || return 1
    printf '[%s]\n' "$result"
}

backup_docker_daemon_json() {
    local daemon_json="$1"
    local backup_file="${daemon_json}.bak"

    [ -s "$daemon_json" ] || return 0
    if [ ! -e "$backup_file" ]; then
        cp -p "$daemon_json" "$backup_file" || return 1
    fi
}

ensure_jq_available() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    update_package_list
    install_package jq
}

write_docker_daemon_json_with_jq() {
    local daemon_json="$1"
    local action="$2"
    local mirrors_json="${3:-}"
    local tmp_file

    tmp_file=$(mktemp) || return 1

    if [ "$action" = "set" ]; then
        if ! jq --argjson mirrors "$mirrors_json" '.["registry-mirrors"] = $mirrors' "$daemon_json" >"$tmp_file"; then
            rm -f "$tmp_file"
            return 1
        fi
    elif ! jq 'del(.["registry-mirrors"])' "$daemon_json" >"$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi

    if [ ! -s "$tmp_file" ]; then
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$daemon_json"
}

reload_docker_after_daemon_change() {
    if [ "${SKIP_DOCKER_RESTART:-0}" = "1" ]; then
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        if systemctl is-active --quiet docker >/dev/null 2>&1; then
            systemctl restart docker || warn "Docker配置已更新，但重启Docker失败，请手动执行 systemctl restart docker。"
        fi
        return 0
    fi

    if command -v service >/dev/null 2>&1 && service docker status >/dev/null 2>&1; then
        service docker restart || warn "Docker配置已更新，但重启Docker失败，请手动执行 service docker restart。"
    fi
}

configure_docker_registry_mirror() {
    local setting
    local daemon_json="${DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
    local daemon_dir
    local mirrors_json

    setting=$(trim_spaces "$(docker_registry_mirror_setting)")
    [ -n "$setting" ] || return 0

    daemon_dir=$(dirname "$daemon_json")
    mkdir -p "$daemon_dir" || return 1

    if docker_registry_official_requested "$setting"; then
        [ -s "$daemon_json" ] || return 0
        backup_docker_daemon_json "$daemon_json" || return 1
        ensure_jq_available || {
            warn "未找到jq，无法安全移除已有Docker registry-mirrors配置。"
            return 1
        }
        write_docker_daemon_json_with_jq "$daemon_json" "del" || return 1
        reload_docker_after_daemon_change
        echo "Docker Registry镜像配置已移除，使用官方Docker Hub。"
        return 0
    fi

    mirrors_json=$(docker_registry_mirrors_json "$setting") || return 1

    if [ -s "$daemon_json" ]; then
        backup_docker_daemon_json "$daemon_json" || return 1
        ensure_jq_available || {
            warn "未找到jq，无法安全保留并更新已有Docker daemon.json。"
            return 1
        }
        write_docker_daemon_json_with_jq "$daemon_json" "set" "$mirrors_json" || return 1
    else
        printf '{\n  "registry-mirrors": %s\n}\n' "$mirrors_json" >"$daemon_json"
    fi

    reload_docker_after_daemon_change
    echo "Docker Registry镜像已配置：$mirrors_json"
}

# 安装 Docker
install_docker() {
    echo "正在安装 Docker... (Installing Docker...)"

    if command -v docker >/dev/null 2>&1; then
        echo "Docker已经安装 (Docker is already installed)."
        configure_docker_registry_mirror || warn "Docker Registry镜像配置失败，请手动检查 $DOCKER_DAEMON_JSON。"
        start_enable_service docker || true
        return 0
    fi

    detect_package_manager
    ensure_curl_available || die "安装curl失败，无法继续安装Docker"

    case "$PKG_MANAGER" in
        apt)
            install_docker_with_apt_package_manager || install_docker_with_install_script || die "Docker安装失败"
            ;;
        dnf|yum)
            install_docker_with_yum_package_manager || install_docker_with_install_script || die "Docker安装失败"
            ;;
        *)
            die "无法找到适合的包管理器来安装 Docker"
            ;;
    esac

    if command -v docker >/dev/null 2>&1; then
        echo "Docker安装成功 (Docker installed successfully)."
        configure_docker_registry_mirror || warn "Docker Registry镜像配置失败，请手动检查 $DOCKER_DAEMON_JSON。"
        start_enable_service docker || true
    else
        die "Docker安装后仍不可用，请检查包管理器输出"
    fi
}

# 从包管理器安装 Docker（针对 yum/dnf）
install_docker_with_yum_package_manager() {
    local docker_components=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-compose-plugin"
        "docker-buildx-plugin"
    )
    local repo_os
    local source
    local repo_url
    local repo_file="/etc/yum.repos.d/docker-ce.repo"

    if install_docker_with_amazon_linux; then
        install_package docker-compose-plugin docker-buildx-plugin >/dev/null 2>&1 || true
        return 0
    fi

    repo_os=$(docker_rpm_repo_os)
    mkdir -p /etc/yum.repos.d

    while IFS= read -r source; do
        [ -n "$source" ] || continue
        repo_url="$source/linux/$repo_os/docker-ce.repo"
        echo "正在尝试Docker源：$repo_url (Trying Docker repository: $repo_url)"

        if curl -fsSL --retry 2 --connect-timeout 5 --max-time 20 "$repo_url" -o "$repo_file"; then
            if install_package "${docker_components[@]}"; then
                return 0
            fi
        fi
    done < <(docker_repo_sources)

    return 1
}

# 从包管理器安装 Docker（针对 apt）
install_docker_with_apt_package_manager() {
    local docker_components=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-compose-plugin"
        "docker-buildx-plugin"
    )
    local docker_os
    local codename
    local arch
    local source
    local keyring="/etc/apt/keyrings/docker.gpg"
    local tmp_keyring
    local repo_file="/etc/apt/sources.list.d/docker.list"

    docker_os=$(docker_apt_os) || {
        warn "当前apt系统不是Debian/Ubuntu及兼容发行版，无法自动配置Docker官方源。"
        return 1
    }
    codename=$(docker_apt_codename "$docker_os") || {
        warn "无法识别发行版代号，无法自动配置Docker官方源。"
        return 1
    }
    arch=$(dpkg --print-architecture)

    update_package_list
    install_package ca-certificates curl gnupg lsb-release || return 1
    install -m 0755 -d /etc/apt/keyrings

    while IFS= read -r source; do
        [ -n "$source" ] || continue
        echo "正在尝试Docker源：$source/linux/$docker_os (Trying Docker repository: $source/linux/$docker_os)"
        tmp_keyring=$(mktemp) || return 1
        rm -f "$tmp_keyring"

        if curl -fsSL --retry 2 --connect-timeout 5 --max-time 20 "$source/linux/$docker_os/gpg" |
            gpg --batch --yes --dearmor -o "$tmp_keyring"; then
            mv "$tmp_keyring" "$keyring"
            chmod a+r "$keyring"
            printf 'deb [arch=%s signed-by=%s] %s/linux/%s %s stable\n' \
                "$arch" "$keyring" "$source" "$docker_os" "$codename" >"$repo_file"

            if apt-get update && apt-get install -y "${docker_components[@]}"; then
                return 0
            fi
        else
            rm -f "$tmp_keyring"
        fi
    done < <(docker_repo_sources)

    return 1
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1 || docker-compose --version >/dev/null 2>&1
}

ensure_legacy_docker_compose_command() {
    if command -v docker-compose >/dev/null 2>&1; then
        return 0
    fi

    if docker compose version >/dev/null 2>&1; then
        cat > "$DOCKER_COMPOSE_WRAPPER" <<'EOF'
#!/bin/sh
exec docker compose "$@"
EOF
        chmod +x "$DOCKER_COMPOSE_WRAPPER"
        return $?
    fi

    return 1
}

compose_standalone_arch() {
    local arch

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        armv7l|armv7)
            echo "armv7"
            ;;
        armv6l|armv6)
            echo "armv6"
            ;;
        ppc64le|s390x|riscv64)
            echo "$arch"
            ;;
        *)
            return 1
            ;;
    esac
}

latest_compose_release() {
    curl -fsSL --connect-timeout 5 --max-time 20 "https://api.github.com/repos/docker/compose/releases/latest" |
        sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
}

install_docker_compose_standalone() {
    local tag
    local arch
    local os_name
    local asset
    local base_url
    local tmp_dir

    command -v sha256sum >/dev/null 2>&1 || install_package coreutils >/dev/null 2>&1 || true
    command -v sha256sum >/dev/null 2>&1 || {
        warn "未找到sha256sum，跳过standalone docker-compose安装。"
        return 1
    }

    tag=$(latest_compose_release) || return 1
    [ -n "$tag" ] || return 1
    arch=$(compose_standalone_arch) || {
        warn "当前CPU架构不支持自动安装standalone docker-compose：$(uname -m)"
        return 1
    }
    os_name=$(uname -s | tr '[:upper:]' '[:lower:]')
    asset="docker-compose-${os_name}-${arch}"
    base_url="https://github.com/docker/compose/releases/download/${tag}/${asset}"
    tmp_dir=$(mktemp -d) || return 1

    if curl -fsSL --connect-timeout 10 --max-time 120 "$base_url" -o "$tmp_dir/$asset" &&
       curl -fsSL --connect-timeout 10 --max-time 30 "$base_url.sha256" -o "$tmp_dir/$asset.sha256" &&
       (cd "$tmp_dir" && sha256sum -c "$asset.sha256" >/dev/null 2>&1); then
        install -m 0755 "$tmp_dir/$asset" "$DOCKER_COMPOSE_WRAPPER"
        if [ ! -e /usr/bin/docker-compose ]; then
            ln -s "$DOCKER_COMPOSE_WRAPPER" /usr/bin/docker-compose
        fi
        rm -rf "$tmp_dir"
        return 0
    fi

    rm -rf "$tmp_dir"
    return 1
}

# 安装docker-compose
install_docker_compose() {
    echo "正在安装 Docker Compose... (Installing Docker Compose...)"

    if docker_compose_available; then
        ensure_legacy_docker_compose_command || true
        echo "Docker Compose已经安装 (Docker Compose already installed)."
        return 0
    fi

    detect_package_manager
    update_package_list
    install_package docker-compose-plugin || install_package docker-compose || install_docker_compose_standalone || {
        warn "无法安装Docker Compose。请确认Docker官方源可用，或手动安装经校验的Docker Compose release。"
        return 1
    }

    if docker_compose_available; then
        ensure_legacy_docker_compose_command || true
        echo "Docker Compose已安装 (Docker Compose installed)."
        return 0
    fi

    warn "Docker Compose安装后仍不可用，请手动检查Docker版本和插件路径。"
    return 1
}


# 安装常用软件
install_utilities() {
    echo "安装常用工具... (Installing common utilities...)"
    detect_package_manager
    update_package_list
    install_package curl wget mtr screen net-tools zip unzip tar lsof || warn "部分常用工具安装失败。"

    echo "常用工具已安装 (Utilities installed)."
}


# 检测组件和设置是否正确
check_components() {
    echo "检查系统组件... (Checking system components...)"
    # 定义要检查的软件列表
    components=("docker" "curl" "wget" "mtr" "screen" "zip" "unzip" "tar" "lsof")

    # 遍历检查软件是否安装
    for component in "${components[@]}"; do
        if command -v "$component" &>/dev/null; then
            echo "$component 已正确安装 ($component is correctly installed)."
        else
            echo "警告：$component 未正确安装 (Warning: $component is not correctly installed)."
        fi
    done

    if docker_compose_available; then
        echo "docker compose 已正确安装 (Docker Compose is correctly installed)."
    else
        echo "警告：docker compose 未正确安装 (Warning: Docker Compose is not correctly installed)."
    fi

    # 检测当前时间是否正确
    current_time=$(date)
    echo "当前时间为：$current_time (Current time is: $current_time)"

    # 检测BBR是否正确启用
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$bbr_status" = "bbr" ]; then
        echo "BBR 已正确启用 (BBR is correctly enabled)."
    else
        echo "警告：BBR 未正确启用 (Warning: BBR is not correctly enabled)."
    fi
}

# 设置swap
setup_swap() {
    local swap_file="/swapfile"
    local mem_total_kb
    local mem_total_mb
    local mem_total_gb
    local available_disk_space_kb
    local available_disk_space_mb
    local available_disk_space_gb
    local recommended_swap_size_mb
    local max_swap_size_mb
    local swap_size_mb

    echo "设置交换空间... (Setting up swap space...)"

    if swapon --show | awk 'NR > 1 {print $1}' | grep -qx "$swap_file"; then
        echo "Swap已存在。当前的swap大小为： (Swap already exists. Current swap size is:)"
        swapon --show
        return 0
    fi

    if [ -f "$swap_file" ]; then
        if grep -Eq "^[[:space:]]*${swap_file}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab 2>/dev/null; then
            if swapon "$swap_file" >/dev/null 2>&1; then
                echo "已启用现有swap文件。当前的swap大小为： (Existing swap file enabled. Current swap size is:)"
                swapon --show
                return 0
            fi
        fi

        warn "$swap_file 已存在但不是可用swap文件，为避免覆盖数据，请手动处理后重试。"
        return 1
    fi

    # 获取系统内存大小 (单位为KB)
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_total_mb=$((mem_total_kb / 1024))
    mem_total_gb=$((mem_total_mb / 1024))

    # 获取根目录可用磁盘空间 (单位为KB)
    available_disk_space_kb=$(df / | tail -1 | awk '{print $4}')
    available_disk_space_mb=$((available_disk_space_kb / 1024))
    available_disk_space_gb=$((available_disk_space_mb / 1024))

    # 如果可用磁盘空间小于5GB，则设置swap为512MB
    if [ "$available_disk_space_gb" -lt 5 ]; then
        swap_size_mb=512
    else
        # 根据系统内存大小推荐swap大小
        if [ "$mem_total_gb" -le 1 ]; then
            recommended_swap_size_mb=1024
        elif [ "$mem_total_gb" -le 2 ]; then
            recommended_swap_size_mb=$((mem_total_mb * 2))
        elif [ "$mem_total_gb" -le 8 ]; then
            recommended_swap_size_mb=$mem_total_mb
        elif [ "$mem_total_gb" -le 64 ]; then
            recommended_swap_size_mb=4096
        else
            recommended_swap_size_mb=4096
        fi

        # 确保swap大小不超过可用磁盘空间的一半和8GB
        max_swap_size_mb=$((available_disk_space_mb / 2))
        if [ "$max_swap_size_mb" -gt $((8 * 1024)) ]; then
            max_swap_size_mb=$((8 * 1024))
        fi

        if [ "$recommended_swap_size_mb" -gt "$max_swap_size_mb" ]; then
            swap_size_mb=$max_swap_size_mb
        else
            swap_size_mb=$recommended_swap_size_mb
        fi
    fi

    if [ "$available_disk_space_mb" -lt $((swap_size_mb + 256)) ]; then
        warn "可用磁盘空间不足，跳过swap创建。"
        return 1
    fi

    echo "未检测到swap。创建一个swap文件，大小为 $((swap_size_mb / 1024))GB... (No swap detected. Creating a swap file with size $((swap_size_mb / 1024))GB...)"
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${swap_size_mb}M" "$swap_file" || dd if=/dev/zero of="$swap_file" bs=1M count="$swap_size_mb"
    else
        dd if=/dev/zero of="$swap_file" bs=1M count="$swap_size_mb"
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file"
    swapon "$swap_file"

    if ! grep -Eq "^[[:space:]]*${swap_file}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab 2>/dev/null; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
    fi

    echo "Swap创建成功。当前的swap大小为： (Swap created successfully. Current swap size is:)"
    swapon --show
}


# 提示用户批量安装所需组件
prompt_install_components() {
    local confirm

    echo "即将安装组件以增强系统功能：(The following components will be installed to enhance system functionality:)"
    echo "  - cloud-init: 初始化云实例。(Cloud instance initialization.)"
    echo "  - qemu-guest-agent: 宿主机通信。(Host communication.)"
    echo "  - cloud-utils: 磁盘管理工具。(Disk management tools.)"

    # 检查组件是否已安装
    if dpkg -l cloud-init qemu-guest-agent cloud-utils cloud-initramfs-growroot &>/dev/null || rpm -q cloud-init qemu-guest-agent cloud-utils cloud-utils-growpart &>/dev/null; then
        echo "组件已安装，跳过安装过程。(Components are already installed, skipping installation process.)"
        return
    fi

    detect_package_manager
    if [ "$PKG_MANAGER" = "apt" ]; then
        echo "  - cloud-initramfs-growroot: 调整文件系统大小。(Filesystem resizing.)"
        echo ""
        read -r -p "确认安装？(Confirm installation?) (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            update_package_list
            install_package cloud-init qemu-guest-agent cloud-initramfs-growroot cloud-utils
        else
            echo "组件安装已取消。(Component installation canceled.)"
        fi
    elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        echo "  - cloud-utils-growpart: 调整分区大小。(Partition resizing.)"
        echo ""
        read -r -p "确认安装？(Confirm installation?) (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            update_package_list
            install_package cloud-init qemu-guest-agent cloud-utils-growpart cloud-utils
        else
            echo "组件安装已取消。(Component installation canceled.)"
        fi
    else
        echo "操作系统不支持，需手动安装。(Unsupported OS, manual installation required.)"
    fi
}


# 主脚本逻辑
main() {
    check_root

    while true; do
        echo "请选择要执行的操作: (Please choose the operation to execute:)"
        echo "1) 执行完整功能 (Execute full setup)"
        echo "2) 只安装 Docker 和 Docker Compose (Install only Docker and Docker Compose)"
        echo "3) 退出 (Exit)"
        read -r -p "请输入选项 (1, 2 or 3): " choice

        case $choice in
            1)
                # 执行完整功能
                install_utilities
                adjust_timezone
                sync_system_time
                enable_bbr
                adjust_hostname
                install_docker
                install_docker_compose
                setup_swap
                prompt_install_components
                check_components
                echo "设置完成 (Setup complete)."
                bash -l
                break
                ;;
            2)
                # 只安装 Docker 和 Docker Compose
                install_docker
                install_docker_compose
                echo "设置完成 (Setup complete)."
                break
                ;;
            3)
                # 退出
                echo "退出 (Exit)."
                exit 0
                ;;
            *)
                echo "无效的选项，请输入 1, 2 或 3 (Invalid option, please enter 1, 2 or 3)"
                ;;
        esac
    done
}

# 执行主脚本逻辑
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
