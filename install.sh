#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${red}致命错误：${plain}请使用 root 权限运行此脚本 \n " && exit 1

# 检查系统并设置 release 变量
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "检测系统失败，请联系作者！" >&2
    exit 1
fi
echo "当前系统发行版为：$release"

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${green}不支持的 CPU 架构！${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "架构：$(arch)"

install_base() {
    case "${release}" in
    centos | almalinux | rocky | oracle)
        yum -y update && yum install -y -q wget curl tar tzdata jq wireguard-tools
        ;;
    fedora)
        dnf -y update && dnf install -y -q wget curl tar tzdata jq wireguard-tools
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata jq wireguard-tools
        ;;
    opensuse-tumbleweed)
        zypper refresh && zypper -q install -y wget curl tar timezone jq wireguard-tools
        ;;
    *)
        apt-get update && apt-get install -y -q wget curl tar tzdata jq wireguard
        ;;
    esac
}

config_after_install() {
    echo -e "${yellow}正在迁移... ${plain}"
    /usr/local/s-ui/sui migrate

    echo -e "${yellow}开始自动化配置面板登录信息... ${plain}"
    
    if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
        local usernameTemp=$(head -c 6 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
        local passwordTemp=$(head -c 6 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
        echo -e "这是全新安装，已自动生成随机登录信息："
        echo -e "###############################################"
        echo -e "${green}用户名：${usernameTemp}${plain}"
        echo -e "${green}密码：${passwordTemp}${plain}"
        echo -e "###############################################"
        echo -e "${red}如果忘记登录信息，可以输入 ${green}s-ui${red} 打开配置菜单${plain}"
        /usr/local/s-ui/sui admin -username ${usernameTemp} -password ${passwordTemp}
    else
        echo -e "${yellow}这是升级安装，已自动保留您旧的面板设置。${plain}"
    fi
}

prepare_services() {
    if [[ -f "/etc/systemd/system/sing-box.service" ]]; then
        echo -e "${yellow}正在停止 sing-box 服务... ${plain}"
        systemctl stop sing-box
        rm -f /usr/local/s-ui/bin/sing-box /usr/local/s-ui/bin/runSingbox.sh /usr/local/s-ui/bin/signal
    fi
    if [[ -e "/usr/local/s-ui/bin" ]]; then
        echo -e "###############################################################"
        echo -e "${green}/usr/local/s-ui/bin${red} 目录已存在！"
        echo -e "请检查其中内容，并在迁移后手动删除 ${plain}"
        echo -e "###############################################################"
    fi
    systemctl daemon-reload
}

# ==========================================================
# 新增函数：完全静默、动态注册并配置专属的纯净 WARP wg0 网口
# ==========================================================
auto_configure_warp() {
    echo -e "${yellow}正在动态申请并配置当前服务器专属的 WARP 纯净网口...${plain}"
    
    # 1. 创建临时目录并分析架构
    mkdir -p /tmp/wgcf_install && cd /tmp/wgcf_install
    local current_arch=$(arch)
    
    # 2. 匹配架构自动抓取官方最新的账户生成工具
    if [ "${current_arch}" = "amd64" ]; then
        curl -fsSL https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_2.2.22_linux_amd64 -o wgcf
    elif [ "${current_arch}" = "arm64" ]; then
        curl -fsSL https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_2.2.22_linux_arm64 -o wgcf
    else
        echo -e "${red}不受支持的架构，跳过自动化 WARP 配置。${plain}"
        cd / && rm -rf /tmp/wgcf_install
        return 0
    fi
    chmod +x wgcf

    # 3. 动态向 Cloudflare 注册新设备并本地落地密钥对
    ./wgcf register --accept-tos --quiet
    ./wgcf generate --quiet

    # 4. 关键诊断与处理：强行改造成纯净网口
    if [ -f "wgcf-profile.conf" ]; then
        mkdir -p /etc/wireguard/
        
        # 精准在 [Interface] 字段的正下方静默注入 Table = off，确保绝不抢占原生全局路由
        sed '/\[Interface\]/a Table = off' wgcf-profile.conf > /etc/wireguard/wg0.conf
        chmod 600 /etc/wireguard/wg0.conf
        
        # 5. 自动启动并固定开机自启
        wg-quick down wg0 &> /dev/null
        wg-quick up wg0
        systemctl enable wg-quick@wg0
        echo -e "${green}=== 专属网口 wg0 已经由脚本在本地动态填充并安全拉起！ ===${plain}"
    else
        echo -e "${red}警告：向 Cloudflare 动态获取专属凭证失败，请检查服务器网络。${plain}"
    fi

    # 清理垃圾文件
    cd / && rm -rf /tmp/wgcf_install
}

install_s-ui() {
    cd /tmp/

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/frankgoing/s-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}获取 s-ui 版本失败，可能是 Github API 限制导致，请稍后重试${plain}"
            exit 1
        fi
        echo -e "已获取 s-ui 最新版本：${last_version}，开始安装..."
        wget -N --no-check-certificate -O /tmp/s-ui-linux-$(arch).tar.gz https://github.com/frankgoing/s-ui/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 s-ui 失败，请确认服务器可以访问 Github ${plain}"
            exit 1
        fi
    else
        last_version=$1
        [[ "${last_version}" != v* ]] && last_version="v${last_version}"
        url="https://github.com/frankgoing/s-ui/releases/download/${last_version}/s-ui-linux-$(arch).tar.gz"
        echo -e "开始安装 s-ui ${last_version}"
        wget -N --no-check-certificate -O /tmp/s-ui-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 s-ui ${last_version} 失败，请检查该版本是否存在${plain}"
            exit 1
        fi
    fi

    if [[ -e /usr/local/s-ui/ ]]; then
        systemctl stop s-ui
    fi

    tar zxvf s-ui-linux-$(arch).tar.gz
    rm s-ui-linux-$(arch).tar.gz -f

    chmod +x s-ui/sui s-ui/s-ui.sh
    cp s-ui/s-ui.sh /usr/bin/s-ui
    cp -rf s-ui /usr/local/
    cp -f s-ui/*.service /etc/systemd/system/
    rm -rf s-ui

    config_after_install
    prepare_services

    systemctl enable s-ui --now

    # 在面板主程序完全跑起来后，顺手执行 WARP 动态配置
    auto_configure_warp

    echo -e "${green}s-ui ${last_version}${plain} 安装完成，现已启动并运行..."
    echo -e "你可以通过以下 URL 访问面板：${green}"
    /usr/local/s-ui/sui uri
    echo -e "${plain}"
    echo -e ""
    s-ui help
}

echo -e "${green}正在执行...${plain}"
install_base
install_s-ui $1
