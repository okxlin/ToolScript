#!/bin/bash

# 检查是否以root身份运行脚本
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请以root身份或使用sudo运行此脚本 (Please run this script as root or using sudo)"
        exit 1
    fi
}

# 同步系统时间
sync_system_time() {
    # 输出提示消息：时间同步前 (Synchronizing system time...)
    echo "开始执行时间同步操作... (Starting time synchronization...)"

    # 检查是否安装了curl，如果没有，使用包管理器安装它
    if ! command -v curl &>/dev/null; then
        echo "未找到curl。将尝试安装... (curl not found. Attempting to install...)"
        $curl_install_command
    fi

    # 更新包管理器的软件包列表
    echo "正在更新包管理器的软件包列表... (Updating package manager's package list...)"
    $update_command

    # 安装tzdata包，用于设置系统时区
    echo "正在安装tzdata包... (Installing tzdata package...)"
    $install_command

    # 从百度网站获取GMT时间，并提取日期和时间部分
    GMT_TIME=$(curl -I 'https://www.baidu.com/' 2>/dev/null | grep -i '^date:' | awk -F ' ' '{print $3 " " $4 " " $5 " " $6}')

    # 将GMT时间转换为时间戳
    GMT_TIMESTAMP=$(date -d "$GMT_TIME" '+%s')

    # 计算CST（中国标准时间）时间戳（GMT时间戳 + 8小时的秒数）
    CST_TIMESTAMP=$((GMT_TIMESTAMP + 8*3600))

    # 将CST时间戳转换为CST时间并设置为系统时间
    TZ='Asia/Shanghai' date -s "@$CST_TIMESTAMP"

    # 获取当前时间
    current_time=$(date)

    # 输出提示消息：时间同步完成和当前时间 (Time synchronization completed. Current time:)
    echo "时间同步操作完成。当前时间：$current_time (Time synchronization completed. Current time: $current_time)"
}

# 内核启动bbr设置
enable_bbr() {
    kernel_version=$(uname -r | cut -d. -f1)
    if [ "$kernel_version" -gt 4 ] || ([ "$kernel_version" -eq 4 ] && [ "$(uname -r | cut -d. -f2)" -ge 9 ]); then
        echo "启用 BBR... (Enabling BBR...)"
        cat > /etc/sysctl.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl -p
        echo "BBR 已启用 (BBR enabled)."
    else
        echo "内核版本低于 4.9。请使用脚本启用 BBR... (Kernel version is less than 4.9. Enabling BBR using script...)"
        wget --no-check-certificate -O /opt/bbr.sh https://github.com/teddysun/across/raw/master/bbr.sh && chmod 755 /opt/bbr.sh && /opt/bbr.sh
    fi
}

# 调整时区到上海
adjust_timezone() {
    timedatectl set-timezone Asia/Shanghai
    echo "时区已设置为Asia/Shanghai (Timezone set to Asia/Shanghai)."
}

# 调整主机名
adjust_hostname() {
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

    hostnamectl set-hostname $new_hostname
    echo "主机名已设置为 $new_hostname (Hostname set to $new_hostname)."
}


# 安装docker
install_docker() {
    if command -v yum &>/dev/null; then
        yum install -y yum-utils device-mapper-persistent-data lvm2
        if [ $? -eq 0 ]; then
            echo "必需组件安装成功 (Necessary components installed successfully)."
            
            # 测试官方源的延迟
            official_source="download.docker.com"
            official_delay=$(curl -o /dev/null -s -w "%{time_total}\n" https://$official_source)

            # 测试 mirrors.nju.edu.cn/docker-ce 的延迟
            mirror_source="mirrors.nju.edu.cn/docker-ce"
            mirror_delay=$(curl -o /dev/null -s -w "%{time_total}\n" https://$mirror_source)
            
            echo "官方源延迟为: $official_delay 秒 (Official source latency: $official_delay seconds)"
            echo "镜像源延迟为: $mirror_delay 秒 (Mirror source latency: $mirror_delay seconds)"
            
            # 比较延迟并选择延迟较低的源
            if (( $(echo "$official_delay < $mirror_delay" | bc -l) )); then
                echo "官方源延迟更低，选择官方源。(Official source has lower latency, selecting official source.)"
                chosen_source=$official_source
            else
                echo "镜像源延迟更低，选择镜像源。(Mirror source has lower latency, selecting mirror source.)"
                chosen_source=$mirror_source
            fi
            
            yum-config-manager --add-repo https://$chosen_source/linux/centos/docker-ce.repo
            if [ $? -eq 0 ]; then
                echo "Docker源添加成功 (Docker repository added successfully)."
                yum install -y docker-ce docker-ce-cli containerd.io
                if [ $? -eq 0 ]; then
                    echo "Docker安装成功 (Docker installed successfully)."
                    
                    # 启动 Docker 服务
                    systemctl start docker
                    
                    if [ $? -eq 0 ]; then
                        echo "Docker服务已启动 (Docker service started)."
                        
                        # 设置 Docker 服务在系统启动时自动启动
                        systemctl enable docker
                        
                        if [ $? -eq 0 ]; then
                            echo "Docker已设置为开机自启 (Docker set to start on boot)."
                        else
                            echo "无法设置Docker为开机自启 (Failed to set Docker to start on boot)."
                        fi
                    else
                        echo "无法启动Docker服务 (Failed to start Docker service)."
                    fi
                else
                    echo "Docker安装失败 (Failed to install Docker)."
                fi
            else
                echo "无法添加Docker源 (Failed to add Docker repository)."
            fi
        else
            echo "必需组件安装失败 (Failed to install necessary components)."
        fi
    elif command -v apt-get &>/dev/null; then
        # 检查Docker是否已安装
        if command -v docker &>/dev/null; then
            echo "Docker已经安装 (Docker is already installed)."
        else
            # 使用官方源尝试安装Docker
            if timeout 5 bash -c "curl -fsSL https://get.docker.com > /dev/null"; then
                curl -fsSL https://get.docker.com -o get-docker.sh
                sh get-docker.sh
                if [ $? -eq 0 ]; then
                    echo "Docker安装成功 (Docker installed successfully)."
                else
                    # 使用阿里云镜像安装Docker
                    curl -fsSL https://get.docker.com -o get-docker.sh
                    sh get-docker.sh --mirror Aliyun
                    if [ $? -eq 0 ]; then
                        echo "Docker安装成功 (Docker installed successfully)."
                    else
                        echo "Docker安装失败 (Failed to install Docker)."
                    fi
                fi
                rm get-docker.sh
            else
                echo "无法连接官方源，尝试使用阿里云镜像安装Docker (Failed to connect to official source, trying installation using Aliyun mirror)."
                curl -fsSL https://get.docker.com -o get-docker.sh
                sh get-docker.sh --mirror Aliyun
                if [ $? -eq 0 ]; then
                    echo "Docker安装成功 (Docker installed successfully)."
                else
                    echo "Docker安装失败 (Failed to install Docker)."
                fi
                rm get-docker.sh
            fi
        fi
    else
        echo "不支持的包管理器。跳过Docker安装 (Unsupported package manager. Docker installation skipped)."
    fi
}


# 安装docker-compose
install_docker_compose() {
    if command -v docker-compose &>/dev/null; then
        echo "Docker-compose已经安装 (Docker-compose already installed)."
    else
        latest_compose=$(curl -sL "https://api.github.com/repos/docker/compose/releases/latest" | grep -oP '"tag_name": "\K(.*)(?=")')
        download_url="https://github.com/docker/compose/releases/download/$latest_compose/docker-compose-$(uname -s)-$(uname -m)"
        
        # 使用timeout设置下载超时时间为5秒
        if timeout 5 bash -c "curl -fsSL $download_url > /dev/null"; then
            wget $download_url -O /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose

            # 检查软链接是否存在
            if [ ! -e /usr/bin/docker-compose ]; then
                # 创建软链接
                ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
                echo "Docker-compose已安装 (Docker-compose installed)."
            else
                echo "软链接已存在。跳过创建 (Soft link already exists. Skipping creation)."
            fi
        else
            echo "下载docker-compose超时，使用代理重新下载... (Download timed out, retrying with proxy...)"
            download_url="https://mirror.ghproxy.com/$download_url"
            wget --no-check-certificate -O /usr/local/bin/docker-compose $download_url
            chmod +x /usr/local/bin/docker-compose

            # 检查软链接是否存在
            if [ ! -e /usr/bin/docker-compose ]; then
                # 创建软链接
                ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
                echo "Docker-compose已安装 (Docker-compose installed)."
            else
                echo "软链接已存在。跳过创建 (Soft link already exists. Skipping creation)."
            fi
        fi
    fi
}


# 安装常用软件
install_utilities() {
    if command -v yum &>/dev/null; then
        yum install -y curl wget mtr screen net-tools zip unzip tar lsof
    elif command -v apt-get &>/dev/null; then
        apt-get update
        apt-get install -y curl wget mtr screen net-tools zip unzip tar lsof
    else
        echo "不支持的包管理器。跳过工具安装 (Unsupported package manager. Utilities installation skipped)."
    fi

    echo "常用工具已安装 (Utilities installed)."
}


# 检测组件和设置是否正确
check_components() {
    # 定义要检查的软件列表
    components=("docker" "docker-compose" "curl" "wget" "mtr" "screen" "zip" "unzip" "tar" "lsof")

    # 遍历检查软件是否安装
    for component in "${components[@]}"; do
        if command -v "$component" &>/dev/null; then
            echo "$component 已正确安装 ($component is correctly installed)."
        else
            echo "警告：$component 未正确安装 (Warning: $component is not correctly installed)."
        fi
    done

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


# 执行函数
check_root
install_utilities
adjust_timezone
sync_system_time
enable_bbr
adjust_hostname
install_docker
install_docker_compose

# 检查组件和设置是否正确
check_components

echo "设置完成 (Setup complete)."
bash -l
