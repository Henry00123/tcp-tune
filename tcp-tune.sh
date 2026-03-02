#!/bin/bash

# ====================================================
# 颜色定义
# ====================================================
RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
BLUE=$'\e[34m'
PURPLE=$'\e[35m'
CYAN=$'\e[36m'
BOLD=$'\e[1m'
NC=$'\e[0m'

# ====================================================
# 全局变量与前置检查
# ====================================================
[[ $EUID -ne 0 ]] && echo "${RED}错误: 必须以 root 运行!${NC}" && exit 1

CONF_FILE="/etc/sysctl.d/99-vps-tune.conf"
SERVICE_FILE="/etc/systemd/system/vps-net-fix.service"

get_network_info() {
    MAIN_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    GATEWAY=$(ip route | grep default | awk '{print $3}')
}

draw_line() {
    echo "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# ====================================================
# 核心计算逻辑
# ====================================================
calc_buffer() {
    local bw=$1; local ram=$2; local factor=$3
    local raw=$(( bw * factor * 131072 ))
    [ "$raw" -lt 4194304 ] && raw=4194304
    [ "$ram" -le 1024 ] && [ "$raw" -gt 33554432 ] && raw=33554432
    [ "$ram" -le 4096 ] && [ "$raw" -gt 67108864 ] && raw=67108864
    echo "$raw"
}

# ====================================================
# 模块 1: 底层网络核心调优 (带中文注释生成)
# ====================================================
setup_network() {
    clear
    echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${PURPLE}┃             核心网络调优 (缓冲区/并发)           ┃${NC}"
    echo "${BOLD}${PURPLE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    echo "${BOLD}${CYAN}➔ 1. 硬件配置${NC}"
    read -p "   请输入 CPU 核心数: " CORES
    read -p "   请输入物理内存 (MB): " RAM_MB

    echo "${BOLD}${CYAN}➔ 2. 网络带宽${NC}"
    read -p "   请输入下行带宽 (Mbps): " DL_MBPS
    read -p "   请输入上行带宽 (Mbps): " UL_MBPS

    echo "${BOLD}${CYAN}➔ 3. 线路类型${NC}"
    echo "   1) 美欧/长距离 (RTT > 150ms)"
    echo "   2) 亚太/短距离 (RTT < 60ms)"
    read -p "   请选择 [1-2]: " REG_CHOICE
    RTT_FACTOR=3; [[ "$REG_CHOICE" == "2" ]] && RTT_FACTOR=1

    echo -e "\n${YELLOW}正在精准计算并应用带有中文注释的内核配置...${NC}"

    BUFFER_RX_MAX=$(calc_buffer $DL_MBPS $RAM_MB $RTT_FACTOR)
    BUFFER_TX_MAX=$(calc_buffer $UL_MBPS $RAM_MB $RTT_FACTOR)
    CONN_MAX=$(( RAM_MB * 100 )); [ "$CONN_MAX" -lt 65536 ] && CONN_MAX=65536
    Q_SIZE=$(( CORES * 8192 )); [ "$Q_SIZE" -gt 65535 ] && Q_SIZE=65535

    # 写入带有详细中文注释的配置文件
    cat <<EOF > $CONF_FILE
# ====================================================
# VPS 网络调优配置文件 - 智能生成的终极配置
# ====================================================

# [1] 核心基础优化
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384

# [2] 非对称 TCP 缓冲区调优
# 接收最大值 (针对 ${DL_MBPS}M 下行)
net.core.rmem_max = $BUFFER_RX_MAX
# 发送最大值 (针对 ${UL_MBPS}M 上行)
net.core.wmem_max = $BUFFER_TX_MAX
# TCP 读缓冲区: [最小, 默认, 最大]
net.ipv4.tcp_rmem = 4096 131072 $BUFFER_RX_MAX
# TCP 写缓冲区: [最小, 默认, 最大]
net.ipv4.tcp_wmem = 4096 131072 $BUFFER_TX_MAX

# [3] 高并发与资源快速回收
# 扩充临时端口范围，支持更多并发
net.ipv4.ip_local_port_range = 1024 65535
# 允许将处于 TIME_WAIT 状态的端口重新分配
net.ipv4.tcp_tw_reuse = 1
# 缩短断开连接的超时时间，快速释放内存
net.ipv4.tcp_fin_timeout = 15
# 系统同时保持 TIME_WAIT 状态的最大数量
net.ipv4.tcp_max_tw_buckets = 131072
# 缩短已建立连接的空闲检测，清理僵尸连接 (2小时)
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
# 最大连接跟踪数 (依据内存动态分配)
net.nf_conntrack_max = $CONN_MAX
net.netfilter.nf_conntrack_max = $CONN_MAX

# [4] 队列与并发优化 (依据 CPU 核心数加粗水管)
# 系统监听队列上限 (成品连接)
net.core.somaxconn = $Q_SIZE
# 网卡收包队列上限 (待处理物理包)
net.core.netdev_max_backlog = $Q_SIZE
# TCP 半连接队列上限 (握手中连接)
net.ipv4.tcp_max_syn_backlog = $Q_SIZE
EOF

    sysctl --system >/dev/null 2>&1
    get_network_info
    mask=$(printf "%x" $(( (1 << CORES) - 1 )))

    cat <<EOF > $SERVICE_FILE
[Unit]
Description=VPS Network Persistence
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c ' \
    ip route change default via $GATEWAY dev $MAIN_IFACE initcwnd 32 initrwnd 32; \
    for q in /sys/class/net/$MAIN_IFACE/queues/rx-*; do echo $mask > \$q/rps_cpus; done'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vps-net-fix.service >/dev/null 2>&1
    systemctl restart vps-net-fix.service

    echo "${BOLD}${GREEN}✔ 核心网络调优已完成！(中文注释已写入 /etc/sysctl.d/99-vps-tune.conf)${NC}"
    pause
}

# ====================================================
# 模块 2: TC 流量整形单独管理
# ====================================================
manage_tc() {
    get_network_info
    clear
    echo "${BOLD}${YELLOW}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${YELLOW}┃              TC 上行流量限速控制台               ┃${NC}"
    echo "${BOLD}${YELLOW}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo -e "作用：防止 BBR 突发超速导致运营商强制丢包(断流)。\n"
    
    tc_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    if [[ -n "$tc_info" ]]; then
        current_rate=$(echo $tc_info | grep -Po '(?<=maxrate )(\S+)')
        echo -e "当前状态: ${GREEN}● 已开启 ($current_rate)${NC}"
    else
        echo -e "当前状态: ${YELLOW}○ 未开启${NC}"
    fi
    draw_line
    
    echo "  ${BOLD}1)${NC} ${GREEN}开启 / 修改限速${NC}"
    echo "  ${BOLD}2)${NC} ${RED}关闭限速${NC}"
    echo "  ${BOLD}0)${NC} 返回主菜单"
    draw_line
    
    read -p "  请选择操作 [0-2]: " tc_choice
    case $tc_choice in
        1)
            read -p "  请输入限速值 (单位 Mbps，建议为物理带宽的 90%): " rate
            if [[ "$rate" =~ ^[0-9]+$ ]]; then
                tc qdisc replace dev $MAIN_IFACE root fq maxrate ${rate}mbit 2>/dev/null
                echo "${GREEN}✔ TC 限速已成功设置为 ${rate} Mbps！${NC}"
            else
                echo "${RED}错误：请输入纯数字！${NC}"
            fi
            ;;
        2)
            tc qdisc del dev $MAIN_IFACE root 2>/dev/null
            echo "${GREEN}✔ TC 限速已关闭，恢复无限制突发。${NC}"
            ;;
        0) return 0 ;;
        *) echo "${RED}无效选项！${NC}" ;;
    esac
    pause
}

# ====================================================
# 模块 3: 彻底卸载
# ====================================================
uninstall_all() {
    get_network_info
    echo -e "\n${YELLOW}正在清理配置文件...${NC}"
    rm -f $CONF_FILE $SERVICE_FILE
    systemctl disable vps-net-fix.service >/dev/null 2>&1
    systemctl daemon-reload
    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
    ip route change default via $GATEWAY dev $MAIN_IFACE initcwnd 10 initrwnd 10
    sysctl --system >/dev/null 2>&1
    echo "${GREEN}✔ 卸载成功，系统已恢复默认设置。${NC}"
    pause
}

# ====================================================
# 主循环与状态面板
# ====================================================
while true; do
    get_network_info
    clear
    echo "${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${CYAN}┃            VPS 智能网络调优工具 v4.9             ┃${NC}"
    echo "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    wmem=$(sysctl net.core.wmem_max 2>/dev/null | awk '{print $3}')
    cwnd=$(ip route show | grep default | grep -Po '(?<=initcwnd )\d+')
    tc_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    
    if [[ -z "$bbr_status" ]]; then
        echo "  ${YELLOW}尚未执行网络调优，请选择选项 1 开始。${NC}"
    else
        echo -e "  ${BOLD}拥塞算法${NC}    : ${GREEN}${bbr_status}${NC}"
        echo -e "  ${BOLD}核心缓冲区${NC}  : RX ${BLUE}$(( rmem / 1024 / 1024 ))MB${NC} | TX ${BLUE}$(( wmem / 1024 / 1024 ))MB${NC}"
        echo -e "  ${BOLD}初始窗口${NC}    : ${PURPLE}${cwnd:-10}${NC}"
        
        if [[ -n "$tc_info" ]]; then
            rate=$(echo $tc_info | grep -Po '(?<=maxrate )(\S+)')
            echo -e "  ${BOLD}TC 上行限速${NC} : ${GREEN}● 已开启 ($rate)${NC}"
        else
            echo -e "  ${BOLD}TC 上行限速${NC} : ${YELLOW}○ 未开启${NC}"
        fi
    fi
    
    draw_line
    echo -e "  ${BOLD}1)${NC} ${CYAN}执行底层核心网络调优${NC} (非对称缓冲区+多核优化)"
    echo -e "  ${BOLD}2)${NC} ${YELLOW}管理 TC 上行流量限速${NC} (防断流/按需微调)"
    echo -e "  ${BOLD}3)${NC} ${RED}彻底卸载并恢复默认${NC}"
    echo -e "  ${BOLD}0)${NC} 退出脚本"
    draw_line
    
    read -p "  请选择操作 [0-3]: " main_choice
    case $main_choice in
        1) setup_network ;;
        2) manage_tc ;;
        3) uninstall_all ;;
        0) clear; exit 0 ;;
        *) echo "${RED}无效的选项，请重新输入！${NC}"; sleep 1 ;;
    esac
done
