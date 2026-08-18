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
TC_SERVICE_FILE="/etc/systemd/system/vps-tc-limit.service"

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

# 计算单 Socket 缓冲区（精确对齐 2MB 边界）
calc_buffer() {
    local bw=$1; local ram=$2; local factor=$3
    local block=$(( 2 * 1024 * 1024 ))  # 2MB 字节基准单位
    
    local raw=$(( bw * 131072 * factor / 10 ))
    local dynamic_max=$(( ram * 26214 ))
    local absolute_min=4194304       # 4MB 保底
    local absolute_max=536870912     # 512MB 封顶

    [ "$dynamic_max" -gt "$absolute_max" ] && dynamic_max=$absolute_max
    [ "$dynamic_max" -lt "$absolute_min" ] && dynamic_max=$absolute_min

    if [ "$raw" -gt "$dynamic_max" ]; then
        raw=$dynamic_max
    elif [ "$raw" -lt "$absolute_min" ]; then
        raw=$absolute_min
    fi

    # 2MB 边界对齐
    raw=$(( (raw + block / 2) / block * block ))
    [ "$raw" -gt "$absolute_max" ] && raw=$absolute_max
    [ "$raw" -lt "$absolute_min" ] && raw=$absolute_min

    echo "$raw"
}

# ====================================================
# 模块 1: 底层网络核心调优 (已实现硬件自动获取)
# ====================================================
setup_network() {
    clear
    echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${PURPLE}┃            全栈系统与网络调优 (底层解封)         ┃${NC}"
    echo "${BOLD}${PURPLE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    # 自动获取硬件基础设施信息
    CORES=$(nproc)
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    
    echo -e "系统硬件检测: CPU核心数 = ${CYAN}$CORES${NC} | 物理内存 = ${CYAN}${RAM_MB}MB${NC}"
    draw_line
    
    echo "${BOLD}${CYAN}➔ 1. 网络带宽${NC}"
    read -p "   请输入下行带宽 (Mbps): " DL_MBPS
    read -p "   请输入上行带宽 (Mbps): " UL_MBPS

    echo -e "\n${BOLD}${CYAN}➔ 2. 线路类型${NC}"
    echo "   1) 美欧/长距离 (RTT > 150ms)"
    echo "   2) 亚太/短距离 (RTT < 60ms)"
    read -p "   请选择 [1-2]: " REG_CHOICE
    RTT_FACTOR=3; [[ "$REG_CHOICE" == "2" ]] && RTT_FACTOR=1

    echo -e "\n${YELLOW}正在精准计算并应用全栈优化配置...${NC}"

    BUFFER_RX_MAX=$(calc_buffer $DL_MBPS $RAM_MB $RTT_FACTOR)
    BUFFER_TX_MAX=$(calc_buffer $UL_MBPS $RAM_MB $RTT_FACTOR)
    
    apply_sysctl_config "$CORES" "$RAM_MB" "$BUFFER_RX_MAX" "$BUFFER_TX_MAX"
}

# ====================================================
# 模块 2: 手动指定缓冲区大小 (2MB倍数自动对齐)
# ====================================================
manual_buffer() {
    clear
    echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${PURPLE}┃            手动定制内核缓冲区 (2MB倍数对齐)         ┃${NC}"
    echo "${BOLD}${PURPLE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    # 自动获取硬件基础设施信息
    CORES=$(nproc)
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    
    echo -e "系统硬件检测: CPU核心数 = ${CYAN}$CORES${NC} | 物理内存 = ${CYAN}${RAM_MB}MB${NC}"
    draw_line
    
    echo "${BOLD}${CYAN}➔ 请输入自定义参数 (有效范围: 4MB - 512MB)${NC}"
    read -p "   请输入接收缓冲区大小 RX Buffer (MB): " rx_mb
    read -p "   请输入发送缓冲区大小 TX Buffer (MB): " tx_mb
    
    if [[ ! "$rx_mb" =~ ^[0-9]+$ ]] || [[ ! "$tx_mb" =~ ^[0-9]+$ ]]; then
        echo "${RED}错误：请输入纯正整数数字！${NC}"
        pause
        return 1
    fi
    
    # 2MB 边界对齐逻辑：奇数自动向上加 1 变成偶数
    [[ $((rx_mb % 2)) -ne 0 ]] && rx_mb=$((rx_mb + 1))
    [[ $((tx_mb % 2)) -ne 0 ]] && tx_mb=$((tx_mb + 1))
    
    # 极端值防御钳制
    [[ $rx_mb -lt 4 ]] && rx_mb=4 && echo "${YELLOW}⚠ RX过小，已触发4MB保底机制${NC}"
    [[ $rx_mb -gt 512 ]] && rx_mb=512 && echo "${YELLOW}⚠ RX过大，已触发512MB封顶机制${NC}"
    [[ $tx_mb -lt 4 ]] && tx_mb=4 && echo "${YELLOW}⚠ TX过小，已触发4MB保底机制${NC}"
    [[ $tx_mb -gt 512 ]] && tx_mb=512 && echo "${YELLOW}⚠ TX过大，已触发512MB封顶机制${NC}"
    
    BUFFER_RX_MAX=$(( rx_mb * 1024 * 1024 ))
    BUFFER_TX_MAX=$(( tx_mb * 1024 * 1024 ))
    
    echo -e "\n${YELLOW}正在精准应用手动配置 (RX: ${rx_mb}MB | TX: ${tx_mb}MB)...${NC}"
    apply_sysctl_config "$CORES" "$RAM_MB" "$BUFFER_RX_MAX" "$BUFFER_TX_MAX"
}

# ====================================================
# 公共配置应用底层引擎
# ====================================================
apply_sysctl_config() {
    local CORES=$1; local RAM_MB=$2; local BUFFER_RX_MAX=$3; local BUFFER_TX_MAX=$4

    CONN_MAX=$(( RAM_MB * 100 )); [ "$CONN_MAX" -lt 65536 ] && CONN_MAX=65536
    Q_SIZE=$(( CORES * 8192 )); [ "$Q_SIZE" -gt 65535 ] && Q_SIZE=65535
    
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
net.ipv4.tcp_notsent_lowat = 16384

# [2] 全局与 TCP 缓冲区 (非对称计算)
net.core.rmem_max = $BUFFER_RX_MAX
net.core.wmem_max = $BUFFER_TX_MAX
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 $BUFFER_RX_MAX
net.ipv4.tcp_wmem = 4096 65536 $BUFFER_TX_MAX
net.ipv4.tcp_mem = $MEM_MIN $MEM_MID $MEM_MAX

# [3] 高并发与资源回收
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 131072
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# [4] 队列与并发调优
net.core.somaxconn = $Q_SIZE
net.core.netdev_max_backlog = $Q_SIZE
net.ipv4.tcp_max_syn_backlog = $Q_SIZE

# [5] UDP 与 QUIC 专项优化
net.ipv4.udp_mem = $MEM_MIN $MEM_MID $MEM_MAX
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

    echo "${BOLD}${GREEN}✔ 优化配置已成功应用！(内核底座已刷新)${NC}"
    pause
}

# ====================================================
# 模块 3: TC 流量整形单独管理 (支持双向分别限速)
# ====================================================
manage_tc() {
    get_network_info
    clear
    echo "${BOLD}${YELLOW}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${YELLOW}┃            TC 上下行流量限速控制台               ┃${NC}"
    echo "${BOLD}${YELLOW}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    
    # 侦测上行状态
    ul_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    if [[ -n "$ul_info" ]]; then
        ul_rate=$(echo "$ul_info" | grep -Po '(?<=maxrate )(\S+)')
        echo -e "当前上行状态: ${GREEN}● 已开启 ($ul_rate)${NC}"
    else
        echo -e "当前上行状态: ${YELLOW}○ 未开启 (无限制)${NC}"
    fi

    # 侦测下行状态 (基于 ifb0 虚拟网卡)
    dl_info=$(tc qdisc show dev ifb0 2>/dev/null | grep "maxrate")
    if [[ -n "$dl_info" ]]; then
        dl_rate=$(echo "$dl_info" | grep -Po '(?<=maxrate )(\S+)')
        echo -e "当前下行状态: ${GREEN}● 已开启 ($dl_rate)${NC}"
    else
        echo -e "当前下行状态: ${YELLOW}○ 未开启 (无限制)${NC}"
    fi
    draw_line
    
    echo "  ${BOLD}1)${NC} ${GREEN}开启 / 修改限速${NC}"
    echo "  ${BOLD}2)${NC} ${RED}关闭全部限速${NC}"
    echo "  ${BOLD}0)${NC} 返回主菜单"
    draw_line
    
    read -p "  请选择操作 [0-2]: " tc_choice
    case $tc_choice in
        1)
            read -p "  请输入【上行】限速值 (单位 Mbps，0表示不限): " up_rate
            read -p "  请输入【下行】限速值 (单位 Mbps，0表示不限): " down_rate
            
            if [[ "$up_rate" =~ ^[0-9]+$ ]] && [[ "$down_rate" =~ ^[0-9]+$ ]]; then
                if [[ "$up_rate" -eq 0 ]] && [[ "$down_rate" -eq 0 ]]; then
                    # 均为 0，等同于彻底卸载限速
                    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
                    tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null
                    tc qdisc del dev ifb0 root 2>/dev/null
                    systemctl disable vps-tc-limit.service >/dev/null 2>&1
                    rm -f $TC_SERVICE_FILE
                    systemctl daemon-reload >/dev/null 2>&1
                    echo "${GREEN}✔ 检测到双向均为 0，已清除所有限速规则，恢复无限制突发。${NC}"
                else
                    # 动态生成启动命令脚本内容
                    EXEC_START_CMD=""
                    
                    # 1. 临时应用并记录【上行】限速
                    if [[ "$up_rate" -gt 0 ]]; then
                        tc qdisc replace dev $MAIN_IFACE root fq maxrate ${up_rate}mbit 2>/dev/null
                        EXEC_START_CMD="${EXEC_START_CMD}/sbin/tc qdisc replace dev $MAIN_IFACE root fq maxrate ${up_rate}mbit; "
                    else
                        tc qdisc del dev $MAIN_IFACE root 2>/dev/null
                    fi
                    
                    # 2. 临时应用并记录【下行】限速 (重定向 ingress 至 ifb0)
                    if [[ "$down_rate" -gt 0 ]]; then
                        modprobe ifb numifbs=1 2>/dev/null
                        ip link set dev ifb0 up 2>/dev/null
                        tc qdisc add dev $MAIN_IFACE handle ffff: ingress 2>/dev/null || true
                        tc filter replace dev $MAIN_IFACE parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null
                        tc qdisc replace dev ifb0 root fq maxrate ${down_rate}mbit 2>/dev/null
                        
                        EXEC_START_CMD="${EXEC_START_CMD}/sbin/modprobe ifb numifbs=1; /sbin/ip link set dev ifb0 up; /sbin/tc qdisc add dev $MAIN_IFACE handle ffff: ingress 2>/dev/null || true; /sbin/tc filter replace dev $MAIN_IFACE parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0; /sbin/tc qdisc replace dev ifb0 root fq maxrate ${down_rate}mbit; "
                    else
                        tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null
                        tc qdisc del dev ifb0 root 2>/dev/null
                    fi
                    
                    EXEC_START_CMD="${EXEC_START_CMD}true"

                    # 3. 写入系统级持久化守护
                    cat <<EOF > $TC_SERVICE_FILE
[Unit]
Description=VPS TC Rate Limit Persistence
After=network-online.target vps-net-fix.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '$EXEC_START_CMD'
ExecStop=/bin/bash -c '/sbin/tc qdisc del dev $MAIN_IFACE root 2>/dev/null; /sbin/tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null; /sbin/tc qdisc del dev ifb0 root 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload >/dev/null 2>&1
                    systemctl enable vps-tc-limit.service >/dev/null 2>&1
                    
                    echo "${GREEN}✔ TC 限速已成功设置！(上行: ${up_rate}Mbps | 下行: ${down_rate}Mbps)${NC}"
                fi
            else
                echo "${RED}错误：请输入纯正整数！${NC}"
            fi
            ;;
        2)
            tc qdisc del dev $MAIN_IFACE root 2>/dev/null
            tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null
            tc qdisc del dev ifb0 root 2>/dev/null
            systemctl disable vps-tc-limit.service >/dev/null 2>&1
            rm -f $TC_SERVICE_FILE
            systemctl daemon-reload >/dev/null 2>&1
            echo "${GREEN}✔ TC 全部限速已关闭，恢复无限制突发。${NC}"
            ;;
        0) return 0 ;;
        *) echo "${RED}无效选项！${NC}" ;;
    esac
    pause
}

# ====================================================
# 模块 4: 彻底卸载
# ====================================================
uninstall_all() {
    get_network_info
    echo -e "\n${YELLOW}正在清理所有优化配置...${NC}"
    
    # 清理文件
    rm -f $CONF_FILE $SERVICE_FILE $LIMITS_FILE $TC_SERVICE_FILE
    systemctl disable vps-net-fix.service vps-tc-limit.service >/dev/null 2>&1
    systemctl daemon-reload
    
    # 卸载所有 tc 队列规则
    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
    tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null 
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set dev ifb0 down 2>/dev/null

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
    fd_limit=$(ulimit -n 2>/dev/null)
    
    # 获取 TC 状态 (上行和下行)
    ul_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    dl_info=$(tc qdisc show dev ifb0 2>/dev/null | grep "maxrate")
    
    if [[ -z "$bbr_status" ]]; then
        echo "  ${YELLOW}尚未执行调优，请选择选项 1 或 2 开始。${NC}"
    else
        echo -e "  ${BOLD}协议底座${NC} : BBR已开启 | CWND=${PURPLE}${cwnd:-10}${NC} | TCP+UDP双擎"
        echo -e "  ${BOLD}高并发池${NC} : FD上限=${GREEN}${fd_limit}${NC} | Keepalive 快速回收"
        echo -e "  ${BOLD}内核缓冲${NC} : RX ${BLUE}$(( rmem / 1024 / 1024 ))MB${NC} | TX ${BLUE}$(( wmem / 1024 / 1024 ))MB${NC}"
        
        # 面板显示 TC 上下行状态
        if [[ -n "$ul_info" ]] || [[ -n "$dl_info" ]]; then
            ul_rate=$(echo "$ul_info" | grep -Po '(?<=maxrate )(\S+)' || echo "无限制")
            dl_rate=$(echo "$dl_info" | grep -Po '(?<=maxrate )(\S+)' || echo "无限制")
            echo -e "  ${BOLD}TC 限速 ${NC} : ${GREEN}● 已开启 (上行: $ul_rate | 下行: $dl_rate)${NC}"
        else
            echo -e "  ${BOLD}TC 限速 ${NC} : ${YELLOW}○ 未开启${NC}"
        fi
    fi
    
    draw_line
    echo -e "  ${BOLD}1)${NC} ${CYAN}执行全栈网络调优${NC} (硬件全自动侦测 + 动态算法)"
    echo -e "  ${BOLD}2)${NC} ${PURPLE}手动定制内核缓冲区${NC} (手动指定MB大小, 2MB对齐)"
    echo -e "  ${BOLD}3)${NC} ${YELLOW}管理 TC 流量限速${NC} (双向独立控制, 防断流)"
    echo -e "  ${BOLD}4)${NC} ${RED}彻底卸载并恢复默认${NC}"
    echo -e "  ${BOLD}0)${NC} 退出脚本"
    draw_line
    
    read -p "  请选择操作 [0-4]: " main_choice
    case $main_choice in
        1) setup_network ;;
        2) manual_buffer ;;
        3) manage_tc ;;
        4) uninstall_all ;;
        0) clear; exit 0 ;;
        *) echo "${RED}无效的选项，请重新输入！${NC}"; sleep 1 ;;
    esac
done
