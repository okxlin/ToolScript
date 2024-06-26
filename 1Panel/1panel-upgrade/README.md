- [1. 简介](#1-简介)
- [2. 使用说明](#2-使用说明)
  - [2.1 国内网络](#21-国内网络)
    - [2.1.1 root](#211-root)
    - [2.1.2 sudo](#212-sudo)
  - [2.2 国际网络](#22-国际网络)
    - [2.2.1 root](#221-root)
    - [2.2.2 sudo](#222-sudo)

# 1. 简介
`1Panel`升级到最新版本的脚本

# 2. 使用说明
## 2.1 国内网络
### 2.1.1 root
- 无交互
```
# echo y | bash <(wget -qO- --no-check-certificate https://fastly.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
# echo y | bash <(wget -qO- --no-check-certificate https://gcore.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
# echo y | bash <(wget -qO- --no-check-certificate https://testingcf.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
# echo y | bash <(wget -qO- --no-check-certificate https://cdn.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
echo y | bash <(wget -qO- --no-check-certificate https://mirror.ghproxy.com/https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh)
```

- 交互
```
# bash <(wget -qO- --no-check-certificate https://fastly.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
# bash <(wget -qO- --no-check-certificate https://gcore.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
# bash <(wget -qO- --no-check-certificate https://testingcf.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
# bash <(wget -qO- --no-check-certificate https://cdn.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh)
bash <(wget -qO- --no-check-certificate https://mirror.ghproxy.com/https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh)
```

### 2.1.2 sudo
- 无交互
```
# wget -qO- --no-check-certificate https://fastly.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && echo y | sudo bash 1panel-upgrade.sh
# wget -qO- --no-check-certificate https://gcore.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && echo y | sudo bash 1panel-upgrade.sh
# wget -qO- --no-check-certificate https://testingcf.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && echo y | sudo bash 1panel-upgrade.sh
# wget -qO- --no-check-certificate https://cdn.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && echo y | sudo bash 1panel-upgrade.sh
wget -N --no-check-certificate https://mirror.ghproxy.com/https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && echo y | sudo bash 1panel-upgrade.sh
```

- 交互
```
# wget -qO- --no-check-certificate https://fastly.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && sudo bash 1panel-upgrade.sh
# wget -qO- --no-check-certificate https://gcore.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && sudo bash 1panel-upgrade.sh
# wget -qO- --no-check-certificate https://testingcf.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && sudo bash 1panel-upgrade.sh
# wget -qO- --no-check-certificate https://cdn.jsdelivr.net/gh/okxlin/ToolScript@main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && sudo bash 1panel-upgrade.sh
wget -N --no-check-certificate https://mirror.ghproxy.com/https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && sudo bash 1panel-upgrade.sh
```

## 2.2 国际网络
### 2.2.1 root
- 无交互
```
echo y | bash <(wget -qO- --no-check-certificate https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh)
```

- 交互
```
bash <(wget -qO- --no-check-certificate https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh)
```

### 2.2.2 sudo
- 无交互
```
wget -N --no-check-certificate https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && echo y | sudo bash 1panel-upgrade.sh
```

- 交互
```
wget -N --no-check-certificate https://github.com/okxlin/ToolScript/raw/main/1Panel/1panel-upgrade/1panel-upgrade.sh && sudo chmod +x 1panel-upgrade.sh && sudo bash 1panel-upgrade.sh
```
