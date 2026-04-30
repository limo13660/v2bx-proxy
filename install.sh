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
HY2_SHORTCUT_CMD="v2hy2"
HY2_SHORTCUT_PATH="/usr/local/bin/${HY2_SHORTCUT_CMD}"
PROJECT_REPO_URL="https://github.com/limo13660/v2bx-proxy"
ONE_KEY_INSTALL_CMD="bash <(curl -fsSL https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/install.sh)"

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
    local target_path="${2:-$SHORTCUT_PATH}"
    local tmp_target="${target_path}.tmp.$$"

    [[ -r "$source_file" ]] || return 1
    mkdir -p "$(dirname "$target_path")" || return 1

    cat "$source_file" > "$tmp_target" || {
        rm -f "$tmp_target"
        return 1
    }
    chmod 755 "$tmp_target" || {
        rm -f "$tmp_target"
        return 1
    }
    mv -f "$tmp_target" "$target_path" || {
        rm -f "$tmp_target"
        return 1
    }
}

main() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份执行安装脚本"

    local tmpfile="/tmp/${SHORTCUT_CMD}.install.$$"
    local hy2_tmpfile="/tmp/${HY2_SHORTCUT_CMD}.install.$$"
    local url=""
    local script_dir=""
    local installed="false"
    local hy2_installed="false"
    local -a update_urls=(
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/v2pr.sh"
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/master/v2pr.sh"
    )
    local -a hy2_urls=(
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/main/hy2.sh"
        "https://raw.githubusercontent.com/limo13660/v2bx-proxy/master/hy2.sh"
    )

    trap 'rm -f "/tmp/${SHORTCUT_CMD}.install.$$" "/tmp/${HY2_SHORTCUT_CMD}.install.$$"' EXIT
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "${script_dir}/v2pr.sh" ]] && validate_script_file "${script_dir}/v2pr.sh"; then
        info "使用本地通用反代脚本：${script_dir}/v2pr.sh"
        install_shortcut_from_file "${script_dir}/v2pr.sh" "$SHORTCUT_PATH" || die "脚本写入失败：${SHORTCUT_PATH}"
        installed="true"
    fi

    for url in "${update_urls[@]}"; do
        [[ "$installed" == "true" ]] && break
        info "尝试下载通用反代脚本：$url"
        if ! safe_download "$url" "$tmpfile"; then
            warn "下载失败：$url"
            continue
        fi

        if ! validate_script_file "$tmpfile"; then
            warn "下载内容不是有效脚本：$url"
            rm -f "$tmpfile"
            continue
        fi

        if install_shortcut_from_file "$tmpfile" "$SHORTCUT_PATH"; then
            installed="true"
            break
        fi

        die "脚本写入失败：${SHORTCUT_PATH}"
    done

    [[ "$installed" == "true" ]] || die "安装失败：无法从项目地址下载有效脚本，请检查网络或仓库地址"

    if [[ -f "${script_dir}/hy2.sh" ]] && validate_script_file "${script_dir}/hy2.sh"; then
        info "使用本地 HY2 伪装脚本：${script_dir}/hy2.sh"
        install_shortcut_from_file "${script_dir}/hy2.sh" "$HY2_SHORTCUT_PATH" || die "HY2 脚本写入失败：${HY2_SHORTCUT_PATH}"
        hy2_installed="true"
    fi

    for url in "${hy2_urls[@]}"; do
        [[ "$hy2_installed" == "true" ]] && break
        info "尝试下载 HY2 伪装脚本：$url"
        if ! safe_download "$url" "$hy2_tmpfile"; then
            warn "下载失败：$url"
            continue
        fi

        if ! validate_script_file "$hy2_tmpfile"; then
            warn "下载内容不是有效脚本：$url"
            rm -f "$hy2_tmpfile"
            continue
        fi

        if install_shortcut_from_file "$hy2_tmpfile" "$HY2_SHORTCUT_PATH"; then
            hy2_installed="true"
            break
        fi

        die "HY2 脚本写入失败：${HY2_SHORTCUT_PATH}"
    done

    [[ "$hy2_installed" == "true" ]] || die "安装失败：无法从项目地址下载有效 HY2 脚本，请检查网络或仓库地址"

    success "安装完成，可直接运行：${SHORTCUT_CMD}"
    success "HY2 伪装脚本：${HY2_SHORTCUT_CMD}"
    info "更新通用反代脚本命令：${SHORTCUT_CMD} update"
    info "远程一键安装命令：${ONE_KEY_INSTALL_CMD}"
    info "项目地址：${PROJECT_REPO_URL}"
}

main "$@"
