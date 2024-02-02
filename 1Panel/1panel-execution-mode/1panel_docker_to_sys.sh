#!/bin/bash

# 函数：检查是否具有 root 或 sudo 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "请使用 root 或 sudo 权限运行此脚本"
        exit 1
    fi
}

# 函数：检查 1Panel 是否已经安装
check_1panel_installed() {
    if command -v 1panel &>/dev/null && command -v 1pctl &>/dev/null; then
        echo "1Panel 已经安装在宿主机上，跳过安装步骤。"
        exit 0
    fi

    echo "1Panel 尚未在宿主机上安装，继续检查数据库文件。"
    
    read -p "请输入 1Panel 数据所在的顶层目录路径（默认为 /opt）: " db_directory
    db_directory=${db_directory:-"/opt"}
    local db_file="$db_directory/1panel/db/1Panel.db"
    
    if [[ ! -f "$db_file" ]]; then
        echo "1Panel 未安装过，不需要执行迁移"
        exit 1
    else
        # 备份数据库文件
        local backup_dir="/opt/1panel-bak/db"
        mkdir -p "$backup_dir"
        cp "$db_file" "$backup_dir/1Panel.db"
        echo "已经备份旧数据库文件到 $backup_dir/1Panel.db"
    fi
}

# 函数：检查并安装缺失的组件
check_and_install_dependencies() {
    local dependencies=("curl" "tar" "awk" "ping" "bc" "docker")
    local missing_dependencies=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_dependencies+=("$dep")
        fi
    done

    if [[ ${#missing_dependencies[@]} -gt 0 ]]; then
        echo "缺少以下组件，将尝试安装："
        printf '%s\n' "${missing_dependencies[@]}"
        if command -v apt-get &>/dev/null; then
            apt-get update && apt-get install -y "${missing_dependencies[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y "${missing_dependencies[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y "${missing_dependencies[@]}"
        else
            echo "无法确定包管理器，无法自动安装组件。请手动安装以下组件："
            printf '%s\n' "${missing_dependencies[@]}"
            exit 1
        fi
    fi
}

# 函数：创建目录
create_dir() {
    PANEL_DIR=~/1panel-install-dir
    mkdir -p ${PANEL_DIR}
    cd ${PANEL_DIR}
}

# 函数：下载 1Panel
download_1panel() {
    local osCheck=$(uname -a)
    local INSTALL_MODE=${1:-"stable"}
    
    if [[ $osCheck =~ 'x86_64' ]]; then
        local architecture="amd64"
    elif [[ $osCheck =~ 'arm64' ]] || [[ $osCheck =~ 'aarch64' ]]; then
        local architecture="arm64"
    elif [[ $osCheck =~ 'armv7l' ]]; then
        local architecture="armv7"
    elif [[ $osCheck =~ 'ppc64le' ]]; then
        local architecture="ppc64le"
    elif [[ $osCheck =~ 's390x' ]]; then
        local architecture="s390x"
    else
        echo "暂不支持的系统架构，请参阅官方文档，选择受支持的系统。"
        return 1
    fi

    if [[ ${INSTALL_MODE} != "dev" && ${INSTALL_MODE} != "stable" ]]; then
        echo "请输入正确的安装模式（dev or stable）"
        return 1
    fi

    local VERSION=$(curl -s https://resource.fit2cloud.com/1panel/package/${INSTALL_MODE}/latest)
    local FIT2CLOUD_URL="https://resource.fit2cloud.com/1panel/package/${INSTALL_MODE}/${VERSION}/release/checksums.txt"
    local GITHUB_URL="https://github.com/wanghe-fit2cloud/1Panel/releases/download/${VERSION}/checksums.txt"

    if [[ "x${VERSION}" == "x" ]]; then
        echo "获取最新版本失败，请稍候重试"
        return 1
    fi

    local package_file_name="1panel-${VERSION}-linux-${architecture}.tar.gz"

    local fit2cloud_latency=$(ping -c 3 -q -w 2 resource.fit2cloud.com | awk -F'/' 'END{print $5}')
    local github_latency=$(ping -c 3 -q -w 2 github.com | awk -F'/' 'END{print $5}')

    local package_download_url=""
    if [[ $(echo "$fit2cloud_latency < $github_latency" | bc) -eq 1 ]]; then
        package_download_url="https://resource.fit2cloud.com/1panel/package/${INSTALL_MODE}/${VERSION}/release/${package_file_name}"
    else
        package_download_url="https://github.com/wanghe-fit2cloud/1Panel/releases/download/${VERSION}/${package_file_name}"
    fi

    echo "开始下载 1Panel ${VERSION} 版本在线安装包"
    echo "选用下载源："
    if [[ $(echo "$fit2cloud_latency < $github_latency" | bc) -eq 1 ]]; then
        echo "resource.fit2cloud.com"
    else
        echo "github.com"
    fi
    echo "安装包下载地址： ${package_download_url}"

    curl -LOk -o ${package_file_name} ${package_download_url}
    if [ ! -f ${package_file_name} ]; then
        echo "下载安装包失败，请稍候重试。"
        rm -f ${package_file_name}
        return 1
    fi
    cd ${PANEL_DIR}
    tar zxvf ${package_file_name} --strip-components 1
    if [ $? != 0 ]; then
        echo "解压安装包失败，请稍候重试。"
        rm -f ${package_file_name}
        return 1
    fi
}

# 函数：安装 1Panel
install_1panel() {
    cp ${PANEL_DIR}/1panel /usr/local/bin && chmod +x /usr/local/bin/1panel
    cp ${PANEL_DIR}/1pctl /usr/local/bin && chmod +x /usr/local/bin/1pctl
    cp ${PANEL_DIR}/1panel.service /etc/systemd/system
    if [[ ! -f /usr/bin/1panel ]]; then
        ln -s /usr/local/bin/1panel /usr/bin/1panel >/dev/null 2>&1
    fi
    if [[ ! -f /usr/bin/1pctl ]]; then
        ln -s /usr/local/bin/1pctl /usr/bin/1pctl >/dev/null 2>&1
    fi
    systemctl daemon-reload
    systemctl enable 1panel
    systemctl start 1panel
    sleep 2 # 等待服务启动
    if systemctl status 1panel >/dev/null 2>&1; then
        echo "1panel 服务已成功启动。"
    else
        echo "1panel 服务启动失败。"
    fi
}

# 函数：移除容器
remove_container() {
    local container_exists=false

    while [[ $container_exists == false ]]; do
        # 列出已创建容器及其对应镜像
        echo "已创建的 Docker 容器及其对应镜像："
        docker ps -a --format "table {{.Names}}\t{{.Image}}"

        read -p "请输入要移除的 1Panel 容器名（默认为 '1panel'，输入 'removed' 则表示已经手动移除过）: " container_name
        container_name=${container_name:-"1panel"}

        if [[ $container_name != "removed" ]]; then
            if docker inspect "$container_name" &>/dev/null; then
                container_exists=true
            else
                echo "容器 $container_name 不存在。请重新输入。"
            fi
        fi
    done

    if [[ $container_name != "removed" ]]; then
        docker stop "$container_name" &>/dev/null
        docker rm "$container_name" &>/dev/null
        echo "容器 $container_name 已停止并移除。"
    fi
}


# 函数：返回用户根目录并删除临时文件
cleanup_and_notify() {
    local user_home=$(eval echo ~$USER)
    rm -rf ${PANEL_DIR}
    echo "1Panel 已经由 Docker 运行方式切换到宿主机直接运行"
}

# 调用函数
function main(){
    check_root
    check_1panel_installed
    check_and_install_dependencies
    create_dir
    download_1panel
    remove_container
    install_1panel
    cleanup_and_notify
}
main
