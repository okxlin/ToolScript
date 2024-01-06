#!/bin/bash

# 检查是否以root身份运行脚本
if [ "$EUID" -ne 0 ]; then
    echo "请以root身份或使用sudo运行此脚本"
    exit 1
fi

# 检测包管理器类型
if [ -x "$(command -v apt-get)" ]; then
    # 使用APT包管理器（Debian/Ubuntu）
    update_command="apt-get update"
    install_command="apt-get install -y tzdata"
    curl_install_command="apt-get install -y curl"
elif [ -x "$(command -v yum)" ]; then
    # 使用YUM包管理器（CentOS/RHEL）
    update_command="yum makecache"
    install_command="yum install -y tzdata"
    curl_install_command="yum install -y curl"
else
    echo "不支持的Linux发行版，无法确定包管理器类型"
    exit 1
fi

# 输出提示消息：时间同步前
echo "开始执行时间同步操作..."

# 检查是否安装了curl，如果没有，使用包管理器安装它
if ! command -v curl &>/dev/null; then
    echo "未找到curl。将尝试安装..."
    $curl_install_command
fi

# 更新包管理器的软件包列表
echo "正在更新包管理器的软件包列表..."
$update_command

# 安装tzdata包，用于设置系统时区
echo "正在安装tzdata包..."
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

# 输出提示消息：时间同步完成和当前时间
echo "时间同步操作完成。当前时间：$current_time"
