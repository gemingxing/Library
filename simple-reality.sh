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
HY2_SHARE_FILE="${CONFIG_DIR}/hysteria2.txt"
HY2_CLASH_FILE="${CONFIG_DIR}/hysteria2-clash.yaml"
DEFAULT_VERSION="26.9.9"
DEFAULT_HY2_PORT="443"
DEFAULT_PORT="443"
DEFAULT_SNI="www.debian.org"
INSTALL_STAGE=""
INSTALL_MUTATED="0"
INSTALL_COMPLETED="0"
UPDATE_MUTATED="0"
UPDATE_COMPLETED="0"

cleanup_on_exit() {
  local exit_code=$?
  if [[ "$exit_code" != "0" && "$UPDATE_MUTATED" == "1" && "$UPDATE_COMPLETED" != "1" ]]; then
    # 原因：核心和配置必须配套恢复，否则旧核心可能无法读取新增的 Hysteria2 配置；
    # 例如：新核心启动失败时，只恢复 config.json 会留下未验证的核心；
    # 所以恢复本次修改前的核心、配置、状态和管理命令，再启动原服务。
    local rollback_ok="1" file
    for file in xray config.json state.env; do
      case "$file" in
        xray) cp -p -- "${INSTALL_STAGE}/backup/$file" "${INSTALL_DIR}/xray.rollback" && mv -f -- "${INSTALL_DIR}/xray.rollback" "${INSTALL_DIR}/xray" || rollback_ok="0" ;;
        *) cp -p -- "${INSTALL_STAGE}/backup/$file" "${CONFIG_DIR}/$file" || rollback_ok="0" ;;
      esac
    done
    if [[ -f "${INSTALL_STAGE}/backup/command" ]]; then
      cp -p -- "${INSTALL_STAGE}/backup/command" "$COMMAND_FILE" || rollback_ok="0"
    else
      rm -f -- "$COMMAND_FILE" || rollback_ok="0"
    fi
    rm -f -- "$HY2_SHARE_FILE" "$HY2_CLASH_FILE" "${INSTALL_DIR}/xray.new" "${CONFIG_FILE}.new" || rollback_ok="0"
    systemctl restart "$SERVICE_NAME" || rollback_ok="0"
    sleep 1
    [[ "$(systemctl is-active "$SERVICE_NAME")" == "active" ]] || rollback_ok="0"
    if [[ "$rollback_ok" == "1" ]]; then
      echo "添加失败，已恢复原核心、配置和服务。" >&2
    else
      echo "回滚未完全成功，备份保留在 ${INSTALL_STAGE}/backup，请人工恢复。" >&2
      INSTALL_STAGE=""
    fi
  fi
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
  bash simple-reality.sh install [--address IPv4] [--port 443] [--hy2-port 443] [--sni 域名] [--version 版本] [--yes]
  bash simple-reality.sh add-hysteria2 [--address IPv4] [--hy2-port 443] [--sni 域名] [--version 版本] [--yes]
  bash simple-reality.sh uninstall [--yes]
  bash simple-reality.sh show
  bash simple-reality.sh status

说明：
  install    同一 Xray 服务安装 VLESS + REALITY 和 Hysteria2，设置开机启动。
  add-hysteria2  为旧版安装添加 Hysteria2，保留原 REALITY 配置和分享链接。
  uninstall  停止服务、取消开机启动，只删除本脚本创建的文件和系统用户。
  show       显示 VLESS、Hysteria2 分享链接及 Hysteria2 Clash 配置。
  status     显示服务状态与开机启动状态。

Hysteria2 使用自签证书和 SHA-256 指纹校验；导入客户端时必须保留指纹。
TCP 与 UDP 可共用 443；系统防火墙及云安全规则需放行对应 UDP 端口。
--version 最低为 26.9.9；应用添加操作时会短暂重启同一个服务。
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
  local assume_yes="$1" address="$2" port="$3" sni="$4" version="$5" hy2_port="$6"
  echo "即将安装：同一 Xray 服务的 VLESS + REALITY 与 Hysteria2"
  echo "公网地址：${address}"
  echo "监听端口：TCP ${port} / UDP ${hy2_port}"
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

acquire_lock() {
  exec 9>/run/lock/simple-reality.lock
  flock -n 9 || fail "另一个安装或卸载操作正在运行。"
}

validate_hysteria_version() {
  validate_version "$1"
  [[ "$(printf '%s\n' '26.9.9' "$1" | sort -V | head -n 1)" == "26.9.9" ]] || fail "双协议要求 Xray 26.9.9 或更新版本。"
}

check_udp_port() {
  local listeners
  listeners="$(ss -H -lun "sport = :$1")"
  [[ -z "$listeners" ]] || fail "UDP $1 已被其他程序占用。"
}

write_hysteria_config() {
  local directory="$1" address="$2" port="$3" sni="$4" version="$5"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "${directory}/hy2-key.pem" -out "${directory}/hy2-cert.pem" \
    -days 3650 -subj "/CN=${sni}" -addext "subjectAltName=DNS:${sni}" >/dev/null 2>&1 || return
  # 原因：自签证书不能通过公共 CA 校验，完全跳过校验会接受冒充服务；
  # 例如：导入 insecure=1 却丢掉 pinSHA256 的链接后，客户端无法确认服务器身份；
  # 所以同时导出证书指纹，客户端必须支持并保留该指纹。
  python3 - "$directory" "$address" "$port" "$sni" "$version" <<'PY' || return
import hashlib
import json
from pathlib import Path
import re
import secrets
import ssl
import sys
import urllib.parse

root = Path(sys.argv[1])
address, port, sni, version = sys.argv[2:]
generated = root / "generated"
config_file = generated / "config.json"
config = json.loads(config_file.read_text())
if any(i.get("protocol") == "hysteria" or i.get("tag") == "hysteria2" for i in config["inbounds"]):
    raise SystemExit("配置中已有 Hysteria 入站，拒绝重复添加。")
cert = (root / "hy2-cert.pem").read_text()
key = (root / "hy2-key.pem").read_text()
fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert)).hexdigest()
password = secrets.token_urlsafe(32)
config["inbounds"].append({
    "tag": "hysteria2", "listen": "0.0.0.0", "port": int(port), "protocol": "hysteria",
    "settings": {"version": 2, "users": [{"auth": password, "email": "hy2@simple-reality.invalid"}]},
    "streamSettings": {
        "network": "hysteria", "security": "tls",
        "tlsSettings": {"serverName": sni, "alpn": ["h3"],
                        "certificates": [{"certificate": cert.splitlines(), "key": key.splitlines()}]},
        "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60},
        "finalmask": {"quicParams": {"congestion": "bbr"}}},
    "sniffing": {"enabled": False}})
config_file.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
params = urllib.parse.urlencode({"sni": sni, "insecure": "1", "pinSHA256": fingerprint})
(generated / "hysteria2.txt").write_text(
    f"hysteria2://{password}@{address}:{port}/?{params}#VPS-Hysteria2\n")
(generated / "hysteria2-clash.yaml").write_text(
    "proxies:\n  - name: VPS-Hysteria2\n    type: hysteria2\n"
    f"    server: {json.dumps(address)}\n    port: {int(port)}\n    password: {json.dumps(password)}\n"
    f"    sni: {json.dumps(sni)}\n    alpn: [h3]\n    udp: true\n"
    f"    skip-cert-verify: false\n    fingerprint: {json.dumps(fingerprint)}\n")
state_file = generated / "state.env"
state = state_file.read_text()
state = re.sub(r"^XRAY_VERSION=.*$", f"XRAY_VERSION='{version}'", state, flags=re.M)
state_file.write_text(state + f"HY2_PORT='{int(port)}'\nHY2_SNI='{sni}'\n")
PY
  "${directory}/xray" run -test -config "${directory}/generated/config.json"
}

check_dual_listeners() {
  local tcp_port="$1" udp_port="$2" listeners
  [[ "$(systemctl is-active "$SERVICE_NAME")" == "active" ]] || fail "服务未处于运行状态。"
  listeners="$(ss -H -ltn "sport = :${tcp_port}")"
  [[ -n "$listeners" ]] || fail "没有监听 TCP ${tcp_port}。"
  listeners="$(ss -H -lun "sport = :${udp_port}")"
  [[ -n "$listeners" ]] || fail "没有监听 UDP ${udp_port}。"
}

add_hysteria2() {
  require_root
  acquire_lock
  local address="" port="$DEFAULT_HY2_PORT" sni="" version="$DEFAULT_VERSION" assume_yes="0" tcp_port saved
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --address) [[ $# -ge 2 ]] || fail "--address 缺少参数。"; address="$2"; shift 2 ;;
      --hy2-port) [[ $# -ge 2 ]] || fail "--hy2-port 缺少参数。"; port="$2"; shift 2 ;;
      --sni) [[ $# -ge 2 ]] || fail "--sni 缺少参数。"; sni="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || fail "--version 缺少参数。"; version="$2"; shift 2 ;;
      --yes) assume_yes="1"; shift ;;
      *) fail "未知添加参数：$1" ;;
    esac
  done
  [[ -f "$MARKER_FILE" && -f "$CONFIG_FILE" && -f "$STATE_FILE" && -f "$SHARE_FILE" ]] || fail "未检测到完整的旧版安装。"
  [[ ! -e "$HY2_SHARE_FILE" && ! -e "$HY2_CLASH_FILE" ]] || fail "已存在 Hysteria2 导出文件，拒绝覆盖。"
  [[ "$(systemctl is-active "$SERVICE_NAME")" == "active" ]] || fail "请先恢复现有服务，再添加 Hysteria2。"
  command -v python3 >/dev/null 2>&1 || fail "添加操作需要 python3，请先安装。"
  # 原因：旧配置可能含有正在使用的 UUID 和 REALITY 私钥，重建会使现有客户端失效；
  # 例如：旧链接仍使用原 UUID 时，新生成的 UUID 会让认证失败；
  # 所以只从旧状态读取公网地址，从原入站读取端口和域名，并在配置末尾追加 Hysteria2。
  saved="$(python3 - "$CONFIG_FILE" "$STATE_FILE" <<'PY'
import json
from pathlib import Path
import shlex
import sys
config = json.loads(Path(sys.argv[1]).read_text())
if any(i.get("protocol") == "hysteria" for i in config["inbounds"]):
    raise SystemExit("已有 Hysteria 入站，拒绝重复添加。")
reality = [i for i in config["inbounds"] if i.get("protocol") == "vless" and i.get("streamSettings", {}).get("security") == "reality"]
if len(reality) != 1:
    raise SystemExit("要求恰好存在一个 VLESS + REALITY 入站。")
state = dict(v.split("=", 1) for v in shlex.split(Path(sys.argv[2]).read_text(), comments=True))
print(state["ADDRESS"], reality[0]["port"], reality[0]["streamSettings"]["realitySettings"]["serverNames"][0])
PY
)"
  local saved_address saved_sni
  read -r saved_address tcp_port saved_sni <<< "$saved"
  address="${address:-$saved_address}"
  sni="${sni:-$saved_sni}"
  validate_address "$address"
  validate_port "$port"
  validate_sni "$sni"
  validate_hysteria_version "$version"
  check_udp_port "$port"
  echo "将保留 REALITY，升级 Xray 至 ${version}，添加 UDP ${port} 的 Hysteria2 并重启 ${SERVICE_NAME}。"
  if [[ "$assume_yes" != "1" ]]; then
    read -r -p "输入 ADD 继续，其他输入取消：" answer
    [[ "$answer" == "ADD" ]] || fail "已取消。"
  fi
  INSTALL_STAGE="$(mktemp -d /tmp/simple-reality.XXXXXXXX)"
  download_xray "$INSTALL_STAGE" "$version"
  mkdir -m 0700 "${INSTALL_STAGE}/generated" "${INSTALL_STAGE}/backup"
  cp -p -- "$CONFIG_FILE" "$STATE_FILE" "${INSTALL_STAGE}/generated/"
  cp -p -- "$CONFIG_FILE" "$STATE_FILE" "${INSTALL_STAGE}/backup/"
  cp -p -- "${INSTALL_DIR}/xray" "${INSTALL_STAGE}/backup/xray"
  if [[ -f "$COMMAND_FILE" ]]; then
    cp -p -- "$COMMAND_FILE" "${INSTALL_STAGE}/backup/command"
  fi
  write_hysteria_config "$INSTALL_STAGE" "$address" "$port" "$sni" "$version"
  UPDATE_MUTATED="1"
  # 原因：运行中的 Linux 可执行文件不能直接覆盖，否则可能出现 Text file busy；
  # 例如：旧 Xray 仍服务 TCP 443 时直接 install 到原路径会失败；所以写入新文件后原子替换。
  install -m 0755 "${INSTALL_STAGE}/xray" "${INSTALL_DIR}/xray.new"
  mv -f -- "${INSTALL_DIR}/xray.new" "${INSTALL_DIR}/xray"
  install -o root -g "$SERVICE_USER" -m 0640 "${INSTALL_STAGE}/generated/config.json" "${CONFIG_FILE}.new"
  mv -f -- "${CONFIG_FILE}.new" "$CONFIG_FILE"
  install -m 0600 "${INSTALL_STAGE}/generated/state.env" "$STATE_FILE"
  install -m 0600 "${INSTALL_STAGE}/generated/hysteria2.txt" "$HY2_SHARE_FILE"
  install -m 0600 "${INSTALL_STAGE}/generated/hysteria2-clash.yaml" "$HY2_CLASH_FILE"
  install -m 0700 "${BASH_SOURCE[0]}" "$COMMAND_FILE"
  systemctl restart "$SERVICE_NAME"
  sleep 2
  check_dual_listeners "$tcp_port" "$port"
  UPDATE_COMPLETED="1"
  echo "Hysteria2 已添加到同一 Xray 服务，原 VLESS 分享链接保持不变。"
  show_proxy
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
  acquire_lock
  local address="" port="$DEFAULT_PORT" sni="$DEFAULT_SNI" version="$DEFAULT_VERSION" assume_yes="0" hy2_port="$DEFAULT_HY2_PORT"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --address) [[ $# -ge 2 ]] || fail "--address 缺少参数。"; address="$2"; shift 2 ;;
      --port) [[ $# -ge 2 ]] || fail "--port 缺少参数。"; port="$2"; shift 2 ;;
      --hy2-port) [[ $# -ge 2 ]] || fail "--hy2-port 缺少参数。"; hy2_port="$2"; shift 2 ;;
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
  validate_hysteria_version "$version"
  validate_port "$hy2_port"
  confirm_reinstall_absent
  confirm_install "$assume_yes" "$address" "$port" "$sni" "$version" "$hy2_port"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip openssl iproute2 python3 util-linux
  check_target "$sni"
  if ss -H -ltn "sport = :${port}" | grep -q .; then
    fail "TCP ${port} 已被其他程序占用。"
  fi

  check_udp_port "$hy2_port"
  INSTALL_STAGE="$(mktemp -d /tmp/simple-reality.XXXXXXXX)"
  download_xray "$INSTALL_STAGE" "$version"
  write_config "$INSTALL_STAGE" "$address" "$port" "$sni" "$version"
  write_hysteria_config "$INSTALL_STAGE" "$address" "$hy2_port" "$sni" "$version"
  write_unit "$INSTALL_STAGE"

  INSTALL_MUTATED="1"
  useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  install -d -m 0755 "$INSTALL_DIR"
  install -d -o root -g "$SERVICE_USER" -m 0750 "$CONFIG_DIR"
  install -m 0755 "${INSTALL_STAGE}/xray" "${INSTALL_DIR}/xray"
  install -o root -g "$SERVICE_USER" -m 0640 "${INSTALL_STAGE}/generated/config.json" "$CONFIG_FILE"
  install -o root -g root -m 0600 "${INSTALL_STAGE}/generated/state.env" "$STATE_FILE"
  install -o root -g root -m 0600 "${INSTALL_STAGE}/generated/vless.txt" "$SHARE_FILE"
  install -m 0600 "${INSTALL_STAGE}/generated/hysteria2.txt" "$HY2_SHARE_FILE"
  install -m 0600 "${INSTALL_STAGE}/generated/hysteria2-clash.yaml" "$HY2_CLASH_FILE"
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
  check_dual_listeners "$port" "$hy2_port"
  INSTALL_COMPLETED="1"

  echo
  echo "安装成功，服务已运行并设置开机启动。"
  show_proxy
  echo
  echo "管理命令：simple-reality status | show | add-hysteria2 | uninstall"
}

uninstall_proxy() {
  require_root
  acquire_lock
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
  if [[ -f "$HY2_SHARE_FILE" ]]; then
    echo
    cat "$HY2_SHARE_FILE"
    echo
    echo "Hysteria2 Clash 节点片段（需合并到客户端配置并加入代理组）："
    cat "$HY2_CLASH_FILE"
  fi
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
    add-hysteria2) add_hysteria2 "$@" ;;
    uninstall) uninstall_proxy "$@" ;;
    show) show_proxy "$@" ;;
    status) status_proxy "$@" ;;
    -h|--help|help|"") usage ;;
    *) usage; fail "未知命令：${command}" ;;
  esac
}

main "$@"
