#!/bin/bash

# 从.env文件中读取配置信息
if [ -f .env ]; then
  source .env
else
  echo "未找到.env文件，请创建并配置.env文件。"
  exit 1
fi

# 定义一些常量
LAST_CHECKED_VERSION=""
SLEEP_MIN=30
SLEEP_MAX=60

# 函数：发送Webhook通知
send_webhook_notification() {
  local status="$1"  # 传入通知状态
  local message="$2"  # 传入通知消息

  if [[ -z "$WEBHOOK_URL" ]]; then
    echo "Webhook URL 未配置，无法发送Webhook通知"
  else
    local payload="{\"status\":\"$status\",\"message\":\"#1Panel自动升级 $HOST_REMARK - $message\"}"
    curl -s -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL"
  fi
}

# 函数：发送Telegram通知
send_telegram_notification() {
  local message="$1"  # 传入通知消息

  if [[ -z "$TELEGRAM_API_TOKEN" ]] || [[ -z "$TELEGRAM_CHAT_ID" ]]; then
    echo "Telegram通知未配置，无法发送Telegram通知"
  else
    local tag="#1Panel自动升级"  # 添加标签文本
    local telegram_message="$tag $HOST_REMARK - $message"
    local url="https://api.telegram.org/bot$TELEGRAM_API_TOKEN/sendMessage"
    curl -s -X POST $url -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$telegram_message"
  fi
}


# 函数：检查是否具有 root 或 sudo 权限
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 或 sudo 权限运行此脚本"
    exit 1
  fi
}

# 函数：检查可用的包管理器
check_package_manager() {
  if command -v apt >/dev/null 2>&1; then
    # 使用 apt 包管理器（Debian、Ubuntu等）
    apt_packages=("sqlite3" "sed" "curl" "tar" "grep")
    update_command="apt update"
    install_command="apt install -y"
  elif command -v yum >/dev/null 2>&1; then
    # 使用 yum 包管理器（CentOS、Rocky Linux等）
    yum_packages=("sqlite" "sed" "curl" "tar" "grep")
    update_command="yum update"
    install_command="yum install -y"
  else
    echo "无法确定包管理器"
    exit 1
  fi
}

# 函数：检查 1Panel 是否安装
check_1panel_existence() {
  if [[ ! -f /usr/local/bin/1panel ]]; then
    echo "1Panel 未安装，不需要执行 1Panel 升级脚本！"
    exit 1
  fi
}

# 函数：更新包管理器并安装软件包
update_and_install_packages() {
  $update_command
  if [[ ${#apt_packages[@]} -gt 0 ]]; then
    $install_command "${apt_packages[@]}"
  fi

  if [[ ${#yum_packages[@]} -gt 0 ]]; then
    $install_command "${yum_packages[@]}"
  fi
}

# 函数：下载 1Panel
download_1panel() {
  mkdir -p ~/1pupdate-tmp
  cd ~/1pupdate-tmp
  PANELVER=$(curl -s https://resource.fit2cloud.com/1panel/package/stable/latest)
  INSTALL_MODE="stable"
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
  package_download_url="https://resource.fit2cloud.com/1panel/package/${INSTALL_MODE}/${PANELVER}/release/${package_file_name}"
  echo "正在尝试下载 ${package_download_url}"
  curl -sSL -o ${package_file_name} "$package_download_url" || {
    echo "下载失败，切换到备选链接"
    package_download_url="https://github.com/wanghe-fit2cloud/1Panel/releases/download/${PANELVER}/${package_file_name}"
    echo "正在下载备选链接 ${package_download_url}"
    curl -sSL -o ${package_file_name} "$package_download_url" || {
      echo "备选链接下载失败"
      send_webhook_notification "Failure" "1Panel下载失败"
      send_telegram_notification "1Panel下载失败"
      exit 1
    }
  }
  tar zxvf ${package_file_name} --strip-components 1
}

# 函数：更新 1pctl 文件中的 BASE_DIR
update_1pctl_basedir() {
  if [[ -f /usr/local/bin/1pctl ]]; then
    BASE_DIR=$(grep '^BASE_DIR=' /usr/local/bin/1pctl | cut -d '=' -f 2-)
    sed -i "s#BASE_DIR=.*#BASE_DIR=$BASE_DIR#" ~/1pupdate-tmp/1pctl
  else
    echo "/usr/local/bin/1pctl 文件不存在"
    exit 1
  fi
}

# 函数：更新数据库
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

# 函数：安装 1Panel
install_1panel() {
  systemctl stop 1panel
  cp ~/1pupdate-tmp/1panel /usr/local/bin && chmod +x /usr/local/bin/1panel
  cp ~/1pupdate-tmp/1pctl /usr/local/bin && chmod +x /usr/local/bin/1pctl
}

# 函数：重启 1Panel
restart_1panel() {
  systemctl restart 1panel
  echo "升级 1Panel 到 ${PANELVER} 版本相关操作已执行完毕"
  send_webhook_notification "Success" "1Panel 已成功升级到版本 ${PANELVER}"
  send_telegram_notification "1Panel 已成功升级到版本 ${PANELVER}"
}

# 函数：删除临时文件
cleanup() {
  rm -r ~/1pupdate-tmp
}

# 初始化函数，执行一次初始化操作
initialize() {
  check_root
  check_package_manager
  check_1panel_existence
  update_and_install_packages
}

# 主函数
main() {
  initialize  # 调用初始化函数

  while true; do
    # 随机生成30到60秒的等待时间
    sleep_duration=$((RANDOM % ($SLEEP_MAX - $SLEEP_MIN + 1) + $SLEEP_MIN))
    sleep $sleep_duration

    # 获取当前1Panel版本
    CURRENT_VER=$(/usr/local/bin/1panel version | grep -oP 'version:\s*\K.*')
    # 获取最新1Panel版本
    PANELVER=$(curl -s https://resource.fit2cloud.com/1panel/package/stable/latest)

    # 检查当前1Panel版本和已检查的版本是否一致
    if [ "$CURRENT_VER" != "$PANELVER" ]; then
      # 如果版本不匹配，执行升级操作
      download_1panel
      update_1pctl_basedir
      install_1panel
      cleanup
      update_database
      restart_1panel
    else
      echo "1Panel 已是最新版本 $CURRENT_VER，无需升级"
    fi
  done
}

# 执行主函数
main
