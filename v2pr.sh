#!/usr/bin/env bash
# Generic Nginx reverse proxy installer (WS/gRPC + TLS)

set -u
set -o pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

NGINX_CONF_PATH="/etc/nginx/conf.d/"
BT="false"
PMT=""
CMD_INSTALL=""
CRON_SERVICE="cron"

IPV4=""
IPV6=""
IP=""
PORT=""
BACKEND_HOST=""
BACKEND_HOST_NGINX=""
BACKEND_PORT=""
DOMAIN=""
MODE=""
WS_PATH=""
GRPC_SERVICE=""
CERT_FILE=""
KEY_FILE=""
REMOTE_HOST=""
PROXY_URL=""
ALLOW_SPIDER="n"
SITE_CONF=""
ROBOT_CONFIG=""
DEFAULT_PROXY_URL="https://bing.ioliu.cn"
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

is_valid_backend_host() {
    [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

normalize_backend_host() {
    BACKEND_HOST_NGINX="$BACKEND_HOST"

    case "$BACKEND_HOST" in
        ::1)
            BACKEND_HOST_NGINX="[::1]"
            ;;
        *:*)
            if [[ "$BACKEND_HOST" != \[*\] ]]; then
                BACKEND_HOST_NGINX="[$BACKEND_HOST]"
            fi
            ;;
    esac
}

backend_is_local() {
    case "$BACKEND_HOST" in
        127.0.0.1|localhost|::1|[::1])
            return 0
            ;;
    esac
    return 1
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

check_backend_target() {
    if backend_is_local && [[ "$PORT" == "$BACKEND_PORT" ]]; then
        die "当后端与 Nginx 在同一台机器上时，前端监听端口与后端回源端口不能相同"
    fi

    if backend_is_local; then
        if is_port_in_use "$BACKEND_PORT"; then
            info "检测到本机后端端口 ${BACKEND_PORT} 正在监听"
        else
            warn "当前未检测到本机后端端口 ${BACKEND_PORT} 正在监听"
            warn "脚本仍会继续写入 Nginx 配置；如果后续回源失败，请先确认后端已经启动并监听该端口"
        fi
    else
        info "后端回源目标：${BACKEND_HOST}:${BACKEND_PORT}"
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
    echo -e "  ${GREEN}2.${PLAIN} gRPC + TLS"

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
            read -r -p " 请输入 WS 路径，以 / 开头(不懂请直接回车)：" WS_PATH
            if [[ -z "$WS_PATH" ]]; then
                WS_PATH="$(suggested_ws_path)"
                break
            elif ! is_valid_ws_path "$WS_PATH"; then
                colorEcho "$RED" " WS 路径不合法，请重新输入！"
            else
                break
            fi
        done
        info "WS 路径：$WS_PATH"
    else
        while true; do
            read -r -p " 请输入 gRPC serviceName / 路径前缀(仅字母/数字/._-，不懂请直接回车)：" GRPC_SERVICE
            if [[ -z "$GRPC_SERVICE" ]]; then
                GRPC_SERVICE="$(suggested_grpc_service)"
                break
            elif ! is_valid_grpc_service "$GRPC_SERVICE"; then
                colorEcho "$RED" " gRPC 路径前缀不合法，请重新输入！"
            else
                break
            fi
        done
        info "gRPC 路径前缀：/${GRPC_SERVICE}/"
    fi
}

getData() {
    echo ""
    echo " 运行之前请确认如下条件已经具备："
    colorEcho "$YELLOW" "  1. 一个伪装域名 DNS 解析指向当前服务器 IP（${IP:-未检测到公网IP}）"
    colorEcho "$BLUE"   "  2. 证书将使用 Cloudflare DNS 模式申请，请提前准备可编辑 DNS 的 API Token"
    colorEcho "$BLUE"   "  3. 你的后端已准备好使用 WS 或 gRPC，并监听在你将要填写的回源地址和端口上"
    colorEcho "$BLUE"   "  4. 如果后端和 Nginx 在同机，建议后端只监听 127.0.0.1 / ::1，不要直接暴露到公网"
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

    while true; do
        read -r -p " 请输入后端回源地址[默认127.0.0.1]：" BACKEND_HOST
        BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
        if is_valid_backend_host "$BACKEND_HOST"; then
            break
        fi
        colorEcho "$RED" " 后端地址格式不合法，请重新输入！"
    done

    while true; do
        read -r -p " 请输入后端回源端口[1-65535]：" BACKEND_PORT
        [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || {
            colorEcho "$RED" " 后端端口必须是数字"
            continue
        }
        (( BACKEND_PORT >= 1 && BACKEND_PORT <= 65535 )) || {
            colorEcho "$RED" " 后端端口范围错误"
            continue
        }
        [[ "${BACKEND_PORT:0:1}" != "0" ]] || {
            colorEcho "$RED" " 端口不能以 0 开头"
            continue
        }
        break
    done

    normalize_backend_host
    info "后端回源：${BACKEND_HOST}:${BACKEND_PORT}"
    check_backend_target

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
        transport_block="location ${WS_PATH} {
        proxy_redirect off;
        proxy_read_timeout 1200s;
        proxy_pass http://${BACKEND_HOST_NGINX}:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }"
    else
        transport_block="location ^~ /${GRPC_SERVICE}/ {
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header Host \$host;
        grpc_read_timeout 1200s;
        grpc_send_timeout 1200s;
        grpc_socket_keepalive on;
        grpc_pass grpc://${BACKEND_HOST_NGINX}:${BACKEND_PORT};
    }"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        cp -f "$SITE_CONF" "$bak_conf" || die "备份现有 Nginx 配置失败"
    fi

    cat > "$tmp_conf" <<EOF_NGINX_SITE
# Managed by v2pr
# Backend: ${BACKEND_HOST}:${BACKEND_PORT}
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

showSummary() {
    echo ""
    success "安装完成，入口 ${DOMAIN}:${PORT} 已反代到 ${BACKEND_HOST}:${BACKEND_PORT}"
    success "----------- 关键参数 -----------------------------"
    colorEcho "$RED"   " 域名(SNI)：${DOMAIN}"
    colorEcho "$RED"   " 用户连接端口：${PORT}"
    colorEcho "$RED"   " 后端回源：${BACKEND_HOST}:${BACKEND_PORT}"
    colorEcho "$RED"   " 传输安全：tls"
    colorEcho "$RED"   " 传输协议：${MODE}"

    echo ""
    if [[ "$MODE" == "ws" ]]; then
        colorEcho "$RED" " WS 路径：${WS_PATH}"
    else
        colorEcho "$RED" " gRPC 路径前缀：/${GRPC_SERVICE}/"
    fi

    echo ""
    info "Nginx 配置文件：${SITE_CONF}"
    info "证书文件：${CERT_FILE}"
    info "伪装站点：${PROXY_URL:-/usr/share/nginx/html 本地站点}"
    if [[ -x "$SHORTCUT_PATH" ]]; then
        info "后续可直接运行命令：${SHORTCUT_CMD}"
        info "更新脚本命令：${SHORTCUT_CMD} update"
    fi
    info "如果后端与 Nginx 在同一台机器上，建议后端只监听 127.0.0.1 / ::1"
}

postCheck() {
    if ! nginx_is_active; then
        if [[ "$BT" == "false" ]]; then
            warn "Nginx 当前未处于运行状态，请检查：systemctl status nginx"
        else
            warn "Nginx 当前未处于运行状态，请检查宝塔面板或执行 nginx -t / nginx -s reload"
        fi
    fi

    if backend_is_local; then
        if is_port_in_use "$BACKEND_PORT"; then
            success "已确认本机后端端口 ${BACKEND_PORT} 正在监听"
        else
            warn "未检测到本机后端端口 ${BACKEND_PORT} 正在监听，请确认后端已启动"
        fi
    fi
}

list_site_confs() {
    local conf=""
    local found_managed="false"

    while IFS= read -r conf; do
        [[ -n "$conf" ]] || continue
        if grep -Fq '# Managed by v2pr' "$conf" 2>/dev/null; then
            echo "$conf"
            found_managed="true"
        fi
    done < <(find "$NGINX_CONF_PATH" -maxdepth 1 -type f -name '*.conf' ! -name '*.bak' ! -name '*.tmp' 2>/dev/null | sort)

    if [[ "$found_managed" == "true" ]]; then
        return 0
    fi

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
    getCert
    installTemplate
    configNginx

    if nginx_is_active; then
        reloadNginx || die "Nginx 重载失败"
    else
        startNginx || die "Nginx 启动失败"
    fi

    showSummary
    postCheck || true
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
    if nginx_is_active; then
        success "Nginx: 运行中"
    else
        warn "Nginx: 未运行"
    fi

    info "站点配置目录：${NGINX_CONF_PATH}"
}

menu() {
    clear
    echo "================================"
    echo "      通用 Nginx 反代脚本       "
    echo "================================"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}   安装 Nginx 反代(WS/gRPC + TLS)"
    echo -e "  ${GREEN}2.${PLAIN}   检测并删除某个域名的反代配置"
    echo -e "  ${GREEN}3.${PLAIN}   查看当前服务状态"
    echo -e "  ${GREEN}4.${PLAIN}   更新脚本"
    echo -e "  ${GREEN}0.${PLAIN}   退出"
    echo ""

    read -r -p " 请选择操作：" answer
    case "$answer" in
        1) install_proxy ;;
        2) uninstall_proxy ;;
        3) show_status ;;
        4) update_script ;;
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
    uninstall)
        uninstall_proxy
        ;;
    uninstall_proxy)
        uninstall_proxy
        ;;
    status)
        show_status
        ;;
    update)
        update_script
        ;;
    *)
        echo "参数错误"
        echo "用法: $(basename "$0") [menu|install|uninstall|uninstall_proxy|status|update]"
        exit 1
        ;;
esac
