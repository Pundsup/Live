#!/bin/bash

# =========================================================
#  vProxy Manager - Professional Edition
#  Power by: 0x676e67/vproxy
# =========================================================

# --- 样式与颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 核心配置 ---
SERVICE_FILE="/etc/systemd/system/vproxy.service"
OFFICIAL_SCRIPT="https://raw.githubusercontent.com/0x676e67/vproxy/main/.github/install.sh"
SCRIPT_VER="v3.1"

# --- 基础检查 ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[Error]${PLAIN} 此脚本必须以 root 身份运行！"
    exit 1
fi

# --- 依赖检查 ---
check_dependencies() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}正在安装必要依赖 (curl)...${PLAIN}"
        if [[ -f /etc/debian_version ]]; then
            apt-get update && apt-get install -y curl
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y curl
        fi
    fi
}

# --- 核心工具函数 ---

get_vproxy_path() {
    if [[ -f "/usr/local/bin/vproxy" ]]; then
        VPROXY_BIN="/usr/local/bin/vproxy"
    elif [[ -f "/usr/bin/vproxy" ]]; then
        VPROXY_BIN="/usr/bin/vproxy"
    else
        VPROXY_BIN=""
    fi
}

get_service_info() {
    if [[ -f "${SERVICE_FILE}" ]]; then
        CMD_LINE=$(grep "ExecStart=" ${SERVICE_FILE})
        
        # 提取 绑定地址:端口 (正则匹配 --bind 后的非空内容)
        BIND_FULL=$(echo "$CMD_LINE" | grep -oP '(?<=--bind )\S+')
        if [[ -n "$BIND_FULL" ]]; then
            # 兼容 IPv6 格式 [::]:1080，使用从右边最后一个冒号切割
            CURRENT_IP=${BIND_FULL%:*}
            CURRENT_PORT=${BIND_FULL##*:}
        else
            CURRENT_IP="未知"
            CURRENT_PORT="未知"
        fi

        # 提取模式
        if [[ "$CMD_LINE" == *" auto"* ]]; then
            CURRENT_MODE="AUTO (全协议)"
            CURRENT_MODE_RAW="auto"
            if [[ "$CMD_LINE" == *"--tls-cert"* ]]; then
                CERT_INFO="${GREEN}含证书${PLAIN}"
            else
                CERT_INFO="${YELLOW}无证书${PLAIN}"
            fi
        elif [[ "$CMD_LINE" == *"socks5"* ]]; then
            CURRENT_MODE="SOCKS5"
            CURRENT_MODE_RAW="socks5"
            CERT_INFO=""
        elif [[ "$CMD_LINE" == *"https "* ]] || [[ "$CMD_LINE" == *"https"* ]]; then
            CURRENT_MODE="HTTPS"
            CURRENT_MODE_RAW="https"
            if [[ "$CMD_LINE" == *"--tls-cert"* ]]; then
                CERT_INFO="${GREEN}自定义证书${PLAIN}"
            else
                CERT_INFO="${YELLOW}自签名证书${PLAIN}"
            fi
        elif [[ "$CMD_LINE" == *"http"* ]]; then
            CURRENT_MODE="HTTP"
            CURRENT_MODE_RAW="http"
            CERT_INFO=""
        else
            CURRENT_MODE="未知"
            CURRENT_MODE_RAW=""
            CERT_INFO=""
        fi
        
        # 提取认证信息
        CURRENT_USER=$(echo "$CMD_LINE" | grep -oP '(?<=-u )\S+')
        CURRENT_PASS=$(echo "$CMD_LINE" | grep -oP '(?<=-p )\S+')

        if [[ -n "$CURRENT_USER" ]]; then
            CURRENT_AUTH="${GREEN}开启${PLAIN}"
        else
            CURRENT_AUTH="${YELLOW}无${PLAIN}"
        fi
    else
        CURRENT_IP="-"
        CURRENT_PORT="-"
        CURRENT_MODE="-"
        CURRENT_AUTH="-"
        CERT_INFO=""
    fi
}

check_status() {
    get_vproxy_path
    if [[ -n "$VPROXY_BIN" ]]; then
        if systemctl is-active --quiet vproxy; then
            STATUS="${GREEN}运行中${PLAIN}"
            STATUS_ICON="${GREEN}●${PLAIN}"
        else
            STATUS="${RED}已停止${PLAIN}"
            STATUS_ICON="${RED}●${PLAIN}"
        fi
        INSTALL_STATUS="${GREEN}已安装${PLAIN}"
        VERSION=$(${VPROXY_BIN} --version 2>/dev/null | awk '{print $2}')
    else
        STATUS="${PLAIN}未检测到服务${PLAIN}"
        STATUS_ICON="${PLAIN}○${PLAIN}"
        INSTALL_STATUS="${RED}未安装${PLAIN}"
        VERSION="N/A"
    fi
    get_service_info
}

view_sys_status() {
    clear
    echo -e "${BLUE}==> 服务详细运行状态 (Systemd)${PLAIN}"
    echo -e "------------------------------------------------"
    systemctl status vproxy --no-pager -l
    echo -e "------------------------------------------------"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

# 测试单个协议的辅助函数
test_protocol() {
    local PROTO=$1
    local URL=$2
    local DESC=$3
    
    echo -e ">> 正在测试 ${DESC} 通道 (${PROTO})..."
    # 使用 -s -k --proxy-insecure 忽略所有证书报错
    local CURL_OPTS="-s -k --proxy-insecure --connect-timeout 5"

    for i in $(seq 1 2); do
        RESULT=$(curl $CURL_OPTS -x "${URL}" https://api4.ipify.org)
        if [[ -z "$RESULT" ]]; then
             echo -e "   [${i}] ${RED}失败 / 超时${PLAIN}"
        else
             echo -e "   [${i}] IP: ${GREEN}${RESULT}${PLAIN}"
        fi
    done
    echo ""
}

run_test() {
    echo -e "${BLUE}==> 开始本机连接测试${PLAIN}"
    get_service_info
    
    if [[ "$STATUS_ICON" == *"RED"* ]] || [[ "$CURRENT_PORT" == "-" ]]; then
        echo -e "${RED}[Error] 服务未运行或未配置，无法测试。${PLAIN}"
        return
    fi

    # 确定本地测试 Host
    if [[ "$CURRENT_IP" == "0.0.0.0" ]] || [[ "$CURRENT_IP" == "[::]" ]]; then
        TEST_HOST="127.0.0.1"
    else
        TEST_HOST="$CURRENT_IP"
    fi
    
    if [[ -n "$CURRENT_USER" ]]; then
        AUTH_PART="${CURRENT_USER}:${CURRENT_PASS}@"
    else
        AUTH_PART=""
    fi

    echo -e "测试目标: ${GREEN}https://api4.ipify.org${PLAIN}"
    echo -e "-----------------------------------------------"

    if [[ "$CURRENT_MODE_RAW" == "auto" ]]; then
        test_protocol "socks5" "socks5://${AUTH_PART}${TEST_HOST}:${CURRENT_PORT}" "SOCKS5"
        test_protocol "http"   "http://${AUTH_PART}${TEST_HOST}:${CURRENT_PORT}"   "HTTP"
    else
        test_protocol "${CURRENT_MODE_RAW}" "${CURRENT_MODE_RAW}://${AUTH_PART}${TEST_HOST}:${CURRENT_PORT}" "${CURRENT_MODE}"
    fi

    echo -e "-----------------------------------------------"
}

# --- 操作逻辑 ---

install_vproxy() {
    check_dependencies
    get_vproxy_path
    
    if [[ -n "$VPROXY_BIN" ]]; then
        echo -e "${BLUE}==>${PLAIN} 检测到 vProxy 已安装，执行自我更新..."
        $VPROXY_BIN self update
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}[Success] vProxy 更新成功！${PLAIN}"
            systemctl restart vproxy
        else
            echo -e "${RED}[Error] 自我更新失败，重试安装...${PLAIN}"
            bash <(curl -fsSL ${OFFICIAL_SCRIPT})
        fi
    else
        echo -e "${BLUE}==>${PLAIN} 开始安装 vProxy..."
        bash <(curl -fsSL ${OFFICIAL_SCRIPT})
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}[Error] 下载或安装失败。${PLAIN}"
            return
        fi
    fi
    
    get_vproxy_path
    if [[ -z "$VPROXY_BIN" ]]; then
        echo -e "${RED}[Error] 未找到二进制文件。${PLAIN}"
        return
    fi
    
    echo -e "${GREEN}[Success]${PLAIN} 核心程序准备就绪: ${VPROXY_BIN}"
    if [[ ! -f "${SERVICE_FILE}" ]]; then
        configure_vproxy
    else
        systemctl restart vproxy
    fi
}

configure_vproxy() {
    get_vproxy_path
    echo -e ""
    echo -e "${BLUE}==> 配置向导${PLAIN}"
    echo -e "-----------------------------------------------"
    
    echo -e "请输入监听地址:"
    echo -e "  - ${GREEN}0.0.0.0${PLAIN} (IPv4 全栈 - 推荐 IPv4 机器)"
    echo -e "  - ${GREEN}[::]${PLAIN}    (IPv6/v4 双栈 - 推荐 IPv6 机器)"
    echo -e "  - ${GREEN}127.0.0.1${PLAIN} (仅限本机)"
    read -p "地址 [默认 [::]]: " INPUT_IP
    # 默认使用 [::] 以支持双栈，如果机器没有 v6，Linux 通常也能兼容
    BIND_IP=${INPUT_IP:-"[::]"}

    read -p "端口 [默认 1080]: " INPUT_PORT
    PORT=${INPUT_PORT:-1080}
    
    echo -e "-----------------------------------------------"
    echo -e "请选择协议模式:"
    echo -e "  1. ${GREEN}SOCKS5${PLAIN}"
    echo -e "  2. ${GREEN}HTTP${PLAIN}"
    echo -e "  3. ${GREEN}HTTPS${PLAIN}"
    echo -e "  4. ${GREEN}AUTO${PLAIN} (智能多路复用)"
    read -p "选项 [1-4] (默认 1): " MODE_OPT
    
    TLS_ARGS=""
    case $MODE_OPT in
        2) MODE="http" ;;
        3) MODE="https" ;;
        4) MODE="auto" ;;
        *) MODE="socks5" ;;
    esac
    
    HAS_CERT="false"
    if [[ "$MODE" == "https" ]] || [[ "$MODE" == "auto" ]]; then
        echo -e "-----------------------------------------------"
        if [[ "$MODE" == "auto" ]]; then
            echo -e "${YELLOW}AUTO 模式证书配置:${PLAIN}"
        else
            echo -e "${YELLOW}HTTPS 模式证书配置:${PLAIN}"
        fi
        
        read -p "是否提供自定义证书? [y/N]: " CERT_CONFIRM
        if [[ "$CERT_CONFIRM" =~ ^[yY]$ ]]; then
            read -p "证书路径 (.pem/crt): " CERT_PATH
            read -p "密钥路径 (.key): " KEY_PATH
            if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
                TLS_ARGS="--tls-cert ${CERT_PATH} --tls-key ${KEY_PATH}"
                HAS_CERT="true"
            else
                echo -e "${RED}错误: 文件未找到！${PLAIN}"
                if [[ "$MODE" == "https" ]]; then
                     echo -e "将回退使用自签名证书。"
                     TLS_ARGS=""
                fi
            fi
        else
            if [[ "$MODE" == "https" ]]; then
                echo -e "${GREEN}使用 vProxy 自动生成的自签名证书。${PLAIN}"
                TLS_ARGS=""
            else
                echo -e "${GREEN}跳过证书 (Auto 模式)。${PLAIN}"
            fi
        fi
    fi
    
    echo -e "-----------------------------------------------"
    read -p "是否开启 用户名/密码 认证? [y/N]: " AUTH_OPT
    AUTH_ARGS=""
    AUTH_STR=""
    USER=""
    PASS=""
    if [[ "$AUTH_OPT" =~ ^[yY]$ ]]; then
        read -p "  > 用户名: " USER
        read -p "  > 密  码: " PASS
        if [[ -n "$USER" && -n "$PASS" ]]; then
            AUTH_ARGS="-u ${USER} -p ${PASS}"
            AUTH_STR="${USER}:${PASS}@"
        fi
    fi

    # 写入 systemd
    cat > ${SERVICE_FILE} <<EOF
[Unit]
Description=vProxy Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${VPROXY_BIN} run --bind ${BIND_IP}:${PORT} ${MODE} ${TLS_ARGS} ${AUTH_ARGS}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vproxy
    systemctl restart vproxy
    
    echo -e "-----------------------------------------------"
    echo -e "${GREEN}[Success] 配置已更新并启动！${PLAIN}"
    
    echo -e ""
    echo -e "${YELLOW}=== 正在获取公网 IP 并生成链接... ===${PLAIN}"
    
    # 尝试获取 IPv4
    PUB_IP_4=$(curl -4 -s --connect-timeout 2 https://api.ipify.org)
    # 尝试获取 IPv6
    PUB_IP_6=$(curl -6 -s --connect-timeout 2 https://api64.ipify.org)
    
    # 辅助函数：打印链接
    print_links() {
        local IP=$1
        local TAG=$2
        
        # 如果是 IPv6，需要加 []
        if [[ "$IP" == *":"* ]]; then
            HOST_IP="[${IP}]"
        else
            HOST_IP="${IP}"
        fi
        
        echo -e "${BLUE}>> 公网 ${TAG} 地址 (${IP}):${PLAIN}"
        
        if [[ "$MODE" == "auto" ]]; then
            echo -e "   SOCKS5: ${GREEN}socks5://${AUTH_STR}${HOST_IP}:${PORT}${PLAIN}"
            echo -e "   HTTP:   ${GREEN}http://${AUTH_STR}${HOST_IP}:${PORT}${PLAIN}"
            echo -e "   HTTPS:  ${GREEN}https://${AUTH_STR}${HOST_IP}:${PORT}${PLAIN}"
        else
            echo -e "   LINK:   ${GREEN}${MODE}://${AUTH_STR}${HOST_IP}:${PORT}${PLAIN}"
        fi
    }

    if [[ -n "$PUB_IP_4" ]]; then
        print_links "$PUB_IP_4" "IPv4"
    fi
    
    if [[ -n "$PUB_IP_6" ]]; then
        echo -e ""
        print_links "$PUB_IP_6" "IPv6"
    fi

    if [[ -z "$PUB_IP_4" && -z "$PUB_IP_6" ]]; then
        echo -e "${RED}无法获取公网 IP，请手动替换 IP。${PLAIN}"
        print_links "YOUR_IP" "Unknown"
    fi
    
    if [[ "$MODE" == "https" && "$HAS_CERT" == "false" ]]; then
        echo -e ""
        echo -e "${YELLOW}提示: 检测到 HTTPS 自签名证书，测试时请加 --proxy-insecure${PLAIN}"
    fi

    echo -e "-----------------------------------------------"
    sleep 2
}

uninstall_vproxy() {
    echo -e "${YELLOW}警告: 即将完全卸载 vProxy。${PLAIN}"
    read -p "确认卸载? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
        systemctl stop vproxy 2>/dev/null
        systemctl disable vproxy 2>/dev/null
        rm -f ${SERVICE_FILE}
        systemctl daemon-reload
        get_vproxy_path
        if [[ -n "$VPROXY_BIN" ]]; then
            $VPROXY_BIN self uninstall
            rm -f "$VPROXY_BIN"
        fi
        echo -e "${GREEN}卸载完成。${PLAIN}"
    fi
}

show_logs() {
    echo -e "${BLUE}==> 服务日志 (Ctrl+C 退出)${PLAIN}"
    journalctl -u vproxy -f
}

show_menu() {
    while true; do
        check_status
        clear
        echo -e "__________________________________________________________________"
        echo -e " "
        echo -e "   ${BOLD}vProxy Management Script${PLAIN}               ${BLUE}Script ${SCRIPT_VER}${PLAIN}"
        echo -e "__________________________________________________________________"
        echo -e " "
        echo -e "   运行状态 : ${STATUS_ICON} ${STATUS}"
        echo -e "   安装状态 : ${INSTALL_STATUS} ${PLAIN}(v${VERSION})${PLAIN}"
        echo -e " "
        echo -e "   监听地址 : ${GREEN}${CURRENT_IP}${PLAIN}"
        echo -e "   监听端口 : ${GREEN}${CURRENT_PORT}${PLAIN}"
        echo -e "   协议模式 : ${GREEN}${CURRENT_MODE}${PLAIN} ${CERT_INFO}   [认证: ${CURRENT_AUTH}]"
        echo -e "__________________________________________________________________"
        echo -e " "
        echo -e "   ${BLUE}1.${PLAIN}  安装 / 更新 vProxy"
        echo -e "   ${BLUE}2.${PLAIN}  卸载 vProxy"
        echo -e " "
        echo -e "   ${BLUE}3.${PLAIN}  修改配置 (IP/端口/协议/用户)"
        echo -e "   ${BLUE}4.${PLAIN}  查看实时日志"
        echo -e " "
        echo -e "   ${BLUE}5.${PLAIN}  启动服务"
        echo -e "   ${BLUE}6.${PLAIN}  停止服务"
        echo -e "   ${BLUE}7.${PLAIN}  重启服务"
        echo -e " "
        echo -e "   ${BLUE}8.${PLAIN}  本机连接测试 (Curl Test)"
        echo -e "   ${BLUE}9.${PLAIN}  查看服务状态 (Systemd Status)"
        echo -e "   ${BLUE}0.${PLAIN}  退出脚本"
        echo -e "__________________________________________________________________"
        echo -e " "
        read -p " 请输入选项 [0-9]: " choice
        
        case $choice in
            1) install_vproxy; read -n 1 -s -r -p "按任意键继续..." ;;
            2) uninstall_vproxy; read -n 1 -s -r -p "按任意键继续..." ;;
            3) configure_vproxy; read -n 1 -s -r -p "按任意键继续..." ;;
            4) show_logs ;;
            5) systemctl start vproxy && echo -e "${GREEN}服务已启动${PLAIN}"; sleep 1 ;;
            6) systemctl stop vproxy && echo -e "${RED}服务已停止${PLAIN}"; sleep 1 ;;
            7) systemctl restart vproxy && echo -e "${GREEN}服务已重启${PLAIN}"; sleep 1 ;;
            8) run_test; read -n 1 -s -r -p "按任意键继续..." ;;
            9) view_sys_status ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu