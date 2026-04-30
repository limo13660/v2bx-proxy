#!/usr/bin/env bash
# V2bX Nginx masquerade installer (Hysteria2 + TLS)
# Architecture:
#   TCP: Nginx website only on 443 for masquerade
#   UDP: V2bX Hysteria2 listens only on 443
#   UDP: user-facing port range (default 10001-10099) is NAT redirected to local 443
#
# Purpose:
# - Keep the usable grpc.sh interaction style
# - Adapt the deployment to a V2board/V2bX Hysteria2 node
# - Reuse the same domain/certificate for Nginx(TCP) and HY2(UDP)
# - Keep random/multiple client ports by redirecting the UDP range to 443, similar to agsb's port-hopping idea

set -u
set -o pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

V2BX_BIN="/usr/local/V2bX/V2bX"
V2BX_SERVICE="V2bX"
V2BX_PROCESS_PATTERN='(^|/)(V2bX|v2bx)( |$)'
NGINX_CONF_PATH="/etc/nginx/conf.d/"
BT="false"
PMT=""
CMD_INSTALL=""
CRON_SERVICE="cron"

IPV4=""
IPV6=""
IP=""
DOMAIN=""
HTTP_PORT="80"
PORT="10001-10099"
PORT_START=""
PORT_END=""
PRIMARY_PORT=""
PORT_RANGE_LIMIT="1000"
HY2_LISTEN_PORT="443"
FORWARD_SCRIPT="/usr/local/sbin/v2hy2-port-forward.sh"
FORWARD_SERVICE="v2hy2-port-forward.service"
CERT_FILE=""
KEY_FILE=""
PROXY_URL=""
REMOTE_HOST=""
ALLOW_SPIDER="n"
NEED_BBR="n"
INSTALL_BBR="false"
SITE_CONF=""
ROBOT_CONFIG=""
DEFAULT_PROXY_URL="https://bing.ioliu.cn"

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

die() {
    colorEcho "$RED" " $1"
    exit 1
}

warn() {
    colorEcho "$YELLOW" " $1"
}

info() {
    colorEcho "$BLUE" " $1"
}

success() {
    colorEcho "$GREEN" " $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

fetch_public_ip() {
    local family="$1"
    curl -fsSL --connect-timeout 4 --max-time 10 "-${family}" ip.sb 2>/dev/null || true
}

safe_wget() {
    local url="$1"
    local out="$2"

    rm -f "$out"

    if command_exists wget; then
        wget -q --timeout=20 --tries=2 --max-redirect=3 -O "$out" "$url" && [[ -s "$out" ]] && return 0
    fi

    if command_exists curl; then
        curl -fsSL --connect-timeout 10 --max-time 60 -o "$out" "$url" && [[ -s "$out" ]] && return 0
    fi

    rm -f "$out"
    return 1
}

write_robots_file() {
    mkdir -p /usr/share/nginx/html

    if [[ "$ALLOW_SPIDER" == "n" ]]; then
        cat > /usr/share/nginx/html/robots.txt <<'EOF_ROBOT'
User-Agent: *
Disallow: /
EOF_ROBOT
        ROBOT_CONFIG='location = /robots.txt {}'
    else
        rm -f /usr/share/nginx/html/robots.txt
        ROBOT_CONFIG=''
    fi
}

extract_archive() {
    local archive="$1"
    local outdir="$2"

    mkdir -p "$outdir"

    if tar -tf "$archive" >/dev/null 2>&1; then
        tar -xf "$archive" -C "$outdir" || return 1
        return 0
    fi

    if tar -tzf "$archive" >/dev/null 2>&1; then
        tar -xzf "$archive" -C "$outdir" || return 1
        return 0
    fi

    if command_exists unzip && unzip -tq "$archive" >/dev/null 2>&1; then
        unzip -oq "$archive" -d "$outdir" >/dev/null 2>&1 || return 1
        return 0
    fi

    return 1
}

find_template_dir() {
    local base="$1"
    local found=""

    if [[ -d "$base/html_template" ]]; then
        echo "$base/html_template"
        return 0
    fi

    found="$(find "$base" -mindepth 1 -maxdepth 3 -type d -name 'html_template' 2>/dev/null | head -n 1)"
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi

    found="$(find "$base" -mindepth 1 -maxdepth 3 -type f -name 'index.html' 2>/dev/null | head -n 1)"
    if [[ -n "$found" ]]; then
        dirname "$found"
        return 0
    fi

    return 1
}

find_template_archive() {
    local base="$1"
    local found=""

    if [[ -f "$base/html_template.zip" ]]; then
        echo "$base/html_template.zip"
        return 0
    fi

    found="$(find "$base" -mindepth 1 -maxdepth 4 -type f -name 'html_template.zip' 2>/dev/null | head -n 1)"
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi

    return 1
}

template_has_index() {
    local base="$1"
    [[ -f "$base/index.html" || -f "$base/index.htm" ]]
}

normalize_web_permissions() {
    local web_root="/usr/share/nginx/html"

    [[ -d "$web_root" ]] || return 0

    find "$web_root" -type d -exec chmod 755 {} + >/dev/null 2>&1 || true
    find "$web_root" -type f -exec chmod 644 {} + >/dev/null 2>&1 || true
}

install_default_template() {
    mkdir -p /usr/share/nginx/html
    cat > /usr/share/nginx/html/index.html <<EOF_DEFAULT_HTML
<!doctype html>
<html lang="zh-CN">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${DOMAIN}</title>
    <style>
        body { margin: 0; font-family: Arial, Helvetica, sans-serif; background: #0f172a; color: #e2e8f0; }
        .wrap { min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 24px; }
        .card { width: 100%; max-width: 760px; background: rgba(15, 23, 42, 0.88); border: 1px solid rgba(148, 163, 184, 0.25); border-radius: 16px; padding: 32px; box-sizing: border-box; }
        h1 { margin: 0 0 12px; font-size: 28px; }
        p { margin: 10px 0; line-height: 1.7; color: #cbd5e1; }
        code { color: #93c5fd; }
    </style>
</head>
<body>
    <div class="wrap">
        <div class="card">
            <h1>Welcome</h1>
            <p>站点 <code>${DOMAIN}</code> 已成功部署。</p>
            <p>当前页面为脚本自动生成的默认静态首页。</p>
            <p>TCP ${PORT} 由 Nginx 提供正常网站；UDP ${PORT} 预留给 V2bX 的 Hysteria2 节点。</p>
            <p>如需自定义伪装站内容，请把网页文件放到 <code>/usr/share/nginx/html</code>。</p>
        </div>
    </div>
</body>
</html>
EOF_DEFAULT_HTML
    write_robots_file
    normalize_web_permissions
    success "已生成默认静态首页"
}

nginx_test() {
    if [[ "$BT" == "false" ]]; then
        nginx -t >/dev/null 2>&1
    else
        nginx -t -c /www/server/nginx/conf/nginx.conf >/dev/null 2>&1
    fi
}

nginx_is_active() {
    if [[ "$BT" == "false" ]]; then
        systemctl is-active --quiet nginx
    else
        pgrep -x nginx >/dev/null 2>&1
    fi
}

nginx_reload_cmd() {
    if [[ "$BT" == "false" ]]; then
        echo 'systemctl reload nginx >/dev/null 2>&1 || true'
    else
        echo 'nginx -s reload >/dev/null 2>&1 || true'
    fi
}

startNginx() {
    if [[ "$BT" == "false" ]]; then
        systemctl start nginx
    else
        nginx -c /www/server/nginx/conf/nginx.conf
    fi
}

stopNginx() {
    if [[ "$BT" == "false" ]]; then
        systemctl stop nginx >/dev/null 2>&1 || true
    else
        if pgrep -x nginx >/dev/null 2>&1; then
            nginx -s stop >/dev/null 2>&1 || true
        fi
    fi
}

reloadNginx() {
    if [[ "$BT" == "false" ]]; then
        systemctl reload nginx
    else
        nginx -s reload
    fi
}

is_valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_proxy_url() {
    local re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[-A-Za-z0-9._~!$&()*+,;=:@%/?#]*)?$'
    [[ "$1" =~ $re ]]
}

is_port_in_use_tcp() {
    local port="$1"

    if command_exists ss; then
        ss -lnt "( sport = :${port} )" 2>/dev/null | awk 'NR>1{exit 0} END{exit 1}'
        return $?
    fi

    if command_exists netstat; then
        netstat -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'
        return $?
    fi

    return 1
}

is_port_in_use_udp() {
    local port="$1"

    if command_exists ss; then
        ss -lnu "( sport = :${port} )" 2>/dev/null | awk 'NR>1{exit 0} END{exit 1}'
        return $?
    fi

    if command_exists netstat; then
        netstat -lnu 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'
        return $?
    fi

    return 1
}

set_port_range() {
    local spec="$1"
    local start=""
    local end=""
    local count=""

    spec="${spec//[[:space:]]/}"

    if [[ "$spec" =~ ^([1-9][0-9]{0,4})$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="$start"
    elif [[ "$spec" =~ ^([1-9][0-9]{0,4})-([1-9][0-9]{0,4})$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
    else
        die "连接端口格式错误，请输入单端口或端口段，例如 443 或 10001-10099"
    fi

    (( start >= 100 && start <= 65535 )) || die "连接端口起始值范围错误"
    (( end >= 100 && end <= 65535 )) || die "连接端口结束值范围错误"
    (( start <= end )) || die "连接端口段起始值不能大于结束值"

    count=$((end - start + 1))
    (( count <= PORT_RANGE_LIMIT )) || die "连接端口段最多支持 ${PORT_RANGE_LIMIT} 个端口，避免 Nginx 配置过大"

    PORT_START="$start"
    PORT_END="$end"
    PRIMARY_PORT="$start"

    if [[ "$start" == "$end" ]]; then
        PORT="$start"
    else
        PORT="${start}-${end}"
    fi
}

port_spec_contains() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= PORT_START && port <= PORT_END ))
}

port_spec_to_ufw() {
    if [[ "$PORT_START" == "$PORT_END" ]]; then
        echo "$PORT_START"
    else
        echo "${PORT_START}:${PORT_END}"
    fi
}

port_spec_to_iptables() {
    port_spec_to_ufw
}

build_nginx_https_listens() {
    # Nginx only provides the camouflage website on TCP 443.
    # The public HY2 port range is UDP-only and is redirected to local UDP 443.
    printf "    listen ${HY2_LISTEN_PORT} ssl http2;\n"
    printf "    listen [::]:${HY2_LISTEN_PORT} ssl http2;\n"
}

check_port_range_in_use_tcp() {
    local p=""

    for ((p=PORT_START; p<=PORT_END; p++)); do
        is_port_in_use_tcp "$p" || return 1
    done

    return 0
}

check_port_range_in_use_udp() {
    local p=""

    for ((p=PORT_START; p<=PORT_END; p++)); do
        is_port_in_use_udp "$p" || return 1
    done

    return 0
}

setup_hy2_port_forward() {
    local iptables_ports=""
    iptables_ports="$(port_spec_to_iptables)"

    command_exists iptables || {
        warn "未检测到 iptables，无法自动配置 UDP ${PORT} → ${HY2_LISTEN_PORT} 转发"
        warn "请手动配置等效 nftables/防火墙规则"
        return 1
    }

    # UDP public range -> local HY2 UDP 443.
    iptables -t nat -C PREROUTING -p udp --dport "$iptables_ports" -j REDIRECT --to-ports "$HY2_LISTEN_PORT" >/dev/null 2>&1 \
        || iptables -t nat -A PREROUTING -p udp --dport "$iptables_ports" -j REDIRECT --to-ports "$HY2_LISTEN_PORT"

    # Keep a local OUTPUT rule for loopback tests. It does not affect external clients.
    iptables -t nat -C OUTPUT -p udp -d 127.0.0.1/32 --dport "$iptables_ports" -j REDIRECT --to-ports "$HY2_LISTEN_PORT" >/dev/null 2>&1 \
        || iptables -t nat -A OUTPUT -p udp -d 127.0.0.1/32 --dport "$iptables_ports" -j REDIRECT --to-ports "$HY2_LISTEN_PORT" >/dev/null 2>&1 || true

    success "已配置 UDP ${PORT} → 本机 ${HY2_LISTEN_PORT} 的端口转发"
}

create_hy2_forward_service() {
    local iptables_ports=""
    iptables_ports="$(port_spec_to_iptables)"

    command_exists systemctl || return 0
    command_exists iptables || return 0

    cat > "$FORWARD_SCRIPT" <<EOF_FORWARD_SCRIPT
#!/usr/bin/env bash
set -e
iptables -C INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport ${HTTP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport ${HY2_LISTEN_PORT} -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport ${HY2_LISTEN_PORT} -j ACCEPT
iptables -C INPUT -p udp --dport ${HY2_LISTEN_PORT} -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport ${HY2_LISTEN_PORT} -j ACCEPT
iptables -C INPUT -p udp --dport ${iptables_ports} -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport ${iptables_ports} -j ACCEPT
iptables -t nat -C PREROUTING -p udp --dport ${iptables_ports} -j REDIRECT --to-ports ${HY2_LISTEN_PORT} >/dev/null 2>&1 || iptables -t nat -A PREROUTING -p udp --dport ${iptables_ports} -j REDIRECT --to-ports ${HY2_LISTEN_PORT}
iptables -t nat -C OUTPUT -p udp -d 127.0.0.1/32 --dport ${iptables_ports} -j REDIRECT --to-ports ${HY2_LISTEN_PORT} >/dev/null 2>&1 || iptables -t nat -A OUTPUT -p udp -d 127.0.0.1/32 --dport ${iptables_ports} -j REDIRECT --to-ports ${HY2_LISTEN_PORT} >/dev/null 2>&1 || true
EOF_FORWARD_SCRIPT
    chmod 755 "$FORWARD_SCRIPT"

    cat > "/etc/systemd/system/${FORWARD_SERVICE}" <<EOF_FORWARD_SERVICE
[Unit]
Description=V2bX HY2 UDP port range redirect to 443
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FORWARD_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_FORWARD_SERVICE

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "$FORWARD_SERVICE" >/dev/null 2>&1 || warn "端口转发 systemd 服务启用失败，请手动执行 ${FORWARD_SCRIPT}"
}

remove_hy2_forward_service() {
    if command_exists systemctl; then
        systemctl disable --now "$FORWARD_SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${FORWARD_SERVICE}"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$FORWARD_SCRIPT"
}

show_hy2_forward_rules() {
    if command_exists iptables; then
        iptables -t nat -S PREROUTING 2>/dev/null | grep -E -- "--dport (${PORT}|$(port_spec_to_iptables)) .*--to-ports ${HY2_LISTEN_PORT}" || true
    fi
}

checkSystem() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份执行该脚本"

    if command_exists yum; then
        PMT="yum"
        CMD_INSTALL="yum install -y"
        CRON_SERVICE="crond"
    elif command_exists apt; then
        PMT="apt"
        CMD_INSTALL="apt install -y"
        CRON_SERVICE="cron"
    else
        die "不受支持的 Linux 系统"
    fi

    command_exists systemctl || die "系统版本过低，请升级到支持 systemd 的版本"

    if command_exists bt; then
        BT="true"
        NGINX_CONF_PATH="/www/server/panel/vhost/nginx/"
    fi

    IPV4="$(fetch_public_ip 4)"
    IPV6="$(fetch_public_ip 6)"
    IP="${IPV4:-$IPV6}"
}

checkV2bX() {
    if [[ -x "$V2BX_BIN" ]]; then
        return 0
    fi
    if get_v2bx_service_name >/dev/null 2>&1; then
        return 0
    fi
    if pgrep -af "$V2BX_PROCESS_PATTERN" >/dev/null 2>&1; then
        return 0
    fi
    die "未检测到 V2bX，请先安装 V2bX 再运行此脚本"
}

get_v2bx_service_name() {
    local service_name=""

    service_name="$(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -iE '^(v2bx)\.service$' \
        | head -n 1)"

    if [[ -n "$service_name" ]]; then
        echo "${service_name%.service}"
        return 0
    fi

    return 1
}

restartV2bX() {
    local service_name=""

    if service_name="$(get_v2bx_service_name)"; then
        systemctl restart "$service_name" || return 1
        return 0
    fi
    if command_exists service; then
        service "$V2BX_SERVICE" restart || return 1
        return 0
    fi
    return 1
}

statusV2bX() {
    local service_name=""

    if service_name="$(get_v2bx_service_name)"; then
        systemctl is-active --quiet "$service_name"
        return $?
    fi
    if [[ -x "$V2BX_BIN" ]] || pgrep -af "$V2BX_PROCESS_PATTERN" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

resolve_domain_to_server() {
    local host="$1"
    local resolved=""

    resolved="$({
        getent ahosts "$host" 2>/dev/null | awk '{print $1}'
        command_exists dig && dig +short A "$host" 2>/dev/null
        command_exists dig && dig +short AAAA "$host" 2>/dev/null
    } | sed '/^$/d' | sort -u)"

    [[ -n "$resolved" ]] || return 1

    if [[ -n "$IPV4" ]] && echo "$resolved" | grep -Fxq "$IPV4"; then
        return 0
    fi
    if [[ -n "$IPV6" ]] && echo "$resolved" | grep -Fxq "$IPV6"; then
        return 0
    fi
    return 1
}

getData() {
    echo ""
    echo " 运行之前请确认如下条件已经具备："
    colorEcho "$YELLOW" "  1. 一个伪装域名 DNS 解析指向当前服务器 IP（${IP:-未检测到公网IP}）"
    colorEcho "$BLUE"   "  2. 可手动输入当前域名专属证书路径；如不输入，再尝试 /root/v2ray.pem 和 /root/v2ray.key"
    colorEcho "$BLUE"   "  3. 如果没有现成证书，脚本仍可使用 acme.sh 自动申请"
    colorEcho "$BLUE"   "  4. V2board / V2bX 节点协议改为 Hysteria2，服务端只监听 UDP ${HY2_LISTEN_PORT}"
    colorEcho "$BLUE"   "  5. 最终结构为：TCP ${HY2_LISTEN_PORT} 给 Nginx 网站；UDP ${PORT} 入口转发到 UDP ${HY2_LISTEN_PORT}"
    echo ""
    read -r -p " 确认满足按 y，按其他退出脚本：" answer
    [[ "${answer,,}" == "y" ]] || exit 0

    echo ""
    while true; do
        read -r -p " 请输入伪装域名：" DOMAIN
        DOMAIN="${DOMAIN,,}"
        if is_valid_domain "$DOMAIN"; then
            break
        fi
        colorEcho "$RED" " 域名输入错误，请重新输入！"
    done
    info "伪装域名(host)：$DOMAIN"

    echo ""
    read -r -p " 请输入当前域名证书路径(留空则不使用现成证书)：" CERT_FILE
    if [[ -n "$CERT_FILE" ]]; then
        read -r -p " 请输入当前域名私钥路径：" KEY_FILE
        [[ -n "$KEY_FILE" ]] || die "已输入证书路径时，私钥路径不能为空"
        [[ -f "$CERT_FILE" ]] || die "证书文件不存在：$CERT_FILE"
        [[ -f "$KEY_FILE" ]] || die "私钥文件不存在：$KEY_FILE"
        info "将直接使用手动输入的证书：$CERT_FILE"
    elif [[ -f ~/v2ray.pem && -f ~/v2ray.key ]]; then
        info "检测到 /root/v2ray.pem 和 /root/v2ray.key，将使用其部署"
        CERT_FILE="/etc/ysbl/${DOMAIN}.pem"
        KEY_FILE="/etc/ysbl/${DOMAIN}.key"
    fi

    if [[ -n "$IP" ]] && resolve_domain_to_server "$DOMAIN"; then
        info "${DOMAIN} 已解析到当前服务器 IP"
    else
        die "域名未解析到当前服务器 IP（${IP:-unknown}），请先修正 DNS"
    fi

    echo ""
    read -r -p " 请输入 HTTP 端口[1-65535，默认80]：" HTTP_PORT
    [[ -z "$HTTP_PORT" ]] && HTTP_PORT=80
    [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || die "HTTP 端口必须是数字"
    (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || die "HTTP 端口范围错误"
    [[ "${HTTP_PORT:0:1}" != "0" ]] || die "端口不能以 0 开头"
    info "HTTP 端口：$HTTP_PORT"

    echo ""
    read -r -p " 请输入用户连接端口[单端口或端口段，默认10001-10099]：" PORT
    [[ -z "$PORT" ]] && PORT="10001-10099"
    set_port_range "$PORT"
    info "用户连接端口(UDP入口)：$PORT"
    info "Nginx/HY2 实际监听端口：${HY2_LISTEN_PORT}（TCP 给 Nginx，UDP 给 HY2）"

    if port_spec_contains "$HTTP_PORT"; then
        die "HTTP 端口不能落在用户连接端口/端口段内"
    fi

    if port_spec_contains "$HY2_LISTEN_PORT"; then
        die "用户连接端口段不能包含 ${HY2_LISTEN_PORT}，因为 ${HY2_LISTEN_PORT} 已作为 Nginx/HY2 后端监听端口"
    fi

    echo ""
    info "请选择伪装站类型:"
    echo "   1) 静态网站(位于 /usr/share/nginx/html, 默认带一个模板)"
    echo "   2) 自定义反代站点(需以 http 或 https 开头，默认：${DEFAULT_PROXY_URL})"
    read -r -p "  请选择伪装网站类型[默认:1]：" answer
    case "${answer:-1}" in
        1)
            PROXY_URL=""
            ;;
        2)
            read -r -p " 请输入反代站点(以 http 或 https 开头，默认：${DEFAULT_PROXY_URL})：" PROXY_URL
            PROXY_URL="${PROXY_URL:-$DEFAULT_PROXY_URL}"
            is_valid_proxy_url "$PROXY_URL" || die "反代网站格式不合法！"
            ;;
        *)
            die "请输入正确的选项！"
            ;;
    esac
    REMOTE_HOST="$(echo "$PROXY_URL" | cut -d/ -f3)"
    info "伪装网站：${PROXY_URL:-本地静态模板}"

    echo ""
    info "是否允许搜索引擎爬取网站？[默认：不允许]"
    echo "   y) 允许"
    echo "   n) 不允许"
    read -r -p "  请选择：[y/n] " answer
    if [[ -z "$answer" ]]; then
        ALLOW_SPIDER="n"
    elif [[ "${answer,,}" == "y" ]]; then
        ALLOW_SPIDER="y"
    else
        ALLOW_SPIDER="n"
    fi
    info "允许搜索引擎：$ALLOW_SPIDER"

    echo ""
    read -r -p " 是否安装 BBR(默认不安装)? [y/n]: " NEED_BBR
    [[ -z "$NEED_BBR" ]] && NEED_BBR="n"
    [[ "${NEED_BBR,,}" == "y" ]] && NEED_BBR="y" || NEED_BBR="n"
    info "安装 BBR：$NEED_BBR"
}

installNginx() {
    echo ""
    info "安装 nginx..."
    if [[ "$BT" == "false" ]]; then
        if [[ "$PMT" == "yum" ]]; then
            $CMD_INSTALL epel-release >/dev/null 2>&1 || true
        fi
        $CMD_INSTALL nginx || die "Nginx 安装失败"
        systemctl enable nginx >/dev/null 2>&1 || true
    else
        command_exists nginx || die "检测到宝塔环境，请先在宝塔安装 nginx"
    fi
}

prepareWebRoot() {
    mkdir -p /usr/share/nginx/html
    write_robots_file
}

ensureAcme() {
    mkdir -p /etc/ysbl

    if [[ "$PMT" == "yum" ]]; then
        $CMD_INSTALL socat openssl curl ca-certificates cronie || die "依赖安装失败"
    else
        $CMD_INSTALL socat openssl curl ca-certificates cron || die "依赖安装失败"
    fi
    systemctl enable "$CRON_SERVICE" >/dev/null 2>&1 || true
    systemctl start "$CRON_SERVICE" >/dev/null 2>&1 || true

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL --connect-timeout 10 --max-time 60 https://get.acme.sh | sh -s email="admin@${DOMAIN}" >/dev/null 2>&1
    fi
    [[ -f ~/.acme.sh/acme.sh ]] || die "acme.sh 安装失败"
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

cert_source_exists() {
    [[ -f ~/.acme.sh/${DOMAIN}_ecc/fullchain.cer || -f ~/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer ]]
}

installExistingCert() {
    local reload_cmd
    reload_cmd="$(nginx_reload_cmd)"

    CERT_FILE="/etc/ysbl/${DOMAIN}.pem"
    KEY_FILE="/etc/ysbl/${DOMAIN}.key"

    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --reloadcmd "$reload_cmd" || die "证书安装失败"

    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die "证书安装失败"
}

open_acme_port() {
    if command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="80/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        return 0
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -vq inactive; then
        ufw allow "80/tcp" >/dev/null 2>&1 || true
        return 0
    fi

    if command_exists iptables; then
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    fi
}

getCert() {
    mkdir -p /etc/ysbl

    if [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]]; then
        if [[ "$CERT_FILE" == "/etc/ysbl/${DOMAIN}.pem" && "$KEY_FILE" == "/etc/ysbl/${DOMAIN}.key" ]]; then
            cp ~/v2ray.pem "$CERT_FILE"
            cp ~/v2ray.key "$KEY_FILE"
            [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die "复制现有证书失败"
        else
            [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die "指定的证书文件不存在"
        fi
        success "检测到现成证书，跳过申请：$CERT_FILE"
        return 0
    fi

    ensureAcme

    local certMode default_mode="1"
    echo ""
    info "请选择证书申请方式："
    echo -e "  ${GREEN}1.${PLAIN} Standalone (要求外部 80 端口可用)"
    echo -e "  ${GREEN}2.${PLAIN} Cloudflare DNS"

    if is_port_in_use_tcp 80; then
        default_mode="2"
        warn "检测到 80 端口当前被占用，默认推荐 Cloudflare DNS 模式"
    fi

    if [[ "$HTTP_PORT" != "80" ]]; then
        warn "即使你把网站 HTTP 端口改成了 ${HTTP_PORT}，Let's Encrypt 的 HTTP-01 仍通常要求外部 80 端口可访问。"
    fi

    read -r -p "请输入选项 [1-2]（默认${default_mode}）：" certMode
    certMode="${certMode:-$default_mode}"
    [[ "$certMode" == "1" || "$certMode" == "2" ]] || die "证书申请方式输入错误"

    if [[ "$certMode" == "2" ]]; then
        local CF_Token=""
        if [[ -f /root/.acme.sh/account.conf ]]; then
            CF_Token="$(grep '^CF_Token=' /root/.acme.sh/account.conf 2>/dev/null | head -n 1 | cut -d '"' -f2)"
        fi
        if [[ -z "$CF_Token" ]]; then
            echo ""
            info "请输入 Cloudflare API Token（需要 DNS 编辑权限）："
            read -r -p "CF_Token: " CF_Token
        fi
        [[ -n "$CF_Token" ]] || die "CF_Token 不能为空"
        export CF_Token

        if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --keylength ec-256 --dns dns_cf; then
            :
        else
            if cert_source_exists; then
                warn "检测到已有可用证书，跳过重新签发，继续安装"
            else
                die "Cloudflare DNS 申请证书失败"
            fi
        fi
    else
        stopNginx
        sleep 1
        open_acme_port
        if is_port_in_use_tcp 80; then
            die "检测到 80 端口仍被其他进程占用，请释放后再申请证书，或改用 Cloudflare DNS 模式"
        fi

        if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --keylength ec-256 --standalone; then
            :
        else
            if cert_source_exists; then
                warn "检测到已有可用证书，跳过重新签发，继续安装"
            else
                die "Standalone 申请证书失败"
            fi
        fi
    fi

    cert_source_exists || die "获取证书失败，请检查域名解析 / CF Token / 网络"
    installExistingCert
    success "证书安装成功：$CERT_FILE"
}

configNginx() {
    prepareWebRoot
    mkdir -p "$NGINX_CONF_PATH"
    SITE_CONF="${NGINX_CONF_PATH}${DOMAIN}.conf"

    local tmp_conf="${SITE_CONF}.tmp"
    local bak_conf="${SITE_CONF}.bak"
    local site_action=""
    local redirect_suffix=""
    local https_listens=""

    # HTTP always redirects to the camouflage HTTPS site on TCP 443.
    redirect_suffix=""

    https_listens="$(build_nginx_https_listens)"

    if [[ -n "$PROXY_URL" ]]; then
        site_action="proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
        proxy_set_header Host $REMOTE_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        cp -f "$SITE_CONF" "$bak_conf" || die "备份现有 Nginx 配置失败"
    fi

    cat > "$tmp_conf" <<EOF_NGINX_SITE
server {
    listen ${HTTP_PORT};
    listen [::]:${HTTP_PORT};
    server_name ${DOMAIN};
    return 301 https://\$server_name${redirect_suffix}\$request_uri;
}

server {
${https_listens}
    server_name ${DOMAIN};
    charset utf-8;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=31536000" always;

    root /usr/share/nginx/html;
    index index.html index.htm;

    location / {
        ${site_action}
        try_files \$uri \$uri/ /index.html;
    }
    ${ROBOT_CONFIG}
}
EOF_NGINX_SITE

    mv -f "$tmp_conf" "$SITE_CONF"

    if nginx_test; then
        rm -f "$bak_conf"
        return 0
    fi

    warn "新的 Nginx 站点配置校验失败，正在回滚..."
    if [[ -f "$bak_conf" ]]; then
        mv -f "$bak_conf" "$SITE_CONF"
    else
        rm -f "$SITE_CONF"
    fi
    nginx_test || true
    die "Nginx 配置测试失败，请检查站点配置"
}

installTemplate() {
    if [[ -n "$PROXY_URL" ]]; then
        return 0
    fi

    echo ""
    info "安装网页模板..."

    local tmpfile="/tmp/html_template.pkg"
    local tmpdir="/tmp/html_template_extract"
    local staged="/tmp/html_template_staged"
    local extracted_dir=""
    local nested_archive=""
    local downloaded="false"
    local extracted="false"
    local script_dir=""
    local url=""
    local -a template_urls=(
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/html_template.zip"
        "https://github.com/limo13660/v2bx-proxy/archive/refs/heads/main.tar.gz"
        "https://codeload.github.com/limo13660/v2bx-proxy/tar.gz/refs/heads/main"
    )

    rm -rf "$tmpfile" "$tmpdir" "$staged"

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$script_dir/html_template.zip" ]]; then
        info "优先使用脚本目录内的模板包：$script_dir/html_template.zip"
        if extract_archive "$script_dir/html_template.zip" "$tmpdir"; then
            extracted="true"
        else
            warn "本地模板包解压失败：$script_dir/html_template.zip"
            rm -rf "$tmpdir"
        fi
    fi

    if [[ "$extracted" != "true" ]]; then
        for url in "${template_urls[@]}"; do
            rm -rf "$tmpfile" "$tmpdir"
            info "尝试下载模板资源：$url"

            if ! safe_wget "$url" "$tmpfile"; then
                warn "模板下载失败：$url"
                continue
            fi

            downloaded="true"

            if extract_archive "$tmpfile" "$tmpdir"; then
                extracted="true"
                break
            fi

            warn "下载内容不是有效的 tar/tar.gz/zip 压缩包：$url"
        done
    fi

    if [[ "$extracted" != "true" ]]; then
        if [[ "$downloaded" == "true" ]]; then
            warn "模板资源已下载，但格式不正确；改为生成默认静态首页"
        else
            warn "模板资源下载失败；改为生成默认静态首页"
        fi
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        install_default_template
        return 0
    fi

    if ! extracted_dir="$(find_template_dir "$tmpdir")"; then
        if nested_archive="$(find_template_archive "$tmpdir")"; then
            info "检测到嵌套模板包，继续解压：$nested_archive"
            rm -rf "$tmpdir/nested"
            if extract_archive "$nested_archive" "$tmpdir/nested"; then
                extracted_dir="$(find_template_dir "$tmpdir/nested")" || true
            fi
        fi
    fi

    if [[ -z "$extracted_dir" ]]; then
        warn "压缩包内未找到可用网页目录；改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        install_default_template
        return 0
    fi

    mkdir -p "$staged"
    cp -a "$extracted_dir"/. "$staged"/ || {
        warn "网页模板暂存失败，改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        install_default_template
        return 0
    }

    if ! template_has_index "$staged"; then
        warn "模板目录缺少 index.html/index.htm，改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        install_default_template
        return 0
    fi

    if [[ -d /usr/share/nginx/html && ! -d /usr/share/nginx/html_bak ]]; then
        cp -a /usr/share/nginx/html /usr/share/nginx/html_bak >/dev/null 2>&1 || true
    fi

    rm -rf /usr/share/nginx/html.new
    mv "$staged" /usr/share/nginx/html.new || {
        warn "网页模板替换失败，改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir" "$staged" /usr/share/nginx/html.new
        install_default_template
        return 0
    }

    rm -rf /usr/share/nginx/html
    mv /usr/share/nginx/html.new /usr/share/nginx/html || {
        warn "网页模板落盘失败，请手动检查 /usr/share/nginx/html"
        rm -rf "$tmpfile" "$tmpdir" /usr/share/nginx/html.new
        install_default_template
        return 0
    }

    if ! template_has_index /usr/share/nginx/html; then
        warn "网页模板已落盘，但首页文件缺失；改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir"
        install_default_template
        return 0
    fi

    write_robots_file
    normalize_web_permissions
    success "网页模板安装完成"
    rm -rf "$tmpfile" "$tmpdir" "$staged"
}

setFirewall() {
    local ufw_ports=""
    local iptables_ports=""

    ufw_ports="$(port_spec_to_ufw)"
    iptables_ports="$(port_spec_to_iptables)"

    if command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${HY2_LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${HY2_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -vq inactive; then
        ufw allow "${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${HY2_LISTEN_PORT}/tcp" >/dev/null 2>&1 || true
        ufw allow "${HY2_LISTEN_PORT}/udp" >/dev/null 2>&1 || true
        ufw allow "${ufw_ports}/udp" >/dev/null 2>&1 || true
    fi

    if command_exists iptables; then
        iptables -C INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT
        iptables -C INPUT -p tcp --dport "$HY2_LISTEN_PORT" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$HY2_LISTEN_PORT" -j ACCEPT
        iptables -C INPUT -p udp --dport "$HY2_LISTEN_PORT" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport "$HY2_LISTEN_PORT" -j ACCEPT
        iptables -C INPUT -p udp --dport "$iptables_ports" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p udp --dport "$iptables_ports" -j ACCEPT
    fi

    setup_hy2_port_forward || true
    create_hy2_forward_service || true
}

installBBR() {
    if [[ "$NEED_BBR" != "y" ]]; then
        INSTALL_BBR="false"
        return
    fi

    if lsmod | grep -q bbr; then
        info "BBR 模块已安装"
        INSTALL_BBR="false"
        return
    fi

    if hostnamectl 2>/dev/null | grep -qi openvz; then
        info "openvz 机器，跳过安装"
        INSTALL_BBR="false"
        return
    fi

    grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true

    if lsmod | grep -q bbr; then
        success "BBR 模块已启用"
        INSTALL_BBR="false"
    else
        warn "已写入 sysctl 参数，但当前内核未立即启用 BBR，可能需要重启"
        INSTALL_BBR="true"
    fi
}

showSummary() {
    echo ""
    success "安装完成：UDP 多入口端口已转发到 443，Nginx 仅在 443/TCP 提供伪装站"
    success "------------------- 端口结构 -------------------"
    colorEcho "$RED"   " 域名：${DOMAIN}"
    colorEcho "$RED"   " HTTP 端口(TCP)：${HTTP_PORT}"
    colorEcho "$RED"   " HTTPS 伪装站端口(TCP)：${HY2_LISTEN_PORT}"
    colorEcho "$RED"   " Hysteria2 实际监听端口(UDP)：${HY2_LISTEN_PORT}"
    colorEcho "$RED"   " 用户连接入口端口(UDP)：${PORT} → ${HY2_LISTEN_PORT}"

    echo ""
    success "---------- V2board / XBoard / V2bX 建议配置 ----------"
    colorEcho "$RED"   " 协议：hysteria2"
    colorEcho "$RED"   " 地址(address / server)：${DOMAIN}"
    colorEcho "$RED"   " 面板/V2bX 节点监听端口(port)：${HY2_LISTEN_PORT}"
    colorEcho "$RED"   " 客户端可用入口端口：${PORT}"
    colorEcho "$RED"   " SNI / server_name：${DOMAIN}"
    colorEcho "$RED"   " ALPN：h3"
    colorEcho "$RED"   " 传输层：udp / quic"
    colorEcho "$RED"   " TLS：开启"
    colorEcho "$RED"   " 证书文件(cert)：${CERT_FILE}"
    colorEcho "$RED"   " 私钥文件(key)：${KEY_FILE}"

    echo ""
    success "---------- 节点侧要点 ----------"
    colorEcho "$RED"   " 1. 面板/V2bX 的 Hysteria2 节点监听端口设为 ${HY2_LISTEN_PORT}"
    colorEcho "$RED"   " 2. 客户端可以使用 ${PORT} 中任意 UDP 端口连接"
    colorEcho "$RED"   " 3. iptables 会把 UDP ${PORT} 自动转发到本机 UDP ${HY2_LISTEN_PORT}"
    colorEcho "$RED"   " 4. Nginx 只占用 TCP ${HY2_LISTEN_PORT} 提供网站伪装"
    colorEcho "$RED"   " 5. 若面板支持证书路径，请使用上面的 cert/key 路径"

    echo ""
    info "Nginx 配置文件：${SITE_CONF}"
    info "证书文件：${CERT_FILE}"
    info "请把面板 / V2bX 节点协议改为 Hysteria2，并确认其监听 UDP ${HY2_LISTEN_PORT}。"
    info "客户端/订阅显示端口可以使用 ${PORT}；服务端会自动转发到 ${HY2_LISTEN_PORT}。"
}

bbrReboot() {
    if [[ "$INSTALL_BBR" == "true" ]]; then
        echo ""
        warn "BBR 参数已写入；若仍未生效，请手动重启系统。"
    fi
}

postCheck() {
    local ok="true"

    if ! nginx_is_active; then
        if [[ "$BT" == "false" ]]; then
            warn "Nginx 当前未处于运行状态，请检查：systemctl status nginx"
        else
            warn "Nginx 当前未处于运行状态，请检查宝塔面板或执行 nginx -t / nginx -s reload"
        fi
        ok="false"
    fi

    if ! statusV2bX; then
        warn "V2bX 当前未处于运行状态，请检查：systemctl status V2bX"
        ok="false"
    fi

    if is_port_in_use_tcp "$HY2_LISTEN_PORT"; then
        success "检测到 TCP ${HY2_LISTEN_PORT} 已在监听（Nginx）"
    else
        warn "未检测到 TCP ${HY2_LISTEN_PORT} 监听"
        ok="false"
    fi

    if is_port_in_use_udp "$HY2_LISTEN_PORT"; then
        success "检测到 UDP ${HY2_LISTEN_PORT} 已在监听（V2bX/HY2）"
    else
        warn "尚未检测到 UDP ${HY2_LISTEN_PORT} 监听，请确认 V2bX 的 Hysteria2 节点端口已改为 ${HY2_LISTEN_PORT}"
    fi

    if command_exists iptables && iptables -t nat -C PREROUTING -p udp --dport "$(port_spec_to_iptables)" -j REDIRECT --to-ports "$HY2_LISTEN_PORT" >/dev/null 2>&1; then
        success "检测到 UDP ${PORT} → ${HY2_LISTEN_PORT} 的转发规则"
    else
        warn "未检测到 UDP ${PORT} → ${HY2_LISTEN_PORT} 的转发规则"
    fi

    [[ "$ok" == "true" ]]
}

list_site_confs() {
    find "$NGINX_CONF_PATH" -maxdepth 1 -type f -name '*.conf' ! -name '*.bak' ! -name '*.tmp' 2>/dev/null | sort
}

pick_site_conf() {
    mapfile -t SITE_CONF_LIST < <(list_site_confs)
    local total="${#SITE_CONF_LIST[@]}"

    (( total > 0 )) || return 1

    echo ""
    info "检测到以下 Nginx 站点配置："
    local i domain_name
    for ((i=0; i<total; i++)); do
        domain_name="$(basename "${SITE_CONF_LIST[$i]}" .conf)"
        printf "  %2d) %s  [%s]\n" "$((i+1))" "$domain_name" "${SITE_CONF_LIST[$i]}"
    done
    echo "   0) 取消"

    local choice
    while true; do
        read -r -p "请选择要删除的配置编号：" choice
        [[ "$choice" =~ ^[0-9]+$ ]] || {
            warn "请输入数字编号"
            continue
        }

        if [[ "$choice" == "0" ]]; then
            return 1
        fi

        if (( choice >= 1 && choice <= total )); then
            SITE_CONF="${SITE_CONF_LIST[$((choice-1))]}"
            DOMAIN="$(basename "$SITE_CONF" .conf)"
            return 0
        fi

        warn "编号超出范围，请重新输入"
    done
}

install_proxy() {
    checkV2bX
    getData

    if [[ "$PMT" == "apt" ]]; then
        apt update -y >/dev/null 2>&1 || true
    else
        yum makecache >/dev/null 2>&1 || true
    fi

    $CMD_INSTALL wget curl vim unzip tar gcc openssl net-tools socat || die "基础依赖安装失败"
    if [[ "$PMT" == "apt" ]]; then
        $CMD_INSTALL libssl-dev g++ ca-certificates || die "额外依赖安装失败"
    else
        $CMD_INSTALL ca-certificates || true
    fi

    command_exists unzip || die "unzip 安装失败，请检查网络"

    installNginx
    setFirewall
    getCert
    configNginx
    installTemplate
    installBBR

    if nginx_is_active; then
        reloadNginx || die "Nginx 重载失败"
    else
        startNginx || die "Nginx 启动失败"
    fi

    if restartV2bX; then
        sleep 2
        if statusV2bX; then
            success "V2bX 重启成功"
        else
            warn "V2bX 已尝试重启，但当前状态未确认，请用 systemctl status V2bX 检查"
        fi
    else
        warn "V2bX 重启失败，请手动执行 systemctl restart V2bX"
    fi

    showSummary
    postCheck || true
    bbrReboot
}

uninstall_proxy() {
    pick_site_conf || {
        warn "未选择任何配置，已取消"
        return 0
    }

    local conf="$SITE_CONF"
    [[ -f "$conf" ]] || die "未找到配置文件：$conf"

    local cert_pem="/etc/ysbl/${DOMAIN}.pem"
    local cert_key="/etc/ysbl/${DOMAIN}.key"
    local bak_conf="${conf}.bak.$(date +%s)"

    echo ""
    info "将删除配置：$conf"
    read -r -p "确认删除该反代配置？[y/N]：" answer
    [[ "${answer,,}" == "y" ]] || {
        warn "已取消删除"
        return 0
    }

    cp -f "$conf" "$bak_conf" || die "备份配置失败"
    rm -f "$conf"

    if nginx_test; then
        if nginx_is_active; then
            reloadNginx || warn "Nginx 重载失败，请手动执行 nginx -t / reload 检查"
        else
            startNginx || warn "Nginx 启动失败，请手动检查"
        fi
        rm -f "$bak_conf"
    else
        mv -f "$bak_conf" "$conf"
        nginx_test || true
        die "删除后 Nginx 配置校验失败，已自动回滚"
    fi

    if [[ -f "$cert_pem" || -f "$cert_key" ]]; then
        echo ""
        read -r -p "是否一并删除 /etc/ysbl 下该域名证书文件？[y/N]：" answer
        if [[ "${answer,,}" == "y" ]]; then
            rm -f "$cert_pem" "$cert_key"
            success "已删除证书文件：$cert_pem / $cert_key"
        fi
    fi

    echo ""
    read -r -p "是否一并删除 HY2 UDP 端口转发服务？[y/N]：" answer
    if [[ "${answer,,}" == "y" ]]; then
        remove_hy2_forward_service
        success "已删除 HY2 UDP 端口转发服务"
    fi

    success "已删除站点配置：$conf"
    info "此脚本不会删除 V2bX 节点，请再去面板中手动调整或删除对应的 Hysteria2 节点。"
}

show_status() {
    echo ""
    if statusV2bX; then
        success "V2bX: 运行中"
    else
        warn "V2bX: 未运行或未检测到"
    fi

    if nginx_is_active; then
        success "Nginx: 运行中"
    else
        warn "Nginx: 未运行"
    fi

    echo ""
    info "HY2 端口结构：UDP ${PORT} → ${HY2_LISTEN_PORT}，Nginx TCP ${HY2_LISTEN_PORT}"
    show_hy2_forward_rules
}

menu() {
    clear
    echo "==============================================="
    echo "   V2bX 一键添加 Nginx 伪装(Hysteria2 + TLS)    "
    echo "==============================================="
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}   为 V2bX 添加 Hysteria2 的 Nginx 伪装"
    echo -e "  ${GREEN}2.${PLAIN}   检测并删除某个域名的伪装站配置"
    echo -e "  ${GREEN}3.${PLAIN}   查看当前服务状态"
    echo -e "  ${GREEN}0.${PLAIN}   退出"
    echo ""

    read -r -p " 请选择操作：" answer
    case "$answer" in
        1) install_proxy ;;
        2) uninstall_proxy ;;
        3) show_status ;;
        0) exit 0 ;;
        *) die "请选择正确的操作！" ;;
    esac
}

checkSystem

action="${1:-menu}"
case "$action" in
    menu)
        menu
        ;;
    install)
        install_proxy
        ;;
    uninstall)
        uninstall_proxy
        ;;
    status)
        show_status
        ;;
    *)
        die "不支持的参数：$action"
        ;;
esac
