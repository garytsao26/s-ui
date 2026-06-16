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

get_arch() {
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

echo "架构：$(get_arch)"

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
        apt-get update && apt-get install -y -q wget curl tar tzdata jq wireguard-tools
        ;;
    esac
}

config_after_install() {
    echo -e "${yellow}正在迁移... ${plain}"
    /usr/local/s-ui/sui migrate

    echo -e "${yellow}安装/更新完成！出于安全考虑，建议修改面板设置 ${plain}"
    read -p "是否继续修改设置 [y/n]？" config_confirm
    if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        echo -e "请输入${yellow}面板端口${plain}（留空则使用现有/默认值）："
        read config_port
        echo -e "请输入${yellow}面板路径${plain}（留空则使用现有/默认值）："
        read config_path

        # 订阅配置
        echo -e "请输入${yellow}订阅端口${plain}（留空则使用现有/默认值）："
        read config_subPort
        echo -e "请输入${yellow}订阅路径${plain}（留空则使用现有/默认值）："
        read config_subPath

        # 设置配置
        echo -e "${yellow}正在初始化，请稍候...${plain}"
        params=""
        [ -z "$config_port" ] || params="$params -port $config_port"
        [ -z "$config_path" ] || params="$params -path $config_path"
        [ -z "$config_subPort" ] || params="$params -subPort $config_subPort"
        [ -z "$config_subPath" ] || params="$params -subPath $config_subPath"
        /usr/local/s-ui/sui setting ${params}

        read -p "是否修改管理员账号密码 [y/n]？" admin_confirm
        if [[ "${admin_confirm}" == "y" || "${admin_confirm}" == "Y" ]]; then
            # 首个管理员账号密码
            read -p "请设置用户名：" config_account
            read -s -p "请设置密码：" config_password
            echo ""

            # 设置账号密码（避免密码出现在命令行参数中）
            echo -e "${yellow}正在初始化，请稍候...${plain}"
            /usr/local/s-ui/sui admin -username "${config_account}" -password "${config_password}"
        else
            echo -e "${yellow}当前管理员账号密码：${plain}"
            /usr/local/s-ui/sui admin -show
        fi
    else
        echo -e "${red}已取消...${plain}"
        if [[ ! -f "/usr/local/s-ui/db/s-ui.db" ]]; then
            local usernameTemp=$(head -c 6 /dev/urandom | base64)
            local passwordTemp=$(head -c 6 /dev/urandom | base64)
            echo -e "这是全新安装，出于安全考虑将生成随机登录信息："
            echo -e "###############################################"
            echo -e "${green}用户名：${usernameTemp}${plain}"
            echo -e "${green}密码：${passwordTemp}${plain}"
            echo -e "###############################################"
            echo -e "${red}如果忘记登录信息，可以输入 ${green}s-ui${red} 打开配置菜单${plain}"
            /usr/local/s-ui/sui admin -username "${usernameTemp}" -password "${passwordTemp}"
        else
            echo -e "${red}这是升级安装，将保留旧设置；如果忘记登录信息，可以输入 ${green}s-ui${red} 打开配置菜单${plain}"
        fi
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

# ============================================================
# WARP wg0 网络接口配置
# 用途：为 s-ui / sing-box 提供分流出口，需要分流的流量
#       可在 sing-box 出站规则中指定 bind_interface = "wg0"
# ============================================================
setup_warp_interface() {
    echo -e "${yellow}======================================================${plain}"
    echo -e "${yellow}  正在配置 WARP wg0 网络接口（用于后续分流）${plain}"
    echo -e "${yellow}======================================================${plain}"

    local current_arch=$(get_arch)
    local wgcf_bin="/usr/local/bin/wgcf"
    local wgcf_ver="2.2.22"
    local wgcf_url=""

    # 仅支持 amd64 / arm64
    if [ "${current_arch}" = "amd64" ]; then
        wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_amd64"
    elif [ "${current_arch}" = "arm64" ]; then
        wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_ver}/wgcf_${wgcf_ver}_linux_arm64"
    else
        echo -e "${red}当前架构 (${current_arch}) 暂不支持自动配置 WARP，请手动配置 wg0。${plain}"
        return 1
    fi

    # ---------- 1. 下载 wgcf ----------
    echo -e "${yellow}[1/5] 下载 wgcf 工具...${plain}"
    curl -fsSL "${wgcf_url}" -o "${wgcf_bin}"
    if [ ! -f "${wgcf_bin}" ]; then
        echo -e "${red}错误：wgcf 下载失败，请检查服务器能否访问 GitHub。${plain}"
        return 1
    fi
    chmod +x "${wgcf_bin}"

    # ---------- 2. 注册 WARP 账号并生成配置 ----------
    echo -e "${yellow}[2/5] 向 Cloudflare WARP 注册专属账号...${plain}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    (
        cd "${tmp_dir}"
        "${wgcf_bin}" register --accept-tos
        "${wgcf_bin}" generate
    )

    local profile="${tmp_dir}/wgcf-profile.conf"
    if [ ! -f "${profile}" ]; then
        echo -e "${red}错误：未能生成 wgcf-profile.conf，WARP 注册可能失败。${plain}"
        rm -rf "${tmp_dir}"
        return 1
    fi

    # ---------- 3. 写入 /etc/wireguard/wg0.conf ----------
    # 关键：添加 Table = off，避免 wg0 接管全局路由，
    # 保持宿主机默认路由不变，仅作为分流出口使用。
    echo -e "${yellow}[3/5] 写入 /etc/wireguard/wg0.conf（Table=off 模式，不劫持全局路由）...${plain}"
    mkdir -p /etc/wireguard

    # 先建文件并锁权限，再写内容，避免短暂的权限暴露窗口
    install -m 600 /dev/null /etc/wireguard/wg0.conf
    sed '/^\[Interface\]/a Table = off' "${profile}" > /etc/wireguard/wg0.conf

    rm -rf "${tmp_dir}"

    # ---------- 4. 启动 wg0 ----------
    echo -e "${yellow}[4/5] 启动 wg0 接口...${plain}"
    # 若已存在则先关闭
    wg-quick down wg0 &>/dev/null || true
    if wg-quick up wg0; then
        echo -e "${green}wg0 接口已成功拉起！${plain}"
    else
        echo -e "${red}错误：wg0 启动失败，请检查 /etc/wireguard/wg0.conf 内容。${plain}"
        return 1
    fi

    # ---------- 5. 设置开机自启 ----------
    echo -e "${yellow}[5/5] 设置 wg-quick@wg0 开机自启...${plain}"
    systemctl enable wg-quick@wg0

    # ---------- 验证：打印接口状态与 IP ----------
    echo -e "${green}======================================================${plain}"
    echo -e "${green}  WARP wg0 接口配置完成！${plain}"
    echo -e "${green}======================================================${plain}"
    echo -e "接口状态："
    wg show wg0 2>/dev/null || ip link show wg0

    local wg0_ip
    wg0_ip=$(ip -4 addr show wg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -n "${wg0_ip}" ]; then
        echo -e "wg0 分配地址：${green}${wg0_ip}${plain}"
    fi

    echo -e ""
    echo -e "${yellow}【分流使用说明】${plain}"
    echo -e "在 sing-box 出站配置中，对需要走 WARP 的出站节点加入："
    echo -e "  ${green}\"bind_interface\": \"wg0\"${plain}"
    echo -e "示例（直连出站改走 WARP）："
    echo -e '  {'
    echo -e '    "type": "direct",'
    echo -e '    "tag": "warp-out",'
    echo -e '    "bind_interface": "wg0"'
    echo -e '  }'
    echo -e "然后在路由规则中将目标域名/IP 指向 \"warp-out\" 出站即可完成分流。"
    echo -e "${green}======================================================${plain}"
}

install_sui() {
    cd /tmp/

    if [ $# == 0 ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/frankgoing/s-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}获取 s-ui 版本失败，可能是 Github API 限制导致，请稍后重试${plain}"
            exit 1
        fi
        echo -e "已获取 s-ui 最新版本：${last_version}，开始安装..."
        wget -N --no-check-certificate -O /tmp/s-ui-linux-$(get_arch).tar.gz https://github.com/frankgoing/s-ui/releases/download/${last_version}/s-ui-linux-$(get_arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 s-ui 失败，请确认服务器可以访问 Github ${plain}"
            exit 1
        fi
    else
        last_version=$1
        [[ "${last_version}" != v* ]] && last_version="v${last_version}"
        url="https://github.com/frankgoing/s-ui/releases/download/${last_version}/s-ui-linux-$(get_arch).tar.gz"
        echo -e "开始安装 s-ui ${last_version}"
        wget -N --no-check-certificate -O /tmp/s-ui-linux-$(get_arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 s-ui ${last_version} 失败，请检查该版本是否存在${plain}"
            exit 1
        fi
    fi

    if [[ -e /usr/local/s-ui/ ]]; then
        systemctl stop s-ui
    fi

    tar zxvf s-ui-linux-$(get_arch).tar.gz
    rm s-ui-linux-$(get_arch).tar.gz -f

    chmod +x s-ui/sui s-ui/s-ui.sh
    cp s-ui/s-ui.sh /usr/bin/s-ui
    cp -rf s-ui /usr/local/
    cp -f s-ui/*.service /etc/systemd/system/
    rm -rf s-ui

    prepare_services
    config_after_install

    systemctl enable s-ui --now

    # 配置 WARP wg0 分流接口
    setup_warp_interface

    echo -e "${green}s-ui ${last_version}${plain} 安装完成，现已启动并运行..."
    echo -e "你可以通过以下 URL 访问面板：${green}"
    /usr/local/s-ui/sui uri
    echo -e "${plain}"
    echo -e ""
    s-ui help
}

echo -e "${green}正在执行...${plain}"
install_base
install_sui $1
