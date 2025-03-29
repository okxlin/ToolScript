#!/bin/bash

# 检查是否具有 root 或 sudo 权限
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 或 sudo 权限运行此脚本"
    exit 1
  fi
}

# 确认是否执行升级脚本
confirm_upgrade() {
  read -p "是否执行1Panel升级操作？(y/n): " choice
  if [[ $choice == "y" || $choice == "Y" ]]; then
    return 0  # 返回 0 表示确认执行升级操作
  else
    return 1  # 返回 1 表示取消升级操作
  fi
}

# 询问用户选择版本
select_version_type() {
  read -p "请选择1Panel版本（输入 '1' 为国际版，输入 '2' 为国内版）: " version_choice
  if [[ $version_choice == "1" ]]; then
    # 选择国际版
    VERSION_TYPE="international"
    version_url="https://resource.1panel.hk/stable/latest"
    package_url_prefix="https://resource.1panel.hk"
  elif [[ $version_choice == "2" ]]; then
    # 选择国内版
    VERSION_TYPE="domestic"
    version_url="https://resource.fit2cloud.com/1panel/package/stable/latest"
    package_url_prefix="https://resource.fit2cloud.com/1panel/package"
  else
    echo "无效输入，请输入 1 或 2。"
    exit 1
  fi
}

# 获取当前1Panel版本和模式
get_current_version_and_mode() {
  if [[ -f /usr/local/bin/1panel ]]; then
    CURRENT_VERSION=$(1panel version | grep -oP 'version:\s*\K.*')
    CURRENT_MODE=$(1panel version | grep -oP 'mode:\s*\K.*')
  else
    echo "无法获取当前1Panel版本和模式"
    exit 1
  fi
}

# 获取最新的1Panel版本
get_latest_version() {
  PANELVER=$(curl -fsSL "$version_url")
}

# 比较版本
compare_versions() {
  if [[ $CURRENT_VERSION == $PANELVER ]]; then
    echo "当前版本 $CURRENT_VERSION 已是最新版本 $PANELVER"
    exit 0
  fi
}

# 检查可用的包管理器
check_package_manager() {
  if command -v apt >/dev/null 2>&1; then
    # 使用 apt 包管理器（Debian、Ubuntu等）
    packages=("sqlite3" "sed" "curl" "tar" "grep")
    update_command="apt update"
    install_command="apt install -y"
  elif command -v yum >/dev/null 2>&1; then
    # 使用 yum 包管理器（CentOS、Rocky Linux等）
    packages=("sqlite" "sed" "curl" "tar" "grep")
    update_command="yum update"
    install_command="yum install -y"
  else
    echo "无法确定包管理器"
    exit 1
  fi
}

# 检查 1Panel 是否安装
check_1panel_existence() {
  if [[ ! -f /usr/local/bin/1panel ]]; then
    echo "1Panel 未安装，不需要执行 1Panel 升级脚本！"
    exit 1
  fi
}

# 更新包管理器并安装软件包
update_and_install_packages() {
  $update_command
  $install_command "${packages[@]}"
}

# 下载 1Panel
download_1panel() {
  mkdir -p ~/1pupdate-tmp
  cd ~/1pupdate-tmp
  osCheck=$(uname -a)
  if [[ $osCheck =~ 'x86_64' ]]; then
    ARCH="amd64"
  elif [[ $osCheck =~ 'arm64' ]] || [[ $osCheck =~ 'aarch64' ]]; then
    ARCH="arm64"
  elif [[ $osCheck =~ 'armv7l' ]]; then
    ARCH="armv7"
  elif [[ $osCheck =~ 'ppc64le' ]]; then
    ARCH="ppc64le"
  elif [[ $osCheck =~ 's390x' ]]; then
    ARCH="s390x"
  else
    echo "暂不支持的系统架构，请参阅官方文档，选择受支持的系统。"
    exit 1
  fi
  package_file_name="1panel-${PANELVER}-linux-${ARCH}.tar.gz"
  package_download_url="${package_url_prefix}/${CURRENT_MODE}/${PANELVER}/release/${package_file_name}"
  echo "正在尝试下载 ${package_download_url}"
  curl -sSL -o ${package_file_name} "$package_download_url" || {
    echo "下载失败"
    exit 1
  }
  tar zxvf ${package_file_name} --strip-components 1
}

# 更新 1pctl 文件中的 BASE_DIR
update_1pctl_basedir() {
  if [[ -f /usr/local/bin/1pctl ]]; then
    BASE_DIR=$(grep '^BASE_DIR=' /usr/local/bin/1pctl | cut -d '=' -f 2-)
    sed -i "s#BASE_DIR=.*#BASE_DIR=$BASE_DIR#" ~/1pupdate-tmp/1pctl
  else
    echo "/usr/local/bin/1pctl 文件不存在"
    exit 1
  fi
}

# 更新数据库
update_database() {
  if [[ -f $BASE_DIR/1panel/db/1Panel.db ]]; then
    # 备份数据库文件
    cp $BASE_DIR/1panel/db/1Panel.db $BASE_DIR/1panel/db/1Panel.db.bak

    # 使用 sqlite3 执行更新操作
    sqlite3 $BASE_DIR/1panel/db/1Panel.db <<EOF
UPDATE settings
SET value = '$PANELVER'
WHERE key = 'SystemVersion';
.exit
EOF
  else
    echo "$BASE_DIR/1panel/db/1Panel.db 文件不存在"
    exit 1
  fi
}

# 安装 1Panel
install_1panel() {
  systemctl stop 1panel
  cp ~/1pupdate-tmp/1panel /usr/local/bin && chmod +x /usr/local/bin/1panel
  cp ~/1pupdate-tmp/1pctl /usr/local/bin && chmod +x /usr/local/bin/1pctl
}

# 重启 1Panel
restart_1panel() {
  systemctl restart 1panel
  echo "升级 1Panel 到 ${PANELVER} 版本相关操作已执行完毕"
}

# 删除临时文件
cleanup() {
  rm -r ~/1pupdate-tmp
}

# 主函数
main() {
  check_root
  confirm_upgrade
  local confirm_result=$?
  if [[ $confirm_result -eq 0 ]]; then
    select_version_type
    check_package_manager
    check_1panel_existence
    get_current_version_and_mode
    get_latest_version
    compare_versions
    update_and_install_packages
    download_1panel
    update_1pctl_basedir
    install_1panel
    cleanup
    update_database
    restart_1panel
  else
    echo "已取消执行 1Panel 升级操作"
    exit 0  # 直接退出脚本
  fi
}

# 调用主函数
main
