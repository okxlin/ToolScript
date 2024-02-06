#!/bin/bash

# 检查是否以root身份运行脚本
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请以root身份或使用sudo运行此脚本"
        exit 1
    fi
}

# 更新软件包列表
update_package_list() {
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update
    elif [ -x "$(command -v yum)" ]; then
        yum update
    else
        echo "不支持的Linux发行版，无法确定包管理器类型"
        exit 1
    fi
}

# 检查并安装软件包
install_packages() {
    local packages="tzdata curl ntpdate"
    
    if [ -x "$(command -v dpkg-query)" ]; then
        # Debian/Ubuntu系统
        for pkg in $packages; do
            if ! dpkg-query -W -f='${Status}' $pkg 2>/dev/null | grep -q "ok installed"; then
                apt-get install -y $pkg
            else
                echo "$pkg 已经安装，跳过安装步骤。"
            fi
        done
    elif [ -x "$(command -v rpm)" ]; then
        # CentOS/RHEL系统
        for pkg in $packages; do
            if ! rpm -q $pkg &>/dev/null; then
                yum install -y $pkg
            else
                echo "$pkg 已经安装，跳过安装步骤。"
            fi
        done
    else
        echo "不支持的Linux发行版，无法确定包管理器类型"
        exit 1
    fi
}


# 检测并同步时间到时间服务器
sync_time() {
    echo "正在同步系统时间到苹果的时间服务器..."
    ntpdate -u time.apple.com
}

# 设置系统时间
set_system_time() {
    # 从网站获取GMT时间，并提取日期和时间部分
    GMT_TIME=$(curl -I 'https://www.apple.com/' 2>/dev/null | grep -i '^date:' | awk -F ' ' '{print $3 " " $4 " " $5 " " $6}')

    # 将GMT时间转换为时间戳
    GMT_TIMESTAMP=$(date -d "$GMT_TIME" '+%s')

    # 计算CST（中国标准时间）时间戳（GMT时间戳 + 8小时的秒数）
    CST_TIMESTAMP=$((GMT_TIMESTAMP + 8*3600))

    # 将CST时间戳转换为CST时间并设置为系统时间
    TZ='Asia/Shanghai' date -s "@$CST_TIMESTAMP"
}

# 调整时区到上海
adjust_timezone() {
    timedatectl set-timezone Asia/Shanghai
    echo "时区已设置为Asia/Shanghai"
}

# 主函数
main() {
    check_root
    update_package_list
    install_packages
    adjust_timezone
    sync_time
    set_system_time

    # 获取当前时间
    current_time=$(date)

    # 输出提示消息：时间同步完成和当前时间
    echo "时间同步操作完成。当前时间：$current_time"
}

# 执行主函数
main
