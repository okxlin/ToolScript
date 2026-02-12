#!/bin/bash

# ==============================================================================
# 1Panel 运行模式双向迁移工具 
# 适用: Docker <-> 宿主机 (Systemd/OpenRC) 无损互转
# 理论支持: Debian / Ubuntu / CentOS / Alpine Linux
# 仅在 Debian 下进行测试
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
BASE_DIR=""            
PANEL_DIR=""           
DETECTED_VERSION=""    
DB_VERSION=""          
ARCH=""
CONTAINER_NAME=""
INIT_SYSTEM="systemd"

# ==================== 基础检查 ====================

check_root() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}错误: 请使用 root 权限运行${NC}"; exit 1; fi
}

check_sys() {
    if [ -f /etc/alpine-release ]; then
        INIT_SYSTEM="openrc"
        echo -e "${BLUE}检测到系统: Alpine Linux (OpenRC)${NC}"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
        echo -e "${BLUE}检测到系统: Standard Linux (Systemd)${NC}"
    else
        echo -e "${RED}不支持的初始化系统${NC}"; exit 1
    fi
}

check_dependencies() {
    local dependencies=("curl" "tar" "awk" "sed" "docker" "grep" "sqlite3")
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if ! command -v bash >/dev/null 2>&1; then apk add bash; fi
        if ! apk info | grep -q libc6-compat; then apk add libc6-compat; fi
        if ! apk info | grep -q gcompat; then apk add gcompat; fi
    fi
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "安装依赖: $dep ..."
            if command -v apt-get &>/dev/null; then apt-get update && apt-get install -y "$dep"
            elif command -v yum &>/dev/null; then yum install -y "$dep"
            elif command -v dnf &>/dev/null; then dnf install -y "$dep"
            elif command -v apk &>/dev/null; then apk add "$dep"
            else echo -e "${RED}无法安装 $dep${NC}"; exit 1; fi
        fi
    done
}

get_architecture() {
    local os_check=$(uname -a)
    if [[ $os_check =~ 'x86_64' ]]; then ARCH="amd64"
    elif [[ $os_check =~ 'arm64' ]] || [[ $os_check =~ 'aarch64' ]]; then ARCH="arm64"
    elif [[ $os_check =~ 'armv7l' ]]; then ARCH="armv7"
    elif [[ $os_check =~ 'ppc64le' ]]; then ARCH="ppc64le"
    elif [[ $os_check =~ 's390x' ]]; then ARCH="s390x"
    else echo -e "${RED}不支持的架构${NC}"; exit 1; fi
}

# ==================== Alpine 适配 ====================

install_fake_systemctl() {
    if [[ "$INIT_SYSTEM" != "openrc" ]]; then return; fi
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/systemctl << 'EOF'
#!/bin/sh
action=${1}
service=$(echo ${2} | sed 's/\.\(service\|socket\)//g')
case "${action}" in
    start) rc-service "${service}" start ;;
    stop) rc-service "${service}" stop ;;
    restart) rc-service "${service}" restart ;;
    reload) rc-service "${service}" reload || rc-service "${service}" restart ;;
    daemon-reload) return 0 ;;
    status) rc-service "${service}" status ;;
    enable) rc-update add "${service}" ;;
    disable) rc-update del "${service}" ;;
    is-active) if rc-service "${service}" status | grep -q "started"; then echo "active"; else echo "inactive"; exit 1; fi ;;
    *) echo "Unsupported: ${action}"; exit 1 ;;
esac
EOF
    chmod +x /usr/local/bin/systemctl
}

generate_openrc_services() {
    for svc in core agent; do
        cat > /etc/init.d/1panel-$svc << EOF
#!/sbin/openrc-run
directory="${PANEL_DIR}"
command="/usr/local/bin/1panel-$svc"
command_background=true
description="1Panel $svc Service"
rc_ulimit="-n 50000"
rc_cgroup_cleanup="yes"
required_dirs="\${directory}"
required_files="\${command}"
pidfile="/var/run/\${RC_SVCNAME}.pid"
depend() {
    need networking
    use logger dns
    after firewall syslog
}
EOF
        chmod +x /etc/init.d/1panel-$svc
    done
}

svc_stop() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service $1 stop >/dev/null 2>&1
        rc-update del $1 >/dev/null 2>&1
    else
        systemctl stop $1 >/dev/null 2>&1
        systemctl disable $1 >/dev/null 2>&1
    fi
}

svc_start() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add $1; rc-service $1 start
    else
        systemctl enable $1; systemctl start $1
    fi
}

svc_check() {
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service $1 status | grep -q "started"
    else
        systemctl is-active --quiet $1
    fi
}

# ==================== 核心逻辑 ====================

prevent_host_duplicate() {
    local running=false
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if rc-service 1panel-core status 2>/dev/null | grep -q "started"; then running=true; fi
    else
        if systemctl is-active --quiet 1panel || systemctl is-active --quiet 1panel-core; then running=true; fi
    fi

    if [ "$running" = true ]; then
        echo -e "${RED}❌ 错误: 宿主机版 1Panel 已经在运行中！${NC}"
        echo -e "${YELLOW}提示: 您无需迁移。如果需要重装，请先停止服务或卸载。${NC}"; exit 1
    fi
    
    if [ -f "/usr/local/bin/1panel-core" ]; then
        echo -e "${RED}❌ 错误: 检测到 '/usr/local/bin/1panel-core' 残留文件。${NC}"
        echo -e "${YELLOW}请先运行卸载命令，或者手动删除残留文件后再试。${NC}"; exit 1
    fi
}

prevent_docker_duplicate() {
    if docker ps --format '{{.Names}}' | grep -iq "1panel"; then
        echo -e "${RED}❌ 错误: 1Panel 容器已存在！请勿重复迁移。${NC}"; exit 1
    fi
}

clean_db_duplicates() {
    echo -e "${BLUE}>>> [1/3] 清洗数据库...${NC}"
    local db_file=""
    [[ "$DETECTED_VERSION" == "v2" ]] && db_file="${PANEL_DIR}/db/core.db" || db_file="${PANEL_DIR}/db/1Panel.db"
    if [[ -f "$db_file" ]]; then
        sqlite3 "$db_file" "DELETE FROM settings WHERE rowid NOT IN (SELECT MAX(rowid) FROM settings GROUP BY key);"
    fi
}

sync_db_to_1pctl() {
    echo -e "${BLUE}>>> [2/3] 同步配置到 1pctl...${NC}"
    local db_file="${PANEL_DIR}/db/core.db"
    [[ "$DETECTED_VERSION" == "v1" ]] && db_file="${PANEL_DIR}/db/1Panel.db"

    if [[ -f "$db_file" ]]; then
        local real_port=$(sqlite3 "$db_file" "SELECT value FROM settings WHERE key='SystemPort' ORDER BY rowid DESC LIMIT 1;")
        local real_entrance=$(sqlite3 "$db_file" "SELECT value FROM settings WHERE key='SecurityEntrance' ORDER BY rowid DESC LIMIT 1;")
        local real_user=$(sqlite3 "$db_file" "SELECT value FROM settings WHERE key='UserName' ORDER BY rowid DESC LIMIT 1;")
        [ -z "$real_user" ] && real_user=$(sqlite3 "$db_file" "SELECT value FROM settings WHERE key='SystemUser' ORDER BY rowid DESC LIMIT 1;")

        [ -z "$real_port" ] && real_port="10086"
        [ -z "$real_entrance" ] && real_entrance="entrance"
        [ -z "$real_user" ] && real_user="1panel"

        local ctl_file="/usr/local/bin/1pctl"
        if [[ -f "$ctl_file" ]]; then
            sed -i "s#ORIGINAL_PORT=.*#ORIGINAL_PORT=${real_port}#g" "$ctl_file"
            sed -i "s#ORIGINAL_ENTRANCE=.*#ORIGINAL_ENTRANCE=${real_entrance}#g" "$ctl_file"
            sed -i "s#ORIGINAL_USERNAME=.*#ORIGINAL_USERNAME=${real_user}#g" "$ctl_file"
            sed -i "s#ORIGINAL_PASSWORD=.*#ORIGINAL_PASSWORD=**********#g" "$ctl_file"
            sed -i "s#BASE_DIR=.*#BASE_DIR=${BASE_DIR}#g" "$ctl_file"
            if grep -q "^CHANGE_USER_INFO=" "$ctl_file"; then
                sed -i 's/^CHANGE_USER_INFO=.*/CHANGE_USER_INFO=use_existing/' "$ctl_file"
            else
                sed -i '/^LANGUAGE=.*/a CHANGE_USER_INFO=use_existing' "$ctl_file"
            fi
        fi
    fi
}

pre_fix_listening_ip() {
    echo -e "${BLUE}>>> [3/3] 修正监听 IP...${NC}"
    if [[ -f "/usr/local/bin/1panel" ]]; then
        /usr/local/bin/1panel listen-ip ipv4 >/dev/null 2>&1
    fi
}

confirm_path_and_version() {
    echo -e "${BLUE}>>> 步骤 1/4: 确认数据目录${NC}"
    local default_base="/opt"
    while true; do
        read -p "请输入 1Panel 数据目录 (默认: /opt): " input_path
        local check_path="${input_path:-"$default_base"}"
        check_path=${check_path%/}
        [[ "$check_path" == *"/1panel" ]] && check_path=$(dirname "$check_path")
        
        local target_panel_dir="${check_path}/1panel"
        local v2_db="${target_panel_dir}/db/core.db"
        local v1_db="${target_panel_dir}/db/1Panel.db"

        if [[ -f "$v2_db" ]]; then
            DETECTED_VERSION="v2"; BASE_DIR="${check_path}"; PANEL_DIR="${target_panel_dir}"
            echo -e "${GREEN}✅ 发现 V2 版本${NC}"; break
        elif [[ -f "$v1_db" ]]; then
            DETECTED_VERSION="v1"; BASE_DIR="${check_path}"; PANEL_DIR="${target_panel_dir}"
            echo -e "${GREEN}✅ 发现 V1 版本${NC}"; break
        else
            echo -e "${RED}未找到数据库文件。${NC}"
        fi
    done
}

confirm_container_name() {
    echo -e "${BLUE}>>> 步骤 2/4: 确认容器名称${NC}"
    local detected_name=$(docker ps -a --format '{{.Names}}' | grep "1panel" | head -n 1)
    local default_name="${detected_name:-"1panel"}"
    read -p "请输入旧容器名 (默认: ${default_name}): " input_name
    CONTAINER_NAME="${input_name:-"$default_name"}"
}

read_db_version() {
    DB_VERSION=""
    local db_file=""
    [[ "$DETECTED_VERSION" == "v2" ]] && db_file="${PANEL_DIR}/db/core.db" || db_file="${PANEL_DIR}/db/1Panel.db"
    if [[ -f "$db_file" ]]; then
        DB_VERSION=$(sqlite3 -readonly "$db_file" "SELECT value FROM settings WHERE key = 'SystemVersion' LIMIT 1;" 2>/dev/null | head -n 1 | tr -d '[:space:]')
        if [[ -n "$DB_VERSION" ]]; then echo -e "${GREEN}✅ 当前版本号: ${DB_VERSION}${NC}"; else DB_VERSION=""; fi
    fi
}

clean_db_locks() { rm -f "${PANEL_DIR}/db/"*.wal "${PANEL_DIR}/db/"*.shm; }

backup_data() {
    local max_keep=2
    local backups=()
    mapfile -t backups < <(find "${BASE_DIR}" -maxdepth 1 -name "migrate_backup_*" -type d 2>/dev/null | sort)
    if [[ ${#backups[@]} -ge $max_keep ]]; then
        local remove_count=$((${#backups[@]} - max_keep))
        [[ $remove_count -gt 0 ]] && for ((i=0; i<remove_count; i++)); do rm -rf "${backups[$i]}"; done
    fi
    local backup_dir="${BASE_DIR}/migrate_backup_$(date +%Y%m%d%H%M%S)"
    echo -e "${BLUE}>>> 备份数据至: ${backup_dir}${NC}"
    mkdir -p "${backup_dir}"
    cp -r "${PANEL_DIR}" "${backup_dir}/"
}

cleanup_host_legacy() {
    svc_stop 1panel-core; svc_stop 1panel-agent; svc_stop 1panel
    rm -f /etc/systemd/system/1panel*; rm -f /etc/init.d/1panel*
    [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload
    rm -rf /usr/local/bin/1panel* /usr/local/bin/1pctl* /usr/bin/1panel* /usr/bin/1pctl*
}

# ==================== 迁移 A: Docker -> 宿主机 ====================

migrate_to_host() {
    prevent_host_duplicate
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW}🚀 迁移: Docker -> 宿主机 ($INIT_SYSTEM)${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    
    confirm_path_and_version
    confirm_container_name
    read_db_version
    get_architecture
    
    local tmp_dir=~/1panel-install-temp
    rm -rf "${tmp_dir}" && mkdir -p "${tmp_dir}" && cd "${tmp_dir}" || exit

    local package_name=""
    local download_url=""
    
    if [[ "$DETECTED_VERSION" == "v2" ]]; then
        local ver="${DB_VERSION:-$(curl -s https://resource.fit2cloud.com/1panel/package/v2/stable/latest)}"
        package_name="1panel-${ver}-linux-${ARCH}.tar.gz"
        download_url="https://resource.fit2cloud.com/1panel/package/v2/stable/${ver}/release/${package_name}"
    else
        echo "请选择 V1 下载源:"
        echo "1. 国内版 (China/CN) [默认]"
        echo "2. 国际版 (Global)"
        read -p "选择 [默认: 1]: " v1_source
        v1_source=${v1_source:-1}
        local ver="${DB_VERSION:-$(curl -s https://resource.fit2cloud.com/1panel/package/stable/latest)}"
        package_name="1panel-${ver}-linux-${ARCH}.tar.gz"
        if [[ "$v1_source" == "2" ]]; then
            download_url="https://resource.1panel.pro/stable/${ver}/release/${package_name}"
        else
            download_url="https://resource.fit2cloud.com/1panel/package/stable/${ver}/release/${package_name}"
        fi
    fi

    echo "下载: ${download_url}"
    curl -fLOk "${download_url}"
    if [ $? -ne 0 ] || [ ! -f "${package_name}" ]; then echo -e "${RED}下载失败${NC}"; exit 1; fi
    if [ $(wc -c < "${package_name}") -lt 1024000 ]; then echo -e "${RED}文件校验失败${NC}"; exit 1; fi
    tar zxvf "${package_name}" --strip-components 1 > /dev/null

    echo "停止旧容器..."
    docker stop "${CONTAINER_NAME}" &>/dev/null; sleep 3; docker rm "${CONTAINER_NAME}" &>/dev/null
    clean_db_locks; backup_data 

    echo "部署文件..."
    cp 1pctl /usr/local/bin/ && chmod +x /usr/local/bin/1pctl
    [[ "$INIT_SYSTEM" == "openrc" ]] && install_fake_systemctl

    if [[ "$DETECTED_VERSION" == "v2" ]]; then
        cp 1panel-core /usr/local/bin/ && chmod +x /usr/local/bin/1panel-core
        cp 1panel-agent /usr/local/bin/ && chmod +x /usr/local/bin/1panel-agent
        rm -f /usr/bin/1panel /usr/bin/1pctl
        ln -sf /usr/local/bin/1panel-core /usr/bin/1panel
        ln -sf /usr/local/bin/1panel-core /usr/bin/1panel-core
        ln -sf /usr/local/bin/1panel-agent /usr/bin/1panel-agent
        ln -sf /usr/local/bin/1pctl /usr/bin/1pctl
        mkdir -p "${PANEL_DIR}/geo" "${PANEL_DIR}/resource"
        [ -f "GeoIP.mmdb" ] && cp GeoIP.mmdb "${PANEL_DIR}/geo/"
        [ -d "initscript" ] && cp -r initscript "${PANEL_DIR}/resource/"
        [ -d "lang" ] && cp -r lang /usr/local/bin/

        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            sed -i "s#/opt/1panel#${PANEL_DIR}#g" initscript/1panel-core.service
            sed -i "s#/opt/1panel#${PANEL_DIR}#g" initscript/1panel-agent.service
            cp initscript/1panel-core.service /etc/systemd/system/
            cp initscript/1panel-agent.service /etc/systemd/system/
            systemctl daemon-reload
        else
            generate_openrc_services
        fi
        SERVICES="1panel-core 1panel-agent"
    else
        cp 1panel /usr/local/bin/ && chmod +x /usr/local/bin/1panel
        ln -sf /usr/local/bin/1panel /usr/bin/1panel
        ln -sf /usr/local/bin/1pctl /usr/bin/1pctl
        [ -f "GeoIP.mmdb" ] && mkdir -p "${PANEL_DIR}/geo/" && cp GeoIP.mmdb "${PANEL_DIR}/geo/"
        if [[ -f "initscript/1panel.service" ]] && [[ "$INIT_SYSTEM" == "systemd" ]]; then
             sed -i "s#/opt/1panel#${PANEL_DIR}#g" initscript/1panel.service
             cp initscript/1panel.service /etc/systemd/system/
             systemctl daemon-reload
        elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
             generate_openrc_services; mv /etc/init.d/1panel-core /etc/init.d/1panel
             sed -i 's/1panel-core/1panel/g' /etc/init.d/1panel
        fi
        SERVICES="1panel"
    fi

    echo "修复环境..."
    chown -R root:root "${PANEL_DIR}"
    chmod -R 755 "${PANEL_DIR}"
    clean_db_duplicates
    sync_db_to_1pctl
    pre_fix_listening_ip

    echo "启动服务..."
    for svc in $SERVICES; do svc_start $svc; done
    sleep 5
    
    check_target="1panel-core"
    [[ "$DETECTED_VERSION" == "v1" ]] && check_target="1panel"

    if svc_check $check_target; then
         echo -e "${GREEN}✅ 迁移成功！${NC}"
         echo "------------------------------------------------"
         echo -e "${BLUE}提示: 使用 '1pctl user-info' 查看面板信息。${NC}"
         echo -e "${BLUE}提示: 假如登录异常，可以使用 '1pctl update username' 重置面板用户名。${NC}"
         echo -e "${BLUE}提示: 假如登录异常，可以使用 '1pctl update password' 重置面板密码。${NC}"
         echo -e "${BLUE}提示: 假如登录异常，可以使用 '1pctl update port' 重置面板端口。${NC}"
         echo "------------------------------------------------"
         echo -e "${YELLOW}⚠️ 为了防止旧密码被覆盖或不匹配，推荐立即重置密码${NC}"
         read -p "是否重置密码？[Y/n] (默认: Y): " reset_now
         reset_now=${reset_now:-Y}
         if [[ "$reset_now" =~ ^[yY]$ ]]; then
             echo -e "${BLUE}>>> 正在调用 1Panel 命令行工具... (请按提示输入新密码)${NC}"
             /usr/local/bin/1pctl update password
             echo -e "${GREEN}✅ 密码重置成功！${NC}"
             /usr/local/bin/1pctl user-info
         fi
    else
         echo -e "${RED}❌ 启动失败。${NC}"
         if [[ "$INIT_SYSTEM" == "systemd" ]]; then journalctl -u $check_target --no-pager -n 20; fi
         echo -e "${YELLOW}💡 建议: 如无法修复，请迁移回 Docker 模式并在配置时启用 [重置模式]。${NC}"
    fi
    cd / && rm -rf "$tmp_dir"
}

# ==================== 迁移 B: 宿主机 -> Docker ====================

migrate_to_docker() {
    prevent_docker_duplicate
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW}🚀 迁移: 宿主机 -> Docker${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW}⚠️  注意: 仅 moelin/1panel 镜像支持自动配置和重置功能。${NC}"

    confirm_path_and_version

    local detected_tag=""
    if command -v 1pctl &>/dev/null; then
        local raw_ver=$(1pctl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1)
        [ -n "$raw_ver" ] && detected_tag="moelin/1panel:${raw_ver}"
    fi
    
    echo "停止宿主机服务..."
    svc_stop 1panel-core; svc_stop 1panel-agent; svc_stop 1panel
    sleep 2
    clean_db_duplicates; clean_db_locks; backup_data

    echo -e "${BLUE}>>> 步骤 3/4: 配置容器${NC}"
    local default_img="moelin/1panel:latest"
    [ -n "$detected_tag" ] && default_img="$detected_tag"
    [ "$DETECTED_VERSION" == "v1" ] && default_img="moelin/1panel:v1"
    
    read -p "请输入镜像标签 (默认: ${default_img}): " img_tag
    img_tag="${img_tag:-"$default_img"}"

    local default_name="1panel"
    [ "$DETECTED_VERSION" == "v2" ] && default_name="1panel-v2"
    read -p "请输入容器名称 (默认: ${default_name}): " target_container_name
    target_container_name="${target_container_name:-"$default_name"}"

    local env_args=()
    local use_reset=false
    echo "------------------------------------------------"
    echo -e "${YELLOW}是否修改端口/密码？(将启用 RESET 模式覆盖数据库)${NC}"
    echo "------------------------------------------------"
    read -p "修改配置？[y/N] (默认: N): " config_env
    
    if [[ "$config_env" =~ ^[yY]$ ]]; then
        use_reset=true
        env_args+=(-e "RESET=true")
        
        # 端口
        read -p "端口 PORT (留空使用 10086): " env_port
        if [ -n "$env_port" ]; then
            env_args+=(-e "PORT=$env_port")
            echo -e "${GREEN}  -> 已设置端口: $env_port${NC}"
        else
            echo -e "${YELLOW}  -> 将使用默认端口: 10086${NC}"
        fi

        # 用户
        read -p "用户 USERNAME (留空使用 1panel): " env_user
        if [ -n "$env_user" ]; then
            env_args+=(-e "USERNAME=$env_user")
            echo -e "${GREEN}  -> 已设置用户: $env_user${NC}"
        else
            echo -e "${YELLOW}  -> 将使用默认用户: 1panel${NC}"
        fi

        # 密码 (安全警告)
        read -p "密码 PASSWORD (留空生成随机密码): " env_pass
        if [ -n "$env_pass" ]; then
            env_args+=(-e "PASSWORD=$env_pass")
            echo -e "${GREEN}  -> 已设置密码: (已隐藏)${NC}"
        else
            echo -e "${RED}  -> ⚠️  未设置密码，将自动生成随机密码！(请在启动后查看日志)${NC}"
        fi

        # 入口
        read -p "入口 ENTRANCE (留空使用 entrance): " env_ent
        if [ -n "$env_ent" ]; then
            env_args+=(-e "ENTRANCE=$env_ent")
            echo -e "${GREEN}  -> 已设置入口: $env_ent${NC}"
        else
            echo -e "${YELLOW}  -> 将使用默认入口: entrance${NC}"
        fi
    fi

    echo -e "${BLUE}>>> 步骤 4/4: 启动容器${NC}"
    docker pull "${img_tag}"
    docker run -d --name "${target_container_name}" --restart always --network host \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /var/lib/docker/volumes:/var/lib/docker/volumes \
        -v /etc/localtime:/etc/localtime:ro \
        -v "${BASE_DIR}:${BASE_DIR}" \
        -e TZ=Asia/Shanghai -e BASE_DIR="${BASE_DIR}" "${env_args[@]}" "${img_tag}"

    if [ $? -eq 0 ]; then
        if [ "$use_reset" = true ]; then
            echo -e "${YELLOW}⏳ 检测到重置模式，正在等待容器初始化配置 (约 10 秒)...${NC}"
            sleep 10
        fi
        
        echo -e "${GREEN}✅ 容器启动成功: ${target_container_name}${NC}"
        cleanup_host_legacy
        
        # === 安全警告 ===
        echo -e "\n${RED}================== [重要安全提示] ==================${NC}"
        if [[ "$config_env" =~ ^[yY]$ ]] && [ -z "$env_pass" ]; then
            echo -e "${RED}⚠️  注意：您启用了重置模式但未设置密码。${NC}"
            echo -e "${RED}    容器已自动生成一个随机密码并覆盖了旧密码！${NC}"
            echo -e "请立即查看日志获取密码："
            echo -e "${GREEN}docker logs ${target_container_name} 2>&1 | grep '随机密码'${NC}"
            echo -e "${BLUE}或者查看完整日志: docker logs ${target_container_name}${NC}"
        else
            echo -e "${BLUE}提示：管理面板请使用: docker exec -it ${target_container_name} 1pctl user-info${NC}"
            echo -e "${RED}如果密码参数未自定义，将强制生成一个随机密码并覆盖您的旧密码！${NC}"
            echo -e "${RED}请立即执行以下命令查看日志中的随机密码：${NC}"
            echo -e "${GREEN}docker logs ${target_container_name} 2>&1 | grep '随机密码'${NC}"
        fi
        echo -e "${RED}====================================================${NC}\n"
    else
        echo -e "${RED}❌ 启动失败。${NC}"
    fi
}

# ==================== 主入口 ====================

function main(){
    clear
    echo "################################################"
    echo "#              1Panel 双向迁移工具             #"
    echo "################################################"
    check_root
    check_sys
    check_dependencies
    
    echo "请选择操作:"
    echo "1. 迁移到 宿主机模式 ($INIT_SYSTEM)"
    echo "2. 迁移到 Docker 模式"
    echo "0. 退出"
    
    read -p "请输入选项 [默认: 1]: " choice
    choice=${choice:-1}
    case "$choice" in
        1) migrate_to_host ;;
        2) migrate_to_docker ;;
        0) exit 0 ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

main
