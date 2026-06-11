cat > /root/hy2-domain-cert.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){ echo -e "${RED}$1${PLAIN}"; }
green(){ echo -e "${GREEN}$1${PLAIN}"; }
yellow(){ echo -e "${YELLOW}$1${PLAIN}"; }

[[ "${EUID}" -ne 0 ]] && red "请使用 root 用户运行本脚本。" && exit 1

need_cmd(){
  command -v "$1" >/dev/null 2>&1
}

install_deps(){
  green "正在安装依赖..."
  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget ca-certificates openssl iproute2 lsof
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode || true
  elif need_cmd dnf; then
    dnf install -y curl wget ca-certificates openssl iproute lsof
    dnf install -y qrencode || true
  elif need_cmd yum; then
    yum install -y curl wget ca-certificates openssl iproute lsof
    yum install -y qrencode || true
  else
    red "未识别包管理器。建议使用 Debian 11+ / Ubuntu 22.04+。"
    exit 1
  fi
}

random_port(){
  shuf -i 20000-60000 -n 1
}

get_public_ip(){
  local ip=""
  ip=$(curl -fs4m8 https://api.ipify.org || true)
  [[ -z "$ip" ]] && ip=$(curl -fs4m8 https://ifconfig.me || true)
  echo "$ip"
}

yaml_escape(){
  printf "%s" "$1" | sed "s/'/''/g"
}

valid_domain(){
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_email(){
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

check_domain_resolution(){
  local domain="$1"
  local public_ip="$2"
  local resolved_ips=""

  resolved_ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)

  echo
  yellow "当前 VPS 公网 IP：${public_ip}"
  yellow "域名解析结果：${resolved_ips:-未解析到 IPv4}"

  if [[ -z "$resolved_ips" ]]; then
    red "域名没有解析到 IPv4。请先添加 A 记录后再运行脚本。"
    exit 1
  fi

  if ! echo "$resolved_ips" | grep -qw "$public_ip"; then
    yellow "警告：域名当前没有解析到本 VPS IP。"
    yellow "如果 DNS 刚修改，可能需要等待生效。"
    read -rp "是否仍然继续？[y/N]: " yn
    case "$yn" in
      y|Y) ;;
      *) red "已取消。"; exit 1 ;;
    esac
  fi
}

check_ports(){
  local hy_port="$1"

  if ss -lntp 2>/dev/null | grep -Eq '[:.]80[[:space:]]'; then
    red "TCP 80 端口已被占用。ACME HTTP 验证可能失败。"
    echo
    echo "占用情况："
    ss -lntp | grep -E '[:.]80[[:space:]]' || true
    echo
    red "请先停止占用 80 端口的程序，再重新运行脚本。"
    exit 1
  fi

  if ss -lunp 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${hy_port}$"; then
    red "UDP ${hy_port} 端口已被占用，请重新运行脚本换一个端口。"
    exit 1
  fi
}

echo
yellow "======== Hysteria2 域名证书专用安装脚本 ========"
echo

read -rp "请输入你的域名，例如 hy.example.com: " DOMAIN
DOMAIN="${DOMAIN,,}"

if ! valid_domain "$DOMAIN"; then
  red "域名格式不正确。"
  exit 1
fi

read -rp "请输入邮箱，用于申请证书，例如 admin@example.com: " EMAIL
if ! valid_email "$EMAIL"; then
  red "邮箱格式不正确。"
  exit 1
fi

DEFAULT_PORT="$(random_port)"
read -rp "请输入 Hysteria2 UDP 端口 [默认 ${DEFAULT_PORT}]: " PORT
PORT="${PORT:-$DEFAULT_PORT}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  red "端口不合法，必须是 1-65535。"
  exit 1
fi

DEFAULT_PASS="$(openssl rand -hex 8)"
read -rp "请输入连接密码 [默认随机 ${DEFAULT_PASS}]: " PASSWORD
PASSWORD="${PASSWORD:-$DEFAULT_PASS}"

if ! [[ "$PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]]; then
  red "密码只建议使用字母、数字、点、下划线、波浪线、短横线。"
  exit 1
fi

DEFAULT_MASK="https://www.bing.com"
read -rp "请输入伪装网站 [默认 ${DEFAULT_MASK}]: " MASK
MASK="${MASK:-$DEFAULT_MASK}"

PUBLIC_IP="$(get_public_ip)"
if [[ -z "$PUBLIC_IP" ]]; then
  red "无法获取 VPS 公网 IPv4。"
  exit 1
fi

install_deps
check_domain_resolution "$DOMAIN" "$PUBLIC_IP"
check_ports "$PORT"

green "正在安装 / 更新 Hysteria2 官方服务..."
HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)

mkdir -p /etc/hysteria /root/hy2-domain
chmod 700 /root/hy2-domain

if [[ -f /etc/hysteria/config.yaml ]]; then
  BACKUP="/etc/hysteria/config.yaml.bak.$(date +%Y%m%d%H%M%S)"
  cp /etc/hysteria/config.yaml "$BACKUP"
  yellow "已备份旧配置：$BACKUP"
fi

DOMAIN_YAML="$(yaml_escape "$DOMAIN")"
EMAIL_YAML="$(yaml_escape "$EMAIL")"
PASSWORD_YAML="$(yaml_escape "$PASSWORD")"
MASK_YAML="$(yaml_escape "$MASK")"

green "正在写入 /etc/hysteria/config.yaml ..."
cat > /etc/hysteria/config.yaml <<EOF2
listen: :${PORT}

acme:
  domains:
    - ${DOMAIN_YAML}
  email: ${EMAIL_YAML}
  ca: letsencrypt
  listenHost: 0.0.0.0
  type: http
  http:
    altPort: 80

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: '${PASSWORD_YAML}'

masquerade:
  type: proxy
  proxy:
    url: ${MASK_YAML}
    rewriteHost: true
EOF2

green "正在启动 Hysteria2..."
systemctl daemon-reload
systemctl enable hysteria-server.service >/dev/null 2>&1 || true
systemctl restart hysteria-server.service

sleep 8

if ! systemctl is-active --quiet hysteria-server.service; then
  red "Hysteria2 启动失败。请查看日志："
  echo "journalctl --no-pager -e -u hysteria-server.service"
  exit 1
fi

URL="hysteria2://${PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#Hysteria2-domain"

cat > /root/hy2-domain/link.txt <<EOF2
${URL}
EOF2

cat > /root/hy2-domain/info.txt <<EOF2
域名: ${DOMAIN}
端口: ${PORT}
密码: ${PASSWORD}
SNI: ${DOMAIN}
分享链接: ${URL}
配置文件: /etc/hysteria/config.yaml
EOF2

green "安装完成。"
echo
yellow "v2rayN 分享链接："
echo "${URL}"
echo
yellow "已保存到："
echo "/root/hy2-domain/link.txt"
echo "/root/hy2-domain/info.txt"
echo
yellow "重要提醒："
echo "1. v2rayN 导入后，allowInsecure 应该是 false。"
echo "2. 固定证书不需要填写。"
echo "3. 地址和 SNI 都应该是你的域名：${DOMAIN}"
echo "4. VPS 外层如有安全组，需要放行 UDP ${PORT} 和 TCP 80。"
echo

if need_cmd qrencode; then
  yellow "二维码："
  qrencode -t ansiutf8 "${URL}" || true
fi
EOF

chmod +x /root/hy2-domain-cert.sh
bash /root/hy2-domain-cert.sh