#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  KASKAD — Cascading VPN / Proxy Manager
#  Telegram Bot · Live Ping · Monitoring · Alerts · GeoIP · System Stats
#  
# ══════════════════════════════════════════════════════════════

KASKAD_VERSION="2.3"
KASKAD_DIR="/etc/kaskad"
KASKAD_CONF="$KASKAD_DIR/config"
KASKAD_LOG="/var/log/kaskad.log"
MONITOR_DIR="$KASKAD_DIR/monitors"
ALIASES_FILE="$KASKAD_DIR/aliases"
BOT_STATE_DIR="$KASKAD_DIR/bot_state"
BOT_PID_FILE="/var/run/kaskad_bot.pid"
MONITOR_PID_FILE="/var/run/kaskad_monitor.pid"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
BLUE='\033[0;34m'; NC='\033[0m'

IFACE=""
MY_IP=""
BOT_TOKEN=""
BOT_CHAT_ID=""
MENU_STYLE=""

# ─── Config ───────────────────────────────────────────────────

init_config() {
    mkdir -p "$KASKAD_DIR" "$MONITOR_DIR" "$BOT_STATE_DIR"
    touch "$ALIASES_FILE"
    if [ ! -f "$KASKAD_CONF" ]; then
        cat > "$KASKAD_CONF" <<'CONF'
BOT_TOKEN=""
BOT_CHAT_ID=""
MENU_STYLE="inline"
CONF
    fi
    source "$KASKAD_CONF"
}

save_config_val() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$KASKAD_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$KASKAD_CONF"
    else
        echo "${key}=\"${value}\"" >> "$KASKAD_CONF"
    fi
    source "$KASKAD_CONF"
}

# ─── Aliases: IP=name|note|country|isp ────────────────────────

set_alias_full() {
    local ip="$1" name="$2" note="${3:-}" country="${4:-}" isp="${5:-}"
    local val="${name}|${note}|${country}|${isp}"
    if grep -q "^${ip}=" "$ALIASES_FILE" 2>/dev/null; then
        sed -i "s|^${ip}=.*|${ip}=${val}|" "$ALIASES_FILE"
    else
        echo "${ip}=${val}" >> "$ALIASES_FILE"
    fi
}

set_alias() {
    local ip="$1" name="$2"
    local existing
    existing=$(grep "^${ip}=" "$ALIASES_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    local old_note old_country old_isp
    IFS='|' read -r _ old_note old_country old_isp <<< "$existing"
    set_alias_full "$ip" "$name" "${old_note:-}" "${old_country:-}" "${old_isp:-}"
}

set_alias_note() {
    local ip="$1" note="$2"
    local existing
    existing=$(grep "^${ip}=" "$ALIASES_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    local old_name old_note old_country old_isp
    IFS='|' read -r old_name old_note old_country old_isp <<< "$existing"
    set_alias_full "$ip" "${old_name:-}" "$note" "${old_country:-}" "${old_isp:-}"
}

set_alias_geo() {
    local ip="$1" country="$2" isp="$3"
    local existing
    existing=$(grep "^${ip}=" "$ALIASES_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    local old_name old_note old_country old_isp
    IFS='|' read -r old_name old_note old_country old_isp <<< "$existing"
    set_alias_full "$ip" "${old_name:-}" "${old_note:-}" "$country" "$isp"
}

get_alias_field() {
    local ip="$1" field="$2"
    local raw
    raw=$(grep "^${ip}=" "$ALIASES_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    local f_name f_note f_country f_isp
    IFS='|' read -r f_name f_note f_country f_isp <<< "$raw"
    case "$field" in
        name) echo "$f_name" ;; note) echo "$f_note" ;;
        country) echo "$f_country" ;; isp) echo "$f_isp" ;;
        *) echo "$f_name" ;;
    esac
}

get_alias() { get_alias_field "$1" "name"; }

fmt_ip() {
    local ip="$1"
    local name country isp
    name=$(get_alias_field "$ip" "name")
    country=$(get_alias_field "$ip" "country")
    isp=$(get_alias_field "$ip" "isp")
    local result=""
    [ -n "$name" ] && result="${name} " || result=""
    result+="($ip)"
    if [ -n "$country" ] || [ -n "$isp" ]; then
        result+=" "
        [ -n "$country" ] && result+="$country"
        [ -n "$isp" ] && result+=" | $isp"
    fi
    echo "$result"
}

fmt_ip_short() {
    local ip="$1"
    local name
    name=$(get_alias_field "$ip" "name")
    [ -n "$name" ] && echo "$name ($ip)" || echo "$ip"
}

fmt_ip_tg() {
    local ip="$1"
    local name note country isp
    name=$(get_alias_field "$ip" "name")
    note=$(get_alias_field "$ip" "note")
    country=$(get_alias_field "$ip" "country")
    isp=$(get_alias_field "$ip" "isp")
    local result=""
    [ -n "$name" ] && result="<b>$name</b> " || result=""
    result+="<code>$ip</code>"
    if [ -n "$country" ] || [ -n "$isp" ]; then
        result+=" "
        [ -n "$country" ] && result+="$country"
        [ -n "$isp" ] && result+=" | $isp"
    fi
    [ -n "$note" ] && result+="\n  <i>$note</i>"
    echo "$result"
}

# ─── Logging ──────────────────────────────────────────────────

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$KASKAD_LOG"
}

# ─── Validation ───────────────────────────────────────────────

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for o in "${octets[@]}"; do (( o > 255 )) && return 1; done
        return 0
    fi
    return 1
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

read_validated_ip() {
    local prompt="${1:-Введите IP адрес назначения:}"
    while true; do
        echo -e "$prompt"
        read -p "> " _RET_IP
        if validate_ip "$_RET_IP"; then return 0; fi
        echo -e "${RED}Ошибка: некорректный IP-адрес!${NC}"
    done
}

read_validated_port() {
    local prompt="${1:-Введите порт:}"
    while true; do
        echo -e "$prompt"
        read -p "> " _RET_PORT
        if validate_port "$_RET_PORT"; then return 0; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done
}

# ─── GeoIP + Probe ────────────────────────────────────────────

geoip_lookup() {
    local ip="$1"
    curl -s --max-time 5 "http://ip-api.com/json/${ip}?fields=status,country,regionName,city,isp,org" 2>/dev/null
}

probe_server_cli() {
    local ip="$1" port="${2:-}"
    echo -e "\n${CYAN}━━━ Проверка сервера $ip ━━━${NC}"

    echo -e "${YELLOW}[*] GeoIP...${NC}"
    local geo
    geo=$(geoip_lookup "$ip")
    local geo_status geo_country geo_region geo_city geo_isp geo_org
    geo_status=$(echo "$geo" | jq -r '.status // "fail"')
    if [ "$geo_status" = "success" ]; then
        geo_country=$(echo "$geo" | jq -r '.country // ""')
        geo_region=$(echo "$geo" | jq -r '.regionName // ""')
        geo_city=$(echo "$geo" | jq -r '.city // ""')
        geo_isp=$(echo "$geo" | jq -r '.isp // ""')
        geo_org=$(echo "$geo" | jq -r '.org // ""')
        local geo_loc="${geo_country}"
        [ -n "$geo_city" ] && geo_loc+=", ${geo_city}"
        local geo_provider="$geo_isp"
        [ -n "$geo_org" ] && [ "$geo_org" != "$geo_isp" ] && geo_provider+=" ($geo_org)"
        echo -e "  ${WHITE}GeoIP:${NC} ${GREEN}${geo_loc}${NC} | ${CYAN}${geo_provider}${NC}"
        set_alias_geo "$ip" "$geo_country" "$geo_isp"
    else
        echo -e "  ${RED}GeoIP: не удалось определить${NC}"
    fi

    echo -e "${YELLOW}[*] Ping (3x)...${NC}"
    local -a pings=()
    local plost=0
    for n in 1 2 3; do
        local raw method="" ms=""
        raw=$(smart_ping "$ip" 3 "$port")
        if [ -n "$raw" ]; then
            method="${raw%%|*}"; ms="${raw#*|}"
            pings+=("$ms")
            echo -e "  #$n: ${GREEN}${ms}ms${NC} ${CYAN}[$method]${NC}"
        else
            ((plost++))
            echo -e "  #$n: ${RED}timeout${NC} ${WHITE}[ICMP$([ -n "$port" ] && echo "+TCP:$port")]${NC}"
        fi
        [ "$n" -lt 3 ] && sleep 1
    done
    if [ ${#pings[@]} -gt 0 ]; then
        local pavg
        pavg=$(printf '%s\n' "${pings[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
        echo -e "  ${WHITE}Среднее: ${pavg}ms${NC}  Потеряно: $plost/3"
    else
        echo -e "  ${RED}Сервер не отвечает${NC}"
    fi

    echo ""
    local existing_name
    existing_name=$(get_alias "$ip")
    if [ -n "$existing_name" ]; then
        echo -e "Текущее имя: ${GREEN}$existing_name${NC}"
    fi
    echo -e "Введите имя сервера (или Enter — пропустить):"
    read -p "> " _RET_NAME
    [ -n "$_RET_NAME" ] && set_alias "$ip" "$_RET_NAME"

    echo -e "Введите примечание (или Enter — пропустить):"
    read -p "> " _RET_NOTE
    [ -n "$_RET_NOTE" ] && set_alias_note "$ip" "$_RET_NOTE"

    if [ ${#pings[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}━━━ Сервер не ответил ━━━${NC}"
        echo -e "${WHITE}ICMP заблокирован$([ -n "$port" ] && echo " и TCP:$port не удался").${NC}"
        echo ""
        echo -e "${CYAN}Чтобы включить ping на удалённом сервере:${NC}"
        echo -e "  ${WHITE}ssh root@${ip}${NC}"
        echo -e "  ${GREEN}sysctl -w net.ipv4.icmp_echo_ignore_all=0${NC}"
        echo -e "  ${GREEN}echo 'net.ipv4.icmp_echo_ignore_all=0' >> /etc/sysctl.conf${NC}"
        echo -e "  ${GREEN}iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT${NC}"
        echo ""
        read -p "Продолжить добавление? (y/n): " ans
        [[ "$ans" != "y" ]] && return 1
    fi
    return 0
}

probe_server_tg() {
    local ip="$1" port="${2:-}"
    local result=""
    local geo
    geo=$(geoip_lookup "$ip")
    local geo_status
    geo_status=$(echo "$geo" | jq -r '.status // "fail"')
    if [ "$geo_status" = "success" ]; then
        local geo_country geo_city geo_isp geo_org
        geo_country=$(echo "$geo" | jq -r '.country // ""')
        geo_city=$(echo "$geo" | jq -r '.city // ""')
        geo_isp=$(echo "$geo" | jq -r '.isp // ""')
        geo_org=$(echo "$geo" | jq -r '.org // ""')
        local geo_loc="$geo_country"
        [ -n "$geo_city" ] && geo_loc+=", $geo_city"
        result+="🌍 <b>GeoIP:</b> $geo_loc | $geo_isp\n"
        set_alias_geo "$ip" "$geo_country" "$geo_isp"
    fi
    local -a pings=()
    local plost=0
    for n in 1 2 3; do
        local raw method="" ms=""
        raw=$(smart_ping "$ip" 3 "$port")
        if [ -n "$raw" ]; then
            method="${raw%%|*}"; ms="${raw#*|}"
            pings+=("$ms")
            result+="  #$n: ${ms}ms [$method]\n"
        else
            ((plost++))
            result+="  #$n: timeout\n"
        fi
        [ "$n" -lt 3 ] && sleep 1
    done
    if [ ${#pings[@]} -gt 0 ]; then
        local pavg
        pavg=$(printf '%s\n' "${pings[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
        result+="<b>Среднее: ${pavg}ms</b> | Потеряно: $plost/3\n"
    else
        result+="<b>Сервер не ответил</b>\n"
        result+="Включите ping:\n<code>sysctl -w net.ipv4.icmp_echo_ignore_all=0</code>\n"
        result+="<code>iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT</code>\n"
    fi
    echo "$result"
}

# ─── System ───────────────────────────────────────────────────

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"; exit 1
    fi
}

detect_interface() {
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
    [[ -z "$IFACE" ]] && echo -e "${RED}[ERROR] Не удалось определить интерфейс!${NC}" && exit 1
}

get_my_ip() {
    MY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
}

save_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save > /dev/null 2>&1
    elif command -v service &>/dev/null; then
        service iptables save > /dev/null 2>&1
    fi
}

prepare_system() {
    if [ "$(readlink -f "$0" 2>/dev/null)" != "/usr/local/bin/gokaskad" ]; then
        cp -f "$0" "/usr/local/bin/gokaskad"; chmod +x "/usr/local/bin/gokaskad"
    fi
    if grep -qE '^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
        sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    export DEBIAN_FRONTEND=noninteractive
    local need_install=0
    for cmd in iptables jq curl qrencode; do command -v "$cmd" &>/dev/null || need_install=1; done
    dpkg -s iptables-persistent &>/dev/null 2>&1 || need_install=1
    if [ "$need_install" -eq 1 ]; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y iptables-persistent netfilter-persistent qrencode jq curl procps > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y iptables-services jq qrencode curl procps-ng > /dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y iptables-services jq qrencode curl procps-ng > /dev/null 2>&1
        else
            echo -e "${RED}[ERROR] Неподдерживаемый пакетный менеджер!${NC}"; exit 1
        fi
    fi
}

get_system_stats() {
    local cpu_line load_avg mem_info swap_info disk_info uptime_str top_procs cpu_usage
    cpu_line=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")
    load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    mem_info=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%dMB (%.1f%%)", $3, $2, $3/$2*100}')
    swap_info=$(free -m 2>/dev/null | awk '/^Swap:/ {if($2>0) printf "%d/%dMB", $3, $2; else print "N/A"}')
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
    uptime_str=$(uptime -p 2>/dev/null || uptime | sed 's/.*up /up /' | sed 's/,.*load.*//')
    top_procs=$(ps aux --sort=-%cpu 2>/dev/null | head -8 | awk 'NR>1 {printf "%-6s %-4s%% %-4s%% %s\n", $2, $3, $4, $11}')
    cpu_usage=$(awk '/^cpu / {u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; if(t>0) printf "%.1f", u/t*100; else print "0"}' /proc/stat 2>/dev/null)
    local r=""
    r+="<b>📊 Системная информация</b>\n\n"
    r+="<b>Uptime:</b> ${uptime_str}\n"
    r+="<b>CPU:</b> ${cpu_line} ядер | ${cpu_usage}%\n"
    r+="<b>Load:</b> ${load_avg}\n"
    r+="<b>RAM:</b> ${mem_info}\n"
    r+="<b>Swap:</b> ${swap_info}\n"
    r+="<b>Disk /:</b> ${disk_info}\n\n"
    r+="<b>Топ CPU:</b>\n<pre>PID    CPU%  MEM%  CMD\n${top_procs}</pre>"
    echo "$r"
}

# ─── iptables helpers ─────────────────────────────────────────

get_rules_list() {
    iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT" | while read -r line; do
        local port proto dest
        port=$(echo "$line" | sed -n 's/.*--dport \([0-9]*\).*/\1/p')
        proto=$(echo "$line" | sed -n 's/.*-p \([a-z]*\).*/\1/p')
        dest=$(echo "$line" | sed -n 's/.*--to-destination \([0-9.:]*\).*/\1/p')
        [ -n "$port" ] && echo "${proto}|${port}|${dest}"
    done
}

get_target_ips() {
    get_rules_list | awk -F'|' '{split($3,a,":"); print a[1]}' | sort -u
}

get_port_for_ip() {
    local ip="$1"
    get_rules_list | awk -F'|' -v ip="$ip" '{split($3,a,":"); if(a[1]==ip){print a[2]; exit}}'
}

tcp_ping() {
    local ip="$1" port="$2" tout="${3:-3}"
    local raw
    raw=$(curl -so /dev/null -w '%{time_connect}' --max-time "$tout" --connect-timeout "$tout" "http://${ip}:${port}/" 2>/dev/null)
    [ -z "$raw" ] && return 1
    local ms
    ms=$(awk "BEGIN {v=$raw*1000; if(v<0.5) exit 1; printf \"%.2f\", v}" 2>/dev/null) || return 1
    echo "$ms"
}

smart_ping() {
    local ip="$1" tout="${2:-3}" port="${3:-}"
    local ms
    ms=$(ping -c 1 -W "$tout" "$ip" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
    if [ -n "$ms" ]; then echo "ICMP|$ms"; return 0; fi
    [ -z "$port" ] && port=$(get_port_for_ip "$ip")
    [ -z "$port" ] && return 1
    ms=$(tcp_ping "$ip" "$port" "$tout")
    if [ -n "$ms" ]; then echo "TCP:${port}|$ms"; return 0; fi
    return 1
}

remove_rules_for_port() {
    local proto="$1" in_port="$2"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT" | grep -- "--dport ${in_port} " | grep -- "-p ${proto} " | while read -r rule; do
        eval "iptables -t nat -D ${rule#-A }" 2>/dev/null
    done
    iptables -S INPUT 2>/dev/null | grep "kaskad" | grep -- "--dport ${in_port} " | grep -- "-p ${proto} " | while read -r rule; do
        eval "iptables -D ${rule#-A }" 2>/dev/null
    done
    iptables -S FORWARD 2>/dev/null | grep "kaskad" | grep -- "-p ${proto} " | while read -r rule; do
        local rd; rd=$(echo "$rule" | sed -n 's/.*--dport \([0-9]*\).*/\1/p')
        local rs; rs=$(echo "$rule" | sed -n 's/.*--sport \([0-9]*\).*/\1/p')
        [[ "$rd" == "$in_port" || "$rs" == "$in_port" ]] && eval "iptables -D ${rule#-A }" 2>/dev/null
    done
}

apply_iptables_rules() {
    local proto="$1" in_port="$2" out_port="$3" target_ip="$4" name="$5"
    echo -e "${YELLOW}[*] Применение правил...${NC}"
    log_action "ADD rule: $proto :$in_port -> $target_ip:$out_port ($name)"
    remove_rules_for_port "$proto" "$in_port"
    iptables -I INPUT -p "$proto" --dport "$in_port" -m comment --comment "kaskad:${in_port}:${proto}" -j ACCEPT
    iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "$target_ip:$out_port"
    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi
    iptables -I FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" -m state --state NEW,ESTABLISHED,RELATED -m comment --comment "kaskad:${in_port}:${proto}" -j ACCEPT
    iptables -I FORWARD -p "$proto" -s "$target_ip" --sport "$out_port" -m state --state ESTABLISHED,RELATED -m comment --comment "kaskad:${in_port}:${proto}" -j ACCEPT
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$in_port/$proto" > /dev/null 2>&1
    fi
    save_iptables
    echo -e "${GREEN}[SUCCESS] $name настроен!${NC}"
    echo -e "$proto: ${MY_IP:-*}:$in_port -> $target_ip:$out_port"
}

# ─── Interactive rule configuration ──────────────────────────

configure_rule() {
    local proto="$1" name="$2"
    echo -e "\n${CYAN}--- Настройка $name ($proto) ---${NC}"
    read_validated_ip "Введите IP адрес назначения:"
    local target_ip="$_RET_IP"
    read_validated_port "Введите Порт (одинаковый для входа и выхода):"
    local port="$_RET_PORT"
    probe_server_cli "$target_ip" "$port" || return
    echo -e "\n${YELLOW}Будет создано правило:${NC}"
    echo -e "  $proto: ${MY_IP:-*}:$port -> $(fmt_ip_short "$target_ip"):$port"
    read -p "Применить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    apply_iptables_rules "$proto" "$port" "$port" "$target_ip" "$name"
    read -p "Нажмите Enter для возврата в меню..."
}

configure_custom_rule() {
    echo -e "\n${CYAN}--- Универсальное кастомное правило ---${NC}"
    local proto
    while true; do
        echo -e "Выберите протокол (${YELLOW}tcp${NC} или ${YELLOW}udp${NC}):"
        read -p "> " proto
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] && break
        echo -e "${RED}Ошибка: введите tcp или udp!${NC}"
    done
    read_validated_ip "Введите IP адрес назначения:"
    local target_ip="$_RET_IP"
    read_validated_port "Введите ${YELLOW}ВХОДЯЩИЙ Порт${NC} (на этом сервере):"
    local in_port="$_RET_PORT"
    read_validated_port "Введите ${YELLOW}ИСХОДЯЩИЙ Порт${NC} (на конечном сервере):"
    local out_port="$_RET_PORT"
    probe_server_cli "$target_ip" "$out_port" || return
    echo -e "\n${YELLOW}Будет создано правило:${NC}"
    echo -e "  $proto: ${MY_IP:-*}:$in_port -> $(fmt_ip_short "$target_ip"):$out_port"
    read -p "Применить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    apply_iptables_rules "$proto" "$in_port" "$out_port" "$target_ip" "Custom Rule"
    read -p "Нажмите Enter для возврата в меню..."
}

# ─── List / Delete / Flush ────────────────────────────────────

list_active_rules() {
    echo -e "\n${CYAN}━━━ Активные переадресации ━━━${NC}"
    echo -e "${WHITE}Сервер каскада: ${GREEN}${MY_IP:-N/A}${NC}\n"
    local rules
    rules=$(get_rules_list)
    if [ -z "$rules" ]; then
        echo -e "${YELLOW}Нет активных правил.${NC}"
    else
        echo "$rules" | while IFS='|' read -r proto port dest; do
            local dest_ip="${dest%:*}"
            echo -e "  ${WHITE}${MY_IP:-*}:${port}${NC} ($proto) → ${GREEN}${dest}${NC} $(fmt_ip "$dest_ip")"
        done
    fi
    echo ""
    read -p "Нажмите Enter..."
}

delete_single_rule() {
    echo -e "\n${CYAN}--- Удаление правила ---${NC}"
    local -a rules_arr=()
    local i=1
    while IFS='|' read -r proto port dest; do
        rules_arr[$i]="$proto|$port|$dest"
        local dest_ip="${dest%:*}"
        echo -e "${YELLOW}[$i]${NC} ${MY_IP:-*}:$port ($proto) -> $(fmt_ip_short "$dest_ip")"
        ((i++))
    done <<< "$(get_rules_list)"
    if [ ${#rules_arr[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"; read -p "Нажмите Enter..."; return
    fi
    echo ""
    read -p "Номер для удаления (0 — отмена): " rule_num
    [[ "$rule_num" == "0" || -z "${rules_arr[$rule_num]:-}" ]] && return
    IFS='|' read -r d_proto d_port d_dest <<< "${rules_arr[$rule_num]}"
    iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -j DNAT --to-destination "$d_dest" 2>/dev/null
    iptables -S INPUT 2>/dev/null | grep "kaskad:${d_port}:${d_proto}" | while read -r rule; do eval "iptables -D ${rule#-A }" 2>/dev/null; done
    iptables -S FORWARD 2>/dev/null | grep "kaskad:${d_port}:${d_proto}" | while read -r rule; do eval "iptables -D ${rule#-A }" 2>/dev/null; done
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "$d_port/$d_proto" > /dev/null 2>&1
    fi
    save_iptables
    log_action "DELETE rule: $d_proto :$d_port -> $d_dest"
    echo -e "${GREEN}[OK] Правило удалено.${NC}"; read -p "Нажмите Enter..."
}

flush_rules() {
    echo -e "\n${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo "Будут удалены только правила Kaskad."
    read -p "Уверены? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            iptables -S INPUT 2>/dev/null | grep "kaskad" | while read -r ul; do
                local up; up=$(echo "$ul" | sed -n 's/.*--dport \([0-9]*\).*/\1/p')
                local upr; upr=$(echo "$ul" | sed -n 's/.*-p \([a-z]*\).*/\1/p')
                [ -n "$up" ] && [ -n "$upr" ] && ufw delete allow "$up/$upr" > /dev/null 2>&1
            done
        fi
        while iptables -t nat -S PREROUTING 2>/dev/null | grep -q "DNAT"; do
            local rule; rule=$(iptables -t nat -S PREROUTING | grep "DNAT" | head -1)
            eval "iptables -t nat -D ${rule#-A }" 2>/dev/null
        done
        for chain in INPUT FORWARD; do
            while iptables -S "$chain" 2>/dev/null | grep -q "kaskad"; do
                local rule; rule=$(iptables -S "$chain" | grep "kaskad" | head -1)
                eval "iptables -D ${rule#-A }" 2>/dev/null
            done
        done
        save_iptables; log_action "FLUSH all kaskad rules"
        echo -e "${GREEN}[OK] Очищено.${NC}"
    fi
    read -p "Нажмите Enter..."
}

full_uninstall() {
    clear
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║            ⚠  ПОЛНОЕ УДАЛЕНИЕ KASKAD PRO  ⚠               ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Будут удалены:${NC}"
    echo -e "  ${RED}•${NC} Все правила каскада (iptables)"
    echo -e "  ${RED}•${NC} Telegram-бот и мониторинг"
    echo -e "  ${RED}•${NC} Конфигурация ${WHITE}/etc/kaskad/${NC}"
    echo -e "  ${RED}•${NC} Команда ${WHITE}gokaskad${NC}"
    echo -e "  ${RED}•${NC} Логи ${WHITE}/var/log/kaskad.log${NC}"
    echo ""
    echo -e "${GREEN}НЕ будет затронуто:${NC}"
    echo -e "  ${GREEN}•${NC} Системные пакеты (iptables, jq, curl, qrencode)"
    echo -e "  ${GREEN}•${NC} Ваши VPN / прокси (WireGuard, XRay и т.д.)"
    echo -e "  ${GREEN}•${NC} Настройки sysctl (ip_forward, bbr)"
    echo ""
    read -p "$(echo -e "${RED}Удалить Kaskad PRO полностью? (y/n): ${NC}")" confirm1
    [[ "$confirm1" != "y" ]] && { echo -e "\n${CYAN}Отменено.${NC}"; read -p "Нажмите Enter..."; return; }
    local words=("УДАЛИТЬ" "СТЕРЕТЬ" "СНЕСТИ" "УНИЧТОЖИТЬ" "ПРОЩАЙ")
    local word="${words[$((RANDOM % ${#words[@]}))]}"
    echo ""
    echo -e "${RED}Последний шанс! Введите слово ${WHITE}${word}${RED} для подтверждения:${NC}"
    read -p "> " confirm2
    if [[ "$confirm2" != "$word" ]]; then
        echo -e "\n${CYAN}Неверное слово. Удаление отменено.${NC}"
        read -p "Нажмите Enter..."
        return
    fi
    echo ""
    echo -e "${YELLOW}Удаление Kaskad PRO...${NC}\n"
    if systemctl is-active kaskad-bot &>/dev/null; then
        systemctl stop kaskad-bot 2>/dev/null; systemctl disable kaskad-bot 2>/dev/null
    fi
    [ -f "$BOT_PID_FILE" ] && { kill "$(cat "$BOT_PID_FILE")" 2>/dev/null; rm -f "$BOT_PID_FILE"; }
    rm -f /etc/systemd/system/kaskad-bot.service
    echo -e "  ${GREEN}✓${NC}  Telegram-бот остановлен"
    if systemctl is-active kaskad-monitor &>/dev/null; then
        systemctl stop kaskad-monitor 2>/dev/null; systemctl disable kaskad-monitor 2>/dev/null
    fi
    [ -f "$MONITOR_PID_FILE" ] && { kill "$(cat "$MONITOR_PID_FILE")" 2>/dev/null; rm -f "$MONITOR_PID_FILE"; }
    rm -f /etc/systemd/system/kaskad-monitor.service
    systemctl daemon-reload 2>/dev/null
    echo -e "  ${GREEN}✓${NC}  Мониторинг остановлен"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        iptables -S INPUT 2>/dev/null | grep "kaskad" | while read -r ul; do
            local up; up=$(echo "$ul" | sed -n 's/.*--dport \([0-9]*\).*/\1/p')
            local upr; upr=$(echo "$ul" | sed -n 's/.*-p \([a-z]*\).*/\1/p')
            [ -n "$up" ] && [ -n "$upr" ] && ufw delete allow "$up/$upr" > /dev/null 2>&1
        done
        echo -e "  ${GREEN}✓${NC}  Правила UFW очищены"
    fi
    while iptables -t nat -S PREROUTING 2>/dev/null | grep -q "DNAT"; do
        local rule; rule=$(iptables -t nat -S PREROUTING | grep "DNAT" | head -1)
        eval "iptables -t nat -D ${rule#-A }" 2>/dev/null
    done
    for chain in INPUT FORWARD; do
        while iptables -S "$chain" 2>/dev/null | grep -q "kaskad"; do
            local rule; rule=$(iptables -S "$chain" | grep "kaskad" | head -1)
            eval "iptables -D ${rule#-A }" 2>/dev/null
        done
    done
    save_iptables
    echo -e "  ${GREEN}✓${NC}  Правила iptables удалены"
    rm -rf "$KASKAD_DIR"
    echo -e "  ${GREEN}✓${NC}  Конфигурация удалена"
    rm -f "$KASKAD_LOG"
    echo -e "  ${GREEN}✓${NC}  Логи удалены"
    rm -f /usr/local/bin/gokaskad
    echo -e "  ${GREEN}✓${NC}  Команда gokaskad удалена"
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Kaskad PRO полностью удалён.${NC}"
    echo -e "${WHITE}  Спасибо, что пользовались!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    read -p "Нажмите Enter..."
    exit 0
}

manage_aliases_menu() {
    while true; do
        clear
        echo -e "${CYAN}━━━ Имена серверов ━━━${NC}"
        local -a ips=()
        while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
        if [ ${#ips[@]} -eq 0 ]; then echo -e "${YELLOW}Нет серверов.${NC}"; read -p "Enter..."; return; fi
        for i in "${!ips[@]}"; do
            echo -e "  ${YELLOW}[$((i+1))]${NC} $(fmt_ip "${ips[$i]}")"
            local note; note=$(get_alias_field "${ips[$i]}" "note")
            [ -n "$note" ] && echo -e "       ${WHITE}Примечание:${NC} $note"
        done
        echo -e "  ${YELLOW}[0]${NC} Назад"
        read -p "Сервер: " choice
        [[ "$choice" == "0" || -z "$choice" ]] && return
        local idx=$((choice - 1))
        [ -z "${ips[$idx]:-}" ] && continue
        local sel="${ips[$idx]}"
        echo -e "Новое имя для $sel (Enter — оставить):"
        read -p "> " nn; [ -n "$nn" ] && set_alias "$sel" "$nn"
        echo -e "Новое примечание (Enter — оставить):"
        read -p "> " nt; [ -n "$nt" ] && set_alias_note "$sel" "$nt"
        echo -e "${GREEN}[OK]${NC}"; read -p "Enter..."
    done
}

# ─── Auto-update ──────────────────────────────────────────────

self_update() {
    local repo_url="https://raw.githubusercontent.com/anten-ka/kaskad-pro/main/install.sh"
    local update_token
    update_token=$(bot_get_state "system" "UPDATE_TOKEN" 2>/dev/null)
    [ -z "$update_token" ] && update_token=$(grep "^GITHUB_PAT=" "$KASKAD_CONF" 2>/dev/null | cut -d'"' -f2)
    echo -e "${YELLOW}[*] Загрузка обновления...${NC}"
    local ok=0
    [ -n "$update_token" ] && curl -sL -H "Authorization: token $update_token" "$repo_url" -o /tmp/kaskad_update.sh 2>/dev/null \
        && head -1 /tmp/kaskad_update.sh 2>/dev/null | grep -q "#!/bin/bash" && ok=1
    if [ "$ok" -eq 0 ]; then
        curl -sL "$repo_url" -o /tmp/kaskad_update.sh 2>/dev/null \
            && head -1 /tmp/kaskad_update.sh 2>/dev/null | grep -q "#!/bin/bash" && ok=1
    fi
    if [ "$ok" -eq 0 ]; then
        echo -e "${RED}Не удалось скачать. Репозиторий приватный.${NC}"
        echo -e "${WHITE}Введите GitHub PAT (токен доступа) или Enter для отмены:${NC}"
        echo -e "${CYAN}(Создать: GitHub → Settings → Developer settings → Personal access tokens)${NC}"
        read -p "> " new_token
        if [ -n "$new_token" ]; then
            curl -sL -H "Authorization: token $new_token" "$repo_url" -o /tmp/kaskad_update.sh 2>/dev/null \
                && head -1 /tmp/kaskad_update.sh 2>/dev/null | grep -q "#!/bin/bash" && ok=1
            if [ "$ok" -eq 1 ]; then
                mkdir -p "$BOT_STATE_DIR"
                bot_set_state "system" "UPDATE_TOKEN=$new_token"
                save_config_val "GITHUB_PAT" "$new_token"
                echo -e "${GREEN}Токен сохранён для будущих обновлений.${NC}"
            else
                echo -e "${RED}Токен не подошёл или ошибка сети.${NC}"
            fi
        fi
    fi
    if [ "$ok" -eq 1 ] && [ -s /tmp/kaskad_update.sh ]; then
        cp -f /tmp/kaskad_update.sh /usr/local/bin/gokaskad; chmod +x /usr/local/bin/gokaskad; rm -f /tmp/kaskad_update.sh
        systemctl restart kaskad-bot 2>/dev/null; systemctl restart kaskad-monitor 2>/dev/null
        echo -e "${GREEN}[OK] Обновлён! Перезапустите: gokaskad${NC}"; log_action "Self-update completed"
    else
        [ "$ok" -eq 0 ] && echo -e "${RED}[ERROR] Не удалось обновить.${NC}"
        rm -f /tmp/kaskad_update.sh
    fi
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  LIVE PING with ASCII bar
# ═══════════════════════════════════════════════════════════════

make_ping_bar() {
    local ms_str="$1" width=25
    local ms_int
    ms_int=$(awk "BEGIN {printf \"%d\", $ms_str + 0.5}")
    local filled=$(( ms_int * width / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 1 )) && filled=1
    local empty=$(( width - filled ))

    local color="$GREEN"
    (( ms_int > 50 )) && color="$YELLOW"
    (( ms_int > 100 )) && color="$RED"

    local bar="${color}"
    for (( b=0; b<filled; b++ )); do bar+="▓"; done
    bar+="${NC}"
    for (( b=0; b<empty; b++ )); do bar+="░"; done
    echo "$bar"
}

ping_live() {
    local ip="$1"
    local label
    label=$(fmt_ip_short "$ip")
    local -a results=()
    local count=0 lost=0 running=1

    trap 'running=0' INT

    local _port; _port=$(get_port_for_ip "$ip")
    local _mode="ICMP"
    [ -n "$_port" ] && _mode="ICMP/TCP:${_port}"

    while [ "$running" -eq 1 ]; do
        local raw method="" ms=""
        raw=$(smart_ping "$ip" 3 "${_port:-}")
        if [ -n "$raw" ]; then method="${raw%%|*}"; ms="${raw#*|}"; fi
        ((count++))

        clear
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  Live Ping: ${WHITE}$label${CYAN}  (${_mode})  [Ctrl+C — стоп]${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if [ -n "$ms" ]; then
            results+=("$ms")
            local bar
            bar=$(make_ping_bar "$ms")
            printf "  ${GREEN}#%-4d %7sms${NC} ${CYAN}[%s]${NC} %b\n" "$count" "$ms" "$method" "$bar"
        else
            ((lost++))
            printf "  ${RED}#%-4d   ------${NC}  " "$count"
            for (( b=0; b<25; b++ )); do echo -ne "${RED}█${NC}"; done
            echo -e " ${RED}TIMEOUT${NC}"
        fi

        local show=18
        local total=${#results[@]}
        local start_show=$(( count - show ))
        (( start_show < 1 )) && start_show=1

        local display_start=$(( start_show - 1 ))
        local display_idx=0
        local lines_printed=1

        if (( count > 1 )); then
            local hist_start=$(( count - show ))
            (( hist_start < 0 )) && hist_start=0
        fi

        echo ""
        if [ ${#results[@]} -gt 0 ]; then
            local stats
            stats=$(printf '%s\n' "${results[@]}" | awk '
                BEGIN {mn=999999; mx=0; s=0}
                {s+=$1; if($1<mn)mn=$1; if($1>mx)mx=$1}
                END {printf "%.2f|%.2f|%.2f", mn, mx, s/NR}')
            IFS='|' read -r s_min s_max s_avg <<< "$stats"
            echo -e "  ${WHITE}Мин:${NC} ${s_min}ms ${WHITE}│${NC} ${WHITE}Макс:${NC} ${s_max}ms ${WHITE}│${NC} ${WHITE}Сред:${NC} ${s_avg}ms"
        fi
        echo -e "  ${WHITE}Потеряно:${NC} $lost / $count"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        sleep 1
    done

    trap - INT
    echo ""
    if [ ${#results[@]} -eq 0 ] && [ "$count" -gt 0 ]; then
        echo -e "${YELLOW}━━━ Сервер не ответил ни разу ━━━${NC}"
        echo -e "${WHITE}ICMP заблокирован$([ -n "$_port" ] && echo " и TCP:$_port не удался").${NC}"
        echo ""
        echo -e "${CYAN}Чтобы включить ping на удалённом сервере:${NC}"
        echo -e "  ${WHITE}ssh root@${ip}${NC}"
        echo -e "  ${GREEN}sysctl -w net.ipv4.icmp_echo_ignore_all=0${NC}"
        echo -e "  ${GREEN}echo 'net.ipv4.icmp_echo_ignore_all=0' >> /etc/sysctl.conf${NC}"
        echo -e "  ${GREEN}iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT${NC}"
        echo ""
    fi
    read -p "Нажмите Enter для возврата в меню..."
}

ping_menu() {
    echo -e "\n${CYAN}--- Ping серверов ---${NC}"
    local -a ips=()
    while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
    if [ ${#ips[@]} -eq 0 ]; then echo -e "${YELLOW}Нет серверов.${NC}"; read -p "Enter..."; return; fi
    echo -e "Серверы:"
    for i in "${!ips[@]}"; do echo -e "  ${YELLOW}[$((i+1))]${NC} $(fmt_ip "${ips[$i]}")"; done
    echo -e "  ${YELLOW}[0]${NC} Отмена"
    read -p "Выбор: " choice
    [[ "$choice" == "0" || -z "$choice" ]] && return
    local idx=$((choice - 1))
    [ -z "${ips[$idx]:-}" ] && return
    ping_live "${ips[$idx]}"
}

# ═══════════════════════════════════════════════════════════════
#  MONITORING
# ═══════════════════════════════════════════════════════════════

add_monitor() {
    local ip="$1" interval="$2" threshold="$3" cooldown="${4:-300}"
    cat > "$MONITOR_DIR/${ip}.conf" <<EOF
MON_IP="$ip"
MON_INTERVAL=$interval
MON_THRESHOLD=$threshold
MON_COOLDOWN=$cooldown
EOF
    log_action "MONITOR ADD: $ip interval=${interval}s threshold=${threshold}ms cooldown=${cooldown}s"
    sync_monitoring_service
}

remove_monitor() {
    local ip="$1"
    rm -f "$MONITOR_DIR/${ip}.conf" "$MONITOR_DIR/.last_check_${ip}" "$MONITOR_DIR/.last_alert_${ip}"
    log_action "MONITOR REMOVE: $ip"
    sync_monitoring_service
}

has_monitors() {
    for conf in "$MONITOR_DIR"/*.conf; do [ -f "$conf" ] && return 0; done
    return 1
}

sync_monitoring_service() {
    if has_monitors; then
        systemctl is-active kaskad-monitor &>/dev/null 2>&1 || start_monitoring_silent
    else
        systemctl is-active kaskad-monitor &>/dev/null 2>&1 && stop_monitoring_silent
    fi
}

start_monitoring_silent() {
    cat > /etc/systemd/system/kaskad-monitor.service <<EOF
[Unit]
Description=Kaskad Monitoring Daemon
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gokaskad --monitor-daemon
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable kaskad-monitor > /dev/null 2>&1; systemctl start kaskad-monitor 2>/dev/null
    log_action "Monitoring auto-started"
}

stop_monitoring_silent() {
    systemctl stop kaskad-monitor 2>/dev/null; systemctl disable kaskad-monitor 2>/dev/null; rm -f "$MONITOR_PID_FILE"
    log_action "Monitoring auto-stopped"
}

list_monitors() {
    local found=0
    for conf in "$MONITOR_DIR"/*.conf; do
        [ -f "$conf" ] || continue; found=1
        local MON_IP="" MON_INTERVAL="" MON_THRESHOLD="" MON_COOLDOWN=300; source "$conf"
        echo -e "  ${WHITE}$(fmt_ip_short "$MON_IP")${NC}  инт: ${MON_INTERVAL}s  порог: ${MON_THRESHOLD}ms  уведомл: ${MON_COOLDOWN}s"
    done
    [ "$found" -eq 0 ] && echo -e "  ${YELLOW}Нет мониторов.${NC}"
}

monitor_alert() {
    local ip="$1" ping_ms="$2" threshold="$3" cooldown="${4:-300}"
    local alert_file="$MONITOR_DIR/.last_alert_${ip}" last_alert=0
    [ -f "$alert_file" ] && last_alert=$(cat "$alert_file")
    local now; now=$(date +%s)
    (( now - last_alert < cooldown )) && return
    echo "$now" > "$alert_file"
    log_action "ALERT: $ip ping=${ping_ms}ms threshold=${threshold}ms"
    source "$KASKAD_CONF" 2>/dev/null
    if [ -n "${BOT_TOKEN:-}" ] && [ -n "${BOT_CHAT_ID:-}" ]; then
        local header; header=$(fmt_ip_short "$ip")
        local text
        [ "$ping_ms" = "TIMEOUT" ] && text="⚠️ <b>ALERT</b>: ${header}\nPing: TIMEOUT (порог: ${threshold}ms)" \
            || text="⚠️ <b>ALERT</b>: ${header}\nPing: ${ping_ms}ms (порог: ${threshold}ms)"
        tg_send "$BOT_CHAT_ID" "$text" "" > /dev/null 2>&1
    fi
}

monitor_daemon() {
    log_action "Monitor daemon started (PID $$)"; echo $$ > "$MONITOR_PID_FILE"
    while true; do
        local now; now=$(date +%s)
        for cf in "$MONITOR_DIR"/*.conf; do
            [ -f "$cf" ] || continue
            local MON_IP="" MON_INTERVAL="" MON_THRESHOLD="" MON_COOLDOWN=300; source "$cf"
            local ckf="$MONITOR_DIR/.last_check_${MON_IP}" lc=0
            [ -f "$ckf" ] && lc=$(cat "$ckf")
            if (( now - lc >= MON_INTERVAL )); then
                echo "$now" > "$ckf"
                local pr_raw; pr_raw=$(smart_ping "$MON_IP" 3)
                local pr="${pr_raw#*|}"
                if [ -z "$pr" ] || [ -z "$pr_raw" ]; then
                    monitor_alert "$MON_IP" "TIMEOUT" "$MON_THRESHOLD" "$MON_COOLDOWN"
                else
                    local pi; pi=$(awk "BEGIN {printf \"%d\", $pr + 0.5}")
                    (( pi > MON_THRESHOLD )) && monitor_alert "$MON_IP" "$pr" "$MON_THRESHOLD" "$MON_COOLDOWN"
                fi
            fi
        done
        sleep 1
    done
}

monitoring_menu() {
    while true; do
        clear
        local ms="${RED}Остановлен${NC}"
        systemctl is-active kaskad-monitor &>/dev/null 2>&1 && ms="${GREEN}Работает${NC}"
        echo -e "${CYAN}━━━ Мониторинг (авто) ━━━${NC}"
        echo -e "Статус: $ms"; echo ""; list_monitors; echo ""
        echo -e "1) Добавить"; echo -e "2) Удалить"; echo -e "0) Назад"
        read -p "Выбор: " choice
        case $choice in
            1)
                local -a ips=()
                while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
                [ ${#ips[@]} -eq 0 ] && echo -e "${YELLOW}Нет серверов.${NC}" && read -p "Enter..." && continue
                for i in "${!ips[@]}"; do echo -e "  ${YELLOW}[$((i+1))]${NC} $(fmt_ip_short "${ips[$i]}")"; done
                read -p "Сервер: " sc; local si=$((sc-1)); [ -z "${ips[$si]:-}" ] && continue
                echo -e "Интервал: 1) 10с  2) 1мин  3) 5мин"
                read -p "> " ic; local iv=60; case $ic in 1) iv=10;; 3) iv=300;; esac
                read_validated_port "Порог (мс):"; local th="$_RET_PORT"
                echo -e "Уведомления: 1) 10с  2) 60с  3) 5мин  4) 15мин"
                read -p "> " cc; local cd=300; case $cc in 1) cd=10;; 2) cd=60;; 4) cd=900;; esac
                add_monitor "${ips[$si]}" "$iv" "$th" "$cd"
                echo -e "${GREEN}[OK]${NC}"; read -p "Enter..." ;;
            2)
                local -a mi=()
                for c in "$MONITOR_DIR"/*.conf; do [ -f "$c" ] || continue; local MON_IP=""; source "$c"; mi+=("$MON_IP"); done
                [ ${#mi[@]} -eq 0 ] && echo -e "${YELLOW}Нет.${NC}" && read -p "Enter..." && continue
                for i in "${!mi[@]}"; do echo -e "  ${YELLOW}[$((i+1))]${NC} $(fmt_ip_short "${mi[$i]}")"; done
                read -p "Номер: " dc; local di=$((dc-1))
                [ -n "${mi[$di]:-}" ] && remove_monitor "${mi[$di]}" && echo -e "${GREEN}[OK]${NC}"
                read -p "Enter..." ;;
            0) return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  TELEGRAM BOT
# ═══════════════════════════════════════════════════════════════

tg_api() {
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

tg_send() {
    local chat_id="$1" text keyboard="${3:-}"
    text=$(printf '%b' "$2")
    local payload
    if [ -n "$keyboard" ]; then
        payload=$(jq -n --arg c "$chat_id" --arg t "$text" --argjson k "$keyboard" \
            '{chat_id:$c, text:$t, parse_mode:"HTML", reply_markup:{inline_keyboard:$k}}')
    else
        payload=$(jq -n --arg c "$chat_id" --arg t "$text" \
            '{chat_id:$c, text:$t, parse_mode:"HTML"}')
    fi
    tg_api "sendMessage" "$payload"
}

tg_send_reply_kb() {
    local chat_id="$1" text keyboard="$3"
    text=$(printf '%b' "$2")
    local payload
    payload=$(jq -n --arg c "$chat_id" --arg t "$text" --argjson k "$keyboard" \
        '{chat_id:$c, text:$t, parse_mode:"HTML", reply_markup:{keyboard:$k, resize_keyboard:true, one_time_keyboard:false}}')
    tg_api "sendMessage" "$payload"
}

tg_remove_reply_kb() {
    local chat_id="$1" text="$2"
    text=$(printf '%b' "$text")
    local payload
    payload=$(jq -n --arg c "$chat_id" --arg t "$text" \
        '{chat_id:$c, text:$t, parse_mode:"HTML", reply_markup:{remove_keyboard:true}}')
    tg_api "sendMessage" "$payload"
}

tg_edit() {
    local chat_id="$1" msg_id="$2" text keyboard="${4:-}"
    text=$(printf '%b' "$3")
    local payload
    if [ -n "$keyboard" ]; then
        payload=$(jq -n --arg c "$chat_id" --argjson m "$msg_id" --arg t "$text" --argjson k "$keyboard" \
            '{chat_id:$c, message_id:$m, text:$t, parse_mode:"HTML", reply_markup:{inline_keyboard:$k}}')
    else
        payload=$(jq -n --arg c "$chat_id" --argjson m "$msg_id" --arg t "$text" \
            '{chat_id:$c, message_id:$m, text:$t, parse_mode:"HTML"}')
    fi
    tg_api "editMessageText" "$payload"
}

tg_answer_cb() {
    tg_api "answerCallbackQuery" "{\"callback_query_id\":\"$1\",\"text\":\"${2:-}\"}"
}

# ─── Bot state ────────────────────────────────────────────────

bot_set_state() { local c="$1"; shift; printf '%s\n' "$@" > "$BOT_STATE_DIR/$c"; }
bot_get_state() { [ -f "$BOT_STATE_DIR/$1" ] && grep "^${2}=" "$BOT_STATE_DIR/$1" | head -1 | cut -d= -f2-; }
bot_clear_state() { rm -f "$BOT_STATE_DIR/$1"; }

get_menu_style() { source "$KASKAD_CONF" 2>/dev/null; echo "${MENU_STYLE:-inline}"; }

# ─── Bot keyboards ───────────────────────────────────────────

kbd_inline_main() {
    cat <<'JSON'
[
  [{"text":"🔀 AWG","callback_data":"a_u"},{"text":"🔀 VLESS","callback_data":"a_t"},{"text":"🔀 MTProto","callback_data":"a_mt"}],
  [{"text":"🛠 Custom","callback_data":"a_c"},{"text":"📋 Правила","callback_data":"lr"}],
  [{"text":"🏓 Ping","callback_data":"pm"},{"text":"📊 Монитор","callback_data":"mm"}],
  [{"text":"💻 Система","callback_data":"sys"}],
  [{"text":"❌ Удалить","callback_data":"dr"},{"text":"🗑 Сброс","callback_data":"fa"}],
  [{"text":"🏢 Хостинг","callback_data":"promo"}],
  [{"text":"⌨️ Reply-клавиатура","callback_data":"sw_reply"}]
]
JSON
}

reply_kb_json() {
    cat <<'JSON'
[
  ["🔀 AWG/WG", "🔀 VLESS"],
  ["🔀 MTProto", "🛠 Custom"],
  ["📋 Правила", "🏓 Ping"],
  ["📊 Монитор", "💻 Система"],
  ["❌ Удалить", "🗑 Сброс"],
  ["🏢 Хостинг"],
  ["/inline"]
]
JSON
}

kbd_back() { echo '[[{"text":"⬅️ Меню","callback_data":"m"}]]'; }
kbd_proto() { echo '[[{"text":"TCP","callback_data":"a_cp_tcp"},{"text":"UDP","callback_data":"a_cp_udp"}],[{"text":"⬅️ Меню","callback_data":"m"}]]'; }

kbd_ping_opts() {
    local ip="$1"
    jq -n --arg ip "$ip" '[[{"text":"1 раз","callback_data":("po:"+$ip)}],[{"text":"10 раз","callback_data":("p10:"+$ip)}],[{"text":"60 сек","callback_data":("p60:"+$ip)}],[{"text":"⬅️ Меню","callback_data":"m"}]]'
}

kbd_monitor() { cat <<'JSON'
[[{"text":"➕ Добавить","callback_data":"ma"}],[{"text":"📋 Список","callback_data":"ml"}],[{"text":"➖ Удалить","callback_data":"md"}],[{"text":"⬅️ Меню","callback_data":"m"}]]
JSON
}

kbd_intervals() {
    local ip="$1"
    jq -n --arg ip "$ip" '[[{"text":"10с","callback_data":("mi:"+$ip+":10")}],[{"text":"1мин","callback_data":("mi:"+$ip+":60")}],[{"text":"5мин","callback_data":("mi:"+$ip+":300")}],[{"text":"⬅️","callback_data":"m"}]]'
}

kbd_cooldowns() {
    local ip="$1" interval="$2" threshold="$3"
    jq -n --arg ip "$ip" --arg i "$interval" --arg t "$threshold" \
        '[[{"text":"10с","callback_data":("mc:"+$ip+":"+$i+":"+$t+":10")}],[{"text":"60с","callback_data":("mc:"+$ip+":"+$i+":"+$t+":60")}],[{"text":"5мин","callback_data":("mc:"+$ip+":"+$i+":"+$t+":300")}],[{"text":"15мин","callback_data":("mc:"+$ip+":"+$i+":"+$t+":900")}],[{"text":"⬅️","callback_data":"m"}]]'
}

build_ip_kbd() {
    local prefix="$1"; shift; local ips=("$@") rows="" first=1
    for ip in "${ips[@]}"; do
        local label; label=$(get_alias "$ip"); [ -z "$label" ] && label="$ip" || label="$label ($ip)"
        [ "$first" -eq 0 ] && rows+=","; rows+="[{\"text\":\"$label\",\"callback_data\":\"${prefix}:${ip}\"}]"; first=0
    done
    echo "[${rows},[{\"text\":\"⬅️ Меню\",\"callback_data\":\"m\"}]]"
}

build_delete_kbd() {
    local rules; rules=$(get_rules_list)
    local rows="" i=1 first=1
    while IFS='|' read -r proto port dest; do
        [ -z "$port" ] && continue
        local dip="${dest%:*}" label; label=$(get_alias "$dip")
        local bt="❌ :$port ($proto) → $dest"; [ -n "$label" ] && bt="❌ :$port → $label"
        [ "$first" -eq 0 ] && rows+=","; rows+="[{\"text\":\"$bt\",\"callback_data\":\"dr_${i}\"}]"; first=0; ((i++))
    done <<< "$rules"
    [ -z "$rows" ] && echo '[[{"text":"Нет правил","callback_data":"m"}]]' || echo "[${rows},[{\"text\":\"⬅️\",\"callback_data\":\"m\"}]]"
}

# ─── Bot handlers ─────────────────────────────────────────────

bot_main_menu() {
    local chat_id="$1" msg_id="${2:-}"
    bot_clear_state "$chat_id"
    local style; style=$(get_menu_style)
    local text="<b>Kaskad PRO v${KASKAD_VERSION}</b>\nIP: <code>${MY_IP:-N/A}</code>\nВыберите действие:"

    if [ "$style" = "reply" ]; then
        tg_send_reply_kb "$chat_id" "$text" "$(reply_kb_json)" > /dev/null
    else
        local kbd; kbd=$(kbd_inline_main)
        if [ -n "$msg_id" ]; then
            tg_edit "$chat_id" "$msg_id" "$text" "$kbd"
        else
            tg_send "$chat_id" "$text" "$kbd"
        fi
    fi
}

bot_handle_reply_text() {
    local chat_id="$1" text="$2"
    case "$text" in
        "🔀 AWG/WG")       bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=udp" "NAME=AmneziaWG" "CUSTOM=0"; tg_send "$chat_id" "🔀 <b>AmneziaWG (UDP)</b>\n\nВведите IP:" "$(kbd_back)" > /dev/null ;;
        "🔀 VLESS")         bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=tcp" "NAME=VLESS" "CUSTOM=0"; tg_send "$chat_id" "🔀 <b>VLESS (TCP)</b>\n\nВведите IP:" "$(kbd_back)" > /dev/null ;;
        "🔀 MTProto")       bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=tcp" "NAME=MTProto" "CUSTOM=0"; tg_send "$chat_id" "🔀 <b>MTProto (TCP)</b>\n\nВведите IP:" "$(kbd_back)" > /dev/null ;;
        "🛠 Custom")        tg_send "$chat_id" "🛠 <b>Custom Rule</b>\n\nВыберите протокол:" "$(kbd_proto)" > /dev/null ;;
        "📋 Правила")       bot_handle_callback "$chat_id" "" "" "lr_new" ;;
        "🏓 Ping")          bot_handle_callback "$chat_id" "" "" "pm_new" ;;
        "📊 Монитор")       bot_handle_callback "$chat_id" "" "" "mm_new" ;;
        "💻 Система")       local s; s=$(get_system_stats); tg_send "$chat_id" "$s" "$(kbd_back)" > /dev/null ;;
        "❌ Удалить")       tg_send "$chat_id" "❌ <b>Выберите правило:</b>" "$(build_delete_kbd)" > /dev/null ;;
        "🗑 Сброс")        tg_send "$chat_id" "🗑 <b>Уверены?</b>" '[[{"text":"✅ Да","callback_data":"fa_y"},{"text":"❌ Нет","callback_data":"m"}]]' > /dev/null ;;
        "🏢 Хостинг")      bot_handle_callback "$chat_id" "" "" "promo_new" ;;
        *) return 1 ;;
    esac
    return 0
}

bot_handle_callback() {
    local chat_id="$1" msg_id="$2" cb_id="$3" data="$4"
    [ -n "$cb_id" ] && tg_answer_cb "$cb_id" > /dev/null

    local use_send=0
    [[ "$data" == *_new ]] && use_send=1 && data="${data%_new}"

    case "$data" in
        m) bot_main_menu "$chat_id" "$msg_id" ;;
        sw_reply) save_config_val "MENU_STYLE" "reply"; bot_main_menu "$chat_id" ;;
        sw_inline) save_config_val "MENU_STYLE" "inline"; bot_main_menu "$chat_id" ;;

        a_u) bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=udp" "NAME=AmneziaWG" "CUSTOM=0"
             [ "$use_send" -eq 1 ] && tg_send "$chat_id" "🔀 <b>AmneziaWG (UDP)</b>\n\nВведите IP:" "$(kbd_back)" > /dev/null \
                 || tg_edit "$chat_id" "$msg_id" "🔀 <b>AmneziaWG (UDP)</b>\n\nВведите IP:" "$(kbd_back)" ;;
        a_t) bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=tcp" "NAME=VLESS" "CUSTOM=0"
             [ "$use_send" -eq 1 ] && tg_send "$chat_id" "🔀 <b>VLESS (TCP)</b>\n\nВведите IP:" "$(kbd_back)" > /dev/null \
                 || tg_edit "$chat_id" "$msg_id" "🔀 <b>VLESS (TCP)</b>\n\nВведите IP:" "$(kbd_back)" ;;
        a_mt) bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=tcp" "NAME=MTProto" "CUSTOM=0"
              [ "$use_send" -eq 1 ] && tg_send "$chat_id" "🔀 <b>MTProto (TCP)</b>\n\nВведите IP:" "$(kbd_back)" > /dev/null \
                  || tg_edit "$chat_id" "$msg_id" "🔀 <b>MTProto (TCP)</b>\n\nВведите IP:" "$(kbd_back)" ;;
        a_c) [ "$use_send" -eq 1 ] && tg_send "$chat_id" "🛠 <b>Custom</b>\n\nПротокол:" "$(kbd_proto)" > /dev/null \
                 || tg_edit "$chat_id" "$msg_id" "🛠 <b>Custom</b>\n\nПротокол:" "$(kbd_proto)" ;;
        a_cp_tcp|a_cp_udp)
            local proto="${data#a_cp_}"
            bot_set_state "$chat_id" "STATE=awaiting_ip" "PROTO=$proto" "NAME=Custom" "CUSTOM=1"
            tg_edit "$chat_id" "$msg_id" "🛠 <b>Custom ($proto)</b>\n\nВведите IP:" "$(kbd_back)" ;;

        lr)
            local rules text=""; rules=$(get_rules_list)
            if [ -z "$rules" ]; then text="📋 <b>Нет правил.</b>"
            else
                text="📋 <b>Правила</b>\nСервер: <code>${MY_IP:-N/A}</code>\n\n"
                while IFS='|' read -r proto port dest; do
                    [ -n "$port" ] || continue
                    local dip="${dest%:*}"
                    text+="<code>${MY_IP:-*}:$port ($proto) → $dest</code>\n"
                    text+="  $(fmt_ip_tg "$dip")\n"
                done <<< "$rules"
            fi
            [ "$use_send" -eq 1 ] && tg_send "$chat_id" "$text" "$(kbd_back)" > /dev/null \
                || tg_edit "$chat_id" "$msg_id" "$text" "$(kbd_back)" ;;

        dr) [ "$use_send" -eq 1 ] && tg_send "$chat_id" "❌ <b>Выберите:</b>" "$(build_delete_kbd)" > /dev/null \
                || tg_edit "$chat_id" "$msg_id" "❌ <b>Выберите:</b>" "$(build_delete_kbd)" ;;
        dr_*)
            local idx="${data#dr_}" line; line=$(get_rules_list | sed -n "${idx}p")
            if [ -n "$line" ]; then
                IFS='|' read -r dp dpo dd <<< "$line"
                iptables -t nat -D PREROUTING -p "$dp" --dport "$dpo" -j DNAT --to-destination "$dd" 2>/dev/null
                iptables -S INPUT 2>/dev/null | grep "kaskad:${dpo}:${dp}" | while read -r r; do eval "iptables -D ${r#-A }" 2>/dev/null; done
                iptables -S FORWARD 2>/dev/null | grep "kaskad:${dpo}:${dp}" | while read -r r; do eval "iptables -D ${r#-A }" 2>/dev/null; done
                save_iptables; log_action "BOT DELETE: $dp :$dpo -> $dd"
                tg_edit "$chat_id" "$msg_id" "✅ <code>$dp :$dpo → $dd</code> удалено." "$(kbd_back)"
            else tg_edit "$chat_id" "$msg_id" "Не найдено." "$(kbd_back)"; fi ;;

        fa) tg_edit "$chat_id" "$msg_id" "🗑 <b>Уверены?</b>" '[[{"text":"✅ Да","callback_data":"fa_y"},{"text":"❌ Нет","callback_data":"m"}]]' ;;
        fa_y)
            while iptables -t nat -S PREROUTING 2>/dev/null | grep -q "DNAT"; do
                local r; r=$(iptables -t nat -S PREROUTING | grep "DNAT" | head -1); eval "iptables -t nat -D ${r#-A }" 2>/dev/null
            done
            for ch in INPUT FORWARD; do
                while iptables -S "$ch" 2>/dev/null | grep -q "kaskad"; do
                    local r; r=$(iptables -S "$ch" | grep "kaskad" | head -1); eval "iptables -D ${r#-A }" 2>/dev/null
                done
            done
            save_iptables; log_action "BOT FLUSH"
            tg_edit "$chat_id" "$msg_id" "✅ Очищено." "$(kbd_back)" ;;

        sys) local s; s=$(get_system_stats)
             [ "$use_send" -eq 1 ] && tg_send "$chat_id" "$s" "$(kbd_back)" > /dev/null \
                 || tg_edit "$chat_id" "$msg_id" "$s" "$(kbd_back)" ;;

        promo)
            local pt="<b>🏢 Хостинг, который работает</b>\n\n<b>🌍 РФ и Европа</b>\n👉 https://vk.cc/ct29NQ\n\n<code>OFF60</code> — 60% скидка\n<code>antenka20</code> — +20% (3мес)\n<code>antenka6</code> — +15% (6мес)\n<code>antenka12</code> — +5% (12мес)\n\n<b>🇧🇾 Беларусь</b>\n👉 https://vk.cc/cUxAhj\n<code>OFF60</code> — 60% скидка"
            [ "$use_send" -eq 1 ] && tg_send "$chat_id" "$pt" "$(kbd_back)" > /dev/null \
                || tg_edit "$chat_id" "$msg_id" "$pt" "$(kbd_back)" ;;

        pm) local -a ips=()
            while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
            if [ ${#ips[@]} -eq 0 ]; then
                [ "$use_send" -eq 1 ] && tg_send "$chat_id" "🏓 Нет серверов." "$(kbd_back)" > /dev/null \
                    || tg_edit "$chat_id" "$msg_id" "🏓 Нет серверов." "$(kbd_back)"
            else
                [ "$use_send" -eq 1 ] && tg_send "$chat_id" "🏓 <b>Сервер:</b>" "$(build_ip_kbd "ps" "${ips[@]}")" > /dev/null \
                    || tg_edit "$chat_id" "$msg_id" "🏓 <b>Сервер:</b>" "$(build_ip_kbd "ps" "${ips[@]}")"
            fi ;;
        ps:*) local ip="${data#ps:}"; local lb; lb=$(fmt_ip_short "$ip")
              tg_edit "$chat_id" "$msg_id" "🏓 <b>$lb</b>\nРежим:" "$(kbd_ping_opts "$ip")" ;;
        po:*) local ip="${data#po:}"; local lb; lb=$(fmt_ip_short "$ip")
              ( local raw; raw=$(smart_ping "$ip" 3)
                if [ -n "$raw" ]; then
                    local mtd="${raw%%|*}" pms="${raw#*|}"
                    tg_send "$chat_id" "🏓 <b>$lb</b>\n<code>${pms} ms</code> [$mtd]" "$(kbd_back)" > /dev/null
                else
                    tg_send "$chat_id" "🏓 <b>$lb</b>\n<code>timeout</code>\n\n<i>Сервер не ответил.\nВключите ping:</i>\n<code>sysctl -w net.ipv4.icmp_echo_ignore_all=0</code>\n<code>iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT</code>" "$(kbd_back)" > /dev/null
                fi ) & ;;
        p10:*) local ip="${data#p10:}"; local lb; lb=$(fmt_ip_short "$ip")
               ( local resp; resp=$(tg_send "$chat_id" "🏓 $lb (10x)..." "")
                 local mid; mid=$(echo "$resp" | jq -r '.result.message_id // empty')
                 local -a res=(); local lost=0 txt=""
                 for n in $(seq 1 10); do
                     local raw; raw=$(smart_ping "$ip" 3)
                     if [ -n "$raw" ]; then
                         local mtd="${raw%%|*}" pms="${raw#*|}"
                         res+=("$pms"); txt+="#$n: ${pms}ms [$mtd]\n"
                     else ((lost++)); txt+="#$n: timeout\n"; fi
                     sleep 1
                 done
                 local sm="🏓 <b>$lb (10x)</b>\n${txt}"
                 [ ${#res[@]} -gt 0 ] && { local av; av=$(printf '%s\n' "${res[@]}" | awk '{s+=$1} END {printf "%.2f",s/NR}'); sm+="\n<b>Среднее: ${av}ms</b>"; }
                 sm+="\nПотеряно: $lost/10"
                 if [ ${#res[@]} -eq 0 ]; then sm+="\n\n<i>Включите ping:</i>\n<code>sysctl -w net.ipv4.icmp_echo_ignore_all=0</code>"; fi
                 [ -n "$mid" ] && tg_edit "$chat_id" "$mid" "$sm" "$(kbd_back)" > /dev/null || tg_send "$chat_id" "$sm" "$(kbd_back)" > /dev/null
               ) & ;;
        p60:*) local ip="${data#p60:}"; local lb; lb=$(fmt_ip_short "$ip")
               ( local resp; resp=$(tg_send "$chat_id" "🏓 $lb (60с)..." "")
                 local mid; mid=$(echo "$resp" | jq -r '.result.message_id // empty')
                 local -a res=(); local lost=0
                 for n in $(seq 1 60); do
                     local raw; raw=$(smart_ping "$ip" 3)
                     if [ -n "$raw" ]; then
                         local pms="${raw#*|}"; res+=("$pms")
                     else ((lost++)); fi
                     if (( n % 10 == 0 )) && [ -n "$mid" ]; then
                         local p="🏓 <b>$lb</b>: ${n}/60с\nОК: ${#res[@]} | Lost: $lost"
                         [ ${#res[@]} -gt 0 ] && { local pa; pa=$(printf '%s\n' "${res[@]}" | awk '{s+=$1} END {printf "%.2f",s/NR}'); p+="\nСред: ${pa}ms"; }
                         tg_edit "$chat_id" "$mid" "$p" "" > /dev/null
                     fi; sleep 1
                 done
                 local sm="🏓 <b>$lb (60с) — готово</b>\n"
                 if [ ${#res[@]} -gt 0 ]; then
                     local st; st=$(printf '%s\n' "${res[@]}" | awk 'BEGIN{mn=999999;mx=0;s=0}{s+=$1;if($1<mn)mn=$1;if($1>mx)mx=$1}END{printf "%.2f|%.2f|%.2f",mn,mx,s/NR}')
                     IFS='|' read -r sn sx sa <<< "$st"; sm+="Мин: ${sn}ms\nМакс: ${sx}ms\nСред: ${sa}ms\n"
                 fi; sm+="Потеряно: $lost/60"
                 if [ ${#res[@]} -eq 0 ]; then sm+="\n\n<i>Включите ping:</i>\n<code>sysctl -w net.ipv4.icmp_echo_ignore_all=0</code>"; fi
                 [ -n "$mid" ] && tg_edit "$chat_id" "$mid" "$sm" "$(kbd_back)" > /dev/null || tg_send "$chat_id" "$sm" "$(kbd_back)" > /dev/null
               ) & ;;

        mm) [ "$use_send" -eq 1 ] && tg_send "$chat_id" "📊 <b>Мониторинг</b>" "$(kbd_monitor)" > /dev/null \
                || tg_edit "$chat_id" "$msg_id" "📊 <b>Мониторинг</b>" "$(kbd_monitor)" ;;
        ma) local -a ips=()
            while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
            [ ${#ips[@]} -eq 0 ] && tg_edit "$chat_id" "$msg_id" "Нет серверов." "$(kbd_back)" \
                || tg_edit "$chat_id" "$msg_id" "📊 Сервер:" "$(build_ip_kbd "ma" "${ips[@]}")" ;;
        ma:*) local ip="${data#ma:}"; tg_edit "$chat_id" "$msg_id" "📊 <b>$(fmt_ip_short "$ip")</b>\nИнтервал:" "$(kbd_intervals "$ip")" ;;
        mi:*) local rest="${data#mi:}" ip="${rest%:*}" interval="${rest##*:}"
              bot_set_state "$chat_id" "STATE=awaiting_threshold" "MON_IP=$ip" "MON_INTERVAL=$interval"
              tg_edit "$chat_id" "$msg_id" "📊 <b>$(fmt_ip_short "$ip")</b> (${interval}с)\n\nПорог (мс):" "$(kbd_back)" ;;
        mc:*) local rest="${data#mc:}"; IFS=':' read -r ip interval threshold cooldown <<< "$rest"
              add_monitor "$ip" "$interval" "$threshold" "$cooldown"
              tg_edit "$chat_id" "$msg_id" "✅ <b>$(fmt_ip_short "$ip")</b>\n${interval}с | ${threshold}мс | уведомл: ${cooldown}с" "$(kbd_back)" ;;
        ml) local t="📊 <b>Мониторы:</b>\n"; local found=0
            for c in "$MONITOR_DIR"/*.conf; do
                [ -f "$c" ] || continue; found=1
                local MON_IP="" MON_INTERVAL="" MON_THRESHOLD="" MON_COOLDOWN=300; source "$c"
                t+="$(fmt_ip_tg "$MON_IP")\n  ${MON_INTERVAL}с | ${MON_THRESHOLD}мс | ${MON_COOLDOWN}с\n"
            done
            [ "$found" -eq 0 ] && t+="<i>Нет.</i>"
            tg_edit "$chat_id" "$msg_id" "$t" "$(kbd_monitor)" ;;
        md) local -a mi=()
            for c in "$MONITOR_DIR"/*.conf; do [ -f "$c" ] || continue; local MON_IP=""; source "$c"; mi+=("$MON_IP"); done
            [ ${#mi[@]} -eq 0 ] && tg_edit "$chat_id" "$msg_id" "Нет." "$(kbd_monitor)" \
                || tg_edit "$chat_id" "$msg_id" "📊 Удалить:" "$(build_ip_kbd "md" "${mi[@]}")" ;;
        md:*) local ip="${data#md:}"; remove_monitor "$ip"
              tg_edit "$chat_id" "$msg_id" "✅ $(fmt_ip_short "$ip") удалён." "$(kbd_monitor)" ;;
    esac
}

bot_handle_message() {
    local chat_id="$1" text="$2"

    if [ "$text" = "/start" ] || [ "$text" = "/menu" ]; then bot_main_menu "$chat_id"; return; fi
    if [ "$text" = "/inline" ]; then
        save_config_val "MENU_STYLE" "inline"
        tg_remove_reply_kb "$chat_id" "Переключено на inline-кнопки." > /dev/null
        bot_main_menu "$chat_id"; return
    fi

    local style; style=$(get_menu_style)
    if [ "$style" = "reply" ]; then
        local state; state=$(bot_get_state "$chat_id" "STATE")
        if [ -z "$state" ]; then
            bot_handle_reply_text "$chat_id" "$text" && return
        fi
    fi

    local state; state=$(bot_get_state "$chat_id" "STATE")

    case "$state" in
        awaiting_ip)
            if ! validate_ip "$text"; then
                tg_send "$chat_id" "❌ Некорректный IP. Ещё раз:" "$(kbd_back)" > /dev/null; return
            fi
            local proto name custom
            proto=$(bot_get_state "$chat_id" "PROTO"); name=$(bot_get_state "$chat_id" "NAME"); custom=$(bot_get_state "$chat_id" "CUSTOM")
            if [ "$custom" = "1" ]; then
                bot_set_state "$chat_id" "STATE=awaiting_in_port" "PROTO=$proto" "NAME=$name" "CUSTOM=1" "TARGET_IP=$text"
                tg_send "$chat_id" "IP: <code>$text</code> ✅\n\n<b>ВХОДЯЩИЙ</b> порт:" "$(kbd_back)" > /dev/null
            else
                bot_set_state "$chat_id" "STATE=awaiting_port" "PROTO=$proto" "NAME=$name" "CUSTOM=0" "TARGET_IP=$text"
                tg_send "$chat_id" "IP: <code>$text</code> ✅\n\nВведите порт:" "$(kbd_back)" > /dev/null
            fi ;;
        awaiting_port)
            if ! validate_port "$text"; then tg_send "$chat_id" "❌ Порт (1-65535)." "" > /dev/null; return; fi
            local proto name target_ip
            proto=$(bot_get_state "$chat_id" "PROTO"); name=$(bot_get_state "$chat_id" "NAME"); target_ip=$(bot_get_state "$chat_id" "TARGET_IP")
            local port="$text"
            local probe_msg; probe_msg=$(tg_send "$chat_id" "🔍 Проверяю <code>$target_ip:$port</code>..." "")
            local probe_mid; probe_mid=$(echo "$probe_msg" | jq -r '.result.message_id // empty')
            local probe_result; probe_result=$(probe_server_tg "$target_ip" "$port")
            local info_text="<code>$target_ip:$port</code>\n${probe_result}\nВведите имя (или <code>-</code> — пропустить):"
            [ -n "$probe_mid" ] && tg_edit "$chat_id" "$probe_mid" "$info_text" "$(kbd_back)" > /dev/null \
                || tg_send "$chat_id" "$info_text" "$(kbd_back)" > /dev/null
            bot_set_state "$chat_id" "STATE=awaiting_name" "PROTO=$proto" "NAME=$name" "CUSTOM=0" "TARGET_IP=$target_ip" "PORT=$port"
            ;;
        awaiting_name)
            local proto name custom target_ip port
            proto=$(bot_get_state "$chat_id" "PROTO"); name=$(bot_get_state "$chat_id" "NAME")
            custom=$(bot_get_state "$chat_id" "CUSTOM"); target_ip=$(bot_get_state "$chat_id" "TARGET_IP")
            port=$(bot_get_state "$chat_id" "PORT")
            if [ "$text" != "-" ] && [ -n "$text" ]; then set_alias "$target_ip" "$text"; fi
            bot_set_state "$chat_id" "STATE=awaiting_note" "PROTO=$proto" "NAME=$name" "CUSTOM=$custom" "TARGET_IP=$target_ip" "PORT=$port" "IN_PORT=$(bot_get_state "$chat_id" "IN_PORT")" "OUT_PORT=$(bot_get_state "$chat_id" "OUT_PORT")"
            tg_send "$chat_id" "Примечание (или <code>-</code> — пропустить):" "$(kbd_back)" > /dev/null
            ;;
        awaiting_note)
            local proto name custom target_ip port
            proto=$(bot_get_state "$chat_id" "PROTO"); name=$(bot_get_state "$chat_id" "NAME")
            custom=$(bot_get_state "$chat_id" "CUSTOM"); target_ip=$(bot_get_state "$chat_id" "TARGET_IP")
            if [ "$text" != "-" ] && [ -n "$text" ]; then set_alias_note "$target_ip" "$text"; fi
            if [ "$custom" = "1" ]; then
                local in_port out_port
                in_port=$(bot_get_state "$chat_id" "IN_PORT"); out_port=$(bot_get_state "$chat_id" "OUT_PORT")
                bot_clear_state "$chat_id"
                apply_iptables_rules "$proto" "$in_port" "$out_port" "$target_ip" "$name"
                tg_send "$chat_id" "✅ <b>Custom</b>\n<code>$proto ${MY_IP:-*}:$in_port → $target_ip:$out_port</code>\n$(fmt_ip_tg "$target_ip")" "$(kbd_back)" > /dev/null
            else
                port=$(bot_get_state "$chat_id" "PORT")
                bot_clear_state "$chat_id"
                apply_iptables_rules "$proto" "$port" "$port" "$target_ip" "$name"
                tg_send "$chat_id" "✅ <b>$name</b>\n<code>$proto ${MY_IP:-*}:$port → $target_ip:$port</code>\n$(fmt_ip_tg "$target_ip")" "$(kbd_back)" > /dev/null
            fi ;;
        awaiting_in_port)
            if ! validate_port "$text"; then tg_send "$chat_id" "❌ Порт." "" > /dev/null; return; fi
            local proto name target_ip
            proto=$(bot_get_state "$chat_id" "PROTO"); name=$(bot_get_state "$chat_id" "NAME"); target_ip=$(bot_get_state "$chat_id" "TARGET_IP")
            bot_set_state "$chat_id" "STATE=awaiting_out_port" "PROTO=$proto" "NAME=$name" "CUSTOM=1" "TARGET_IP=$target_ip" "IN_PORT=$text"
            tg_send "$chat_id" "Вход: <code>$text</code> ✅\n\n<b>ИСХОДЯЩИЙ</b> порт:" "$(kbd_back)" > /dev/null ;;
        awaiting_out_port)
            if ! validate_port "$text"; then tg_send "$chat_id" "❌ Порт." "" > /dev/null; return; fi
            local proto name target_ip in_port
            proto=$(bot_get_state "$chat_id" "PROTO"); name=$(bot_get_state "$chat_id" "NAME")
            target_ip=$(bot_get_state "$chat_id" "TARGET_IP"); in_port=$(bot_get_state "$chat_id" "IN_PORT")
            local probe_msg; probe_msg=$(tg_send "$chat_id" "🔍 Проверяю <code>$target_ip:$text</code>..." "")
            local probe_mid; probe_mid=$(echo "$probe_msg" | jq -r '.result.message_id // empty')
            local probe_result; probe_result=$(probe_server_tg "$target_ip" "$text")
            local info_text="<code>$target_ip</code> (вход:$in_port → выход:$text)\n${probe_result}\nВведите имя (или <code>-</code> — пропустить):"
            [ -n "$probe_mid" ] && tg_edit "$chat_id" "$probe_mid" "$info_text" "$(kbd_back)" > /dev/null \
                || tg_send "$chat_id" "$info_text" "$(kbd_back)" > /dev/null
            bot_set_state "$chat_id" "STATE=awaiting_name" "PROTO=$proto" "NAME=$name" "CUSTOM=1" "TARGET_IP=$target_ip" "IN_PORT=$in_port" "OUT_PORT=$text"
            ;;
        awaiting_threshold)
            if ! validate_port "$text"; then tg_send "$chat_id" "❌ Число (1-65535):" "" > /dev/null; return; fi
            local mon_ip mon_interval
            mon_ip=$(bot_get_state "$chat_id" "MON_IP"); mon_interval=$(bot_get_state "$chat_id" "MON_INTERVAL")
            bot_clear_state "$chat_id"
            tg_send "$chat_id" "📊 <b>$(fmt_ip_short "$mon_ip")</b>\n${mon_interval}с | ${text}мс\n\nЧастота уведомлений:" "$(kbd_cooldowns "$mon_ip" "$mon_interval" "$text")" > /dev/null ;;
        *) tg_send "$chat_id" "/start или /menu" "" > /dev/null ;;
    esac
}

# ─── Bot daemon ───────────────────────────────────────────────

bot_daemon() {
    log_action "Bot daemon started (PID $$)"; echo $$ > "$BOT_PID_FILE"
    source "$KASKAD_CONF"
    [ -z "$BOT_TOKEN" ] && log_action "BOT ERROR: no token" && exit 1
    detect_interface; get_my_ip
    local offset=0
    while true; do
        local response; response=$(curl -s --max-time 35 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" 2>/dev/null)
        [ -z "$response" ] && sleep 2 && continue
        local ok; ok=$(echo "$response" | jq -r '.ok // "false"')
        [ "$ok" != "true" ] && sleep 5 && continue
        local cnt; cnt=$(echo "$response" | jq '.result | length')
        for (( i=0; i<cnt; i++ )); do
            local upd; upd=$(echo "$response" | jq ".result[$i]")
            local uid; uid=$(echo "$upd" | jq -r '.update_id'); offset=$((uid + 1))
            local cbd; cbd=$(echo "$upd" | jq -r '.callback_query.data // empty')
            if [ -n "$cbd" ]; then
                local cbi cci cmi
                cbi=$(echo "$upd" | jq -r '.callback_query.id')
                cci=$(echo "$upd" | jq -r '.callback_query.message.chat.id')
                cmi=$(echo "$upd" | jq -r '.callback_query.message.message_id')
                [ -n "$BOT_CHAT_ID" ] && [ "$cci" != "$BOT_CHAT_ID" ] && tg_answer_cb "$cbi" "Unauthorized" > /dev/null && continue
                bot_handle_callback "$cci" "$cmi" "$cbi" "$cbd"
            else
                local mci mtx
                mci=$(echo "$upd" | jq -r '.message.chat.id // empty')
                mtx=$(echo "$upd" | jq -r '.message.text // empty')
                if [ -n "$mci" ] && [ -n "$mtx" ]; then
                    [ -n "$BOT_CHAT_ID" ] && [ "$mci" != "$BOT_CHAT_ID" ] && tg_send "$mci" "⛔ Нет доступа.\nChat ID: <code>$mci</code>" "" > /dev/null && continue
                    bot_handle_message "$mci" "$mtx"
                fi
            fi
        done
    done
}

start_bot() {
    source "$KASKAD_CONF"
    [ -z "$BOT_TOKEN" ] && echo -e "${RED}Задайте BOT_TOKEN!${NC}" && return
    [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null && echo -e "${YELLOW}Уже запущен.${NC}" && return
    cat > /etc/systemd/system/kaskad-bot.service <<EOF
[Unit]
Description=Kaskad Telegram Bot
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/gokaskad --bot-daemon
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable kaskad-bot > /dev/null 2>&1; systemctl start kaskad-bot; sleep 1
    systemctl is-active kaskad-bot &>/dev/null && echo -e "${GREEN}[OK] Бот запущен.${NC}" && log_action "Bot started" \
        || echo -e "${RED}[ERROR] journalctl -u kaskad-bot${NC}"
}

stop_bot() {
    systemctl stop kaskad-bot 2>/dev/null; systemctl disable kaskad-bot 2>/dev/null; rm -f "$BOT_PID_FILE"
    echo -e "${GREEN}[OK] Остановлен.${NC}"; log_action "Bot stopped"
}

bot_menu() {
    while true; do
        clear; source "$KASKAD_CONF" 2>/dev/null
        local bs="${RED}Выкл${NC}"; [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE" 2>/dev/null)" 2>/dev/null && bs="${GREEN}Вкл ($(cat "$BOT_PID_FILE"))${NC}"
        local td="нет"; [ -n "${BOT_TOKEN:-}" ] && td="***${BOT_TOKEN: -6}"
        local ut; ut=$(bot_get_state "system" "UPDATE_TOKEN" 2>/dev/null); local ud="нет"; [ -n "$ut" ] && ud="***${ut: -6}"
        echo -e "${CYAN}━━━ Telegram Bot ━━━${NC}"
        echo -e "Статус: $bs\nТокен: ${YELLOW}$td${NC}\nChat ID: ${YELLOW}${BOT_CHAT_ID:-нет}${NC}\nUpdate: ${YELLOW}$ud${NC}\nМеню: ${YELLOW}${MENU_STYLE:-inline}${NC}\n"
        echo -e "1) Токен бота\n2) Chat ID (авто)\n3) Chat ID (вручную)\n4) ${GREEN}Запустить${NC}\n5) ${RED}Остановить${NC}\n6) GitHub PAT\n0) Назад"
        read -p "Выбор: " ch
        case $ch in
            1) echo "Токен:"; read -p "> " t; [ -n "$t" ] && save_config_val "BOT_TOKEN" "$t" && echo -e "${GREEN}OK${NC}"; read -p "Enter..." ;;
            2) [ -z "${BOT_TOKEN:-}" ] && echo -e "${RED}Токен!${NC}" && read -p "" && continue
               echo -e "${YELLOW}Отправьте боту сообщение, затем Enter.${NC}"; read -p ""
               local c; c=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=1&offset=-1" | jq -r '.result[0].message.chat.id // empty')
               [ -n "$c" ] && save_config_val "BOT_CHAT_ID" "$c" && echo -e "${GREEN}$c${NC}" || echo -e "${RED}Нет.${NC}"; read -p "Enter..." ;;
            3) echo "ID:"; read -p "> " c; [ -n "$c" ] && save_config_val "BOT_CHAT_ID" "$c" && echo -e "${GREEN}OK${NC}"; read -p "Enter..." ;;
            4) start_bot; read -p "Enter..." ;; 5) stop_bot; read -p "Enter..." ;;
            6) echo "PAT:"; read -p "> " u; [ -n "$u" ] && bot_set_state "system" "UPDATE_TOKEN=$u" && echo -e "${GREEN}OK${NC}"; read -p "Enter..." ;;
            0) return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  PROMO & INSTRUCTIONS
# ═══════════════════════════════════════════════════════════════

show_promo() {
    clear; echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║ ХОСТИНГ СО СКИДКОЙ ДО -60%                                 ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${CYAN}🌍 РФ И ЕВРОПА${NC}\n${WHITE} >>> https://vk.cc/ct29NQ${NC}"
    printf " ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "OFF60" "60% скидка" "antenka20" "+20% (3мес)" "antenka6" "+15% (6мес)" "antenka12" "+5% (12мес)"
    echo -e "\n${CYAN}🇧🇾 БЕЛАРУСЬ${NC}\n${WHITE} >>> https://vk.cc/cUxAhj${NC}"
    printf " ${YELLOW}%-12s${NC} : ${WHITE}%s${NC}\n" "OFF60" "60% скидка"
    echo -e "\n${YELLOW}QR-код... (3с)${NC}"; for i in 3 2 1; do echo -ne "$i..."; sleep 1; done; echo ""
    echo -e "\n${WHITE}"; command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "https://vk.cc/ct29NQ" || echo "Ссылки выше."; echo -e "${NC}"
    read -p "Нажмите Enter..."
}

show_instructions() {
    local p=1 tp=7
    while true; do
        clear; echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}║  📚 KASKAD PRO v${KASKAD_VERSION}  (${p}/${tp})                                  ║${NC}"
        echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        case $p in
        1) echo -e "${CYAN}═══ ЧТО ТАКОЕ КАСКАД ═══${NC}\n\nМост: Клиент → Этот сервер → Зарубежный VPN → Интернет\nПровайдер видит только РФ IP.\n\nНужно: VPS в РФ + зарубежный VPN + IP:Порт" ;;
        2) echo -e "${CYAN}═══ AWG/VLESS/MTProto ═══${NC}\n\n1) AWG: UDP, порт 51820\n2) VLESS: TCP, порт 443\n3) MTProto: TCP, порт 8443\n\nПосле ввода IP — автоматический GeoIP + пинг-тест" ;;
        3) echo -e "${CYAN}═══ CUSTOM / ПРАВИЛА ═══${NC}\n\n4) Custom: разные порты, SSH/RDP\n5) Правила: таблица с IP каскада + GeoIP\n14) Имена серверов + примечания" ;;
        4) echo -e "${CYAN}═══ PING ═══${NC}\n\n6) Live Ping с ASCII-графиком:\n  ▓▓▓░░░░░ — зелёный (<50ms)\n  ▓▓▓▓▓▓░░ — жёлтый (50-100ms)\n  ▓▓▓▓▓▓▓▓ — красный (>100ms)\n  ████████ — TIMEOUT" ;;
        5) echo -e "${CYAN}═══ МОНИТОРИНГ ═══${NC}\n\n7) Автопроверка с алертами в Telegram\nИнтервалы: 10с / 1мин / 5мин\nУведомления: 10с / 60с / 5мин / 15мин\nСлужба авто-запуск/стоп" ;;
        6) echo -e "${CYAN}═══ TELEGRAM BOT ═══${NC}\n\n8) @BotFather → токен → Chat ID → запуск\nДва режима меню:\n  Inline — кнопки под сообщением\n  Reply — большие кнопки внизу экрана\nПереключение: кнопка в меню или /inline" ;;
        7) echo -e "${CYAN}═══ ВОЗМОЖНОСТИ БОТА ═══${NC}\n\nПравила, Ping (1x/10x/60с), Мониторинг\n💻 Система: CPU/RAM/Swap/Disk/процессы\n🏢 Хостинг: промокоды\nGeoIP + пинг-тест при добавлении\nИмена + примечания серверов" ;;
        esac
        echo -e "\n${MAGENTA}──────────────────────────────────────────────────────────────${NC}"
        [ "$p" -eq 1 ] && echo -e "  ${YELLOW}[N]${NC} Далее  ${YELLOW}[0]${NC} Выход"
        [ "$p" -eq "$tp" ] && echo -e "  ${YELLOW}[P]${NC} Назад  ${YELLOW}[0]${NC} Выход"
        (( p > 1 && p < tp )) && echo -e "  ${YELLOW}[P]${NC} Назад  ${YELLOW}[N]${NC} Далее  ${YELLOW}[0]${NC} Выход"
        read -p "  > " nav
        case "$nav" in [nN]) ((p<tp)) && ((p++));; [pP]) ((p>1)) && ((p--));; 0) return;; [1-7]) p="$nav";; esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        clear
        echo -e "${MAGENTA}******************************************************"
        echo " anten-ka  ·  Kaskad PRO v${KASKAD_VERSION}"
        echo " YouTube: https://www.youtube.com/@antenkaru"
        echo -e "******************************************************${NC}"
        echo -e "${WHITE}IP: ${GREEN}${MY_IP}${NC}  ${WHITE}Iface: ${CYAN}${IFACE}${NC}"
        echo -e "------------------------------------------------------"
        echo -e " 1) ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e " 2) ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e " 3) ${CYAN}TProxy / MTProto${NC} (TCP)"
        echo -e " 4) 🛠  ${YELLOW}Кастомное правило${NC}"
        echo -e " 5) 📋 Правила"
        echo -e " 6) 🏓 ${CYAN}Ping (live)${NC}"
        echo -e " 7) 📊 ${CYAN}Мониторинг${NC}"
        echo -e " 8) 🤖 ${CYAN}Telegram Bot${NC}"
        echo -e " 9) ${RED}Удалить правило${NC}"
        echo -e "10) ${RED}Сбросить всё${NC}"
        echo -e "11) ${YELLOW}Обновить скрипт${NC}"
        echo -e "12) ${YELLOW}PROMO${NC}"
        echo -e "13) ${MAGENTA}📚 Инструкция${NC}"
        echo -e "14) ${WHITE}Имена серверов${NC}"
        echo -e "15) ${RED}⚠  Удалить Kaskad PRO${NC}"
        echo -e " 0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Выбор: " ch
        case $ch in
            1) configure_rule "udp" "AmneziaWG";; 2) configure_rule "tcp" "VLESS";;
            3) configure_rule "tcp" "MTProto/TProxy";; 4) configure_custom_rule;;
            5) list_active_rules;; 6) ping_menu;; 7) monitoring_menu;; 8) bot_menu;;
            9) delete_single_rule;; 10) flush_rules;; 11) self_update;; 12) show_promo;;
            13) show_instructions;; 14) manage_aliases_menu;; 15) full_uninstall;; 0) exit 0;; esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  STARTUP WITH PROGRESS
# ═══════════════════════════════════════════════════════════════

run_startup() {
    local total=7 s=0

    clear; echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║              KASKAD PRO v${KASKAD_VERSION} — Загрузка                          ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Проверка прав root..." "$s" "$total"
    check_root
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Права root подтверждены                    \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Загрузка конфигурации..." "$s" "$total"
    init_config
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Конфигурация загружена                     \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Установка gokaskad..." "$s" "$total"
    if [ "$(readlink -f "$0" 2>/dev/null)" != "/usr/local/bin/gokaskad" ]; then
        cp -f "$0" "/usr/local/bin/gokaskad"; chmod +x "/usr/local/bin/gokaskad"
    fi
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Команда gokaskad                            \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  IP Forwarding + BBR..." "$s" "$total"
    if grep -qE '^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
        sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   IP Forwarding + BBR Turbo                   \n" "$s" "$total"

    export DEBIAN_FRONTEND=noninteractive
    local need_install=0
    for cmd in iptables jq curl qrencode; do command -v "$cmd" &>/dev/null || need_install=1; done
    dpkg -s iptables-persistent &>/dev/null 2>&1 || need_install=1
    ((s++))
    if [ "$need_install" -eq 1 ]; then
        printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Установка пакетов" "$s" "$total"
        ( while true; do printf "."; sleep 1; done ) &
        local dpid=$!
        if command -v apt-get &>/dev/null; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y iptables-persistent netfilter-persistent qrencode jq curl procps > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y iptables-services jq qrencode curl procps-ng > /dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y iptables-services jq qrencode curl procps-ng > /dev/null 2>&1
        else
            kill $dpid 2>/dev/null; wait $dpid 2>/dev/null
            printf "\r  ${CYAN}[%d/%d]${NC}  ${RED}✗${NC}   Пакетный менеджер не найден!                \n" "$s" "$total"
            exit 1
        fi
        kill $dpid 2>/dev/null; wait $dpid 2>/dev/null
        printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Пакеты установлены                          \n" "$s" "$total"
    else
        printf "  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Все зависимости на месте                    \n" "$s" "$total"
    fi

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Сетевой интерфейс..." "$s" "$total"
    detect_interface
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Интерфейс: %-20s              \n" "$s" "$total" "$IFACE"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Внешний IP..." "$s" "$total"
    get_my_ip
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   IP: %-25s              \n" "$s" "$total" "$MY_IP"

    echo ""
    local w=40 bar=""
    for ((i=0; i<w; i++)); do bar+="█"; done
    echo -e "  ${CYAN}[${GREEN}${bar}${CYAN}]${NC} ${GREEN}100%${NC}"
    echo ""
    echo -e "  ${GREEN}✅  Kaskad PRO v${KASKAD_VERSION} готов к работе!${NC}"
    echo ""
    sleep 2

    show_promo
    show_menu
}

# ═══════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════

case "${1:-}" in
    --bot-daemon) init_config; bot_daemon ;;
    --monitor-daemon) init_config; monitor_daemon ;;
    *) run_startup ;;
esac
