#!/usr/bin/env bash

set -u
set -o pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

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

safe_download() {
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

validate_script_file() {
    local file="$1"

    [[ -s "$file" ]] || return 1
    grep -q '^#!/usr/bin/env bash' "$file" 2>/dev/null || return 1
    bash -n "$file" >/dev/null 2>&1 || return 1
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

main() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份执行安装脚本"

    local tmpfile="/tmp/${SHORTCUT_CMD}.install.$$"
    local url=""
    local installed="false"
    local -a update_urls=(
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/v2pr.sh"
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/master/v2pr.sh"
    )

    trap 'rm -f "$tmpfile"' EXIT

    for url in "${update_urls[@]}"; do
        info "尝试下载脚本：$url"
        if ! safe_download "$url" "$tmpfile"; then
            warn "下载失败：$url"
            continue
        fi

        if ! validate_script_file "$tmpfile"; then
            warn "下载内容不是有效脚本：$url"
            rm -f "$tmpfile"
            continue
        fi

        if install_shortcut_from_file "$tmpfile"; then
            installed="true"
            break
        fi

        die "脚本写入失败：${SHORTCUT_PATH}"
    done

    [[ "$installed" == "true" ]] || die "安装失败：无法从项目地址下载有效脚本，请检查网络或仓库地址"

    success "安装完成，可直接运行：${SHORTCUT_CMD}"
    info "更新脚本命令：${SHORTCUT_CMD} update"
    info "项目地址：${PROJECT_REPO_URL}"
}

main "$@"
