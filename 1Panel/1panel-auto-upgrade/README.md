## 简介

1Panel自动升级脚本。

自动更新有风险，使用需谨慎。

## 使用说明

```
# 创建目录以存放脚本和配置文件
mkdir -p /usr/local/1panel-auto-upgrade

# 使用 wget 下载脚本并保存到指定目录
wget -N --no-check-certificate -O /usr/local/1panel-auto-upgrade/1panel-auto-upgrade.sh "https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-auto-upgrade/1panel-auto-upgrade.sh"

# 授予脚本执行权限
chmod +x /usr/local/1panel-auto-upgrade/1panel-auto-upgrade.sh

# 创建 systemd 服务单元文件
cat > /etc/systemd/system/1panel-auto-upgrade.service <<EOF
[Unit]
Description=1Panel Auto Upgrade Service

[Service]
ExecStart=/usr/local/1panel-auto-upgrade/1panel-auto-upgrade.sh
WorkingDirectory=/usr/local/1panel-auto-upgrade
User=root
Group=root
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 创建配置文件以存放 Webhook 和 Telegram 信息
cat > /usr/local/1panel-auto-upgrade/.env <<EOF
# 通知方式1，不填不影响
WEBHOOK_URL="YOUR_WEBHOOK_URL"  # 替换为实际的Webhook URL

# 通知方式2，不填不影响
TELEGRAM_API_TOKEN="YOUR_TELEGRAM_BOT_API_TOKEN"  # 替换为实际的Telegram Bot的API令牌
TELEGRAM_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"  # 替换为实际的Telegram聊天ID

# 通知用机器名备注
HOST_REMARK="Your Host Remark"   # 添加主机备注变量
EOF

# 启动服务
systemctl start 1panel-auto-upgrade

# 查看服务状态
systemctl status 1panel-auto-upgrade

# 设置开机自启
systemctl enable 1panel-auto-upgrade
```

- 脚本链接替代
  - https://cdn.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-auto-upgrade/1panel-auto-upgrade.sh

  - https://gh-proxy.com/https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-auto-upgrade/1panel-auto-upgrade.sh

  - https://ghproxy.com/https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-auto-upgrade/1panel-auto-upgrade.sh
