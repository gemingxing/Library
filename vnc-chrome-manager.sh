#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly STATE_DIR="/var/lib/vnc-chrome-manager"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly VNC_USERS_FILE="/etc/tigervnc/vncserver.users"
readonly CHROME_LIST_FILE="/etc/apt/sources.list.d/google-chrome.list"
readonly CHROME_KEY_FILE="/usr/share/keyrings/google-chrome.gpg"

MANAGED_USER="admin"
DISPLAY_NUM="1"
GEOMETRY="1440x900"
ASSUME_YES="0"
GENERATE_PASSWORD="0"
STATE_LOADED="0"
STATE_USER=""
STATE_DISPLAY=""
STATE_GEOMETRY=""

log() {
    printf '[信息] %s\n' "$*"
}

warn() {
    printf '[警告] %s\n' "$*" >&2
}

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
用法：
  sudo bash ${SCRIPT_NAME} install [选项]
  sudo bash ${SCRIPT_NAME} uninstall [选项]
  sudo bash ${SCRIPT_NAME} reinstall [选项]
  sudo bash ${SCRIPT_NAME} start
  sudo bash ${SCRIPT_NAME} stop
  sudo bash ${SCRIPT_NAME} status
  bash ${SCRIPT_NAME} help

命令：
  install      安装 XFCE、TigerVNC 和 Google Chrome，只完成配置，不启动 VNC
  uninstall    停止 VNC，卸载软件并删除本脚本管理的全部配置
  reinstall    完整卸载后重新安装，旧 VNC 密码和桌面配置不会保留
  start        手动启动 VNC 服务
  stop         手动关闭 VNC 服务
  status       查看 VNC 服务、监听端口和安装版本
  help         显示帮助

选项：
  --user USER          桌面用户，默认：admin；禁止使用 root
  --display NUMBER     VNC 显示号，默认：1，对应端口 5901
  --geometry WxH       桌面分辨率，默认：1440x900
  --generate-password  自动生成 8 位 VNC 密码并在安装结束时显示
  --yes                卸载或重装时跳过人工确认
  -h, --help           显示帮助

安装示例：
  sudo bash ${SCRIPT_NAME} install --user admin --generate-password

手动启动与关闭：
  sudo bash ${SCRIPT_NAME} start
  sudo bash ${SCRIPT_NAME} stop

客户端连接：
  1. 在客户端本机建立 SSH 隧道并保持终端运行：
     ssh -N -L 5901:127.0.0.1:5901 root@<服务器IP>
  2. 使用 VNC Viewer 或 MobaXterm 的 VNC 会话连接 127.0.0.1:5901。
  3. 输入安装时设置或生成的 VNC 密码。

安全说明：
  VNC 仅监听服务器的 127.0.0.1，不直接暴露到公网。
  VNC 传统密码最多有效 8 位，本脚本仅接受 6 到 8 位可打印 ASCII 字符。
  uninstall 和 reinstall 会删除专用桌面用户及其整个主目录；--yes 会跳过确认。
EOF
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die "该命令必须使用 root 权限，请在命令前添加 sudo。"
}

load_state() {
    [[ -f "${STATE_FILE}" ]] || return 0

    # 原因：状态文件决定后续操作的用户名和显示号，若普通用户可修改会导致 root 删除错误路径；
    # 例如：把 MANAGED_USER 篡改为其他系统账号后执行卸载，可能清理不属于脚本的配置；
    # 所以只读取属于 root 且普通用户不可写的状态文件。
    local owner mode
    owner="$(stat -c '%u' "${STATE_FILE}")"
    mode="$(stat -c '%a' "${STATE_FILE}")"
    [[ "${owner}" == "0" && "${mode}" == "600" ]] || \
        die "状态文件 ${STATE_FILE} 的所有者或权限异常，请人工检查后再操作。"

    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    STATE_LOADED="1"
    STATE_USER="${MANAGED_USER}"
    STATE_DISPLAY="${DISPLAY_NUM}"
    STATE_GEOMETRY="${GEOMETRY}"
}

save_state() {
    install -d -m 700 "${STATE_DIR}"
    {
        printf 'MANAGED_USER=%q\n' "${MANAGED_USER}"
        printf 'DISPLAY_NUM=%q\n' "${DISPLAY_NUM}"
        printf 'GEOMETRY=%q\n' "${GEOMETRY}"
    } > "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
}

parse_options() {
    while (($# > 0)); do
        case "$1" in
            --user)
                (($# >= 2)) || die "--user 缺少用户名。"
                MANAGED_USER="$2"
                shift 2
                ;;
            --display)
                (($# >= 2)) || die "--display 缺少显示号。"
                DISPLAY_NUM="$2"
                shift 2
                ;;
            --geometry)
                (($# >= 2)) || die "--geometry 缺少分辨率。"
                GEOMETRY="$2"
                shift 2
                ;;
            --generate-password)
                GENERATE_PASSWORD="1"
                shift
                ;;
            --yes)
                ASSUME_YES="1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知选项：$1。使用 '${SCRIPT_NAME} help' 查看帮助。"
                ;;
        esac
    done
}

require_state_consistency() {
    [[ "${STATE_LOADED}" == "0" ]] && return 0
    [[ "${MANAGED_USER}" == "${STATE_USER}" ]] || \
        die "已有状态记录的用户是 ${STATE_USER}，不能用参数改为 ${MANAGED_USER}；请先卸载再重新安装。"
    [[ "${DISPLAY_NUM}" == "${STATE_DISPLAY}" ]] || \
        die "已有状态记录的显示号是 :${STATE_DISPLAY}，不能用参数改为 :${DISPLAY_NUM}；请先卸载再重新安装。"
    [[ "${GEOMETRY}" == "${STATE_GEOMETRY}" ]] || \
        die "已有状态记录的分辨率是 ${STATE_GEOMETRY}，不能直接改为 ${GEOMETRY}；请先卸载再重新安装。"
}

validate_settings() {
    [[ "${MANAGED_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
        die "用户名只能包含小写字母、数字、下划线和短横线，且必须以字母或下划线开头。"
    [[ "${MANAGED_USER}" != "root" ]] || die "禁止为 root 配置桌面和 Chrome。"
    [[ "${DISPLAY_NUM}" =~ ^[1-9][0-9]?$ ]] || die "显示号必须是 1 到 99 的整数。"
    [[ "${GEOMETRY}" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || \
        die "分辨率格式错误，正确示例：1440x900。"
}

check_platform() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统。"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" ]] || \
        die "当前仅支持 Debian 和 Ubuntu，检测到：${ID:-未知}。"
    [[ "$(dpkg --print-architecture)" == "amd64" ]] || \
        die "Google Chrome 官方 Linux 包仅支持 amd64，本机架构为 $(dpkg --print-architecture)。"
}

service_name() {
    printf 'tigervncserver@:%s.service' "${DISPLAY_NUM}"
}

user_home() {
    getent passwd "${MANAGED_USER}" | cut -d: -f6
}

confirm_destructive_action() {
    [[ "${ASSUME_YES}" == "1" ]] && return 0
    [[ -t 0 ]] || die "非交互环境必须显式添加 --yes 才能执行卸载或重装。"

    printf '\n即将执行以下不可逆操作：\n'
    printf '  - 停止 VNC 显示 :%s 并删除该显示号映射；\n' "${DISPLAY_NUM}"
    printf '  - 删除用户 %s 的 VNC 和 Chrome 配置；\n' "${MANAGED_USER}"
    printf '  - 删除专用用户 %s 及其整个主目录，不保留任何用户文件；\n' "${MANAGED_USER}"
    printf '  - 卸载 Chrome、TigerVNC、XFCE 及不再使用的依赖。\n\n'

    local answer
    read -r -p "请输入 DELETE 确认继续：" answer
    [[ "${answer}" == "DELETE" ]] || die "操作已取消。"
}

install_chrome_repository() {
    wget -q --https-only -O - https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor --yes --output "${CHROME_KEY_FILE}"
    chmod 644 "${CHROME_KEY_FILE}"
    printf '%s\n' \
        "deb [arch=amd64 signed-by=${CHROME_KEY_FILE}] https://dl.google.com/linux/chrome/deb/ stable main" \
        > "${CHROME_LIST_FILE}"
    chmod 644 "${CHROME_LIST_FILE}"
}

create_managed_user() {
    if id "${MANAGED_USER}" >/dev/null 2>&1; then
        die "用户 ${MANAGED_USER} 已存在。为避免误删已有数据，请改用未占用的专用用户名，或先人工确认并清理该账号。"
    fi

    useradd --create-home --user-group --shell /bin/bash "${MANAGED_USER}"
    passwd --lock "${MANAGED_USER}" >/dev/null
    log "已创建仅用于桌面的普通用户 ${MANAGED_USER}，其系统密码保持锁定。"
}

read_vnc_password() {
    local first second
    if [[ "${GENERATE_PASSWORD}" == "1" ]]; then
        VNC_PASSWORD="$(openssl rand -hex 4)"
        return 0
    fi

    [[ -t 0 ]] || die "非交互安装必须添加 --generate-password。"
    read -r -s -p "请输入 6 到 8 位 VNC 密码，直接回车则随机生成：" first
    printf '\n'
    if [[ -z "${first}" ]]; then
        VNC_PASSWORD="$(openssl rand -hex 4)"
        return 0
    fi
    [[ "${first}" =~ ^[[:graph:]]{6,8}$ ]] || die "VNC 密码必须是 6 到 8 位可打印 ASCII 字符。"
    read -r -s -p "请再次输入 VNC 密码：" second
    printf '\n'
    [[ "${first}" == "${second}" ]] || die "两次输入的 VNC 密码不一致。"
    VNC_PASSWORD="${first}"
}

ensure_display_available() {
    [[ -f "${VNC_USERS_FILE}" ]] || return 0

    local mapped_user
    mapped_user="$(awk -F= -v display=":${DISPLAY_NUM}" '$1 == display {print $2; exit}' "${VNC_USERS_FILE}")"
    [[ -z "${mapped_user}" || "${mapped_user}" == "${MANAGED_USER}" ]] || \
        die "显示号 :${DISPLAY_NUM} 已分配给用户 ${mapped_user}，请更换 --display。"
}

write_vnc_configuration() {
    local home config_home vnc_dir legacy_dir
    home="$(user_home)"
    [[ -n "${home}" && "${home}" == /home/* ]] || \
        die "用户 ${MANAGED_USER} 的主目录 ${home:-为空} 不在 /home 下，拒绝写入。"
    config_home="${home}/.config"
    vnc_dir="${config_home}/tigervnc"
    legacy_dir="${home}/.vnc"

    # 原因：TigerVNC 1.15 使用 ~/.config/tigervnc，而旧版 Debian 仍读取 ~/.vnc；
    # 例如：Debian 13 直接使用旧目录时会尝试迁移，但缺少 ~/.config 父目录会导致服务退出；
    # 所以将真实配置写入新目录，并用 ~/.vnc 符号链接兼容旧版 TigerVNC。
    [[ ! -e "${legacy_dir}" && ! -L "${legacy_dir}" ]] || \
        die "路径 ${legacy_dir} 已存在，拒绝覆盖未知的 VNC 配置。"
    install -d -m 700 -o "${MANAGED_USER}" -g "${MANAGED_USER}" \
        "${config_home}" "${vnc_dir}"
    ln -s ".config/tigervnc" "${legacy_dir}"
    chown -h "${MANAGED_USER}:${MANAGED_USER}" "${legacy_dir}"
    (umask 077; printf '%s\n' "${VNC_PASSWORD}" | tigervncpasswd -f > "${vnc_dir}/passwd")
    chown "${MANAGED_USER}:${MANAGED_USER}" "${vnc_dir}/passwd"
    {
        printf '$session = "xfce";\n'
        printf '$geometry = "%s";\n' "${GEOMETRY}"
        printf '$depth = "24";\n'
        printf '$localhost = "yes";\n'
    } > "${vnc_dir}/config.pl"
    chown "${MANAGED_USER}:${MANAGED_USER}" "${vnc_dir}/config.pl"
    chmod 600 "${vnc_dir}/config.pl"
    ln -s "config.pl" "${vnc_dir}/tigervnc.conf"
    chown -h "${MANAGED_USER}:${MANAGED_USER}" "${vnc_dir}/tigervnc.conf"
}

write_user_mapping() {
    touch "${VNC_USERS_FILE}"
    sed -i -E "/^:${DISPLAY_NUM}=/d; /=${MANAGED_USER}$/d" "${VNC_USERS_FILE}"
    printf ':%s=%s\n' "${DISPLAY_NUM}" "${MANAGED_USER}" >> "${VNC_USERS_FILE}"
}

install_all() {
    check_platform
    validate_settings
    ensure_display_available

    log "更新软件索引并安装 XFCE、TigerVNC 及基础组件。"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        xfce4 xfce4-goodies \
        tigervnc-standalone-server tigervnc-tools \
        dbus-x11 xauth fonts-noto-cjk \
        wget ca-certificates gnupg openssl

    log "配置 Google 官方软件源并安装稳定版 Chrome。"
    install_chrome_repository
    apt-get update
    apt-get install -y google-chrome-stable

    create_managed_user
    read_vnc_password
    write_vnc_configuration
    write_user_mapping
    save_state

    # 安装阶段只写配置，不启动也不开机自启，服务生命周期完全由 start/stop 命令控制。
    systemctl disable --now "$(service_name)" >/dev/null 2>&1 || true
    systemctl daemon-reload

    printf '\n安装完成。VNC 当前未启动。\n'
    printf '桌面用户：%s\n' "${MANAGED_USER}"
    printf '显示号：:%s\n' "${DISPLAY_NUM}"
    printf '本机监听端口：%s\n' "$((5900 + DISPLAY_NUM))"
    printf 'VNC 密码：%s\n' "${VNC_PASSWORD}"
    printf '\n手动启动：sudo bash %s start\n' "${SCRIPT_NAME}"
    unset VNC_PASSWORD
}

remove_user_configuration() {
    id "${MANAGED_USER}" >/dev/null 2>&1 || return 0

    local home
    home="$(user_home)"
    [[ -n "${home}" && "${home}" == /home/* ]] || \
        die "用户 ${MANAGED_USER} 的主目录 ${home:-为空} 不在 /home 下，拒绝删除。"

    userdel --remove "${MANAGED_USER}" 2>/dev/null || \
        die "删除用户 ${MANAGED_USER} 失败，请人工检查该用户是否仍有进程。"
}

remove_user_mapping() {
    [[ -f "${VNC_USERS_FILE}" ]] || return 0
    sed -i -E "/^:${DISPLAY_NUM}=${MANAGED_USER}$/d" "${VNC_USERS_FILE}"
}

uninstall_all() {
    validate_settings
    confirm_destructive_action

    log "停止 VNC 并删除配置。"
    systemctl disable --now "$(service_name)" >/dev/null 2>&1 || true
    remove_user_mapping
    pkill -TERM -u "${MANAGED_USER}" 2>/dev/null || true
    sleep 1
    pkill -KILL -u "${MANAGED_USER}" 2>/dev/null || true
    remove_user_configuration

    log "卸载 Chrome、TigerVNC、XFCE 及其不再使用的依赖。"
    export DEBIAN_FRONTEND=noninteractive
    local candidate installed_packages=()
    for candidate in \
        google-chrome-stable \
        tigervnc-standalone-server tigervnc-tools \
        xfce4 xfce4-goodies \
        dbus-x11 xauth fonts-noto-cjk; do
        if dpkg-query -W -f='${db:Status-Abbrev}' "${candidate}" 2>/dev/null | grep -q '^ii'; then
            installed_packages+=("${candidate}")
        fi
    done
    if ((${#installed_packages[@]} > 0)); then
        apt-get purge -y "${installed_packages[@]}"
    fi
    rm -f -- "${CHROME_LIST_FILE}" "${CHROME_KEY_FILE}"
    apt-get update
    apt-get autoremove --purge -y
    apt-get clean

    rm -f -- "${STATE_FILE}"
    rmdir "${STATE_DIR}" 2>/dev/null || true
    systemctl daemon-reload
    log "卸载完成，脚本管理的 VNC 与 Chrome 配置已删除。"
}

start_vnc() {
    validate_settings
    [[ -f "${STATE_FILE}" ]] || die "未找到安装状态，请先执行 install。"
    systemctl start "$(service_name)"

    # systemd 的 Type=forking 可能先报告启动成功，而桌面会话随后才因配置错误退出。
    # 等待服务和端口共同稳定，避免向调用者返回“已启动”但实际无法连接的结果。
    local port attempt
    port="$((5900 + DISPLAY_NUM))"
    for attempt in {1..5}; do
        sleep 1
        if systemctl is-active --quiet "$(service_name)" \
            && ss -lnt 2>/dev/null | grep -Eq "(127\\.0\\.0\\.1|\\[::1\\]):${port}([[:space:]]|$)"; then
            printf 'VNC 已启动：显示号 :%s，端口 %s，仅监听 127.0.0.1。\n' \
                "${DISPLAY_NUM}" "${port}"
            return 0
        fi
    done

    journalctl -u "$(service_name)" --no-pager -n 30 >&2 || true
    die "VNC 启动失败或端口 ${port} 未监听。"
}

stop_vnc() {
    validate_settings
    [[ -f "${STATE_FILE}" ]] || die "未找到安装状态，请先执行 install。"
    systemctl stop "$(service_name)"
    log "VNC 已关闭。"
}

status_vnc() {
    validate_settings
    local service port
    service="$(service_name)"
    port="$((5900 + DISPLAY_NUM))"

    printf '服务：%s\n' "${service}"
    printf '状态：%s\n' "$(systemctl is-active "${service}" 2>/dev/null || true)"
    printf '开机自启：%s\n' "$(systemctl is-enabled "${service}" 2>/dev/null || true)"
    printf '监听端口：\n'
    ss -lntp 2>/dev/null | awk -v port=":${port}" '$4 ~ port {print "  " $0}' || true
    printf 'Chrome：%s\n' "$(google-chrome --version 2>/dev/null || printf '未安装')"
    printf 'TigerVNC：%s\n' \
        "$(dpkg-query -W -f='${Version}' tigervnc-standalone-server 2>/dev/null || printf '未安装')"
}

main() {
    local command="${1:-help}"
    (($# > 0)) && shift

    case "${command}" in
        help|-h|--help)
            usage
            ;;
        install)
            require_root
            load_state
            parse_options "$@"
            [[ ! -f "${STATE_FILE}" ]] || die "检测到已有安装状态；需要全新安装请执行 reinstall。"
            install_all
            ;;
        uninstall)
            require_root
            load_state
            parse_options "$@"
            require_state_consistency
            uninstall_all
            ;;
        reinstall)
            require_root
            load_state
            parse_options "$@"
            require_state_consistency
            validate_settings
            confirm_destructive_action
            ASSUME_YES="1"
            uninstall_all
            install_all
            ;;
        start)
            require_root
            load_state
            parse_options "$@"
            require_state_consistency
            start_vnc
            ;;
        stop)
            require_root
            load_state
            parse_options "$@"
            require_state_consistency
            stop_vnc
            ;;
        status)
            require_root
            load_state
            parse_options "$@"
            require_state_consistency
            status_vnc
            ;;
        *)
            die "未知命令：${command}。使用 '${SCRIPT_NAME} help' 查看帮助。"
            ;;
    esac
}

main "$@"
