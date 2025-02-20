#!/bin/bash
set -euo pipefail  # 启用严格模式：遇到错误立即退出，未定义变量报错，管道错误检测

# ----------------------
# 用户配置区（按需修改）
# ----------------------
TXT_API_URL="https://60s-api-cf.viki.moe/v2/60s?encoding=text"
PIC_API_URL="https://api.03c3.cn/api/zb"

# Telegram 配置（留空则不启用）
TG_BOT_TOKEN=""
TG_CHAT_ID=""

# ntfy 配置（留空则不启用）
NTFY_URL=""      # ntfy 主题的 URL
NTFY_TOKEN=""    # 身份验证令牌（如果需要）

# ----------------------
# 时间处理函数（兼容性改进）
# ----------------------
GET_CN_TIME() {
    # 强制使用英文输出日期，避免本地化问题
    CURRENT_TIME=$(TZ='Asia/Shanghai' LC_ALL=C date "+%Y-%m-%d %H:%M:%S %A")
    
    # 分割时间和英文星期
    TIME_PART=${CURRENT_TIME% *}
    ENG_WEEK=${CURRENT_TIME##* }

    # 兼容旧版 Bash 的星期转换
    case "$ENG_WEEK" in
        "Monday")    CN_WEEK="星期一" ;;
        "Tuesday")   CN_WEEK="星期二" ;;
        "Wednesday") CN_WEEK="星期三" ;;
        "Thursday")  CN_WEEK="星期四" ;;
        "Friday")    CN_WEEK="星期五" ;;
        "Saturday")  CN_WEEK="星期六" ;;
        "Sunday")    CN_WEEK="星期日" ;;
        *)           CN_WEEK="未知"   ;;  # 异常情况处理
    esac

    echo "📅 此时北京时间：${TIME_PART} ${CN_WEEK}"
}

# ----------------------
# 主程序逻辑（增强健壮性）
# ----------------------
# 创建临时文件并确保退出时清理
TEMP_FILE=$(mktemp daily60s.XXXXXX.jpg) || { echo "创建临时文件失败"; exit 1; }
trap 'rm -f "$TEMP_FILE"' EXIT  # 任何退出时自动删除

# 获取时间头
TIME_HEADER=$(GET_CN_TIME) || { echo "时间获取失败"; exit 1; }

# 获取新闻内容（增加失败检测）
echo "正在获取新闻文本..."
CONTENT=$(curl -f -s "$TXT_API_URL") || {
    echo "错误：新闻API请求失败 (HTTP $?)"
    exit 1
}

# 下载图片（增加失败检测和进度显示）
echo "正在下载新闻图片..."
curl -f -#SL -o "$TEMP_FILE" "$PIC_API_URL" || {
    echo "错误：图片下载失败 (HTTP $?)"
    exit 1
}

# ----------------------
# 构建消息内容
# ----------------------
MESSAGE="#每日新闻

${TIME_HEADER}

🔖 ↓昨日新闻↓

${CONTENT}"

# ----------------------
# 推送到 Telegram（安全格式化）
# ----------------------
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    echo "正在推送至 Telegram..."
    curl -f -# -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendPhoto" \
         -F "chat_id=${TG_CHAT_ID}" \
         -F "photo=@$TEMP_FILE" \
         -F "caption=<-" <<<"$MESSAGE" || {
             echo "警告：Telegram 推送失败"
             # 不退出，继续尝试其他推送方式
         }
fi

# ----------------------
# 推送到 ntfy（带身份验证支持）
# ----------------------
if [ -n "$NTFY_URL" ]; then
    echo "正在推送至 ntfy..."
    CURL_CMD=(curl -f -# -d "$MESSAGE")
    
    # 添加身份验证头
    if [ -n "$NTFY_TOKEN" ]; then
        CURL_CMD+=(-H "Authorization: Bearer $NTFY_TOKEN")
    fi

    # 执行推送
    "${CURL_CMD[@]}" "$NTFY_URL" || {
        echo "警告：ntfy 推送失败"
        # 不退出，继续后续流程
    }
fi

# ----------------------
# 完成提示
# ----------------------
echo "推送完成：$(date '+%H:%M:%S')"
