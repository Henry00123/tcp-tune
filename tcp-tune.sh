#!/bin/bash

# ====================================================
# 颜色定义 - 使用 $'\e' 确保所有终端环境下颜色正确显示
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
# 权限检查
# ====================================================
[[ $EUID -ne 0 ]] && echo "${RED}错误: 必须以 root 运行!${NC}" && exit 1

CONF_FILE="/etc/sysctl.d/99-vps-tune.conf"
SERVICE_FILE="/etc/systemd/system/vps-net-fix.service"

# ====================================================
# 核心函数
# ====================================================
get_network_info() {
    MAIN_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    GATEWAY=$(ip route | grep default | awk '{print $3}')
}

draw_line() {
    echo "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

show_status() {
    get_network_info
    clear
    echo "${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${CYAN}┃           VPS 网络调优中心 - 当前状态            ┃${NC}"
    echo "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    bbr_status=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    rmem=$(sysctl net.core.rmem_max | awk '{print $3}')
    wmem=$(sysctl net.core.wmem_max | awk '{print $3}')
    cwnd=$(ip route show | grep default | grep -Po '(?<=initcwnd )\d+')
    tc_info=$(tc qdisc show dev $MAIN_IFACE | grep "maxrate")
    
    # 使用 echo -e 确保变量中的转义字符被解析
    echo -e "  ${BOLD}拥塞控制算法${NC}         : ${GREEN}${bbr_status}${NC}"
    echo -e "  ${BOLD}接收缓冲区 (RX)${NC}      : ${BLUE}$(( rmem / 1024 / 1024 )) MB${NC}"
    echo -e "  ${BOLD}发送缓冲区 (TX)${NC}      : ${BLUE}$(( wmem / 1024 / 1024 )) MB${NC}"
    echo -e "  ${BOLD}初始窗口 (CWND)${NC}      : ${PURPLE}${cwnd:-10}${NC}"
    
    if [[ -n "$tc_info" ]]; then
        rate=$(echo $tc_info | grep -Po '(?<=maxrate )(\S+)')
        echo -e "  ${BOLD}TC 上行限速${NC}          : ${GREEN}● 已开启 ($rate)${NC}"
    else
        echo -e "  ${BOLD}TC 上行限速${NC}          : ${YELLOW}○ 未开启${NC}"
    fi

    if systemctl is-active --quiet vps-net-fix.service; then
        echo -e "  ${BOLD}持久化服务${NC}           : ${GREEN}● 运行中 (重启自动恢复)${NC}"
    else
        echo -e "  ${BOLD}持久化服务${NC}           : ${RED}○ 未激活${NC}"
    fi

    draw_line
    echo -e "  ${BOLD}1)${NC} ${GREEN}退出${NC} | ${BOLD}2)${NC} ${YELLOW}重新配置${NC} | ${BOLD}3)${NC} ${RED}卸载优化${NC}"
    draw_line
    read -p "  请选择操作 [1-3]: " status_choice
    [[ "$status_choice" == "2" ]] && return 0
    [[ "$status_choice" == "3" ]] && uninstall_all && exit 0
    exit 0
}

uninstall_all() {
    get_network_info
    echo "${YELLOW}正在清理配置文件...${NC}"
    rm -f $CONF_FILE $SERVICE_FILE
    systemctl disable vps-net-fix.service >/dev/null 2>&1
    systemctl daemon-reload
    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
    ip route change default via $GATEWAY dev $MAIN_IFACE initcwnd 10 initrwnd 10
    sysctl --system >/dev/null 2>&1
    echo "${GREEN}卸载成功，系统已恢复默认设置。${NC}"
}

calc_buffer() {
    local bw=$1; local ram=$2; local factor=$3
    local raw=$(( bw * factor * 131072 ))
    [ "$raw" -lt 4194304 ] && raw=4194304
    [ "$ram" -le 1024 ] && [ "$raw" -gt 33554432 ] && raw=33554432
    [ "$ram" -le 4096 ] && [ "$raw" -gt 67108864 ] && raw=67108864
    echo "$raw"
}

# --- 启动逻辑 ---
if [ -f "$CONF_FILE" ]; then show_status; fi

clear
echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
echo "${BOLD}${PURPLE}┃          正在进入 VPS 网络优化设置向导           ┃${NC}"
echo "${BOLD}${PURPLE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"

prompt() { echo "${BOLD}${CYAN}➔ $1${NC}"; }

prompt "1. 硬件配置"
read -p "   请输入 CPU 核心数: " CORES
read -p "   请输入物理内存 (MB): " RAM_MB

prompt "2. 网络带宽"
read -p "   请输入下行带宽 (Mbps): " DL_MBPS
read -p "   请输入上行带宽 (Mbps): " UL_MBPS

prompt "3. 线路类型"
echo "   1) 美欧/长距离 (RTT > 150ms)"
echo "   2) 亚太/短距离 (RTT < 60ms)"
read -p "   请选择 [1-2]: " REG_CHOICE
RTT_FACTOR=3; [[ "$REG_CHOICE" == "2" ]] && RTT_FACTOR=1

prompt "4. 流量整形 (TC)"
read -p "   开启 TC 上行限速防丢包? (y/n): " ENABLE_TC
if [[ "$ENABLE_TC" =~ ^[Yy]$ ]]; then
    read -p "   请输入上行限速值 (Mbps): " TC_RATE
fi

# ====================================================
# 执行计算与写入
# ====================================================
echo -e "\n${YELLOW}正在精准计算并应用配置...${NC}"

BUFFER_RX_MAX=$(calc_buffer $DL_MBPS $RAM_MB $RTT_FACTOR)
BUFFER_TX_MAX=$(calc_buffer $UL_MBPS $RAM_MB $RTT_FACTOR)
CONN_MAX=$(( RAM_MB * 100 )); [ "$CONN_MAX" -lt 65536 ] && CONN_MAX=65536
Q_SIZE=$(( CORES * 8192 )); [ "$Q_SIZE" -gt 65535 ] && Q_SIZE=65535

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
# 扩充临时端口范围
net.ipv4.ip_local_port_range = 1024 65535
# 允许将处于 TIME_WAIT 状态的端口重新分配
net.ipv4.tcp_tw_reuse = 1
# 缩短断开连接的超时时间
net.ipv4.tcp_fin_timeout = 15
# 系统同时保持 TIME_WAIT 状态的最大数量
net.ipv4.tcp_max_tw_buckets = 131072
# 缩短已建立连接的空闲检测，清理僵尸连接 (2小时)
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
# 最大连接跟踪数
net.nf_conntrack_max = $CONN_MAX
net.netfilter.nf_conntrack_max = $CONN_MAX

# [4] 队列与并发优化
# 系统监听队列上限
net.core.somaxconn = $Q_SIZE
# 网卡收包队列上限
net.core.netdev_max_backlog = $Q_SIZE
# TCP 半连接队列上限
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

[[ "$ENABLE_TC" =~ ^[Yy]$ ]] && tc qdisc replace dev $MAIN_IFACE root fq maxrate ${TC_RATE}mbit 2>/dev/null

echo -e "\n${BOLD}${GREEN}✔ 配置已成功应用！🚀${NC}\n"
