#!/usr/bin/env bash
# V2bX Nginx reverse proxy installer (WS/gRPC + TLS)
# Purpose: merge ws.sh and grpc.sh into one script without changing originals.
# Scope: reliability, rollback safety, maintainability, and DNS-only cert issuance.

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
MODE=""
WSPATH=""
GRPC_SERVICE=""
STACK_HINT="Trojan + gRPC + TLS + Nginx + 真网站"
CERT_FILE=""
KEY_FILE=""
REMOTE_HOST=""
PROXY_URL=""
ALLOW_SPIDER="n"
NEED_BBR="n"
INSTALL_BBR="false"
SITE_CONF=""
ROBOT_CONFIG=""
DEFAULT_PROXY_URL="https://bing.ioliu.cn"
BACKEND_LOCK_RESULT="未设置"
FIREWALL_TOOL=""
FIREWALL_POLICY_RESULT="未设置"
SHORTCUT_CMD="v2pr"
SHORTCUT_PATH="/usr/local/bin/${SHORTCUT_CMD}"
PROJECT_REPO_URL="https://github.com/limo13660/v2bx-proxy"

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

validate_script_file() {
    local file="$1"

    [[ -s "$file" ]] || return 1
    grep -q '^#!/usr/bin/env bash' "$file" 2>/dev/null || return 1
    bash -n "$file" >/dev/null 2>&1 || return 1
}

download_latest_script_to_file() {
    local outfile="$1"
    local url=""
    local -a update_urls=(
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/v2pr.sh"
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/master/v2pr.sh"
    )

    rm -f "$outfile"

    for url in "${update_urls[@]}"; do
        info "尝试下载脚本：$url"
        if ! safe_wget "$url" "$outfile"; then
            warn "下载失败：$url"
            continue
        fi

        if validate_script_file "$outfile"; then
            return 0
        fi

        warn "下载内容不是有效脚本：$url"
        rm -f "$outfile"
    done

    return 1
}

install_shortcut_from_file() {
    local source_file="$1"
    local tmp_target="${SHORTCUT_PATH}.tmp.$$"

    [[ -r "$source_file" ]] || return 1
    mkdir -p "$(dirname "$SHORTCUT_PATH")" || return 1

    cat "$source_file" > "$tmp_target" || {
        rm -f "$tmp_target"
        return 1
    }
    chmod 755 "$tmp_target" || {
        rm -f "$tmp_target"
        return 1
    }
    mv -f "$tmp_target" "$SHORTCUT_PATH" || {
        rm -f "$tmp_target"
        return 1
    }
}

install_shortcut_command() {
    local script_source="${BASH_SOURCE[0]:-$0}"
    local tmpfile=""
    local source_file=""

    if [[ "$script_source" == "$SHORTCUT_PATH" ]]; then
        return 0
    fi

    case "$script_source" in
        /dev/fd/*|/proc/*|"")
            tmpfile="/tmp/${SHORTCUT_CMD}.install.$$"
            download_latest_script_to_file "$tmpfile" || {
                warn "当前通过临时输入流运行脚本，且未能从项目仓库下载完整脚本，跳过快捷命令安装"
                [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
                return 1
            }
            source_file="$tmpfile"
            ;;
        *)
            if [[ ! -r "$script_source" ]]; then
                warn "未能读取当前脚本内容，跳过快捷命令安装"
                return 1
            fi
            source_file="$script_source"
            ;;
    esac

    if [[ -f "$SHORTCUT_PATH" ]] && cmp -s "$source_file" "$SHORTCUT_PATH" 2>/dev/null; then
        [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
        return 0
    fi

    install_shortcut_from_file "$source_file" || {
        warn "快捷命令安装失败：无法写入 ${SHORTCUT_PATH}"
        [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
        return 1
    }

    [[ -n "$tmpfile" ]] && rm -f "$tmpfile"
    success "已安装快捷命令：${SHORTCUT_CMD}"
    return 0
}

update_script() {
    echo ""
    info "开始更新脚本..."

    local tmpfile="/tmp/${SHORTCUT_CMD}.update.$$"
    download_latest_script_to_file "$tmpfile" || die "脚本更新失败：无法从项目地址下载有效更新，请检查网络或仓库地址"

    install_shortcut_from_file "$tmpfile" || {
        rm -f "$tmpfile"
        die "更新失败：无法写入 ${SHORTCUT_PATH}"
    }

    rm -f "$tmpfile"
    success "脚本更新完成，可直接运行：${SHORTCUT_CMD}"
    info "项目地址：${PROJECT_REPO_URL}"
    return 0
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

fix_web_root_permissions() {
    [[ -d /usr/share/nginx/html ]] || return 0

    chmod 755 /usr/share/nginx/html 2>/dev/null || true
    find /usr/share/nginx/html -type d -exec chmod 755 {} \; 2>/dev/null || true
    find /usr/share/nginx/html -type f -exec chmod 644 {} \; 2>/dev/null || true
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
        .card { width: 100%; max-width: 720px; background: rgba(15, 23, 42, 0.88); border: 1px solid rgba(148, 163, 184, 0.25); border-radius: 16px; padding: 32px; box-sizing: border-box; }
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
            <p>如需自定义伪装站内容，请把网页文件放到 <code>/usr/share/nginx/html</code>。</p>
        </div>
    </div>
</body>
</html>
EOF_DEFAULT_HTML
    write_robots_file
    fix_web_root_permissions
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

is_valid_ws_path() {
    local re='^/[-A-Za-z0-9._~!$&()*+,;=:@%/]+$'
    [[ "$1" != "/" ]] && [[ "$1" =~ $re ]]
}

is_valid_grpc_service() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

is_valid_proxy_url() {
    local re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[-A-Za-z0-9._~!$&()*+,;=:@%/?#]*)?$'
    [[ "$1" =~ $re ]]
}

is_port_in_use() {
    local port="$1"

    if command_exists ss; then
        ss -lnt "( sport = :${port} )" 2>/dev/null | awk 'NR>1{found=1} END{exit !found}'
        return $?
    fi

    if command_exists netstat; then
        netstat -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'
        return $?
    fi

    return 1
}

suggested_ws_path() {
    echo "/assets/$(random_token 4 8)/$(random_token 6 12)"
}

suggested_grpc_service() {
    echo "$(random_token 4 8).$(random_token 6 12)"
}

check_backend_port() {
    [[ "$PORT" != "$V2PORT" ]] || die "Nginx 监听端口与后端服务端口不能相同"

    if is_port_in_use "$V2PORT"; then
        die "后端服务端口 ${V2PORT} 已被占用，请更换一个未使用端口"
    fi
}

check_frontend_port() {
    if is_port_in_use "$PORT" && ! nginx_is_active; then
        die "前端监听端口 ${PORT} 已被其他服务占用，请先释放端口或改用其他端口"
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

random_token() {
    local min_len="$1"
    local max_len="$2"
    local len
    len="$(shuf -i "${min_len}-${max_len}" -n 1)"
    tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$len" | head -n 1
}

choose_mode() {
    echo ""
    info "请选择反代协议："
    echo -e "  ${GREEN}1.${PLAIN} WS + TLS"
    echo -e "  ${GREEN}2.${PLAIN} gRPC + TLS  ${YELLOW}(推荐，更适合 ${STACK_HINT})${PLAIN}"

    local answer
    read -r -p "请输入选项 [1-2，默认2]：" answer
    answer="${answer:-2}"

    case "$answer" in
        1) MODE="ws" ;;
        2) MODE="grpc" ;;
        *) die "协议选项输入错误" ;;
    esac
}

collect_transport_data() {
    echo ""
    if [[ "$MODE" == "ws" ]]; then
        while true; do
            read -r -p " 请输入伪装路径，以 / 开头(不懂请直接回车)：" WSPATH
            if [[ -z "$WSPATH" ]]; then
                WSPATH="$(suggested_ws_path)"
                break
            elif ! is_valid_ws_path "$WSPATH"; then
                colorEcho "$RED" " 伪装路径不合法，请重新输入！"
            else
                break
            fi
        done
        info "WS 路径：$WSPATH"
    else
        while true; do
            read -r -p " 请输入 gRPC serviceName(仅字母/数字/._-，不懂请直接回车)：" GRPC_SERVICE
            if [[ -z "$GRPC_SERVICE" ]]; then
                GRPC_SERVICE="$(suggested_grpc_service)"
                break
            elif ! is_valid_grpc_service "$GRPC_SERVICE"; then
                colorEcho "$RED" " gRPC serviceName 不合法，请重新输入！"
            else
                break
            fi
        done
        info "gRPC serviceName：$GRPC_SERVICE"
        info "Nginx 将转发路径：/${GRPC_SERVICE}/Tun 和 /${GRPC_SERVICE}/TunMulti"
    fi
}

getData() {
    echo ""
    echo " 运行之前请确认如下条件已经具备："
    colorEcho "$YELLOW" "  1. 一个伪装域名 DNS 解析指向当前服务器 IP（${IP:-未检测到公网IP}）"
    colorEcho "$BLUE"   "  2. 证书将使用 Cloudflare DNS 模式申请，请提前准备可编辑 DNS 的 API Token"
    colorEcho "$BLUE"   "  3. 面板 / V2bX 节点传输协议需要与本脚本中选择的模式保持一致，客户端外显地址请使用域名而非服务器 IP"
    colorEcho "$BLUE"   "  4. 后端服务端口仅供本机 / Nginx 回源使用，不应暴露到公网"
    colorEcho "$BLUE"   "  5. 若想尽量贴近正常流量，建议上游节点协议选 Trojan，传输选 gRPC，端口优先 443，并给域名准备一个真网站首页"
    echo ""
    read -r -p " 确认满足按 y，按其他退出脚本：" answer
    [[ "${answer,,}" == "y" ]] || exit 0

    choose_mode

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

    if [[ -n "$IP" ]] && resolve_domain_to_server "$DOMAIN"; then
        info "${DOMAIN} 已解析到当前服务器 IP"
    else
        die "域名未解析到当前服务器 IP（${IP:-unknown}），请先修正 DNS"
    fi

    echo ""
    read -r -p " 请输入 Nginx 监听端口[100-65535，默认443]：" PORT
    [[ -z "$PORT" ]] && PORT=443
    [[ "$PORT" =~ ^[0-9]+$ ]] || die "Nginx 端口必须是数字"
    (( PORT >= 100 && PORT <= 65535 )) || die "Nginx 端口范围错误"
    [[ "${PORT:0:1}" != "0" ]] || die "端口不能以 0 开头"
    check_frontend_port
    info "Nginx 端口：$PORT"

    read -r -p " 请输入服务端口(后端监听端口，仅供本机/Nginx回源，不对公网开放)[10000-65535，默认随机]：" V2PORT
    [[ -z "$V2PORT" ]] && V2PORT="$(shuf -i 10000-65000 -n 1)"
    [[ "$V2PORT" =~ ^[0-9]+$ ]] || die "后端端口必须是数字"
    (( V2PORT >= 10000 && V2PORT <= 65535 )) || die "后端端口范围错误"
    [[ "${V2PORT:0:1}" != "0" ]] || die "端口不能以 0 开头"
    check_backend_port
    info "后端服务端口：$V2PORT"
    info "该端口仅供本机 / Nginx 回源使用，脚本会尝试自动拒绝公网直连"

    collect_transport_data

    echo ""
    info "请选择伪装站类型:"
    echo "   1) 静态网站(位于 /usr/share/nginx/html, 默认带一个模板)"
    echo "   2) 自定义反代站点(需以 http 或 https 开头，更像真网站，默认：${DEFAULT_PROXY_URL})"
    read -r -p "  请选择伪装网站类型[默认:2]：" answer
    case "${answer:-2}" in
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

getCert() {
    mkdir -p /etc/ysbl
    ensureAcme

    local CF_Token=""
    echo ""
    info "证书申请方式：Cloudflare DNS"

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
    local site_block=""
    local transport_block=""

    if [[ -n "$PROXY_URL" ]]; then
        site_block="location / {
        proxy_ssl_server_name on;
        proxy_http_version 1.1;
        proxy_pass $PROXY_URL;
        proxy_set_header Host $REMOTE_HOST;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Accept-Encoding '';
        sub_filter \"$REMOTE_HOST\" \"$DOMAIN\";
        sub_filter_once off;
    }"
    else
        site_block="location / {
        try_files \$uri \$uri/ /index.html;
    }"
    fi

    if [[ "$MODE" == "ws" ]]; then
        transport_block="location ${WSPATH} {
        proxy_redirect off;
        proxy_read_timeout 1200s;
        proxy_pass http://127.0.0.1:${V2PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }"
    else
        transport_block="location ^~ /${GRPC_SERVICE}/Tun {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_read_timeout 1200s;
        grpc_send_timeout 1200s;
        grpc_socket_keepalive on;
        grpc_pass grpc://127.0.0.1:${V2PORT};
    }

    location ^~ /${GRPC_SERVICE}/TunMulti {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_read_timeout 1200s;
        grpc_send_timeout 1200s;
        grpc_socket_keepalive on;
        grpc_pass grpc://127.0.0.1:${V2PORT};
    }"
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
    server_tokens off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_ecdh_curve X25519:prime256v1;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_tickets off;
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security "max-age=31536000" always;

    root /usr/share/nginx/html;
    index index.html;

    ${transport_block}

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    ${site_block}
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
    local downloaded="false"
    local extracted="false"
    local url=""
    local -a template_urls=(
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/html_template.zip"
        "https://github.com/limo13660/xr-proxy/archive/refs/heads/main.tar.gz"
        "https://codeload.github.com/limo13660/xr-proxy/tar.gz/refs/heads/main"
    )

    rm -rf "$tmpfile" "$tmpdir" "$staged"

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

    extracted_dir="$(find_template_dir "$tmpdir")" || {
        warn "压缩包内未找到可用网页目录；改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        install_default_template
        return 0
    }

    mkdir -p "$staged"
    cp -a "$extracted_dir"/. "$staged"/ || {
        warn "网页模板暂存失败，改为生成默认静态首页"
        rm -rf "$tmpfile" "$tmpdir" "$staged"
        install_default_template
        return 0
    }

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

    write_robots_file
    fix_web_root_permissions
    success "网页模板安装完成"
    rm -rf "$tmpfile" "$tmpdir" "$staged"
}

ensureFirewallTool() {
    if [[ "$PMT" == "apt" ]]; then
        if command_exists ufw; then
            FIREWALL_TOOL="ufw"
            return 0
        fi
        if command_exists firewall-cmd; then
            FIREWALL_TOOL="firewalld"
            return 0
        fi
    else
        if command_exists firewall-cmd; then
            FIREWALL_TOOL="firewalld"
            return 0
        fi
        if command_exists ufw; then
            FIREWALL_TOOL="ufw"
            return 0
        fi
    fi

    echo ""
    if [[ "$PMT" == "apt" ]]; then
        info "未检测到可用防火墙工具，开始自动安装 ufw..."
        if $CMD_INSTALL ufw; then
            command_exists ufw || die "ufw 安装后未检测到命令"
            FIREWALL_TOOL="ufw"
            success "已自动安装防火墙工具：ufw"
            return 0
        fi
    else
        info "未检测到可用防火墙工具，开始自动安装 firewalld..."
        if $CMD_INSTALL firewalld; then
            command_exists firewall-cmd || die "firewalld 安装后未检测到命令"
            FIREWALL_TOOL="firewalld"
            success "已自动安装防火墙工具：firewalld"
            return 0
        fi
    fi

    if command_exists iptables; then
        FIREWALL_TOOL="iptables"
        warn "自动安装防火墙工具失败，回退为 iptables 兼容模式"
        return 0
    fi

    die "未能准备可用的防火墙工具，无法继续保护后端端口"
}

getFirewalldZone() {
    local zone=""
    zone="$(firewall-cmd --get-default-zone 2>/dev/null || true)"
    echo "${zone:-public}"
}

configureFirewalldDefaultAllow() {
    local zone=""

    systemctl enable firewalld >/dev/null 2>&1 || true
    systemctl start firewalld >/dev/null 2>&1 || die "firewalld 启动失败"

    zone="$(getFirewalldZone)"
    firewall-cmd --permanent --zone="$zone" --set-target=ACCEPT >/dev/null 2>&1 || die "firewalld 默认放行设置失败"
    firewall-cmd --reload >/dev/null 2>&1 || die "firewalld 重载失败"

    FIREWALL_POLICY_RESULT="firewalld 已启用，默认放行入站/出站流量，仅额外锁定后端端口"
    success "已启用 firewalld，并设置默认放行流量"
}

configureUfwDefaultAllow() {
    ufw default allow incoming >/dev/null 2>&1 || die "ufw 默认入站放行设置失败"
    ufw default allow outgoing >/dev/null 2>&1 || die "ufw 默认出站放行设置失败"
    ufw --force enable >/dev/null 2>&1 || die "ufw 启用失败"

    FIREWALL_POLICY_RESULT="ufw 已启用，默认放行入站/出站流量，仅额外锁定后端端口"
    success "已启用 ufw，并设置默认放行流量"
}

configureIptablesCompatibility() {
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    if [[ "$PORT" != "443" ]]; then
        iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    fi

    FIREWALL_POLICY_RESULT="使用 iptables 兼容模式：已放行 80/443/前端端口，并继续锁定后端端口"
    warn "当前回退为 iptables 兼容模式，未统一改动系统默认放行策略"
}

setFirewall() {
    ensureFirewallTool

    case "$FIREWALL_TOOL" in
        firewalld)
            configureFirewalldDefaultAllow
            ;;
        ufw)
            configureUfwDefaultAllow
            ;;
        iptables)
            configureIptablesCompatibility
            ;;
        *)
            die "未知的防火墙工具：${FIREWALL_TOOL}"
            ;;
    esac
}

backendListensPublicly() {
    local port="${1:-$V2PORT}"
    local addr=""

    while IFS= read -r addr; do
        case "$addr" in
            127.0.0.1:${port}|[::1]:${port}|::1:${port})
                ;;
            *:${port})
                return 0
                ;;
        esac
    done < <(get_port_listen_addresses "$port")

    return 1
}

get_port_listen_addresses() {
    local port="${1:-$V2PORT}"

    if command_exists ss; then
        ss -lnt 2>/dev/null | awk -v p=":${port}" 'NR>1 && $4 ~ p"$" {print $4}' | sort -u
        return 0
    fi

    if command_exists netstat; then
        netstat -lnt 2>/dev/null | awk -v p=":${port}" 'NR>2 && $4 ~ p"$" {print $4}' | sort -u
        return 0
    fi

    return 1
}

lockBackendPortWithFirewalld() {
    firewall-cmd --permanent --remove-port="${V2PORT}/tcp" >/dev/null 2>&1 || true

    firewall-cmd --permanent --direct --remove-rule ipv4 filter INPUT 0 -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv4 filter INPUT 1 ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || return 1
    firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 1 ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || return 1

    firewall-cmd --permanent --direct --remove-rule ipv6 filter INPUT 0 -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv6 filter INPUT 1 ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --add-rule ipv6 filter INPUT 0 -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --add-rule ipv6 filter INPUT 1 ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || true

    firewall-cmd --reload >/dev/null 2>&1 || return 1
}

lockBackendPortWithUfw() {
    ufw --force delete allow in on lo to any port "$V2PORT" proto tcp >/dev/null 2>&1 || true
    ufw --force delete deny "${V2PORT}/tcp" >/dev/null 2>&1 || true

    ufw insert 1 allow in on lo to any port "$V2PORT" proto tcp >/dev/null 2>&1 || return 1
    ufw insert 2 deny "${V2PORT}/tcp" >/dev/null 2>&1 || return 1
}

lockBackendPortWithIptables() {
    iptables -C INPUT -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT 1 -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || return 1
    iptables -C INPUT ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || iptables -I INPUT 2 ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || return 1

    if command_exists ip6tables; then
        ip6tables -C INPUT -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || ip6tables -I INPUT 1 -i lo -p tcp --dport "$V2PORT" -j ACCEPT >/dev/null 2>&1 || true
        ip6tables -C INPUT ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || ip6tables -I INPUT 2 ! -i lo -p tcp --dport "$V2PORT" -j DROP >/dev/null 2>&1 || true
    fi
}

protectBackendPort() {
    case "$FIREWALL_TOOL" in
        firewalld)
            if lockBackendPortWithFirewalld; then
                BACKEND_LOCK_RESULT="已通过 firewalld 限制仅本机可访问"
                success "已通过 firewalld 拒绝公网直连后端端口 ${V2PORT}"
                return 0
            fi
            ;;
        ufw)
            if lockBackendPortWithUfw; then
                BACKEND_LOCK_RESULT="已通过 ufw 限制仅本机可访问"
                success "已通过 ufw 拒绝公网直连后端端口 ${V2PORT}"
                return 0
            fi
            ;;
        iptables)
            if lockBackendPortWithIptables; then
                BACKEND_LOCK_RESULT="已通过 iptables 限制仅本机可访问（重启后请确认规则仍在）"
                success "已通过 iptables 拒绝公网直连后端端口 ${V2PORT}"
                return 0
            fi
            ;;
    esac

    BACKEND_LOCK_RESULT="未自动锁定，请手动限制仅 127.0.0.1 / ::1 可访问"
    warn "已检测到防火墙工具 ${FIREWALL_TOOL:-unknown}，但未能自动锁定后端端口 ${V2PORT}"
    warn "请手动限制仅 127.0.0.1 / ::1 可访问，避免客户端直连节点 IP"
    return 1
}

extract_backend_port_from_conf() {
    local conf="$1"

    awk '
        match($0, /127\.0\.0\.1:([0-9]+)/, m) {
            print m[1]
            exit
        }
    ' "$conf" 2>/dev/null
}

remove_backend_firewalld_rules() {
    local port="$1"

    command_exists firewall-cmd || return 1
    systemctl is-active --quiet firewalld || return 1

    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv4 filter INPUT 0 -i lo -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv4 filter INPUT 1 ! -i lo -p tcp --dport "$port" -j DROP >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv6 filter INPUT 0 -i lo -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    firewall-cmd --permanent --direct --remove-rule ipv6 filter INPUT 1 ! -i lo -p tcp --dport "$port" -j DROP >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    return 0
}

remove_backend_ufw_rules() {
    local port="$1"

    command_exists ufw || return 1

    ufw --force delete allow in on lo to any port "$port" proto tcp >/dev/null 2>&1 || true
    ufw --force delete deny "${port}/tcp" >/dev/null 2>&1 || true
    return 0
}

remove_backend_iptables_rules() {
    local port="$1"

    command_exists iptables || return 1

    while iptables -C INPUT -i lo -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -i lo -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
    done
    while iptables -C INPUT ! -i lo -p tcp --dport "$port" -j DROP >/dev/null 2>&1; do
        iptables -D INPUT ! -i lo -p tcp --dport "$port" -j DROP >/dev/null 2>&1 || break
    done

    if command_exists ip6tables; then
        while ip6tables -C INPUT -i lo -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; do
            ip6tables -D INPUT -i lo -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || break
        done
        while ip6tables -C INPUT ! -i lo -p tcp --dport "$port" -j DROP >/dev/null 2>&1; do
            ip6tables -D INPUT ! -i lo -p tcp --dport "$port" -j DROP >/dev/null 2>&1 || break
        done
    fi

    return 0
}

cleanup_backend_firewall_rules() {
    local port="$1"
    local handled="false"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1

    if remove_backend_firewalld_rules "$port"; then
        handled="true"
    fi
    if remove_backend_ufw_rules "$port"; then
        handled="true"
    fi
    if remove_backend_iptables_rules "$port"; then
        handled="true"
    fi

    if [[ "$handled" == "true" ]]; then
        success "已清理后端端口 ${port} 的防火墙规则"
        return 0
    fi

    warn "未检测到可清理的防火墙工具，跳过后端端口 ${port} 的规则清理"
    return 1
}

find_v2bx_config() {
    local candidate=""
    local exec_line=""
    local token=""
    local -a candidates=(
        "/etc/V2bX/config.json"
        "/usr/local/V2bX/config.json"
        "/usr/local/V2bX/bin/config.json"
    )

    for candidate in "${candidates[@]}"; do
        [[ -f "$candidate" ]] && {
            echo "$candidate"
            return 0
        }
    done

    exec_line="$(systemctl cat "$V2BX_SERVICE" 2>/dev/null | awk -F= '/^ExecStart=/{print $2; exit}')"
    for token in $exec_line; do
        case "$token" in
            *.json|*.yaml|*.yml)
                [[ -f "$token" ]] && {
                    echo "$token"
                    return 0
                }
                ;;
        esac
    done

    return 1
}

extract_listen_ips_from_config() {
    local conf="$1"

    awk '
        match($0, /"ListenIP"[[:space:]]*:[[:space:]]*"([^"]+)"/, m) {
            print m[1]
        }
    ' "$conf" 2>/dev/null
}

show_listenip_reminder() {
    local conf=""
    local listen_ip=""
    local need_change="false"
    local found_any="false"

    conf="$(find_v2bx_config || true)"

    if [[ -z "$conf" ]]; then
        info "如需彻底避免后端端口直连，请把 V2bX 配置里的 ListenIP 改成 127.0.0.1，然后重启 V2bX。"
        return 0
    fi

    while IFS= read -r listen_ip; do
        [[ -n "$listen_ip" ]] || continue
        found_any="true"
        case "$listen_ip" in
            127.0.0.1|::1)
                ;;
            *)
                need_change="true"
                ;;
        esac
    done < <(extract_listen_ips_from_config "$conf")

    if [[ "$found_any" != "true" ]]; then
        info "请检查 ${conf} 里的 ListenIP，建议改成 127.0.0.1 后重启 V2bX。"
        return 0
    fi

    if [[ "$need_change" == "true" ]]; then
        warn "检测到 V2bX 配置中的 ListenIP 仍非本地地址，请把 ${conf} 里的 ListenIP 改成 127.0.0.1 后重启 V2bX。"
    else
        success "V2bX 配置中的 ListenIP 已为本地地址"
    fi
}

detect_listenip_status() {
    checkV2bX

    echo ""
    info "开始检测 V2bX ListenIP 与后端端口监听状态..."

    local conf=""
    local listen_ip=""
    local idx=1
    local found_any="false"
    local domain=""
    local backend_port=""
    local listen_addresses=""
    local conf_path=""

    conf="$(find_v2bx_config || true)"
    if [[ -n "$conf" ]]; then
        info "V2bX 配置文件：$conf"
        while IFS= read -r listen_ip; do
            [[ -n "$listen_ip" ]] || continue
            found_any="true"
            case "$listen_ip" in
                127.0.0.1|::1)
                    success "Node ${idx} ListenIP: ${listen_ip}"
                    ;;
                *)
                    warn "Node ${idx} ListenIP: ${listen_ip}，建议改成 127.0.0.1"
                    ;;
            esac
            idx=$((idx + 1))
        done < <(extract_listen_ips_from_config "$conf")

        [[ "$found_any" == "true" ]] || warn "未能从配置文件中解析到 ListenIP 字段"
    else
        warn "未定位到 V2bX 配置文件，请手动检查 ListenIP 是否为 127.0.0.1"
    fi

    echo ""
    info "检测本脚本已创建反代的后端端口监听情况："
    local found_site="false"
    while IFS= read -r conf_path; do
        [[ -n "$conf_path" ]] || continue
        backend_port="$(extract_backend_port_from_conf "$conf_path" || true)"
        [[ -n "$backend_port" ]] || continue

        found_site="true"
        domain="$(basename "$conf_path" .conf)"
        listen_addresses="$(get_port_listen_addresses "$backend_port" | tr '\n' ',' | sed 's/,$//')"
        [[ -n "$listen_addresses" ]] || listen_addresses="未检测到监听"

        if backendListensPublicly "$backend_port"; then
            warn "${domain}: 后端端口 ${backend_port} 正在公网地址监听 [${listen_addresses}]"
        else
            success "${domain}: 后端端口 ${backend_port} 仅本地监听 [${listen_addresses}]"
        fi
    done < <(list_site_confs)

    [[ "$found_site" == "true" ]] || info "未检测到由本脚本创建的反代配置"

    echo ""
    show_listenip_reminder
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
    success "安装完成，V2bX 内部回源端口为 ${V2PORT}，用户连接端口为 ${PORT}!"
    success "----------- 关键参数 -----------------------------"
    colorEcho "$RED"   " 推荐栈：${STACK_HINT}"
    colorEcho "$RED"   " 服务/后端监听端口(仅本机回源)：${V2PORT}"
    colorEcho "$RED"   " 用户连接端口：${PORT}"
    colorEcho "$RED"   " 客户端连接地址：${DOMAIN}:${PORT}"
    colorEcho "$RED"   " 域名(SNI)：${DOMAIN}"
    colorEcho "$RED"   " 传输安全：tls"
    colorEcho "$RED"   " 传输协议：${MODE}"

    echo ""
    if [[ "$MODE" == "ws" ]]; then
        success "---------- V2board / XBoard 传输协议配置示例 ----------------"
        colorEcho "$RED"   "{"
        colorEcho "$RED"   "  \"path\": \"${WSPATH}\","
        colorEcho "$RED"   "  \"headers\": {"
        colorEcho "$RED"   "    \"Host\": \"${DOMAIN}\""
        colorEcho "$RED"   "  }"
        colorEcho "$RED"   "}"

        echo ""
        success "---------- SSPANEL 节点配置(首段建议填域名) -------"
        colorEcho "$RED"   "${DOMAIN};${V2PORT};0;ws;tls;path=${WSPATH}|server=${DOMAIN}|host=${DOMAIN}|outside_port=${PORT}"
    else
        success "---------- V2board / XBoard 传输协议配置示例 ----------------"
        colorEcho "$RED"   "{"
        colorEcho "$RED"   "  \"serviceName\": \"${GRPC_SERVICE}\""
        colorEcho "$RED"   "}"

        echo ""
        success "---------- Nginx 实际分流路径 -------------------------------"
        colorEcho "$RED"   " /${GRPC_SERVICE}/Tun"
        colorEcho "$RED"   " /${GRPC_SERVICE}/TunMulti"
    fi

    echo ""
    info "Nginx 配置文件：${SITE_CONF}"
    info "证书文件：${CERT_FILE}"
    info "伪装站点：${PROXY_URL:-/usr/share/nginx/html 本地站点}"
    info "防火墙策略：${FIREWALL_POLICY_RESULT}"
    info "后端端口防护：${BACKEND_LOCK_RESULT}"
    if [[ -x "$SHORTCUT_PATH" ]]; then
        info "后续可直接运行命令：${SHORTCUT_CMD}"
        info "更新脚本命令：${SHORTCUT_CMD} update"
    fi
    show_listenip_reminder
    if [[ "$MODE" == "ws" ]]; then
        info "建议面板主协议使用 Trojan，传输改为 network=ws、security=tls、path=${WSPATH}、host=${DOMAIN}。"
        info "客户端外显地址请使用 ${DOMAIN}:${PORT}，不要把 ${V2PORT} 直接暴露给客户端。"
    else
        info "建议面板主协议使用 Trojan，传输改为 network=grpc、security=tls、serviceName=${GRPC_SERVICE}。"
        info "gRPC 由 Nginx 终止 TLS 后转发到 127.0.0.1:${V2PORT}，后端无需再次套 TLS。"
        info "客户端外显地址请使用 ${DOMAIN}:${PORT}，不要把 ${V2PORT} 直接暴露给客户端。"
    fi
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

    if backendListensPublicly; then
        warn "检测到后端端口 ${V2PORT} 正在非本地地址监听"
        warn "脚本已尝试通过防火墙阻断公网直连，但仍建议把 V2bX 改为仅监听 127.0.0.1 / ::1"
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
    protectBackendPort || true
    getCert
    installTemplate
    configNginx
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
    local backend_port=""
    [[ -f "$conf" ]] || die "未找到配置文件：$conf"

    backend_port="$(extract_backend_port_from_conf "$conf" || true)"

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

    if [[ -n "$backend_port" ]]; then
        cleanup_backend_firewall_rules "$backend_port" || true
    else
        warn "未能从配置中识别后端端口，已跳过防火墙规则清理"
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

    show_listenip_reminder
}

menu() {
    clear
    echo "================================"
    echo "     V2bX 一键添加 Nginx 反代     "
    echo "================================"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}   为 V2bX 添加 Nginx 反代(WS/gRPC + TLS)"
    echo -e "  ${GREEN}2.${PLAIN}   检测并删除某个域名的反代配置"
    echo -e "  ${GREEN}3.${PLAIN}   查看当前服务状态"
    echo -e "  ${GREEN}4.${PLAIN}   检测 ListenIP 与后端端口暴露"
    echo -e "  ${GREEN}5.${PLAIN}   更新脚本"
    echo -e "  ${GREEN}0.${PLAIN}   退出"
    echo ""

    read -r -p " 请选择操作：" answer
    case "$answer" in
        1) install_proxy ;;
        2) uninstall_proxy ;;
        3) show_status ;;
        4) detect_listenip_status ;;
        5) update_script ;;
        0) exit 0 ;;
        *) die "请选择正确的操作！" ;;
    esac
}

checkSystem
install_shortcut_command || true

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
    detect)
        detect_listenip_status
        ;;
    update)
        update_script
        ;;
    *)
        echo "参数错误"
        echo "用法: $(basename "$0") [menu|install|uninstall_proxy|status|detect|update]"
        exit 1
        ;;
esac
