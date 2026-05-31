#!/usr/bin/env bash
#
# nftables 端口转发管理工具 v1.5
# 交互式管理 DNAT 端口转发规则
# 支持：单端口转发（可重映射）+ 端口范围同范围转发（端口保持不变，1:1）
# 支持：TCP / UDP 分别转发到不同目标（同一端口可拆分协议）
# 支持：每条转发备注、流量统计、在线修改
#

# ============== 常量定义 ==============
CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/port-forward.conf"
BACKUP_DIR="${CONF_DIR}/backups"
MAIN_CONF="/etc/nftables.conf"
SYSCTL_CONF="/etc/sysctl.d/99-nft-forward.conf"
LOG_FILE="/var/log/nft-forward.log"
LOGROTATE_CONF="/etc/logrotate.d/nft-forward"
TABLE_NAME="port_forward"

# ============== 日志函数 ==============
log_action() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ============== 输出辅助（用 printf 避免 echo -e 转义副作用） ==============
info()    { printf '\033[32m[信息]\033[0m %s\n' "$1"; }
warn()    { printf '\033[33m[警告]\033[0m %s\n' "$1"; }
err()     { printf '\033[31m[错误]\033[0m %s\n' "$1"; }

# ============== root 权限检查 ==============
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "此脚本需要 root 权限运行，请使用 sudo 或 root 用户执行。"
        exit 1
    fi
}

# ============== 输入验证 ==============
validate_port() {
    local port="$1"
    # 拒绝非纯数字、前导零（避免 bash 八进制歧义）、空串
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" =~ ^0[0-9] ]]; then
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        return 1
    fi
    return 0
}

# 校验"端口或端口范围"：单端口 N，或范围 N-M（要求 N<=M 且都合法）
validate_port_or_range() {
    local spec="$1"
    if [[ "$spec" == *-* ]]; then
        local start="${spec%%-*}" end="${spec##*-}"
        validate_port "$start" || return 1
        validate_port "$end"   || return 1
        (( start <= end )) || return 1
        return 0
    fi
    validate_port "$spec"
}

# 是否为端口范围（含一个 '-'）
is_range() { [[ "$1" == *-* ]]; }

# nft / firewalld 用 '-' 表示范围；ufw / iptables 用 ':'。统一转换给后者用。
to_colon_range() { printf '%s\n' "${1/-/:}"; }

# ============== 协议辅助 ==============
# RULES 数组格式: "本机端口|协议|目标IP|目标端口|备注"，协议 ∈ {tcp, udp, both}
# both 表示 tcp+udp 转发到同一目标；tcp / udp 表示仅该协议（同一端口可分别指向不同目标）

# 展开为实际写入 nft / 防火墙的协议列表
proto_list() {
    case "$1" in
        both) printf 'tcp udp\n' ;;
        tcp)  printf 'tcp\n' ;;
        udp)  printf 'udp\n' ;;
    esac
}

# 列表 / 确认时的人类可读协议名
proto_display() {
    case "$1" in
        both) printf 'tcp+udp\n' ;;
        *)    printf '%s\n' "$1" ;;
    esac
}

sanitize_remark() {
    local text="$1"
    # 备注保存在 RULES 的管道分隔字段中，因此需要清理控制字符和分隔符。
    text=$(printf '%s' "$text" | sed -E 's/[[:cntrl:]]+/ /g; s/[|]/\//g; s/^[[:space:]]+//; s/[[:space:]]+$//')
    printf '%s\n' "$text"
}

remark_display() {
    if [[ -n "$1" ]]; then
        printf '%s\n' "$1"
    else
        printf -- '-\n'
    fi
}

# 两个协议在 tcp/udp 层面是否存在交集（用于同端口冲突判断）
proto_overlap() {
    local a="$1" b="$2"
    [[ "$a" == "both" || "$b" == "both" || "$a" == "$b" ]]
}

# 两个端口规格（单端口或 N-M 范围）是否重叠
ports_overlap() {
    local a="$1" b="$2"
    local as ae bs be
    if is_range "$a"; then
        as="${a%%-*}"; ae="${a##*-}"
    else
        as="$a"; ae="$a"
    fi
    if is_range "$b"; then
        bs="${b%%-*}"; be="${b##*-}"
    else
        bs="$b"; be="$b"
    fi
    (( as <= be && bs <= ae ))
}

# read_dest 的返回值（用全局变量避免命令替换吞掉交互提示）
DEST_IP=""
DEST_PORT=""
# 读取目标 IP 与目标端口；端口范围则保持同范围。$1=本机端口/范围  $2=提示前缀
read_dest() {
    local lport="$1" label="$2"
    while true; do
        read -rp "请输入${label}目标 IP 地址: " DEST_IP
        if validate_ip "$DEST_IP"; then break; fi
        err "IP 地址格式无效，请重新输入（如 192.168.1.100，不含前导零）。"
    done
    if is_range "$lport"; then
        DEST_PORT="$lport"
    else
        while true; do
            read -rp "请输入${label}目标端口 (1-65535) [默认: ${lport}]: " DEST_PORT
            DEST_PORT="${DEST_PORT:-$lport}"
            if validate_port "$DEST_PORT"; then break; fi
            err "端口无效，请输入 1-65535 之间的数字。"
        done
    fi
}

validate_ip() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    # 拒绝前导零（避免 bash 八进制解析歧义，如 010 != 10）
    if [[ "$ip" =~ (^|\.)0[0-9] ]]; then
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            return 1
        fi
    done
    return 0
}

# ============== 自动获取本机 IP ==============
get_local_ip() {
    local ip
    # 优先取默认路由出口的 IP（最准确：这就是发包时实际使用的源 IP）
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi
    # 回退：取第一个非 lo 接口的 IP
    ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1) || true
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return
    fi
    # 最终回退
    hostname -I 2>/dev/null | awk '{print $1}' || true
}

# ============== 发行版检测 ==============
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

# ============== iptables 可用性检测 ==============
# 不依赖 systemd 服务，而是检测命令是否存在且能读取规则
has_iptables() {
    command -v iptables &>/dev/null && iptables -S &>/dev/null
}

# ============== iptables 规则持久化尝试 ==============
try_persist_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && return 0
    fi
    if command -v iptables-save &>/dev/null; then
        if [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null && return 0
        elif [[ -d /etc/sysconfig ]]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null && return 0
        fi
    fi
    if command -v service &>/dev/null; then
        service iptables save >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ============== 检查目标是否仍被其他规则使用 ==============
# 参数: $1=目标IP  $2=目标端口  $3=要排除的本机端口(即正在删除的那条)
dest_still_used() {
    local check_ip="$1" check_dport="$2" exclude_lport="$3"
    local rule lport proto dip dport remark
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport proto dip dport remark <<< "$rule"
        # 跳过正在删除的那条
        [[ "$lport" == "$exclude_lport" ]] && continue
        # 如果其他规则也指向同一 dest_ip:dport，返回 true
        if [[ "$dip" == "$check_ip" && "$dport" == "$check_dport" ]]; then
            return 0
        fi
    done
    return 1
}

# ============== firewalld / iptables 端口放行 ==============
# 参数: $1=本机监听端口  $2=目标IP  $3=目标端口  $4=协议(both/tcp/udp，默认 both)
firewall_open_port() {
    local lport="$1" dest_ip="$2" dport="$3" proto="${4:-both}"
    # ufw / iptables 的端口范围分隔符是 ':'，firewalld / nft 用 '-'
    local lport_c dport_c p protos
    lport_c="$(to_colon_range "$lport")"
    dport_c="$(to_colon_range "$dport")"
    protos="$(proto_list "$proto")"

    # firewalld 优先：如果 firewalld 在运行，只用 firewall-cmd，不碰 iptables
    # （firewalld 可能以 iptables 为后端，手动插 iptables 规则会被 reload 冲掉）
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        for p in $protos; do
            firewall-cmd --add-port="${lport}/${p}" --permanent >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "已在 firewalld 中放行端口 ${lport} ($(proto_display "$proto"))。"
        log_action "firewalld 放行端口 ${lport}/${proto}"
        return
    fi

    # UFW: Ubuntu 小白最常见的防火墙
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        for p in $protos; do
            # INPUT: 放行进入本机的流量
            ufw allow "${lport_c}/${p}" >/dev/null 2>&1 || true
            # FORWARD: ufw allow 只管 INPUT，转发流量需要 route allow
            ufw route allow proto "$p" to "${dest_ip}" port "${dport_c}" >/dev/null 2>&1 || true
        done
        info "已在 UFW 中放行端口 ${lport} 及转发到 ${dest_ip}:${dport} ($(proto_display "$proto"))。"
        log_action "UFW 放行端口 ${lport}/${proto} 转发到 ${dest_ip}:${dport}"
        return
    fi

    # 无 firewalld / UFW，检测 iptables
    if has_iptables; then
        for p in $protos; do
            # INPUT 链: 放行进入本机的流量（匹配 DNAT 前的本机端口）
            iptables -C INPUT -p "$p" --dport "${lport_c}" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p "$p" --dport "${lport_c}" -j ACCEPT 2>/dev/null || true
            # FORWARD 链: DNAT 后包的目的地已改写为 dest_ip:dport，需按此匹配
            iptables -C FORWARD -d "${dest_ip}" -p "$p" --dport "${dport_c}" -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -d "${dest_ip}" -p "$p" --dport "${dport_c}" -j ACCEPT 2>/dev/null || true
        done
        # FORWARD 链: 放行回程已建立连接的包（DNAT 转发场景标配）
        iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        info "已在 iptables 中放行: INPUT ${lport}, FORWARD → ${dest_ip}:${dport} ($(proto_display "$proto"))。"
        log_action "iptables 放行 INPUT:${lport} FORWARD:${dest_ip}:${dport} (${proto})"
        if ! try_persist_iptables; then
            warn "iptables 规则已生效但未能自动持久化，重启后可能丢失。"
            warn "如需持久化请安装 iptables-persistent / netfilter-persistent。"
        fi
    fi
}

# 参数: $1=本机监听端口  $2=目标IP  $3=目标端口  $4=协议(both/tcp/udp，默认 both)
#       $5=是否跳过共享检查("force" 表示强制删除)
firewall_close_port() {
    local lport="$1" dest_ip="$2" dport="$3" proto="${4:-both}" force="${5:-}"
    # ufw / iptables 的端口范围分隔符是 ':'，firewalld / nft 用 '-'
    local lport_c dport_c p protos
    lport_c="$(to_colon_range "$lport")"
    dport_c="$(to_colon_range "$dport")"
    protos="$(proto_list "$proto")"

    # firewalld
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        for p in $protos; do
            firewall-cmd --remove-port="${lport}/${p}" --permanent >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
        info "已从 firewalld 中移除端口 ${lport} ($(proto_display "$proto")) 的放行规则。"
        log_action "firewalld 移除端口 ${lport}/${proto}"
        return
    fi

    # UFW（用 yes 管道防止 ufw delete 交互询问卡住脚本）
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        for p in $protos; do
            yes | ufw delete allow "${lport_c}/${p}" >/dev/null 2>&1 || true
        done
        # route 规则按目标匹配，只有在没有其他规则共享同一目标时才删除
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            for p in $protos; do
                yes | ufw route delete allow proto "$p" to "${dest_ip}" port "${dport_c}" >/dev/null 2>&1 || true
            done
        fi
        info "已从 UFW 中移除端口 ${lport} ($(proto_display "$proto")) 的放行规则。"
        log_action "UFW 移除端口 ${lport}/${proto}"
        return
    fi

    # iptables
    if has_iptables; then
        for p in $protos; do
            # INPUT 链: 总是删除（lport+协议 是唯一的）
            iptables -D INPUT -p "$p" --dport "${lport_c}" -j ACCEPT 2>/dev/null || true
        done
        # FORWARD 链: 只有在没有其他规则共享同一 dest_ip:dport 时才删除
        if [[ "$force" == "force" ]] || ! dest_still_used "$dest_ip" "$dport" "$lport"; then
            for p in $protos; do
                iptables -D FORWARD -d "${dest_ip}" -p "$p" --dport "${dport_c}" -j ACCEPT 2>/dev/null || true
            done
        fi
        # 注意: 不删除 ESTABLISHED,RELATED 规则，它是通用规则，其他转发可能还需要
        info "已从 iptables 中移除: INPUT ${lport}, FORWARD → ${dest_ip}:${dport} ($(proto_display "$proto"))。"
        log_action "iptables 移除 INPUT:${lport} FORWARD:${dest_ip}:${dport} (${proto})"
        try_persist_iptables || true
    fi
}

# ============== 端口占用检测（TCP + UDP） ==============
check_port_conflict() {
    local port="$1" proto="${2:-both}"
    local conflict=""
    if [[ "$proto" == "both" || "$proto" == "tcp" ]] && ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
        conflict="TCP"
    fi
    if [[ "$proto" == "both" || "$proto" == "udp" ]] && ss -ulnp 2>/dev/null | grep -qE ":${port}\b"; then
        if [[ -n "$conflict" ]]; then
            conflict="TCP+UDP"
        else
            conflict="UDP"
        fi
    fi
    if [[ -n "$conflict" ]]; then
        warn "本机端口 ${port} 已被其他服务占用（${conflict}）。"
        warn "添加转发后，该端口的外部流量将被转发，本地服务可能无法从外部访问。"
        read -rp "是否仍要继续添加转发规则？[y/N]: " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    return 0
}

# ============== 初始化配置文件结构 ==============
init_conf() {
    mkdir -p "${CONF_DIR}" "${BACKUP_DIR}" 2>/dev/null || {
        err "无法创建配置目录 ${CONF_DIR}，请检查权限。"
        return 1
    }

    # 确保日志文件存在
    touch "${LOG_FILE}" 2>/dev/null || true

    # 创建 logrotate 配置
    if [[ ! -f "${LOGROTATE_CONF}" ]]; then
        cat > "${LOGROTATE_CONF}" <<'LOGROTATE'
/var/log/nft-forward.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
LOGROTATE
    fi

    # 确保主配置存在且包含 include
    if [[ ! -f "${MAIN_CONF}" ]]; then
        # 极简系统可能没有 nftables.conf，创建最小文件确保重启后规则自动加载
        cat > "${MAIN_CONF}" <<'NFTCONF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.conf"
NFTCONF
        info "已创建 ${MAIN_CONF}（系统中不存在该文件）。"
        log_action "创建 ${MAIN_CONF}"
    elif ! grep -qF 'include "/etc/nftables.d/*.conf"' "${MAIN_CONF}" 2>/dev/null; then
        echo 'include "/etc/nftables.d/*.conf"' >> "${MAIN_CONF}"
        info "已在 ${MAIN_CONF} 中添加 include 指令。"
        log_action "在 ${MAIN_CONF} 中添加 include 指令"
    fi

    # 如果转发配置文件不存在，创建初始结构
    if [[ ! -f "${CONF_FILE}" ]]; then
        write_conf_file || return 1
    fi
}

# ============== 写出配置文件（基于当前 RULES 数组） ==============
# RULES 数组格式: "本机端口|协议|目标IP|目标端口|备注"
declare -a RULES=()
declare -A RULE_COUNTER_PACKETS=()
declare -A RULE_COUNTER_BYTES=()
COUNTERS_AVAILABLE=0

format_bytes() {
    local bytes="${1:-0}"
    if (( bytes < 1024 )); then
        printf '%s B\n' "$bytes"
    elif (( bytes < 1048576 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f KiB\n", b / 1024 }'
    elif (( bytes < 1073741824 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f MiB\n", b / 1048576 }'
    elif (( bytes < 1099511627776 )); then
        awk -v b="$bytes" 'BEGIN { printf "%.2f GiB\n", b / 1073741824 }'
    else
        awk -v b="$bytes" 'BEGIN { printf "%.2f TiB\n", b / 1099511627776 }'
    fi
}

rule_counter_key() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"
}

reset_counters() {
    RULE_COUNTER_PACKETS=()
    RULE_COUNTER_BYTES=()
    COUNTERS_AVAILABLE=0
}

add_counter_value() {
    local key="$1" packets="$2" bytes="$3"
    RULE_COUNTER_PACKETS["$key"]=$(( ${RULE_COUNTER_PACKETS["$key"]:-0} + packets ))
    RULE_COUNTER_BYTES["$key"]=$(( ${RULE_COUNTER_BYTES["$key"]:-0} + bytes ))
}

load_counters() {
    reset_counters
    command -v nft &>/dev/null || return

    local nft_output
    if ! nft_output=$(nft list chain ip "${TABLE_NAME}" prerouting 2>/dev/null); then
        return
    fi

    local line p lp packets bytes di dp key
    while IFS= read -r line; do
        # 单端口：tcp dport 8080 counter packets 1 bytes 60 dnat to 10.0.0.2:80
        if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+)[[:space:]]+counter[[:space:]]+packets[[:space:]]+([0-9]+)[[:space:]]+bytes[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+to[[:space:]]+([0-9.]+):([0-9]+) ]]; then
            p="${BASH_REMATCH[1]}"
            lp="${BASH_REMATCH[2]}"
            packets="${BASH_REMATCH[3]}"
            bytes="${BASH_REMATCH[4]}"
            di="${BASH_REMATCH[5]}"
            dp="${BASH_REMATCH[6]}"
            key="$(rule_counter_key "$lp" "$p" "$di" "$dp")"
            add_counter_value "$key" "$packets" "$bytes"
        # 端口范围：tcp dport 30000-30100 counter packets 1 bytes 60 dnat to 10.0.0.2
        elif [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+-[0-9]+)[[:space:]]+counter[[:space:]]+packets[[:space:]]+([0-9]+)[[:space:]]+bytes[[:space:]]+([0-9]+)[[:space:]]+dnat[[:space:]]+to[[:space:]]+([0-9.]+)([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"
            lp="${BASH_REMATCH[2]}"
            packets="${BASH_REMATCH[3]}"
            bytes="${BASH_REMATCH[4]}"
            di="${BASH_REMATCH[5]}"
            dp="$lp"
            key="$(rule_counter_key "$lp" "$p" "$di" "$dp")"
            add_counter_value "$key" "$packets" "$bytes"
        fi
    done <<< "$nft_output"

    COUNTERS_AVAILABLE=1
}

format_rule_stat() {
    local lport="$1" proto="$2" dip="$3" dport="$4"
    if (( ! COUNTERS_AVAILABLE )); then
        printf '未加载\n'
        return
    fi

    local p key packets=0 bytes=0
    for p in $(proto_list "$proto"); do
        key="$(rule_counter_key "$lport" "$p" "$dip" "$dport")"
        packets=$(( packets + ${RULE_COUNTER_PACKETS["$key"]:-0} ))
        bytes=$(( bytes + ${RULE_COUNTER_BYTES["$key"]:-0} ))
    done
    printf '%s/%s包\n' "$(format_bytes "$bytes")" "$packets"
}

config_has_legacy_dnat_without_counter() {
    [[ -f "${CONF_FILE}" ]] || return 1
    grep -Eq '^[[:space:]]*(tcp|udp)[[:space:]]+dport[[:space:]]+[0-9]+(-[0-9]+)?[[:space:]]+dnat[[:space:]]+to' "${CONF_FILE}" 2>/dev/null
}

ensure_counters_enabled() {
    command -v nft &>/dev/null || return
    config_has_legacy_dnat_without_counter || return

    backup_conf
    if write_conf_file && reload_rules; then
        info "已为现有转发规则启用流量统计（counter），统计从现在开始累计。"
        log_action "为现有转发规则启用 counter 统计"
    else
        warn "启用流量统计失败，当前列表仍会显示已有规则。"
    fi
}

print_rules_table() {
    load_counters
    printf "\n\033[1m%-5s %-9s %-15s %-24s %-16s %s\033[0m\n" "序号" "协议" "本机端口/范围" "目标地址" "流量统计" "备注"
    echo "────────────────────────────────────────────────────────────────────────────────"

    local idx=1
    local rule lport proto dip dport remark stat
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport proto dip dport remark <<< "$rule"
        stat="$(format_rule_stat "$lport" "$proto" "$dip" "$dport")"
        printf "%-5s %-9s %-15s -> %-21s %-16s %s\n" \
            "$idx" "$(proto_display "$proto")" "$lport" "${dip}:${dport}" "$stat" "$(remark_display "$remark")"
        ((idx++))
    done
    echo ""
}

load_rules() {
    RULES=()
    if [[ ! -f "${CONF_FILE}" ]]; then
        return
    fi

    # 先把 tcp / udp 的 dnat 行各自收集为 "本机端口|目标IP|目标端口|备注"
    local -a tcp_rules=() udp_rules=()
    local line p lp di dp current_remark=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*转发 ]]; then
            current_remark=""
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*备注:[[:space:]]*(.*)$ ]]; then
            current_remark="$(sanitize_remark "${BASH_REMATCH[1]}")"
            continue
        fi
        # 跳过其他注释行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # 单端口（可重映射）：<proto> dport N [counter ...] dnat to IP:N
        if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+).*dnat[[:space:]]+to[[:space:]]+([0-9.]+):([0-9]+) ]]; then
            p="${BASH_REMATCH[1]}"; lp="${BASH_REMATCH[2]}"; di="${BASH_REMATCH[3]}"; dp="${BASH_REMATCH[4]}"
            if [[ "$p" == "tcp" ]]; then tcp_rules+=("${lp}|${di}|${dp}|${current_remark}"); else udp_rules+=("${lp}|${di}|${dp}|${current_remark}"); fi
        # 端口范围（同范围、端口保持）：<proto> dport N-M [counter ...] dnat to IP（无目标端口）
        elif [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+-[0-9]+).*dnat[[:space:]]+to[[:space:]]+([0-9.]+)([[:space:]]|$) ]]; then
            p="${BASH_REMATCH[1]}"; lp="${BASH_REMATCH[2]}"; di="${BASH_REMATCH[3]}"
            if [[ "$p" == "tcp" ]]; then tcp_rules+=("${lp}|${di}|${lp}|${current_remark}"); else udp_rules+=("${lp}|${di}|${lp}|${current_remark}"); fi
        fi
    done < "${CONF_FILE}"

    # 合并：tcp 与 udp 目标完全相同（同端口、同目标IP、同目标端口）→ both；否则各自独立
    local -a udp_used=()
    local t i match t_remark u_remark remark
    for t in "${tcp_rules[@]}"; do
        IFS='|' read -r lp di dp t_remark <<< "$t"
        match=-1
        for i in "${!udp_rules[@]}"; do
            [[ -n "${udp_used[$i]:-}" ]] && continue
            IFS='|' read -r _ulp _udi _udp u_remark <<< "${udp_rules[$i]}"
            if [[ "$_ulp" == "$lp" && "$_udi" == "$di" && "$_udp" == "$dp" ]]; then match="$i"; break; fi
        done
        if (( match >= 0 )); then
            IFS='|' read -r _ _ _ u_remark <<< "${udp_rules[$match]}"
            remark="${t_remark:-$u_remark}"
            RULES+=("${lp}|both|${di}|${dp}|${remark}")
            udp_used[match]=1
        else
            RULES+=("${lp}|tcp|${di}|${dp}|${t_remark}")
        fi
    done
    # 剩下未配对的 udp 行：仅 udp 转发
    for i in "${!udp_rules[@]}"; do
        [[ -n "${udp_used[$i]:-}" ]] && continue
        IFS='|' read -r lp di dp u_remark <<< "${udp_rules[$i]}"
        RULES+=("${lp}|udp|${di}|${dp}|${u_remark}")
    done
}

write_conf_file() {
    local local_ip
    local_ip=$(get_local_ip)

    if [[ -z "$local_ip" ]]; then
        err "无法获取本机 IP 地址，请检查网络配置。"
        return 1
    fi

    # 先写入临时文件，成功后原子替换，避免写到一半断电导致配置损坏
    local tmp_file="${CONF_FILE}.tmp.$$"

    cat > "${tmp_file}" <<EOF
#!/usr/sbin/nft -f

# --- 本机 IP（自动获取，用于 SNAT 回源）
define LOCAL_IP = ${local_ip}

table ip ${TABLE_NAME} {
    # --- PREROUTING (DNAT) ---
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
EOF

    local rule lport proto dip dport remark p
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport proto dip dport remark <<< "$rule"
        if is_range "$lport"; then
            # 端口范围同范围：不指定目标端口，nft 保持原端口不变（1:1 转发到同范围）
            {
                printf '\n        # 转发(端口范围同范围, %s): 本机:%s -> %s:%s\n' "$proto" "$lport" "$dip" "$lport"
                if [[ -n "$remark" ]]; then
                    printf '        # 备注: %s\n' "$remark"
                fi
                for p in $(proto_list "$proto"); do
                    printf '        %s dport %s counter dnat to %s\n' "$p" "$lport" "$dip"
                done
            } >> "${tmp_file}"
        else
            {
                printf '\n        # 转发(%s): 本机:%s -> %s:%s\n' "$proto" "$lport" "$dip" "$dport"
                if [[ -n "$remark" ]]; then
                    printf '        # 备注: %s\n' "$remark"
                fi
                for p in $(proto_list "$proto"); do
                    printf '        %s dport %s counter dnat to %s:%s\n' "$p" "$lport" "$dip" "$dport"
                done
            } >> "${tmp_file}"
        fi
    done

    cat >> "${tmp_file}" <<EOF
    }

    # --- POSTROUTING (SNAT) ---
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport proto dip dport remark <<< "$rule"
        {
            printf '\n        # 回源(%s): 发往 %s:%s 的已 DNAT 流量, SNAT 为本机 IP\n' "$proto" "$dip" "$dport"
            if [[ -n "$remark" ]]; then
                printf '        # 备注: %s\n' "$remark"
            fi
            for p in $(proto_list "$proto"); do
                printf "        ip daddr %s %s dport %s ct status dnat counter snat to \$LOCAL_IP\n" "$dip" "$p" "$dport"
            done
        } >> "${tmp_file}"
    done

    cat >> "${tmp_file}" <<EOF
    }
}
EOF

    # 原子替换
    mv -f "${tmp_file}" "${CONF_FILE}" 2>/dev/null || {
        err "无法写入配置文件 ${CONF_FILE}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    }
}

# ============== 重新加载规则 ==============
reload_rules() {
    if ! nft -c -f "${CONF_FILE}" >/dev/null 2>&1; then
        err "配置文件语法检查失败，请检查 ${CONF_FILE}"
        return 1
    fi
    nft flush table ip "${TABLE_NAME}" 2>/dev/null || true
    nft delete table ip "${TABLE_NAME}" 2>/dev/null || true
    if ! nft -f "${CONF_FILE}"; then
        err "加载配置文件失败，请检查 ${CONF_FILE}"
        return 1
    fi
    return 0
}

# ============== 备份配置 ==============
backup_conf() {
    if [[ -f "${CONF_FILE}" ]]; then
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        cp "${CONF_FILE}" "${BACKUP_DIR}/port-forward.conf.${ts}" 2>/dev/null || true
    fi
}

# ============== 开启内核参数：仅 IPv4 转发 ==============
enable_ip_forward() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || current="0"
    if [[ "$current" != "1" ]]; then
        if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
            info "已开启 IPv4 转发。"
        else
            warn "无法开启 IPv4 转发，请手动执行: sysctl -w net.ipv4.ip_forward=1"
        fi
    fi

    # 持久化：统一替换所有匹配行为 =1，没有则追加（避免重复项导致后值覆盖前值的误判）
    mkdir -p "$(dirname "${SYSCTL_CONF}")" 2>/dev/null || true
    touch "${SYSCTL_CONF}" 2>/dev/null || true

    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "${SYSCTL_CONF}" 2>/dev/null; then
        sed -i -E 's|^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*|net.ipv4.ip_forward=1|' "${SYSCTL_CONF}" 2>/dev/null || true
    else
        echo "net.ipv4.ip_forward=1" >> "${SYSCTL_CONF}" 2>/dev/null || true
    fi

    # 清理旧版本曾写入本文件的 BBR/fq 项，避免覆盖专用 BBR 优化脚本。
    sed -i -E '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d; /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' "${SYSCTL_CONF}" 2>/dev/null || true

    sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || true
}

# ============== 检测防火墙状态（仅提示） ==============
check_firewall_status() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        info "检测到 firewalld 正在运行，添加转发规则时将自动放行对应端口。"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        info "检测到 UFW 正在运行，添加转发规则时将自动放行对应端口。"
    elif has_iptables; then
        info "检测到 iptables 规则集存在，添加转发规则时将自动放行对应端口。"
    fi
}

# ============== 诊断/自检 ==============
do_diagnose() {
    echo ""
    echo "========================================"
    echo "           诊断 / 自检"
    echo "========================================"

    # 1. IP 转发
    local ip_fwd
    ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || ip_fwd="未知"
    if [[ "$ip_fwd" == "1" ]]; then
        info "IPv4 转发: 已开启"
    else
        err  "IPv4 转发: 未开启 (当前值: ${ip_fwd})"
        echo "  → 修复: 选择菜单【安装 nftables】会自动开启"
    fi

    # 2. nftables 状态
    if command -v nft &>/dev/null; then
        info "nftables: 已安装 ($(nft --version 2>/dev/null || echo '未知版本'))"
    else
        err  "nftables: 未安装"
        echo "  → 修复: 选择菜单【安装 nftables】"
    fi

    local svc_enabled svc_active
    svc_enabled=$(systemctl is-enabled nftables 2>/dev/null) || svc_enabled="unknown"
    svc_active=$(systemctl is-active nftables 2>/dev/null) || svc_active="unknown"

    if [[ "$svc_enabled" == "enabled" ]]; then
        info "nftables 开机启动: 是"
    else
        warn "nftables 开机启动: 否（重启后规则可能丢失）"
        echo "  → 修复: systemctl enable nftables"
    fi

    if [[ "$svc_active" == "active" ]]; then
        info "nftables 服务状态: 运行中"
    else
        warn "nftables 服务状态: 未运行"
        echo "  → 修复: systemctl start nftables"
    fi

    # 3. 转发规则是否加载
    if nft list table ip "${TABLE_NAME}" &>/dev/null; then
        load_rules
        info "转发规则表: 已加载（${#RULES[@]} 条转发规则）"
    else
        warn "转发规则表: 未加载（可能无规则或服务未启动）"
    fi

    # 4. 防火墙检测
    echo ""
    echo "--- 防火墙状态 ---"
    local fw_found=false

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        fw_found=true
        info "firewalld: 活跃"
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qw "active"; then
        fw_found=true
        warn "UFW: 活跃（默认会阻止入站连接，可能影响转发）"
    fi

    if ! $fw_found && has_iptables; then
        fw_found=true
        local fwd_policy
        fwd_policy=$(iptables -S FORWARD 2>/dev/null | grep -- '^-P FORWARD' | awk '{print $3}') || fwd_policy=""
        if [[ "$fwd_policy" == "DROP" || "$fwd_policy" == "REJECT" ]]; then
            warn "iptables FORWARD 默认策略: ${fwd_policy}（可能阻止转发流量）"
        else
            info "iptables FORWARD 默认策略: ${fwd_policy:-ACCEPT}"
        fi
    fi

    if ! $fw_found; then
        info "未检测到活跃的防火墙 (firewalld / UFW / iptables)"
    fi

    # 5. nftables forward 链检测
    echo ""
    echo "--- nftables forward 链 ---"
    local fwd_chains
    fwd_chains=$(nft list chains 2>/dev/null | grep -B1 "hook forward" || true)
    if [[ -n "$fwd_chains" ]]; then
        if echo "$fwd_chains" | grep -qi "drop"; then
            warn "检测到 nftables 存在 forward 链默认策略为 drop"
            echo "  这会阻止所有转发流量，需手动添加放行规则。"
            echo "  查看详情: nft list ruleset | grep -A5 'hook forward'"
        else
            info "nftables forward 链: 未发现 drop 策略"
        fi
    else
        info "未检测到 nftables forward 链（正常，不影响转发）"
    fi

    # 6. 配置持久化
    echo ""
    echo "--- 配置持久化 ---"
    if [[ -f "${MAIN_CONF}" ]]; then
        if grep -qF 'include "/etc/nftables.d/*.conf"' "${MAIN_CONF}" 2>/dev/null; then
            info "主配置 ${MAIN_CONF}: 已包含 include 指令"
        else
            warn "主配置 ${MAIN_CONF}: 缺少 include 指令（重启后规则可能丢失）"
            echo "  → 修复: 选择菜单【安装 nftables】会自动添加"
        fi
    else
        warn "主配置 ${MAIN_CONF}: 不存在（重启后规则可能丢失）"
        echo "  → 修复: 选择菜单【安装 nftables】会自动创建"
    fi

    if [[ -f "${CONF_FILE}" ]]; then
        info "转发配置文件: ${CONF_FILE} 存在"
    else
        info "转发配置文件: 尚未创建（添加首条规则时自动生成）"
    fi

    # 7. 目标连通性测试（可选）
    echo ""
    load_rules
    if [[ ${#RULES[@]} -gt 0 ]]; then
        read -rp "是否测试目标连通性？[y/N]: " test_conn
        if [[ "$test_conn" =~ ^[Yy]$ ]]; then
            local rule lport proto dip dport remark test_port had_range=0
            for rule in "${RULES[@]}"; do
                IFS='|' read -r lport proto dip dport remark <<< "$rule"
                # 仅 UDP 的规则无法用 /dev/tcp 探测，跳过避免误报"不通"
                if [[ "$proto" == "udp" ]]; then
                    printf "  %s:%s (UDP) ... \033[33m跳过（UDP 无法用 TCP 探测）\033[0m\n" "$dip" "$dport"
                    continue
                fi
                # /dev/tcp 只能连单个端口；范围规则取起始端口做采样探测
                if is_range "$dport"; then
                    test_port="${dport%%-*}"
                    had_range=1
                    printf "  测试 %s:%s (TCP，范围只探测起始端口 %s) ... " "$dip" "$dport" "$test_port"
                else
                    test_port="$dport"
                    printf "  测试 %s:%s (TCP) ... " "$dip" "$dport"
                fi
                if timeout 3 bash -c ">/dev/tcp/${dip}/${test_port}" 2>/dev/null; then
                    printf "\033[32m通\033[0m\n"
                else
                    printf "\033[31m不通或超时\033[0m\n"
                fi
            done
            if (( had_range )); then
                echo "  提示：端口范围仅探测了起始端口；若目标未在该端口监听，显示「不通」属正常，"
                echo "        请改用范围内实际在用的业务端口自测（如 nc -vz 目标IP 端口）。"
            fi
        fi
    fi
    echo ""
}

# ====================================================
# 功能 1：安装 nftables
# ====================================================
do_install() {
    echo ""
    if command -v nft &>/dev/null; then
        info "nftables 已安装。"
        nft --version 2>/dev/null || true
        echo ""
        warn "安装将清空所有已有 nftables 配置，由本脚本统一接管。"
        warn "已有的配置文件将被备份（重命名为 .bak）。"
        read -rp "是否继续？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            info "已取消，退出脚本。"
            exit 0
        fi

        # 备份已有配置文件（重命名，不删除）
        local ts
        ts=$(date '+%Y%m%d_%H%M%S')
        if [[ -f "${MAIN_CONF}" ]]; then
            mv "${MAIN_CONF}" "${MAIN_CONF}.bak.${ts}" 2>/dev/null || true
            info "已备份 ${MAIN_CONF} → ${MAIN_CONF}.bak.${ts}"
        fi
        if [[ -d "${CONF_DIR}" ]]; then
            local f
            for f in "${CONF_DIR}"/*.conf; do
                [[ -f "$f" ]] || continue
                mv "$f" "${f}.bak.${ts}" 2>/dev/null || true
                info "已备份 ${f} → ${f}.bak.${ts}"
            done
        fi

        # 清空当前运行中的规则
        nft flush ruleset 2>/dev/null || true
        info "已清空当前 nftables 规则集。"
        log_action "清空已有配置并由脚本接管 (备份时间戳: ${ts})"

        enable_ip_forward
        check_firewall_status
        init_conf

        # 加载主配置（flush + include），验证整条配置链路
        if ! nft -f "${MAIN_CONF}"; then
            err "加载 ${MAIN_CONF} 失败，请检查配置。"
            return
        fi

        # 确保服务开机启动且当前正在运行
        if systemctl enable --now nftables 2>/dev/null; then
            info "已启用 nftables 服务。"
        else
            warn "nftables 服务启用失败，重启后规则可能丢失。"
            warn "请手动执行: systemctl enable --now nftables"
        fi

        info "初始化完成，所有配置已由本脚本接管。"
        return
    fi

    info "未检测到 nftables，准备安装..."
    local pkg_mgr
    pkg_mgr=$(detect_pkg_manager)

    case "$pkg_mgr" in
        apt)
            apt-get update -y && apt-get install -y nftables
            ;;
        dnf)
            dnf install -y nftables
            ;;
        yum)
            yum install -y nftables
            ;;
        pacman)
            pacman -Sy --noconfirm nftables
            ;;
        *)
            err "无法识别包管理器，请手动安装 nftables。"
            return
            ;;
    esac

    if ! command -v nft &>/dev/null; then
        err "安装失败，请手动安装 nftables。"
        return
    fi

    info "nftables 安装成功。"
    nft --version 2>/dev/null || true
    log_action "安装 nftables"

    enable_ip_forward
    check_firewall_status
    init_conf
    # 先写好配置，再启用服务，确保服务启动时直接加载我们的配置
    if systemctl enable --now nftables 2>/dev/null; then
        info "已启用 nftables 服务。"
    else
        warn "nftables 服务启用失败，重启后规则可能丢失。"
        warn "请手动执行: systemctl enable --now nftables"
    fi

    info "安装与初始化完成。"
}

# ====================================================
# 功能 2：查看现有端口转发
# ====================================================
do_list() {
    echo ""
    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则。"
        return
    fi

    ensure_counters_enabled
    print_rules_table
}

# ====================================================
# 功能 3：新增端口转发
# ====================================================
do_add() {
    echo ""
    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    init_conf || return
    enable_ip_forward
    load_rules

    local local_ip
    local_ip=$(get_local_ip)
    if [[ -z "$local_ip" ]]; then
        err "无法获取本机 IP 地址，请检查网络配置。"
        return
    fi

    # 输入本机端口（支持单端口或端口范围 N-M）
    local lport
    while true; do
        read -rp "请输入本机监听端口或范围 (如 8080 或 30000-30100): " lport
        if validate_port_or_range "$lport"; then
            break
        fi
        err "无效，请输入 1-65535 的单端口，或 起-止 范围（起<=止，如 30000-30100）。"
    done

    # 选择转发协议
    echo ""
    echo "请选择转发协议："
    echo "  1) TCP + UDP → 同一目标 (默认)"
    echo "  2) TCP + UDP → 各自不同目标"
    echo "  3) 仅 TCP"
    echo "  4) 仅 UDP"
    local proto_choice proto_mode
    read -rp "请选择 [1-4，默认 1]: " proto_choice
    proto_choice="${proto_choice:-1}"
    case "$proto_choice" in
        1) proto_mode="both" ;;
        2) proto_mode="split" ;;
        3) proto_mode="tcp" ;;
        4) proto_mode="udp" ;;
        *) err "无效选择，已取消。"; return ;;
    esac

    # split（tcp/udp 各自不同目标）在协议占用层面等同于 both，用于冲突与占用检测
    local check_proto="$proto_mode"
    [[ "$proto_mode" == "split" ]] && check_proto="both"

    # 检查端口是否已有协议冲突的转发规则（同端口的 tcp 与 udp 可分别指向不同目标）
    local rule rp rproto
    for rule in "${RULES[@]}"; do
        IFS='|' read -r rp rproto _ _ _ <<< "$rule"
        if ports_overlap "$rp" "$lport" && proto_overlap "$rproto" "$check_proto"; then
            err "本机端口 ${lport} 已存在 $(proto_display "$rproto") 转发规则，与本次冲突，请使用【修改端口转发】调整已有规则。"
            return
        fi
    done

    # 检查端口占用（仅单端口；端口范围逐个检测意义不大，跳过）
    if ! is_range "$lport"; then
        if ! check_port_conflict "$lport" "$check_proto"; then
            info "已取消。"
            return
        fi
    fi

    if is_range "$lport"; then
        info "端口范围转发：将 1:1 转发到目标的同一范围 ${lport}（端口保持不变）。"
    fi

    # 收集目标，构造待添加规则（split 模式生成 tcp / udp 两条独立规则）
    local -a to_add=()
    local remark
    if [[ "$proto_mode" == "split" ]]; then
        read_dest "$lport" "TCP "
        local tcp_ip="$DEST_IP" tcp_port="$DEST_PORT"
        read_dest "$lport" "UDP "
        read -rp "请输入备注（可选，回车跳过）: " remark
        remark="$(sanitize_remark "$remark")"
        to_add+=("${lport}|tcp|${tcp_ip}|${tcp_port}|${remark}")
        to_add+=("${lport}|udp|${DEST_IP}|${DEST_PORT}|${remark}")
    else
        read_dest "$lport" ""
        read -rp "请输入备注（可选，回车跳过）: " remark
        remark="$(sanitize_remark "$remark")"
        to_add+=("${lport}|${proto_mode}|${DEST_IP}|${DEST_PORT}|${remark}")
    fi

    # 确认
    echo ""
    echo "即将添加转发规则:"
    local r lp pr di dp rm
    for r in "${to_add[@]}"; do
        IFS='|' read -r lp pr di dp rm <<< "$r"
        echo "  本机端口 ${lp} ($(proto_display "$pr")) → ${di}:${dp}  备注: $(remark_display "$rm")"
    done
    read -rp "确认添加？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消。"
        return
    fi

    # 备份并写入
    backup_conf
    RULES+=("${to_add[@]}")
    if ! write_conf_file; then
        return
    fi

    if reload_rules; then
        for r in "${to_add[@]}"; do
            IFS='|' read -r lp pr di dp rm <<< "$r"
            firewall_open_port "$lp" "$di" "$dp" "$pr"
            log_action "新增转发: ${lp}/${pr} -> ${di}:${dp} 备注: $(remark_display "$rm")"
        done
        info "转发规则添加成功。"
        info "若转发不通，请使用菜单中的【诊断/自检】排查。"
    else
        err "规则加载失败，请检查配置。"
    fi
}

# ====================================================
# 功能 4：修改端口转发
# ====================================================
do_edit() {
    echo ""
    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则，无需修改。"
        return
    fi

    print_rules_table

    local choice
    read -rp "请输入要修改的序号 (0 取消): " choice

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        info "已取消。"
        return
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
        err "无效的序号。"
        return
    fi

    local selected=$((choice-1))
    local target="${RULES[$selected]}"
    local old_lport old_proto old_dip old_dport old_remark
    IFS='|' read -r old_lport old_proto old_dip old_dport old_remark <<< "$target"

    echo ""
    echo "当前规则:"
    echo "  本机端口 ${old_lport} ($(proto_display "$old_proto")) → ${old_dip}:${old_dport}"
    echo "  备注: $(remark_display "$old_remark")"
    echo ""
    echo "直接回车表示保留当前值。"

    local new_lport
    while true; do
        read -rp "请输入新的本机监听端口或范围 [${old_lport}]: " new_lport
        new_lport="${new_lport:-$old_lport}"
        if validate_port_or_range "$new_lport"; then
            break
        fi
        err "无效，请输入 1-65535 的单端口，或 起-止 范围（起<=止，如 30000-30100）。"
    done

    echo ""
    echo "请选择新的转发协议："
    echo "  1) TCP + UDP"
    echo "  2) 仅 TCP"
    echo "  3) 仅 UDP"
    local default_proto_choice proto_choice new_proto
    case "$old_proto" in
        both) default_proto_choice="1" ;;
        tcp)  default_proto_choice="2" ;;
        udp)  default_proto_choice="3" ;;
    esac
    read -rp "请选择 [1-3，默认 ${default_proto_choice}]: " proto_choice
    proto_choice="${proto_choice:-$default_proto_choice}"
    case "$proto_choice" in
        1) new_proto="both" ;;
        2) new_proto="tcp" ;;
        3) new_proto="udp" ;;
        *) err "无效选择，已取消。"; return ;;
    esac

    local new_dip
    while true; do
        read -rp "请输入新的目标 IP 地址 [${old_dip}]: " new_dip
        new_dip="${new_dip:-$old_dip}"
        if validate_ip "$new_dip"; then
            break
        fi
        err "IP 地址格式无效，请重新输入（如 192.168.1.100，不含前导零）。"
    done

    local new_dport default_dport
    if is_range "$new_lport"; then
        new_dport="$new_lport"
        info "端口范围转发将保持同范围 1:1 转发，目标端口范围为 ${new_dport}。"
    else
        default_dport="$old_dport"
        validate_port "$default_dport" || default_dport="$new_lport"
        while true; do
            read -rp "请输入新的目标端口 (1-65535) [${default_dport}]: " new_dport
            new_dport="${new_dport:-$default_dport}"
            if validate_port "$new_dport"; then
                break
            fi
            err "端口无效，请输入 1-65535 之间的数字。"
        done
    fi

    local new_remark remark_input
    read -rp "请输入新的备注 [当前: $(remark_display "$old_remark")，输入 - 清空]: " remark_input
    if [[ -z "$remark_input" ]]; then
        new_remark="$old_remark"
    elif [[ "$remark_input" == "-" ]]; then
        new_remark=""
    else
        new_remark="$(sanitize_remark "$remark_input")"
    fi

    local i rule rp rproto
    for i in "${!RULES[@]}"; do
        (( i == selected )) && continue
        IFS='|' read -r rp rproto _ _ _ <<< "${RULES[$i]}"
        if ports_overlap "$rp" "$new_lport" && proto_overlap "$rproto" "$new_proto"; then
            err "本机端口 ${new_lport} 与现有规则 ${rp} ($(proto_display "$rproto")) 存在协议冲突，已取消。"
            return
        fi
    done

    if ! is_range "$new_lport" && { [[ "$new_lport" != "$old_lport" ]] || [[ "$new_proto" != "$old_proto" ]]; }; then
        if ! check_port_conflict "$new_lport" "$new_proto"; then
            info "已取消。"
            return
        fi
    fi

    echo ""
    echo "即将修改转发规则:"
    echo "  原: 本机端口 ${old_lport} ($(proto_display "$old_proto")) → ${old_dip}:${old_dport}  备注: $(remark_display "$old_remark")"
    echo "  新: 本机端口 ${new_lport} ($(proto_display "$new_proto")) → ${new_dip}:${new_dport}  备注: $(remark_display "$new_remark")"
    read -rp "确认修改？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消。"
        return
    fi

    backup_conf
    RULES[selected]="${new_lport}|${new_proto}|${new_dip}|${new_dport}|${new_remark}"

    if ! write_conf_file; then
        return
    fi

    if reload_rules; then
        firewall_close_port "$old_lport" "$old_dip" "$old_dport" "$old_proto"
        firewall_open_port "$new_lport" "$new_dip" "$new_dport" "$new_proto"
        info "转发规则修改成功。"
        info "规则重载后，流量统计会从当前规则重新累计。"
        log_action "修改转发: ${old_lport}/${old_proto} -> ${old_dip}:${old_dport} 改为 ${new_lport}/${new_proto} -> ${new_dip}:${new_dport} 备注: $(remark_display "$new_remark")"
    else
        err "规则加载失败，请检查配置。"
    fi
}

# ====================================================
# 功能 5：删除端口转发
# ====================================================
do_delete() {
    echo ""
    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则，无需删除。"
        return
    fi

    # 展示列表
    print_rules_table

    # 选择删除
    local choice
    read -rp "请输入要删除的序号 (0 取消): " choice

    if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
        info "已取消。"
        return
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#RULES[@]} )); then
        err "无效的序号。"
        return
    fi

    local target="${RULES[$((choice-1))]}"
    local lport proto dip dport remark
    IFS='|' read -r lport proto dip dport remark <<< "$target"

    echo "即将删除转发规则:"
    echo "  本机端口 ${lport} ($(proto_display "$proto")) → ${dip}:${dport}"
    echo "  备注: $(remark_display "$remark")"
    read -rp "确认删除？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消。"
        return
    fi

    # 备份并移除
    backup_conf
    unset 'RULES[$((choice-1))]'
    RULES=("${RULES[@]}")

    if ! write_conf_file; then
        return
    fi

    if reload_rules; then
        # nft 规则已成功更新后，再清理防火墙放行（RULES 已移除该条，dest_still_used 能正确判断）
        firewall_close_port "$lport" "$dip" "$dport" "$proto"
        info "转发规则已删除: ${lport} ($(proto_display "$proto")) → ${dip}:${dport}"
        log_action "删除转发: ${lport}/${proto} -> ${dip}:${dport}"
    else
        err "规则加载失败，请检查配置。"
    fi
}

# ====================================================
# 功能 6：一键清空所有转发
# ====================================================
do_clear_all() {
    echo ""
    if ! command -v nft &>/dev/null; then
        err "nftables 未安装，请先选择 [1] 安装。"
        return
    fi

    load_rules

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有端口转发规则，无需清空。"
        return
    fi

    warn "即将清空全部 ${#RULES[@]} 条转发规则！"
    read -rp "确认清空？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消。"
        return
    fi

    backup_conf

    # 先清理所有防火墙规则（清空场景用 force，无需检查共享）
    local rule lport proto dip dport remark
    for rule in "${RULES[@]}"; do
        IFS='|' read -r lport proto dip dport remark <<< "$rule"
        firewall_close_port "$lport" "$dip" "$dport" "$proto" "force"
    done

    RULES=()
    if ! write_conf_file; then
        return
    fi

    if reload_rules; then
        info "所有转发规则已清空。"
        log_action "清空所有转发规则"
    else
        err "规则加载失败，请检查配置。"
    fi
}

# ====================================================
# 主菜单
# ====================================================
main_menu() {
    while true; do
        echo ""
        echo "========================================"
        echo "   nftables 端口转发管理工具 v1.5"
        echo "========================================"
        echo "  1) 安装 nftables"
        echo "  2) 查看现有端口转发 / 流量统计"
        echo "  3) 新增端口转发（单端口 / 范围 / 分协议）"
        echo "  4) 修改端口转发"
        echo "  5) 删除端口转发"
        echo "  6) 一键清空所有转发"
        echo "  7) 诊断/自检"
        echo "  8) 退出"
        echo "========================================"
        read -rp "请选择操作 [1-8]: " choice

        case "$choice" in
            1) do_install ;;
            2) do_list ;;
            3) do_add ;;
            4) do_edit ;;
            5) do_delete ;;
            6) do_clear_all ;;
            7) do_diagnose ;;
            8)
                info "再见！"
                exit 0
                ;;
            *)
                err "无效选择，请输入 1-8。"
                ;;
        esac
    done
}

# ============== 入口 ==============
check_root
main_menu
