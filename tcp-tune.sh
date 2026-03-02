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
LIMITS_FILE="/etc/security/limits.d/99-vps-limits.conf"

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

calc_buffer() {
    local bw=$1; local ram=$2; local factor=$3
    local raw=$(( bw * factor * 131072 ))
    [ "$raw" -lt 4194304 ] && raw=4194304
    [ "$ram" -le 1024 ] && [ "$raw" -gt 33554432 ] && raw=33554432
    [ "$ram" -le 4096 ] && [ "$raw" -gt 67108864 ] && raw=67108864
    echo "$raw"
}

# ====================================================
# 模块 1: 底层网络核心调优 (v5.0 终极全栈版)
# ====================================================
setup_network() {
    clear
    echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${PURPLE}┃          全栈系统与网络调优 (底层解封)           ┃${NC}"
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

    echo -e "\n${YELLOW}正在精准计算并应用全栈优化配置...${NC}"

    BUFFER_RX_MAX=$(calc_buffer $DL_MBPS $RAM_MB $RTT_FACTOR)
    BUFFER_TX_MAX=$(calc_buffer $UL_MBPS $RAM_MB $RTT_FACTOR)
    CONN_MAX=$(( RAM_MB * 100 )); [ "$CONN_MAX" -lt 65536 ] && CONN_MAX=65536
    Q_SIZE=$(( CORES * 8192 )); [ "$Q_SIZE" -gt 65535 ] && Q_SIZE=65535
    
    # 动态计算文件描述符上限
    FD_MAX=$(( RAM_MB * 256 ))
    [ "$FD_MAX" -lt 1048576 ] && FD_MAX=1048576 # 最低保障 100 万

    # 1. 写入内核配置 (加入 fs.file-max, vm.swappiness, keepalive)
    cat <<EOF > $CONF_FILE
# ====================================================
# VPS 终极调优配置 v5.0
# ====================================================

# [0] 系统级底座解封 (文件句柄与内存调度)
fs.file-max = $FD_MAX
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# [1] 核心基础优化
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384

# [2] 非对称 TCP 缓冲区
net.core.rmem_max = $BUFFER_RX_MAX
net.core.wmem_max = $BUFFER_TX_MAX
net.ipv4.tcp_rmem = 4096 131072 $BUFFER_RX_MAX
net.ipv4.tcp_wmem = 4096 131072 $BUFFER_TX_MAX

# [3] 高并发与资源回收 (加入 Keepalive 优化)
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.nf_conntrack_max = $CONN_MAX
net.netfilter.nf_conntrack_max = $CONN_MAX

# [4] 队列与并发调优
net.core.somaxconn = $Q_SIZE
net.core.netdev_max_backlog = $Q_SIZE
net.ipv4.tcp_max_syn_backlog = $Q_SIZE
EOF

    # 2. 写入文件描述符 Limits 解封配置
    mkdir -p /etc/security/limits.d
    cat <<EOF > $LIMITS_FILE
* soft nofile $FD_MAX
* hard nofile $FD_MAX
root soft nofile $FD_MAX
root hard nofile $FD_MAX
EOF

    # 3. 生效配置
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

    # 立即应用 limits 到当前 shell 会话
    ulimit -n $FD_MAX 2>/dev/null

    echo "${BOLD}${GREEN}✔ 全栈优化已完成！(网络/内存/并发封印均已解除)${NC}"
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
            read -p "  请输入限速值 (单位 Mbps): " rate
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
    echo -e "\n${YELLOW}正在清理所有优化配置...${NC}"
    rm -f $CONF_FILE $SERVICE_FILE $LIMITS_FILE
    systemctl disable vps-net-fix.service >/dev/null 2>&1
    systemctl daemon-reload
    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
    ip route change default via $GATEWAY dev $MAIN_IFACE initcwnd 10 initrwnd 10
    sysctl --system >/dev/null 2>&1
    echo "${GREEN}✔ 卸载成功，系统已彻底恢复原貌。${NC}"
    pause
}

# ====================================================
# 主循环与状态面板
# ====================================================
while true; do
    get_network_info
    clear
    echo "${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${CYAN}┃          VPS 智能全栈调优工具 v5.0 Final         ┃${NC}"
    echo "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    wmem=$(sysctl net.core.wmem_max 2>/dev/null | awk '{print $3}')
    cwnd=$(ip route show | grep default | grep -Po '(?<=initcwnd )\d+')
    tc_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    fd_limit=$(ulimit -n 2>/dev/null)
    
    if [[ -z "$bbr_status" ]]; then
        echo "  ${YELLOW}尚未执行调优，请选择选项 1 开始。${NC}"
    else
        echo -e "  ${BOLD}网络底座${NC} : BBR已开启 | CWND=${PURPLE}${cwnd:-10}${NC} | FD上限=${GREEN}${fd_limit}${NC}"
        echo -e "  ${BOLD}缓冲区大小${NC}: RX ${BLUE}$(( rmem / 1024 / 1024 ))MB${NC} | TX ${BLUE}$(( wmem / 1024 / 1024 ))MB${NC}"
        
        if [[ -n "$tc_info" ]]; then
            rate=$(echo $tc_info | grep -Po '(?<=maxrate )(\S+)')
            echo -e "  ${BOLD}TC 流量限速${NC}: ${GREEN}● 已开启 ($rate)${NC}"
        else
            echo -e "  ${BOLD}TC 流量限速${NC}: ${YELLOW}○ 未开启${NC}"
        fi
    fi
    
    draw_line
    echo -e "  ${BOLD}1)${NC} ${CYAN}执行全栈解封调优${NC} (网络/内存/百万并发)"
    echo -e "  ${BOLD}2)${NC} ${YELLOW}管理 TC 上行限速${NC} (动态微调防断流)"
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
