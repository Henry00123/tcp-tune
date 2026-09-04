#!/bin/bash

# ====================================================
# 颜色定义
# ====================================================
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'
PURPLE=$'\e[35m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

# ====================================================
# 全局变量与前置检查
# ====================================================
[[ $EUID -ne 0 ]] && echo "${RED}错误: 必须以 root 运行!${NC}" && exit 1

CONF_FILE="/etc/sysctl.d/99-vps-tune.conf"
SERVICE_FILE="/etc/systemd/system/vps-net-fix.service"
HELPER_FILE="/usr/local/sbin/vps-net-fix.sh"
LIMITS_FILE="/etc/security/limits.d/99-vps-limits.conf"
NOFILE_DROPIN="/etc/systemd/system.conf.d/99-vps-nofile.conf"
TC_SERVICE_FILE="/etc/systemd/system/vps-tc-limit.service"

SNAPSHOT_DIR="/etc/vps-tune"
SNAPSHOT_FILE="$SNAPSHOT_DIR/original-sysctl.snap"
ROUTE_SNAPSHOT="$SNAPSHOT_DIR/original-route.snap"

# 需要快照/回滚的 sysctl 键（必须与 apply_sysctl_config 写入的键保持一致）
SYSCTL_KEYS=(
    fs.file-max vm.swappiness
    net.ipv4.ip_forward net.core.default_qdisc net.ipv4.tcp_congestion_control
    net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default
    net.core.optmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.ipv4.ip_local_port_range net.ipv4.tcp_fin_timeout net.ipv4.tcp_tw_reuse
    net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
    net.ipv4.tcp_fastopen
    net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog
    net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min
)

get_network_info() {
    MAIN_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    GATEWAY=$(ip route | grep default | awk '{print $3}')
}

draw_line() { echo "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
pause() { echo ""; read -n 1 -s -r -p "按任意键返回主菜单..."; }

# 计算单 Socket 缓冲区（精确对齐 2MB 边界）
calc_buffer() {
    local bw=$1; local ram=$2; local factor=$3
    local block=$(( 2 * 1024 * 1024 ))
    local raw=$(( bw * 131072 * factor / 10 ))
    local dynamic_max=$(( ram * 26214 ))
    local absolute_min=4194304
    local absolute_max=536870912

    [ "$dynamic_max" -gt "$absolute_max" ] && dynamic_max=$absolute_max
    [ "$dynamic_max" -lt "$absolute_min" ] && dynamic_max=$absolute_min

    if [ "$raw" -gt "$dynamic_max" ]; then raw=$dynamic_max
    elif [ "$raw" -lt "$absolute_min" ]; then raw=$absolute_min; fi

    raw=$(( (raw + block / 2) / block * block ))
    [ "$raw" -gt "$absolute_max" ] && raw=$absolute_max
    [ "$raw" -lt "$absolute_min" ] && raw=$absolute_min
    echo "$raw"
}

# 调优前快照原始参数（仅首次，避免二次调优把「已调优值」误存为原始值）
snapshot_params() {
    [ -f "$SNAPSHOT_FILE" ] && return 0
    mkdir -p "$SNAPSHOT_DIR"
    {
        echo "# VPS 调优前原始 sysctl 快照 (自动生成，勿手动编辑)"
        local k v
        for k in "${SYSCTL_KEYS[@]}"; do
            v=$(sysctl -n "$k" 2>/dev/null) || continue
            v=$(echo "$v" | tr -s '\t ' ' ' | sed 's/^ *//;s/ *$//')
            echo "$k = $v"
        done
    } > "$SNAPSHOT_FILE"

    ip -4 route show default | head -1 > "$ROUTE_SNAPSHOT" 2>/dev/null
    echo "${GREEN}✔ 已保存调优前参数快照: ${SNAPSHOT_FILE}${NC}"
}

# 卸载时按快照回滚
restore_params() {
    if [ -f "$SNAPSHOT_FILE" ]; then
        sysctl -p "$SNAPSHOT_FILE" >/dev/null 2>&1
        echo "${GREEN}✔ 已回滚 sysctl 参数至调优前快照。${NC}"
    else
        echo "${YELLOW}⚠ 未找到快照，已删除配置文件；未被快照覆盖的运行值将在重启后回落默认。${NC}"
    fi

    local DEF
    if [ -s "$ROUTE_SNAPSHOT" ]; then
        DEF=$(cat "$ROUTE_SNAPSHOT")
        [ -n "$DEF" ] && ip route change $DEF 2>/dev/null
    else
        DEF=$(ip -4 route show default | head -1)
        [ -n "$DEF" ] && ip route change $DEF initcwnd 10 initrwnd 10 2>/dev/null
    fi
}

# ====================================================
# 模块 1: 底层网络核心调优
# ====================================================
setup_network() {
    clear
    echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${PURPLE}┃            全栈系统与网络调优 (底层解封)         ┃${NC}"
    echo "${BOLD}${PURPLE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"

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

    if [[ ! "$DL_MBPS" =~ ^[0-9]+$ ]] || [[ ! "$UL_MBPS" =~ ^[0-9]+$ ]]; then
        echo "${RED}错误：带宽必须为纯正整数！${NC}"; pause; return 1
    fi

    echo -e "\n${YELLOW}正在精准计算并应用全栈优化配置...${NC}"
    BUFFER_RX_MAX=$(calc_buffer $DL_MBPS $RAM_MB $RTT_FACTOR)
    BUFFER_TX_MAX=$(calc_buffer $UL_MBPS $RAM_MB $RTT_FACTOR)
    apply_sysctl_config "$CORES" "$RAM_MB" "$BUFFER_RX_MAX" "$BUFFER_TX_MAX"
}

# ====================================================
# 模块 2: 手动指定缓冲区大小
# ====================================================
manual_buffer() {
    clear
    echo "${BOLD}${PURPLE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${PURPLE}┃            手动定制内核缓冲区 (2MB倍数对齐)         ┃${NC}"
    echo "${BOLD}${PURPLE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"

    CORES=$(nproc)
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    echo -e "系统硬件检测: CPU核心数 = ${CYAN}$CORES${NC} | 物理内存 = ${CYAN}${RAM_MB}MB${NC}"
    draw_line

    echo "${BOLD}${CYAN}➔ 请输入自定义参数 (有效范围: 4MB - 512MB)${NC}"
    read -p "   请输入接收缓冲区大小 RX Buffer (MB): " rx_mb
    read -p "   请输入发送缓冲区大小 TX Buffer (MB): " tx_mb

    if [[ ! "$rx_mb" =~ ^[0-9]+$ ]] || [[ ! "$tx_mb" =~ ^[0-9]+$ ]]; then
        echo "${RED}错误：请输入纯正整数数字！${NC}"; pause; return 1
    fi

    [[ $((rx_mb % 2)) -ne 0 ]] && rx_mb=$((rx_mb + 1))
    [[ $((tx_mb % 2)) -ne 0 ]] && tx_mb=$((tx_mb + 1))
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

    # 写入任何配置前先快照原始值，供卸载回滚
    snapshot_params

    # 队列深度：随核数放大并设下限，单核也有合理 backlog
    local Q_SIZE=$(( CORES * 8192 ))
    [ "$Q_SIZE" -gt 65535 ] && Q_SIZE=65535
    [ "$Q_SIZE" -lt 8192 ] && Q_SIZE=8192

    # FD 上限随内存缩放，保底 1048576
    local FD_MAX=$(( RAM_MB * 256 ))
    [ "$FD_MAX" -lt 1048576 ] && FD_MAX=1048576

    # 小内存机避免过早 OOM kill 代理进程
    local SWAP=10; [ "$RAM_MB" -lt 2048 ] && SWAP=60

    # UDP/raw 默认缓冲适度，避免打穿 udp_mem 并降低排队延迟
    local UDP_DEF=262144

    cat <<EOF > $CONF_FILE
# ====================================================
# VPS 调优配置 v6.1 (TCP/UDP 双协议 · 内存池交还内核自算 · 支持快照回滚)
# ====================================================

# [0] 系统级底座
fs.file-max = $FD_MAX
vm.swappiness = $SWAP

# [1] BBR + 转发
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# [2] 全局与 TCP 缓冲区（非对称）
#     tcp_mem / udp_mem 刻意不设：内核已按物理内存正确计算，
#     手写会与 rmem_max 冲突或在小内存机上加剧 OOM。
net.core.rmem_max = $BUFFER_RX_MAX
net.core.wmem_max = $BUFFER_TX_MAX
net.core.rmem_default = $UDP_DEF
net.core.wmem_default = $UDP_DEF
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 $BUFFER_RX_MAX
net.ipv4.tcp_wmem = 4096 65536 $BUFFER_TX_MAX

# [3] 连接与资源回收
net.ipv4.tcp_fastopen=3
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 131072
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# [4] 队列与并发
net.core.somaxconn = $Q_SIZE
net.core.netdev_max_backlog = $Q_SIZE
net.ipv4.tcp_max_syn_backlog = $Q_SIZE

# [5] UDP/QUIC 最小缓冲保底
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

    # SSH 会话级 FD（PAM 生效）
    mkdir -p /etc/security/limits.d
    cat <<EOF > $LIMITS_FILE
* soft nofile $FD_MAX
* hard nofile $FD_MAX
root soft nofile $FD_MAX
root hard nofile $FD_MAX
EOF

    # systemd 服务级 FD（PAM 不生效，必须走此 drop-in）
    mkdir -p /etc/systemd/system.conf.d
    cat <<EOF > $NOFILE_DROPIN
[Manager]
DefaultLimitNOFILE=$FD_MAX
EOF

    # 应用 sysctl 并显式暴露未生效参数
    local ERR
    ERR=$(sysctl --system 2>&1 | grep -iE 'error|cannot|unknown key|permission')
    if [ -n "$ERR" ]; then
        echo "${YELLOW}⚠ 以下参数未能生效（内核不支持或被虚拟化限制）:${NC}"
        echo "$ERR"
    fi

    # 持久化：路由 initcwnd + 多核 RPS（helper 运行时自适应）
    write_net_helper
    systemctl daemon-reload
    systemctl daemon-reexec
    systemctl enable vps-net-fix.service >/dev/null 2>&1
    systemctl restart vps-net-fix.service

    echo "${BOLD}${GREEN}✔ 优化配置已成功应用！(内核底座已刷新)${NC}"
    echo "${YELLOW}提示：代理进程需 systemctl restart <服务> 后才会拿到新的 FD 上限。${NC}"
    pause
}

# 生成开机持久化 helper 与 unit
write_net_helper() {
    cat <<'HELPER' > $HELPER_FILE
#!/bin/bash
# 运行时读取当前默认路由与核数，避免网关写死 / 单核开 RPS
IFACE=$(ip -4 route ls | awk '/^default/{print $5; exit}')
[ -z "$IFACE" ] && exit 0

# 仅追加 initcwnd/initrwnd，保留原路由 via/dev/proto/metric/onlink/src 等属性
DEF=$(ip -4 route show default | head -1)
if [ -n "$DEF" ] && ! echo "$DEF" | grep -q initcwnd; then
    ip route change $DEF initcwnd 32 initrwnd 32 2>/dev/null
fi

# RPS 仅在多核时开启；mask 按 32 位分组生成，兼容 >32 核
CORES=$(nproc)
if [ "$CORES" -gt 1 ]; then
    MASK=""; c=$CORES
    while [ $c -gt 0 ]; do
        if [ $c -ge 32 ]; then g="ffffffff"; c=$((c-32))
        else g=$(printf "%x" $(( (1<<c)-1 ))); c=0; fi
        [ -z "$MASK" ] && MASK="$g" || MASK="$g,$MASK"
    done
    for q in /sys/class/net/$IFACE/queues/rx-*; do
        [ -w "$q/rps_cpus" ] && echo "$MASK" > "$q/rps_cpus" 2>/dev/null
    done
fi
HELPER
    chmod +x $HELPER_FILE

    cat <<EOF > $SERVICE_FILE
[Unit]
Description=VPS Network Persistence
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER_FILE

[Install]
WantedBy=multi-user.target
EOF
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

    ul_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    if [[ -n "$ul_info" ]]; then
        ul_rate=$(echo "$ul_info" | grep -Po '(?<=maxrate )(\S+)')
        echo -e "当前上行状态: ${GREEN}● 已开启 ($ul_rate)${NC}"
    else
        echo -e "当前上行状态: ${YELLOW}○ 未开启 (无限制)${NC}"
    fi

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
                    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
                    tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null
                    tc qdisc del dev ifb0 root 2>/dev/null
                    systemctl disable vps-tc-limit.service >/dev/null 2>&1
                    rm -f $TC_SERVICE_FILE
                    systemctl daemon-reload >/dev/null 2>&1
                    echo "${GREEN}✔ 检测到双向均为 0，已清除所有限速规则，恢复无限制突发。${NC}"
                else
                    EXEC_START_CMD=""
                    if [[ "$up_rate" -gt 0 ]]; then
                        tc qdisc replace dev $MAIN_IFACE root fq maxrate ${up_rate}mbit 2>/dev/null
                        EXEC_START_CMD="${EXEC_START_CMD}/sbin/tc qdisc replace dev $MAIN_IFACE root fq maxrate ${up_rate}mbit; "
                    else
                        tc qdisc del dev $MAIN_IFACE root 2>/dev/null
                    fi

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
                    echo "${YELLOW}注：下行(ifb)整形对 UDP/QUIC 基本无效，且在低配机上有额外 CPU 开销。${NC}"
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
# 模块 4: 彻底卸载 (按快照回滚)
# ====================================================
uninstall_all() {
    get_network_info
    echo -e "\n${YELLOW}正在清理所有优化配置...${NC}"

    # 1. 删除本工具写入的所有文件
    rm -f $CONF_FILE $SERVICE_FILE $HELPER_FILE $LIMITS_FILE $NOFILE_DROPIN $TC_SERVICE_FILE
    systemctl disable vps-net-fix.service vps-tc-limit.service >/dev/null 2>&1
    systemctl daemon-reload
    systemctl daemon-reexec

    # 2. 清理 TC 队列规则
    tc qdisc del dev $MAIN_IFACE root 2>/dev/null
    tc qdisc del dev $MAIN_IFACE ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set dev ifb0 down 2>/dev/null

    # 3. 按快照回滚运行中的内核参数与默认路由
    restore_params

    # 4. 快照已消费，删除以便下次调优重新记录纯净状态
    rm -f "$SNAPSHOT_FILE" "$ROUTE_SNAPSHOT"
    rmdir "$SNAPSHOT_DIR" 2>/dev/null

    echo "${GREEN}✔ 卸载成功，参数已回滚至调优前状态。${NC}"
    pause
}

# ====================================================
# 主循环与状态面板
# ====================================================
while true; do
    get_network_info
    clear
    echo "${BOLD}${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo "${BOLD}${CYAN}┃          VPS 智能全栈调优工具 v6.1 Final         ┃${NC}"
    echo "${BOLD}${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"

    bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    wmem=$(sysctl net.core.wmem_max 2>/dev/null | awk '{print $3}')
    cwnd=$(ip route show | grep default | grep -Po '(?<=initcwnd )\d+')
    fd_limit=$(systemctl show -p DefaultLimitNOFILE --value 2>/dev/null)

    ul_info=$(tc qdisc show dev $MAIN_IFACE 2>/dev/null | grep "maxrate")
    dl_info=$(tc qdisc show dev ifb0 2>/dev/null | grep "maxrate")

    if [[ -z "$bbr_status" ]]; then
        echo "  ${YELLOW}尚未执行调优，请选择选项 1 或 2 开始。${NC}"
    else
        echo -e "  ${BOLD}协议底座${NC} : BBR已开启 | CWND=${PURPLE}${cwnd:-10}${NC} | TCP+UDP双擎"
        echo -e "  ${BOLD}高并发池${NC} : 服务FD上限=${GREEN}${fd_limit:-未知}${NC} | Keepalive 快速回收"
        echo -e "  ${BOLD}内核缓冲${NC} : RX ${BLUE}$(( rmem / 1024 / 1024 ))MB${NC} | TX ${BLUE}$(( wmem / 1024 / 1024 ))MB${NC}"

        # 快照状态
        if [ -f "$SNAPSHOT_FILE" ]; then
            echo -e "  ${BOLD}回滚快照${NC} : ${GREEN}● 已备份 (可安全卸载回滚)${NC}"
        else
            echo -e "  ${BOLD}回滚快照${NC} : ${YELLOW}○ 无${NC}"
        fi

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
    echo -e "  ${BOLD}4)${NC} ${RED}彻底卸载并回滚快照${NC}"
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
