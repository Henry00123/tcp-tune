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

# [优化版] 动态平滑计算单 Socket 缓冲区
calc_buffer() {
    local bw=$1; local ram=$2; local factor=$3
    
    # 1. 计算理论目标缓冲区大小 (基于 BDP 冗余推算)
    local raw=$(( bw * factor * 131072 ))

    # 2. 动态计算当前物理内存的单 Socket 缓冲区红线 (物理内存的 2.5%)
    local dynamic_max=$(( ram * 26214 ))

    # 3. 设定硬性的绝对下限 (4MB) 和上限 (128MB)
    local absolute_min=4194304
    local absolute_max=134217728

    # 4. 边界约束 (平滑钳制)
    [ "$dynamic_max" -gt "$absolute_max" ] && dynamic_max=$absolute_max
    [ "$dynamic_max" -lt "$absolute_min" ] && dynamic_max=$absolute_min

    if [ "$raw" -gt "$dynamic_max" ]; then
        raw=$dynamic_max
    elif [ "$raw" -lt "$absolute_min" ]; then
        raw=$absolute_min
    fi

    echo "$raw"
}

# ====================================================
# 模块 1: 底层网络核心调优 (v5.2 加入 UDP 专项)
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
    
    # TCP与UDP的共享内存红线 (25%物理内存)
    PAGES_PER_MB=256
    MEM_MAX=$(( RAM_MB * PAGES_PER_MB * 25 / 100 ))
    MEM_MID=$(( MEM_MAX * 3 / 4 ))
    MEM_MIN=$(( MEM_MAX / 2 ))

    FD_MAX=$(( RAM_MB * 256 ))
    [ "$FD_MAX" -lt 1048576 ] && FD_MAX=1048576

    cat <<EOF > $CONF_FILE
# ====================================================
# VPS 终极调优配置 v5.2 (TCP/UDP 双协议优化)
# ====================================================

# [0] 系统级底座解封
fs.file-max = $FD_MAX
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# [1] 核心基础优化 (BBR)
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384

# [2] 全局与 TCP 缓冲区 (非对称计算)
net.core.rmem_max = $BUFFER_RX_MAX
net.core.wmem_max = $BUFFER_TX_MAX
# 提升默认缓冲区大小，对不具备自动调优的 UDP 极其重要
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 $BUFFER_RX_MAX
net.ipv4.tcp_wmem = 4096 131072 $BUFFER_TX_MAX
net.ipv4.tcp_mem = $MEM_MIN $MEM_MID $MEM_MAX

# [3] 高并发与资源回收
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# [4] 队列与并发调优
net.core.somaxconn = $Q_SIZE
net.core.netdev_max_backlog = $Q_SIZE
net.ipv4.tcp_max_syn_backlog = $Q_SIZE

# [5] UDP 与 QUIC 专项优化 (为 Hysteria/TUIC 注入灵魂)
# UDP 内存红线池 (与 TCP 独立计算，互不干扰)
net.ipv4.udp_mem = $MEM_MIN $MEM_MID $MEM_MAX
# 提高 UDP Socket 初始分配内存，防止大包瞬间丢弃
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

    mkdir -p /etc/security/limits.d
    cat <<EOF > $LIMITS_FILE
* soft nofile $FD_MAX
* hard nofile $FD_MAX
root soft nofile $FD_MAX
root hard nofile $FD_MAX
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
    ulimit -n $FD_MAX 2>/dev/null

    echo "${BOLD}${GREEN}✔ 全栈优化已完成！(TCP与UDP双协议封印均已解除)${NC}"
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
                
                # 写入独立的自启动服务实现持久化
                cat <<EOF > /etc/systemd/system/vps-tc-limit.service
[Unit]
Description=VPS TC Rate Limit Persistence
After=network-online.target vps-net-fix.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/tc qdisc replace dev $MAIN_IFACE root fq maxrate ${rate}mbit
ExecStop=/sbin/tc qdisc del dev $MAIN_IFACE root

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload >/dev/null 2>&1
                systemctl enable vps-tc-limit.service >/dev/null 2>&1
                
                echo "${GREEN}✔ TC 限速已成功设置为 ${rate} Mbps (已加入开机自启)！${NC}"
            else
                echo "${RED}错误：请输入纯数字！${NC}"
            fi
            ;;
        2)
            tc qdisc del dev $MAIN_IFACE root 2>/dev/null
            
            # 关闭并清理自启服务
            systemctl disable vps-tc-limit.service >/dev/null 2>&1
            rm -f /etc/systemd/system/vps-tc-limit.service
            systemctl daemon-reload >/dev/null 2>&1
            
            echo "${GREEN}✔ TC 限速已关闭，恢复无限制突发，并已移除开机自启。${NC}"
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
    rm -f $CONF_FILE $SERVICE_FILE $LIMITS_FILE /etc/systemd/system/vps-tc-limit.service
    systemctl disable vps-net-fix.service vps-tc-limit.service >/dev/null 2>&1
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
    echo "${BOLD}${CYAN}┃          VPS 智能全栈调优工具 v5.2 Final         ┃${NC}"
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
        echo -e "  ${BOLD}协议底座${NC} : BBR已开启 | CWND=${PURPLE}${cwnd:-10}${NC} | TCP+UDP双擎"
        echo -e "  ${BOLD}高并发池${NC} : FD上限=${GREEN}${fd_limit}${NC} | Keepalive 快速回收"
        echo -e "  ${BOLD}内核缓冲${NC} : RX ${BLUE}$(( rmem / 1024 / 1024 ))MB${NC} | TX ${BLUE}$(( wmem / 1024 / 1024 ))MB${NC}"
        
        if [[ -n "$tc_info" ]]; then
            rate=$(echo $tc_info | grep -Po '(?<=maxrate )(\S+)')
            echo -e "  ${BOLD}TC 限速 ${NC} : ${GREEN}● 已开启 ($rate)${NC}"
        else
            echo -e "  ${BOLD}TC 限速 ${NC} : ${YELLOW}○ 未开启${NC}"
        fi
    fi
    
    draw_line
    echo -e "  ${BOLD}1)${NC} ${CYAN}执行全栈网络调优${NC} (TCP/UDP解封+动态内存优化)"
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
