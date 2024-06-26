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
    # 输出提示消息：时间同步
    echo "同步系统时间... (Syncing system time...)"

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

    # 从网站获取GMT时间，并提取日期和时间部分
    GMT_TIME=$(curl -I 'https://www.apple.com/' 2>/dev/null | grep -i '^date:' | awk -F ' ' '{print $3 " " $4 " " $5 " " $6}')

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
    echo "启用BBR拥塞控制算法... (Enabling BBR congestion control...)"
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
        echo "wget --no-check-certificate -O /opt/bbr.sh https://testingcf.jsdelivr.net/gh/teddysun/across@master/bbr.sh && chmod 755 /opt/bbr.sh && /opt/bbr.sh"
    fi
}

# 调整时区到上海
adjust_timezone() {
    echo "调整时区... (Adjusting timezone...)"
    timedatectl set-timezone Asia/Shanghai
    echo "时区已设置为Asia/Shanghai (Timezone set to Asia/Shanghai)."
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

    hostnamectl set-hostname $new_hostname
    echo "主机名已设置为 $new_hostname (Hostname set to $new_hostname)."
}


# 安装 Docker
install_docker() {
    echo "正在安装 Docker... (Installing Docker...)"
    install_docker_with_docker_shell
    if ! command -v docker &>/dev/null; then
        echo "尝试使用官方脚本安装失败，尝试使用包管理器安装 Docker (Failed to install using official script, trying package manager)..."
        
        if command -v yum &>/dev/null; then
            echo "使用 yum 包管理器安装 Docker (Installing Docker using yum package manager)..."
            install_docker_with_yum_package_manager
        elif command -v apt-get &>/dev/null; then
            echo "使用 apt 包管理器安装 Docker (Installing Docker using apt package manager)..."
            install_docker_with_apt_package_manager
        else
            echo "无法找到适合的包管理器来安装 Docker (Unable to find suitable package manager to install Docker)."
            echo "请运行以下命令手动安装 Docker 或者尝试其他安装方式 (Please run the following command to install Docker manually or try another installation method)."
            echo "bash <(curl -sSL https://linuxmirrors.cn/docker.sh)"
        fi
    fi
}


# 从docker官方脚本安装 Docker
install_docker_with_docker_shell() {
    if command -v docker &>/dev/null; then
        echo "Docker已经安装 (Docker is already installed)."
    else
        docker_sources=(
            "https://mirrors.aliyun.com/docker-ce"
            "https://mirrors.tencent.com/docker-ce"
            "https://mirrors.163.com/docker-ce"
            "https://mirrors.cernet.edu.cn/docker-ce"
            "https://download.docker.com"
        )

        docker_install_scripts=(
            "https://testingcf.jsdelivr.net/gh/docker/docker-install@master/install.sh"
            "https://cdn.jsdelivr.net/gh/docker/docker-install@master/install.sh"
            "https://fastly.jsdelivr.net/gh/docker/docker-install@master/install.sh"
            "https://gcore.jsdelivr.net/gh/docker/docker-install@master/install.sh"
            "https://raw.githubusercontent.com/docker/docker-install/master/install.sh"
            "https://get.docker.com"
        )

        get_average_delay() {
            local source=$1
            local total_delay=0
            local iterations=2
            local timeout=2

            for ((i = 0; i < iterations; i++)); do
                delay=$(curl -o /dev/null -s -m $timeout -w "%{time_total}\n" "$source")
                if [ $? -ne 0 ]; then
                    delay=$timeout
                fi
                total_delay=$(awk "BEGIN {print $total_delay + $delay}")
            done

            average_delay=$(awk "BEGIN {print $total_delay / $iterations}")
            echo "$average_delay"
        }

        min_delay=99999999
        selected_source=""

        for source in "${docker_sources[@]}"; do
            average_delay=$(get_average_delay "$source" &)

            if (( $(awk 'BEGIN { print '"$average_delay"' < '"$min_delay"' }') )); then
                min_delay=$average_delay
                selected_source=$source
            fi
        done
        wait

        if [ -n "$selected_source" ]; then
            echo "选择延迟最低的源 $selected_source，延迟为 $min_delay 秒 (Selecting source with minimum delay of $min_delay seconds)."
            export DOWNLOAD_URL="$selected_source"
            for script_source in "${docker_install_scripts[@]}"; do
                echo "正在尝试从 $script_source 下载安装脚本 (Attempting to download installation script from $script_source)..."
                curl -# -fsSL --retry 2 --retry-delay 3 --connect-timeout 5 --max-time 10 "$script_source" -o get-docker.sh
                if [ $? -eq 0 ]; then
                    echo "成功从 $script_source 下载安装脚本 (Successfully downloaded installation script from $script_source)."
                    sh get-docker.sh
                    if [ $? -eq 0 ]; then
                        echo "Docker安装成功 (Docker installed successfully)."
                        return
                    else
                        echo "Docker安装失败 (Failed to install Docker)."
                        echo "请运行以下命令手动安装 Docker 或者尝试其他安装方式 (Please run the following command to install Docker manually or try another installation method)."
                        echo "bash <(curl -sSL https://linuxmirrors.cn/docker.sh)"
                    fi
                else
                    echo "从 $script_source 下载安装脚本失败，尝试下一个链接 (Failed to download installation script from $script_source, trying next link)."
                fi
            done
        else
            echo "无法选择源进行安装 (Unable to select a source for installation)."
        fi
    fi
}


# 从包管理器安装 Docker（针对 yum）
install_docker_with_yum_package_manager() {
    # 定义候选源列表
    docker_sources=(
        "https://mirrors.aliyun.com/docker-ce"
        "https://mirrors.tencent.com/docker-ce"
        "https://mirrors.163.com/docker-ce"
        "https://mirrors.cernet.edu.cn/docker-ce"
        "https://download.docker.com"
    )

    # 定义待安装组件列表
    docker_components=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-compose-plugin"
        "docker-ce-rootless-extras"
        "docker-buildx-plugin"
    )

    # 定义函数：获取平均延迟
    get_average_delay() {
        local source=$1
        local total_delay=0
        local iterations=2
        local timeout=2
        
        for ((i = 0; i < iterations; i++)); do
            delay=$(curl -o /dev/null -s -m $timeout -w "%{time_total}\n" "$source")
            if [ $? -ne 0 ]; then
                delay=$timeout
            fi
            total_delay=$(awk "BEGIN {print $total_delay + $delay}")
        done
    
        average_delay=$(awk "BEGIN {print $total_delay / $iterations}")
        echo "$average_delay"
    }
    
    # 初始化最小延迟为一个大数
    min_delay=99999999
    selected_source=""
    
    # 并行测试所有源的延迟
    for source in "${docker_sources[@]}"; do
        average_delay=$(get_average_delay "$source" &)
    
        if (( $(awk 'BEGIN { print '"$average_delay"' < '"$min_delay"' }') )); then
            min_delay=$average_delay
            selected_source=$source
        fi
    done
    wait

    # 如果成功选择了源
    if [ -n "$selected_source" ]; then
        echo "选择延迟最低的源 $selected_source，延迟为 $min_delay 秒 (Selecting source with minimum delay of $min_delay seconds)."
        
        # 添加源并安装Docker组件
        yum-config-manager --add-repo "$selected_source/linux/centos/docker-ce.repo"
        if [ $? -eq 0 ]; then
            echo "Docker源添加成功 (Docker repository added successfully)."
            yum install -y "${docker_components[@]}"
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
                echo "请运行以下命令手动安装 Docker 或者尝试其他安装方式 (Please run the following command to install Docker manually or try another installation method)."
                echo "bash <(curl -sSL https://linuxmirrors.cn/docker.sh)"
            fi
        else
            echo "无法添加Docker源 (Failed to add Docker repository)."
        fi
    else
        echo "无法选择源进行安装 (Unable to select a source for installation)."
    fi
}


# 从包管理器安装 Docker（针对 apt）
install_docker_with_apt_package_manager() {
    # 更新apt源
    apt-get update

    # 安装必要的组件
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    if [ $? -eq 0 ]; then
        echo "必需组件安装成功 (Necessary components installed successfully)."

        # 定义候选源列表
        docker_sources=(
            "https://mirrors.aliyun.com/docker-ce"
            "https://mirrors.tencent.com/docker-ce"
            "https://mirrors.163.com/docker-ce"
            "https://mirrors.cernet.edu.cn/docker-ce"
            "https://download.docker.com"
        )

    # 定义函数：获取平均延迟
    get_average_delay() {
        local source=$1
        local total_delay=0
        local iterations=2
        local timeout=2
        
        for ((i = 0; i < iterations; i++)); do
            delay=$(curl -o /dev/null -s -m $timeout -w "%{time_total}\n" "$source")
            if [ $? -ne 0 ]; then
                delay=$timeout
            fi
            total_delay=$(awk "BEGIN {print $total_delay + $delay}")
        done
    
        average_delay=$(awk "BEGIN {print $total_delay / $iterations}")
        echo "$average_delay"
    }
    
    # 初始化最小延迟为一个大数
    min_delay=99999999
    selected_source=""
    
    # 并行测试所有源的延迟
    for source in "${docker_sources[@]}"; do
        average_delay=$(get_average_delay "$source" &)
    
        if (( $(awk 'BEGIN { print '"$average_delay"' < '"$min_delay"' }') )); then
            min_delay=$average_delay
            selected_source=$source
        fi
    done
    wait

        # 如果成功选择了源
        if [ -n "$selected_source" ]; then
            echo "选择延迟最低的源 $selected_source，延迟为 $min_delay 秒 (Selecting source with minimum delay of $min_delay seconds)."

            # 添加源并安装Docker组件
            curl -fsSL https://$selected_source/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://$selected_source/linux/ubuntu \
                $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-ce-rootless-extras docker-buildx-plugin

            if [ $? -eq 0 ]; then
                echo "Docker安装成功 (Docker installed successfully)."

                systemctl start docker

                if [ $? -eq 0 ]; then
                    echo "Docker服务已启动 (Docker service started)."

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
                echo "请运行以下命令手动安装 Docker 或者尝试其他安装方式 (Please run the following command to install Docker manually or try another installation method)."
                echo "bash <(curl -sSL https://linuxmirrors.cn/docker.sh)"
            fi
        else
            echo "无法选择源进行安装 (Unable to select a source for installation)."
        fi
    else
        echo "必需组件安装失败 (Failed to install necessary components)."
    fi
}


# 安装docker-compose
install_docker_compose() {
    echo "正在安装 Docker Compose... (Installing Docker Compose...)"
    if command -v docker-compose &>/dev/null; then
        echo "Docker-compose已经安装 (Docker-compose already installed)."
    else
        latest_compose=$(curl -sL "https://api.github.com/repos/docker/compose/releases/latest" | grep -oP '"tag_name": "\K(.*)(?=")')
        download_url="https://github.com/docker/compose/releases/download/$latest_compose/docker-compose-$(uname -s)-$(uname -m)"
        proxy_sources=(
            "https://mirror.ghproxy.com"
            "https://ghproxy.net"
            "https://ghproxy.cc"
        )

        # 使用timeout设置下载超时时间为30秒
        if timeout 30 bash -c "curl -fsSL $download_url > /usr/local/bin/docker-compose"; then
            chmod +x /usr/local/bin/docker-compose

            # 检查docker-compose是否可执行
            if docker-compose --version &>/dev/null; then
                # 检查软链接是否存在
                if [ ! -e /usr/bin/docker-compose ]; then
                    # 创建软链接
                    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
                    echo "Docker-compose已安装 (Docker-compose installed)."
                else
                    echo "软链接已存在。跳过创建 (Soft link already exists. Skipping creation)."
                fi
            else
                echo "安装的docker-compose不可执行，请检查下载源。(Installed docker-compose is not executable, please check the download source.)"
            fi
        else
            echo "下载docker-compose超时，使用代理重新下载... (Download timed out, retrying with proxy...)"

            # 尝试从多个代理源下载
            for proxy in "${proxy_sources[@]}"; do
                proxy_download_url="${proxy}/${download_url#https://}"
                if timeout 30 bash -c "wget --quiet --no-check-certificate -O /usr/local/bin/docker-compose $proxy_download_url"; then
                    chmod +x /usr/local/bin/docker-compose

                    # 检查docker-compose是否可执行
                    if docker-compose --version &>/dev/null; then
                        # 检查软链接是否存在
                        if [ ! -e /usr/bin/docker-compose ]; then
                            # 创建软链接
                            ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
                            echo "Docker-compose已通过代理安装 (Docker-compose installed via proxy)."
                        else
                            echo "软链接已存在。跳过创建 (Soft link already exists. Skipping creation)."
                        fi
                        return
                    else
                        echo "安装的docker-compose不可执行，请检查下载源。(Installed docker-compose is not executable, please check the download source.)"
                    fi
                else
                    echo "从 $proxy 下载docker-compose失败，尝试下一个源 (Failed to download docker-compose from $proxy, trying next source)."
                fi
            done

            # 删除下载失败的文件和软链接
            \rm -rf -f /usr/local/bin/docker-compose /usr/bin/docker-compose
            echo "所有代理源均无法下载docker-compose (Failed to download docker-compose from all proxy sources)."
            echo "可以尝试执行以下命令手动下载并安装 docker-compose (Try running this command to install docker-compose manually):"

            arch=$(uname -m)
            if [ "$arch" == 'armv7l' ]; then
                arch='armv7'
            fi
            echo "curl -L https://resource.fit2cloud.com/docker/compose/releases/download/v2.26.1/docker-compose-$(uname -s | tr A-Z a-z)-$arch -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose && ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose"
        fi
    fi
}


# 安装常用软件
install_utilities() {
    echo "安装常用工具... (Installing common utilities...)"
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
    echo "检查系统组件... (Checking system components...)"
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

# 设置swap
setup_swap() {
    echo "设置交换空间... (Setting up swap space...)"
    # 检查是否已经存在swap
    if swapon --show | grep -q '^/'; then
        echo "Swap已存在。当前的swap大小为： (Swap already exists. Current swap size is:)"
        swapon --show
    else
        # 获取系统内存大小 (单位为KB)
        mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_total_mb=$((mem_total_kb / 1024))
        mem_total_gb=$((mem_total_mb / 1024))

        # 获取根目录可用磁盘空间 (单位为KB)
        available_disk_space_kb=$(df / | tail -1 | awk '{print $4}')
        available_disk_space_mb=$((available_disk_space_kb / 1024))
        available_disk_space_gb=$((available_disk_space_mb / 1024))

        # 如果可用磁盘空间小于5GB，则设置swap为512MB
        if [ $available_disk_space_gb -lt 5 ]; then
            swap_size_mb=512
        else
            # 根据系统内存大小推荐swap大小
            if [ $mem_total_gb -le 1 ]; then
                recommended_swap_size_mb=$((1024))
            elif [ $mem_total_gb -le 2 ]; then
                recommended_swap_size_mb=$((mem_total_mb * 2))
            elif [ $mem_total_gb -le 8 ]; then
                recommended_swap_size_mb=$((mem_total_mb))
            elif [ $mem_total_gb -le 64 ]; then
                recommended_swap_size_mb=4096
            else
                recommended_swap_size_mb=4096
            fi

            # 确保swap大小不超过可用磁盘空间的一半和8GB
            max_swap_size_mb=$((available_disk_space_mb / 2))
            if [ $max_swap_size_mb -gt $((8 * 1024)) ]; then
                max_swap_size_mb=$((8 * 1024))
            fi

            if [ $recommended_swap_size_mb -gt $max_swap_size_mb ]; then
                swap_size_mb=$max_swap_size_mb
            else
                swap_size_mb=$recommended_swap_size_mb
            fi
        fi

        # 创建swap文件
        swap_file="/swapfile"
        echo "未检测到swap。创建一个swap文件，大小为 $(($swap_size_mb / 1024))GB... (No swap detected. Creating a swap file with size $(($swap_size_mb / 1024))GB...)"
        dd if=/dev/zero of=$swap_file bs=1M count=$swap_size_mb

        # 设置swap文件
        chmod 600 $swap_file
        mkswap $swap_file
        swapon $swap_file

        # 添加到fstab以便重启后自动启用swap
        echo "$swap_file none swap sw 0 0" >> /etc/fstab

        echo "Swap创建成功。当前的swap大小为： (Swap created successfully. Current swap size is:)"
        swapon --show
    fi
}


# 提示用户批量安装所需组件
prompt_install_components() {
    echo "即将安装组件以增强系统功能：(The following components will be installed to enhance system functionality:)"
    echo "  - cloud-init: 初始化云实例。(Cloud instance initialization.)"
    echo "  - qemu-guest-agent: 宿主机通信。(Host communication.)"
    echo "  - cloud-utils: 磁盘管理工具。(Disk management tools.)"

    # 检查组件是否已安装
    if dpkg -l cloud-init qemu-guest-agent cloud-utils cloud-initramfs-growroot &>/dev/null || rpm -q cloud-init qemu-guest-agent cloud-utils cloud-utils-growpart &>/dev/null; then
        echo "组件已安装，跳过安装过程。(Components are already installed, skipping installation process.)"
        return
    fi

    if grep -q -i "ubuntu\|debian" /etc/*release; then
        echo "  - cloud-initramfs-growroot: 调整文件系统大小。(Filesystem resizing.)"
        echo ""
        read -p "确认安装？(Confirm installation?) (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            apt-get update
            apt-get install -y cloud-init qemu-guest-agent cloud-initramfs-growroot cloud-utils
        else
            echo "组件安装已取消。(Component installation canceled.)"
        fi
    elif grep -q -i "centos\|rhel" /etc/*release; then
        echo "  - cloud-utils-growpart: 调整分区大小。(Partition resizing.)"
        echo ""
        read -p "确认安装？(Confirm installation?) (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            yum install -y cloud-init qemu-guest-agent cloud-utils-growpart cloud-utils
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
        read -p "请输入选项 (1, 2 or 3): " choice

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
main