#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="simple-reality"
SERVICE_USER="simple-reality"
INSTALL_DIR="/usr/local/lib/simple-reality"
CONFIG_DIR="/etc/simple-reality"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_FILE="${CONFIG_DIR}/state.env"
SHARE_FILE="${CONFIG_DIR}/vless.txt"
MARKER_FILE="${CONFIG_DIR}/.managed-by-simple-reality"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
COMMAND_FILE="/usr/local/sbin/simple-reality"
DEFAULT_VERSION="26.3.27"
DEFAULT_PORT="443"
DEFAULT_SNI="www.debian.org"
INSTALL_STAGE=""
INSTALL_MUTATED="0"
INSTALL_COMPLETED="0"

cleanup_on_exit() {
  local exit_code=$?
  if [[ -n "$INSTALL_STAGE" && -d "$INSTALL_STAGE" ]]; then
    rm -rf -- "$INSTALL_STAGE"
  fi
  if [[ "$exit_code" != "0" && "$INSTALL_MUTATED" == "1" && "$INSTALL_COMPLETED" != "1" ]]; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$UNIT_FILE" "$COMMAND_FILE"
    rm -rf -- "$CONFIG_DIR" "$INSTALL_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    userdel "$SERVICE_USER" >/dev/null 2>&1 || true
    echo "安装失败，已回滚本次创建的文件和服务。" >&2
  fi
  trap - EXIT
  exit "$exit_code"
}

trap cleanup_on_exit EXIT

fail() {
  echo "错误：$*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" == "0" ]] || fail "请使用 root 运行。"
  [[ "$(uname -s)" == "Linux" ]] || fail "仅支持 Linux。"
  [[ -d /run/systemd/system ]] || fail "当前系统未使用 systemd。"
  command -v apt-get >/dev/null 2>&1 || fail "当前脚本仅支持 Debian/Ubuntu。"
}

validate_address() {
  local value="$1"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "--address 必须是 IPv4 地址。"
  local part
  IFS='.' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    ((10#$part <= 255)) || fail "--address 不是有效的 IPv4 地址。"
  done
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "--port 必须是数字。"
  ((value >= 1 && value <= 65535)) || fail "--port 必须在 1 到 65535 之间。"
}

validate_sni() {
  local value="$1"
  [[ ${#value} -le 253 ]] || fail "--sni 过长。"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail "--sni 不是有效的 ASCII 域名。"
  [[ "$value" == *.* ]] || fail "--sni 必须是完整域名。"
  [[ "$value" != *..* ]] || fail "--sni 不能包含空标签。"
}

validate_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version 格式应为 26.3.27。"
}

usage() {
  cat <<'EOF'
用法：
  bash simple-reality.sh install [--address IPv4] [--port 443] [--sni 域名] [--version 版本] [--yes]
  bash simple-reality.sh uninstall [--yes]
  bash simple-reality.sh show
  bash simple-reality.sh status

说明：
  install    安装一个 VPS 直出的 VLESS + REALITY 节点，并设置开机启动。
  uninstall  停止服务、取消开机启动，只删除本脚本创建的文件和系统用户。
  show       显示已安装节点的 VLESS 分享链接。
  status     显示服务状态与开机启动状态。
EOF
}

confirm_reinstall_absent() {
  if [[ -e "$MARKER_FILE" ]]; then
    fail "已经安装。如需重建凭据，请先执行 uninstall，再重新 install。"
  fi
  if [[ -e "$CONFIG_DIR" || -e "$INSTALL_DIR" || -e "$UNIT_FILE" || -e "$COMMAND_FILE" ]] || \
     getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    fail "检测到同名文件但没有本脚本的管理标记，为避免误覆盖已停止安装。"
  fi
}

detect_address() {
  if command -v curl >/dev/null 2>&1; then
    curl -4fsS --connect-timeout 8 https://api.ipify.org || true
  elif command -v wget >/dev/null 2>&1; then
    wget -4qO- --timeout=8 https://api.ipify.org || true
  fi
}

confirm_install() {
  local assume_yes="$1" address="$2" port="$3" sni="$4" version="$5"
  echo "即将安装：VLESS + REALITY"
  echo "公网地址：${address}"
  echo "监听端口：TCP ${port}"
  echo "目标域名：${sni}"
  echo "Xray 版本：${version}"
  if [[ "$assume_yes" == "1" ]]; then
    return
  fi
  read -r -p "输入 INSTALL 继续，其他输入取消：" answer
  [[ "$answer" == "INSTALL" ]] || fail "已取消。"
}

check_target() {
  local sni="$1" output
  output="$(timeout 15 openssl s_client -connect "${sni}:443" -servername "$sni" -tls1_3 -alpn h2 </dev/null 2>&1 || true)"
  grep -q "ALPN protocol: h2" <<< "$output" || fail "${sni}:443 未成功协商 TLS 1.3 + h2，请更换 REALITY 目标域名。"
}

download_xray() {
  local directory="$1" version="$2" machine archive url expected actual version_output
  machine="$(uname -m)"
  case "$machine" in
    x86_64) archive="Xray-linux-64.zip" ;;
    aarch64|arm64) archive="Xray-linux-arm64-v8a.zip" ;;
    *) fail "仅支持 Linux amd64/arm64，当前架构：${machine}" ;;
  esac
  url="https://github.com/XTLS/Xray-core/releases/download/v${version}/${archive}"
  curl -fL --retry 3 --connect-timeout 15 -o "${directory}/${archive}" "$url"
  curl -fL --retry 3 --connect-timeout 15 -o "${directory}/${archive}.dgst" "${url}.dgst"

  # 原因：只校验下载成功无法发现文件被截断或替换；
  # 例如：代理缓存返回了损坏的 ZIP 时，直接安装会得到不可执行的核心；
  # 所以使用同一官方发布中的 SHA-256 校验值验证压缩包后再解压。
  mapfile -t hashes < <(grep -Eio '[0-9a-f]{64}' "${directory}/${archive}.dgst")
  [[ ${#hashes[@]} -gt 0 ]] || fail "官方校验文件中没有 SHA-256。"
  expected="${hashes[0],,}"
  actual="$(sha256sum "${directory}/${archive}" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "Xray 官方 SHA-256 校验失败。"
  unzip -q "${directory}/${archive}" xray -d "$directory"
  chmod 0755 "${directory}/xray"
  # 原因：在 pipefail 模式下用 grep -q 提前结束管道，可能让仍在输出第二行的 Xray 收到 SIGPIPE；
  # 例如：第一行已经匹配版本，但管道状态仍可能是 141，导致把正确版本误判为失败；
  # 所以先完整读取版本输出，再单独匹配第一行中的发布版本。
  version_output="$("${directory}/xray" version)"
  grep -q "^Xray ${version} " <<< "$version_output" || fail "下载的 Xray 版本不匹配。"
}

write_config() {
  local directory="$1" address="$2" port="$3" sni="$4" version="$5"
  local keys private_key public_key uuid short_id share_link
  keys="$("${directory}/xray" x25519)"
  private_key="$(sed -nE 's/^PrivateKey:[[:space:]]*([^[:space:]]+).*/\1/p' <<< "$keys" | head -n 1)"
  public_key="$(sed -nE 's/^(Password \(PublicKey\)|PublicKey|Password):[[:space:]]*([^[:space:]]+).*/\2/p' <<< "$keys" | head -n 1)"
  uuid="$(cat /proc/sys/kernel/random/uuid)"
  short_id="$(openssl rand -hex 8)"
  [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "无法解析 REALITY 私钥。"
  [[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || fail "无法解析 REALITY 公钥。"

  mkdir -p "${directory}/generated"
  cat > "${directory}/generated/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision",
            "email": "vps-direct@simple-reality.invalid"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${sni}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": ["${short_id}"]
        }
      },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
  share_link="vless://${uuid}@${address}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&spx=%2F&type=tcp#VPS-Reality"
  printf '%s\n' "$share_link" > "${directory}/generated/vless.txt"
  cat > "${directory}/generated/state.env" <<EOF
XRAY_VERSION='${version}'
ADDRESS='${address}'
PORT='${port}'
SNI='${sni}'
UUID='${uuid}'
PUBLIC_KEY='${public_key}'
SHORT_ID='${short_id}'
EOF
  "${directory}/xray" run -test -config "${directory}/generated/config.json"
}

write_unit() {
  local directory="$1"
  cat > "${directory}/simple-reality.service" <<EOF
[Unit]
Description=Simple VLESS REALITY proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${INSTALL_DIR}/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

install_proxy() {
  require_root
  local address="" port="$DEFAULT_PORT" sni="$DEFAULT_SNI" version="$DEFAULT_VERSION" assume_yes="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --address) [[ $# -ge 2 ]] || fail "--address 缺少参数。"; address="$2"; shift 2 ;;
      --port) [[ $# -ge 2 ]] || fail "--port 缺少参数。"; port="$2"; shift 2 ;;
      --sni) [[ $# -ge 2 ]] || fail "--sni 缺少参数。"; sni="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || fail "--version 缺少参数。"; version="$2"; shift 2 ;;
      --yes) assume_yes="1"; shift ;;
      *) fail "未知安装参数：$1" ;;
    esac
  done
  if [[ -z "$address" ]]; then
    address="$(detect_address)"
    [[ -n "$address" ]] || fail "无法自动获取公网 IPv4，请使用 --address 指定。"
  fi
  validate_address "$address"
  validate_port "$port"
  validate_sni "$sni"
  validate_version "$version"
  confirm_reinstall_absent
  confirm_install "$assume_yes" "$address" "$port" "$sni" "$version"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip openssl iproute2
  check_target "$sni"
  if ss -H -ltn "sport = :${port}" | grep -q .; then
    fail "TCP ${port} 已被其他程序占用。"
  fi

  INSTALL_STAGE="$(mktemp -d /tmp/simple-reality.XXXXXXXX)"
  download_xray "$INSTALL_STAGE" "$version"
  write_config "$INSTALL_STAGE" "$address" "$port" "$sni" "$version"
  write_unit "$INSTALL_STAGE"

  INSTALL_MUTATED="1"
  useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 0755 "$INSTALL_DIR"
  install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
  install -m 0755 "${INSTALL_STAGE}/xray" "${INSTALL_DIR}/xray"
  install -o root -g "$SERVICE_USER" -m 0640 "${INSTALL_STAGE}/generated/config.json" "$CONFIG_FILE"
  install -o root -g root -m 0600 "${INSTALL_STAGE}/generated/state.env" "$STATE_FILE"
  install -o root -g root -m 0600 "${INSTALL_STAGE}/generated/vless.txt" "$SHARE_FILE"
  install -o root -g root -m 0600 /dev/null "$MARKER_FILE"
  install -m 0644 "${INSTALL_STAGE}/simple-reality.service" "$UNIT_FILE"
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    install -m 0700 "${BASH_SOURCE[0]}" "$COMMAND_FILE"
  fi
  systemd-analyze verify "$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  sleep 1
  [[ "$(systemctl is-active "$SERVICE_NAME")" == "active" ]] || {
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    fail "服务启动失败。"
  }
  [[ "$(systemctl is-enabled "$SERVICE_NAME")" == "enabled" ]] || fail "服务未设置开机启动。"
  ss -H -ltn "sport = :${port}" | grep -q . || fail "服务已启动，但没有监听 TCP ${port}。"
  INSTALL_COMPLETED="1"

  echo
  echo "安装成功，服务已运行并设置开机启动。"
  echo "VLESS 分享链接："
  cat "$SHARE_FILE"
  echo
  echo "管理命令：simple-reality status | show | uninstall"
}

uninstall_proxy() {
  require_root
  local assume_yes="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) assume_yes="1"; shift ;;
      *) fail "未知卸载参数：$1" ;;
    esac
  done
  [[ -e "$MARKER_FILE" ]] || fail "没有检测到由本脚本管理的安装，拒绝删除同名路径。"
  if [[ "$assume_yes" != "1" ]]; then
    echo "将停止 ${SERVICE_NAME}，并删除本脚本创建的核心、配置、凭据和系统用户。"
    read -r -p "输入 UNINSTALL 继续，其他输入取消：" answer
    [[ "$answer" == "UNINSTALL" ]] || fail "已取消。"
  fi
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -rf -- "$CONFIG_DIR" "$INSTALL_DIR"
  userdel "$SERVICE_USER" >/dev/null 2>&1 || true
  rm -f -- "$COMMAND_FILE"
  echo "卸载完成；其他服务、代理目录和防火墙规则均未修改。"
}

show_proxy() {
  require_root
  [[ -e "$MARKER_FILE" && -f "$SHARE_FILE" ]] || fail "尚未安装。"
  cat "$SHARE_FILE"
}

status_proxy() {
  require_root
  [[ -e "$MARKER_FILE" ]] || fail "尚未安装。"
  echo "开机启动：$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
  echo "运行状态：$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  systemctl status "$SERVICE_NAME" --no-pager -l
}

main() {
  local command="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$command" in
    install) install_proxy "$@" ;;
    uninstall) uninstall_proxy "$@" ;;
    show) show_proxy "$@" ;;
    status) status_proxy "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; fail "未知命令：${command}" ;;
  esac
}

main "$@"
