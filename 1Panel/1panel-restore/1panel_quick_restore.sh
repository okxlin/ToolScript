#!/bin/sh
# 出错立即退出
set -e

######################################
# 用法说明
# 示例（带认证，使用默认版本）： 
#   ./1panel_quick_restore.sh -u "http://your.alist.site/path/opt-1panel-data.zip" \
#     -a "your_username" -p "your_password" -z "your_zip_password"
#
# 示例（不需要 HTTP 认证，并且获取最新 global 版本）： 
#   ./1panel_quick_restore.sh -u "http://your.alist.site/path/opt-1panel-data.zip" \
#     -a "" -p "" -z "your_zip_password" -i latest
#
# 示例（手工指定其他版本）： 
#   ./1panel_quick_restore.sh -u "http://your.alist.site/path/opt-1panel-data.zip" \
#     -a "user" -p "pass" -z "zip_password" -i "moelin/1panel:custom-version"
######################################
usage() {
  echo "Usage: $0 -u <file_url> -a <http_username> -p <http_password> -z <zip_password> [-i <docker_image>]"
  exit 1
}

# 默认 Docker 镜像版本
DOCKER_IMAGE="moelin/1panel:global-v1.10.29-lts"

# 解析命令行参数
while getopts "u:a:p:z:i:" opt; do
  case "$opt" in
    u) FILE_URL="$OPTARG" ;;
    a) HTTP_USER="$OPTARG" ;;
    p) HTTP_PASS="$OPTARG" ;;
    z) ZIP_PASS="$OPTARG" ;;
    i) DOCKER_IMAGE="$OPTARG" ;;
    *) usage ;;
  esac
done

# 检查必须参数：file_url 与 zip_password 必须提供（HTTP认证信息可为空）
if [ -z "$FILE_URL" ] || [ -z "$ZIP_PASS" ]; then
  usage
fi

######################################
# 函数：安全转义参数（替代 printf "%q"）
######################################
shquote() {
  printf "'%s' " "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

######################################
# 函数：从 Docker Hub 查询最新符合 global-v*-lts 格式的镜像标签
######################################
get_latest_global_version() {
  # 获取最多10个标签的 JSON 数据
  json=$(wget -qO- "https://registry.hub.docker.com/v2/repositories/moelin/1panel/tags/?page_size=10")
  latest=$(echo "$json" | jq -r '.results[] | select(.name | test("global-v.*-lts")) | .name' | sort -V | tail -n1)
  if [ -n "$latest" ]; then
    echo "moelin/1panel:$latest"
  else
    echo "moelin/1panel:global-v1.10.29-lts"
  fi
}

######################################
# 函数：安装缺失的软件包（自动检测包管理器）
######################################
install_pkg() {
  pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    echo "使用 apt-get 安装 $pkg ..."
    apt-get update && apt-get install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    echo "使用 yum 安装 $pkg ..."
    yum install -y "$pkg"
  elif command -v apk >/dev/null 2>&1; then
    echo "使用 apk 安装 $pkg ..."
    apk add --no-cache "$pkg"
  else
    echo "错误：无法识别的包管理器，请手动安装 $pkg." >&2
    exit 1
  fi
}

######################################
# 函数：检测是否以 root 身份运行
######################################
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "错误：需要以 root 身份运行此脚本！" >&2
    exit 1
  fi
}

######################################
# 函数：检测系统资源（磁盘空间、内存）
# 磁盘检查始终执行；内存检测仅在非容器环境下进行
######################################
check_system_resources() {
  free_space_kb=$(df -k / | awk 'NR==2 {print $4}')
  min_space_kb=1572864
  if [ "$free_space_kb" -lt "$min_space_kb" ]; then
    free_space_mb=$(echo "$free_space_kb / 1024" | awk '{printf "%.1f", $1}')
    echo "警告：根目录剩余磁盘空间不足！当前剩余：${free_space_mb} MB (要求至少1536 MB)。是否退出？[y/N]"
    read answer
    case "$answer" in
      [Yy]* ) exit 1 ;;
      * ) echo "继续执行..." ;;
    esac
  fi

  if [ ! -f /.dockerenv ]; then
    if [ -r /proc/meminfo ]; then
      total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    else
      echo "无法获取内存信息，请确认 /proc/meminfo 是否存在。" >&2
      exit 1
    fi
    min_mem_kb=$((384 * 1024))
    if [ "$total_mem_kb" -lt "$min_mem_kb" ]; then
      total_mem_mb=$(echo "$total_mem_kb / 1024" | awk '{printf "%.1f", $1}')
      echo "警告：总内存不足！当前总内存：${total_mem_mb} MB (要求至少384 MB)。是否退出？[y/N]"
      read answer
      case "$answer" in
        [Yy]* ) exit 1 ;;
        * ) echo "继续执行..." ;;
      esac
    fi
  fi
}

######################################
# 函数：检查必要程序是否存在
# 对于 wget、unzip，缺失时自动安装；对于 docker 和 docker-compose 提示用户
######################################
check_programs() {
  for prog in jq wget unzip; do
    if ! command -v "$prog" >/dev/null 2>&1; then
      echo "程序 \"$prog\" 未安装，尝试自动安装..."
      install_pkg "$prog"
    else
      echo "程序 \"$prog\" 已安装。"
    fi
  done

  for prog in docker; do
    if ! command -v "$prog" >/dev/null 2>&1; then
      echo "错误：必需的程序 \"$prog\" 未安装。请先安装 $prog。" >&2
      exit 1
    fi
  done

  if ! command -v docker-compose >/dev/null 2>&1; then
    echo "警告：docker-compose 未安装。在 Alpine 下，通常需要通过 'docker-compose-plugin' 安装。" >&2
  fi
}

######################################
# 函数：检查/opt/1panel/目录
# 如果目录非空，则提示用户是否清空目录，删除内容时采用兼容 BusyBox 的方式删除所有文件（包括隐藏文件）
######################################
check_directory() {
  target_dir="/opt/1panel/"
  if [ -d "$target_dir" ]; then
    if [ "$(ls -A "$target_dir")" ]; then
      echo "目录 $target_dir 非空。是否删除所有内容？[y/N]"
      read answer
      case "$answer" in
        [Yy]* )
          echo "正在删除 $target_dir 下的所有内容..."
          find "$target_dir" -mindepth 1 -exec rm -rf {} +
          ;;
        * )
          echo "请清空目录 $target_dir 后重新运行脚本。" >&2
          exit 1
          ;;
      esac
    fi
  else
    mkdir -p "$target_dir"
  fi
}

######################################
# 函数：下载文件并解压到 /opt/1panel/
# 使用新的 shquote() 函数处理参数转义
######################################
download_and_unzip() {
  target_dir="/opt/1panel/"
  echo "开始下载 opt-1panel-data.zip..."
  cd "$target_dir"

  wget_opts=""
  if [ -n "$HTTP_USER" ] || [ -n "$HTTP_PASS" ]; then
    # 使用安全转义函数
    escaped_user=$(shquote "$HTTP_USER")
    escaped_pass=$(shquote "$HTTP_PASS")
    wget_opts="--user=${escaped_user} --password=${escaped_pass}"
  fi

  wget $wget_opts "$FILE_URL" -O opt-1panel-data.zip
  if [ $? -ne 0 ]; then
    echo "错误：文件下载失败。" >&2
    exit 1
  fi

  echo "开始解压 opt-1panel-data.zip 到 $target_dir..."
  unzip -o -P "$ZIP_PASS" opt-1panel-data.zip
  if [ $? -ne 0 ]; then
    echo "错误：解压文件失败。" >&2
    exit 1
  fi
}

######################################
# 函数：安装 docker-1panel 容器
# 挂载目录使用 $HOME 代替硬编码 /root
######################################
install_docker_1panel() {
  echo "正在安装 docker-1panel 容器..."
  docker run -d \
    --name 1panel \
    --restart always \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    -v /opt:/opt \
    -v "$HOME":/root \
    -v /etc/docker:/etc/docker \
    -e TZ=Asia/Shanghai \
    "$DOCKER_IMAGE"
  if [ $? -ne 0 ]; then
    echo "错误：docker-1panel 容器安装失败。" >&2
    exit 1
  fi
}

######################################
# 函数：递归查找 /opt/1panel/apps/local 下的 docker-compose.yml，并执行 docker-compose up -d
######################################
traverse_and_start_docker_compose() {
  base_dir="/opt/1panel/apps/local"
  if [ ! -d "$base_dir" ]; then
    echo "注意：目录 $base_dir 不存在，跳过 docker-compose 部分。" >&2
    return
  fi

  echo "查找目录 $base_dir 下的 docker-compose.yml，并启动对应服务..."
  find "$base_dir" -type f -name "docker-compose.yml" | while read compose_file; do
    compose_dir=$(dirname "$compose_file")
    echo "在目录 $compose_dir 下执行 docker-compose up -d"
    (cd "$compose_dir" && docker-compose up -d)
  done
}

######################################
# 函数：任务完成后删除下载的压缩包
######################################
cleanup() {
  target_dir="/opt/1panel/"
  cd "$target_dir"
  if [ -f "opt-1panel-data.zip" ]; then
    echo "正在删除下载的压缩包 opt-1panel-data.zip..."
    rm -f opt-1panel-data.zip
  fi
}

######################################
# 主函数
######################################
main() {
  check_root
  check_programs

  # 统一处理 latest 参数
  if [ "$DOCKER_IMAGE" = "latest" ]; then
    echo "正在从 Docker Hub 查询最新符合 global-v*-lts 格式的版本..."
    DOCKER_IMAGE=$(get_latest_global_version)
    echo "获取到 Docker 镜像：$DOCKER_IMAGE"
  fi

  if [ ! -f /.dockerenv ]; then
    check_system_resources
  fi
  check_directory
  download_and_unzip
  install_docker_1panel
  traverse_and_start_docker_compose
  cleanup
  echo "所有操作已成功执行。"
}

# 执行主函数
main
