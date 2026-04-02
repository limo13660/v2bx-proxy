#!/usr/bin/env bash
# V2bX Nginx reverse proxy installer (optimized)
# Purpose: keep original flow (domain -> cert -> nginx -> ws/tls proxy -> output panel params)
# Scope: reliability, rollback safety, and maintainability only.

set -u
set -o pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

V2BX_BIN="/usr/local/V2bX/V2bX"
V2BX_SERVICE="V2bX"
NGINX_CONF_PATH="/etc/nginx/conf.d/"
BT="false"
PMT=""
CMD_INSTALL=""
CRON_SERVICE="cron"

IPV4=""
IPV6=""
IP=""
PORT=""
V2PORT=""
DOMAIN=""
WSPATH=""
CERT_FILE=""
KEY_FILE=""
REMOTE_HOST=""
PROXY_URL=""
ALLOW_SPIDER="n"
NEED_BBR="n"
INSTALL_BBR="false"
SITE_CONF=""
ROBOT_CONFIG=""

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
    wget -q --timeout=15 --tries=2 -O "$out" "$url" || return 1
    [[ -s "$out" ]] || return 1
    return 0
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

is_valid_ws_path() {
    local re='^/[-A-Za-z0-9._~!$&()*+,;=:@%/]+$'
    [[ "$1" != "/" ]] && [[ "$1" =~ $re ]]
}

is_valid_proxy_url() {
    local re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[-A-Za-z0-9._~!$&()*+,;=:@%/?#]*)?$'
    [[ "$1" =~ $re ]]
}

is_port_in_use() {
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
    if systemctl list-unit-files | grep -q '^V2bX\.service'; then
        return 0
    fi
    die "未检测到 V2bX，请先安装 V2bX 再运行此脚本"
}

restartV2bX() {
    if systemctl list-unit-files | grep -q '^V2bX\.service'; then
        systemctl restart "$V2BX_SERVICE" || return 1
        return 0
    fi
    if command_exists service; then
        service "$V2BX_SERVICE" restart || return 1
        return 0
    fi
    return 1
}

statusV2bX() {
    if systemctl list-unit-files | grep -q '^V2bX\.service'; then
        systemctl is-active --quiet "$V2BX_SERVICE"
        return $?
    fi
    return 1
}

resolve_domain_to_server() {
    local host="$1"
    local resolved=""

    resolved="$(
        {
            getent ahosts "$host" 2>/dev/null | awk '{print $1}'
            command_exists dig && dig +short A "$host" 2>/dev/null
            command_exists dig && dig +short AAAA "$host" 2>/dev/null
        } | sed '/^$/d' | sort -u
    )"

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
    colorEcho "$BLUE"   "  2. 如果 /root 目录下有 v2ray.pem 和 v2ray.key 证书文件，将直接使用该证书"
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

    if [[ -f ~/v2ray.pem && -f ~/v2ray.key ]]; then
        info "检测到自有证书，将使用其部署"
        CERT_FILE="/etc/ysbl/${DOMAIN}.pem"
        KEY_FILE="/etc/ysbl/${DOMAIN}.key"
    else
        if [[ -n "$IP" ]] && resolve_domain_to_server "$DOMAIN"; then
            info "${DOMAIN} 已解析到当前服务器 IP"
        else
            die "域名未解析到当前服务器 IP（${IP:-unknown}），请先修正 DNS"
        fi
    fi

    echo ""
    read -r -p " 请输入 Nginx 监听端口[100-65535，默认443]：" PORT
    [[ -z "$PORT" ]] && PORT=443
    [[ "$PORT" =~ ^[0-9]+$ ]] || die "Nginx 端口必须是数字"
    (( PORT >= 100 && PORT <= 65535 )) || die "Nginx 端口范围错误"
    [[ "${PORT:0:1}" != "0" ]] || die "端口不能以 0 开头"
    info "Nginx 端口：$PORT"

    read -r -p " 请输入服务端口(后端监听端口/V2bX节点端口)[10000-65535，默认随机]：" V2PORT
    [[ -z "$V2PORT" ]] && V2PORT="$(shuf -i 10000-65000 -n 1)"
    [[ "$V2PORT" =~ ^[0-9]+$ ]] || die "后端端口必须是数字"
    (( V2PORT >= 10000 && V2PORT <= 65535 )) || die "后端端口范围错误"
    [[ "${V2PORT:0:1}" != "0" ]] || die "端口不能以 0 开头"
    info "后端服务端口：$V2PORT"

    echo ""
    while true; do
        read -r -p " 请输入伪装路径，以 / 开头(不懂请直接回车)：" WSPATH
        if [[ -z "$WSPATH" ]]; then
            local len ws
            len="$(shuf -i 5-12 -n 1)"
            ws="$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$len" | head -n 1)"
            WSPATH="/$ws"
            break
        elif ! is_valid_ws_path "$WSPATH"; then
            colorEcho "$RED" " 伪装路径不合法，请重新输入！"
        else
            break
        fi
    done
    info "ws 路径：$WSPATH"

    echo ""
    info "请选择伪装站类型:"
    echo "   1) 静态网站(位于 /usr/share/nginx/html, 默认带一个模板)"
    echo "   2) 自定义反代站点(需以 http 或 https 开头)"
    read -r -p "  请选择伪装网站类型[默认:1]：" answer
    case "${answer:-1}" in
        1)
            PROXY_URL=""
            ;;
        2)
            read -r -p " 请输入反代站点(以 http 或 https 开头)：" PROXY_URL
            [[ -n "$PROXY_URL" ]] || die "请输入反代网站！"
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
    if [[ "$ALLOW_SPIDER" == "n" ]]; then
        cat > /usr/share/nginx/html/robots.txt <<'EOF_ROBOT'
User-Agent: *
Disallow: /
EOF_ROBOT
        ROBOT_CONFIG='location = /robots.txt {}'
    else
        ROBOT_CONFIG=''
    fi
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

getCert() {
    mkdir -p /etc/ysbl

    if [[ -n "$CERT_FILE" && -n "$KEY_FILE" ]]; then
        cp ~/v2ray.pem "$CERT_FILE"
        cp ~/v2ray.key "$KEY_FILE"
        [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || die "复制现有证书失败"
        return 0
    fi

    ensureAcme

    local certMode default_mode="1"
    echo ""
    info "请选择证书申请方式："
    echo -e "  ${GREEN}1.${PLAIN} Standalone (要求 80 端口可用)"
    echo -e "  ${GREEN}2.${PLAIN} Cloudflare DNS"

    if is_port_in_use 80; then
        default_mode="2"
        warn "检测到 80 端口当前被占用，默认推荐 Cloudflare DNS 模式"
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
        if is_port_in_use 80; then
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
    local action=""

    if [[ -n "$PROXY_URL" ]]; then
        action="proxy_ssl_server_name on;
        proxy_pass $PROXY_URL;
        proxy_set_header Accept-Encoding '';
        sub_filter \"$REMOTE_HOST\" \"$DOMAIN\";
        sub_filter_once off;"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        cp -f "$SITE_CONF" "$bak_conf" || die "备份现有 Nginx 配置失败"
    fi

    cat > "$tmp_conf" <<EOF_NGINX_SITE
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$server_name:${PORT}\$request_uri;
}

server {
    listen ${PORT} ssl http2;
    listen [::]:${PORT} ssl http2;
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
    location / {
        ${action}
        try_files \$uri \$uri/ /index.html;
    }
    ${ROBOT_CONFIG}

    location ${WSPATH} {
        proxy_redirect off;
        proxy_read_timeout 1200s;
        proxy_pass http://127.0.0.1:${V2PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
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
    local tmpfile="/tmp/html_template.tar"
    local tmpdir="/tmp/html_template_extract"
    local staged="/tmp/html_template_staged"
    rm -rf "$tmpfile" "$tmpdir" "$staged"

    safe_wget "https://raw.githubusercontent.com/ParkStable/xrayr-proxy/main/html_template.tar" "$tmpfile" || {
        warn "下载网页模板失败，将保留当前站点目录"
        return 0
    }

    mkdir -p "$tmpdir"
    tar -xf "$tmpfile" -C "$tmpdir" || {
        warn "解压网页模板失败，将保留当前站点目录"
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        return 0
    }

    if [[ -d "$tmpdir/html_template" ]]; then
        mv "$tmpdir/html_template" "$staged" || {
            warn "网页模板暂存失败，将保留当前站点目录"
            rm -rf "$tmpfile" "$tmpdir" "$staged"
            return 0
        }

        if [[ -d /usr/share/nginx/html && ! -d /usr/share/nginx/html_bak ]]; then
            cp -a /usr/share/nginx/html /usr/share/nginx/html_bak >/dev/null 2>&1 || true
        fi

        rm -rf /usr/share/nginx/html.new
        mv "$staged" /usr/share/nginx/html.new || {
            warn "网页模板替换失败，将保留当前站点目录"
            rm -rf "$tmpfile" "$tmpdir" "$staged" /usr/share/nginx/html.new
            return 0
        }

        rm -rf /usr/share/nginx/html
        mv /usr/share/nginx/html.new /usr/share/nginx/html || {
            warn "网页模板落盘失败，请手动检查 /usr/share/nginx/html"
            rm -rf "$tmpfile" "$tmpdir" /usr/share/nginx/html.new
            return 0
        }
        success "网页模板安装完成"
    else
        warn "模板目录不存在，跳过模板安装"
    fi

    rm -rf "$tmpfile" "$tmpdir" "$staged"
}

setFirewall() {
    if command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
        [[ "$PORT" == "443" ]] || firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        return
    fi

    if command_exists ufw && ufw status 2>/dev/null | grep -vq inactive; then
        ufw allow http/tcp >/dev/null 2>&1 || true
        ufw allow https/tcp >/dev/null 2>&1 || true
        [[ "$PORT" == "443" ]] || ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
        return
    fi

    if command_exists iptables; then
        iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        if [[ "$PORT" != "443" ]]; then
            iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        fi
    fi
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
    success "安装完成，V2bX 后端端口为 ${V2PORT}，Nginx 监听端口为 ${PORT}!"
    success "----------- V2board / XBoard 节点配置 -----------------------------"
    colorEcho "$RED"   " 设置服务端口(节点端口)为 ${V2PORT}，连接端口为 ${PORT}!"
    colorEcho "$RED"   " 传输协议配置如下："
    colorEcho "$RED"   "{"
    colorEcho "$RED"   "  \"path\": \"${WSPATH}\","
    colorEcho "$RED"   "  \"headers\": {"
    colorEcho "$RED"   "    \"Host\": \"${DOMAIN}\""
    colorEcho "$RED"   "  }"
    colorEcho "$RED"   "}"

    echo ""
    success "---------- SSPANEL 节点配置 ----------------------"
    colorEcho "$RED"   "${IP};${V2PORT};0;ws;tls;path=${WSPATH}|server=${DOMAIN}|host=${DOMAIN}|outside_port=${PORT}"

    echo ""
    success "---------- SSPANEL 节点配置(custom_config) ---------------"
    colorEcho "$RED" "{"
    colorEcho "$RED" "  \"offset_port_user\": \"${PORT}\","
    colorEcho "$RED" "  \"offset_port_node\": \"${V2PORT}\","
    colorEcho "$RED" "  \"server_sub\": \"${DOMAIN}\","
    colorEcho "$RED" "  \"host\": \"${DOMAIN}\","
    colorEcho "$RED" "  \"alter_id\": \"0\","
    colorEcho "$RED" "  \"network\": \"ws\","
    colorEcho "$RED" "  \"security\": \"tls\","
    colorEcho "$RED" "  \"path\": \"${WSPATH}\","
    colorEcho "$RED" "  \"ws-opts\": {"
    colorEcho "$RED" "    \"path\": \"${WSPATH}\""
    colorEcho "$RED" "  }"
    colorEcho "$RED" "}"

    echo ""
    info "Nginx 配置文件：${SITE_CONF}"
    info "证书文件：${CERT_FILE}"
    info "如果 V2bX 的节点配置尚未使用端口 ${V2PORT}，请先在面板/配置文件中同步后再重启节点。"
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

    $CMD_INSTALL wget curl vim unzip tar gcc openssl net-tools || die "基础依赖安装失败"
    if [[ "$PMT" == "apt" ]]; then
        $CMD_INSTALL libssl-dev g++ || die "额外依赖安装失败"
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

    success "已删除反代配置：$conf"
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
}

menu() {
    clear
    echo "================================"
    echo "      V2bX 一键添加 Nginx 反代     "
    echo "================================"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}   为 V2bX 添加 Nginx 反代(WS+TLS)"
    echo -e "  ${GREEN}2.${PLAIN}   检测并删除某个域名的反代配置"
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
    uninstall_proxy)
        uninstall_proxy
        ;;
    status)
        show_status
        ;;
    *)
        echo "参数错误"
        echo "用法: $(basename "$0") [menu|install|uninstall_proxy|status]"
        exit 1
        ;;
esac
