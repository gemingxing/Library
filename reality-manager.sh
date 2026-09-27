#!/usr/bin/env bash
set -euo pipefail
# 原因：凭据可能含引号等特殊字符；例如：账号中含冒号时 shell 拼接会破坏配置；
# 所以使用 Python 标准库生成配置，避免手工拼接 JSON。
if ! command -v python3 >/dev/null 2>&1; then
  if [[ "$(id -u)" != "0" ]] || ! command -v apt-get >/dev/null 2>&1; then
    echo "需要 root、Debian/Ubuntu 和 Python 3。" >&2
    exit 1
  fi
  apt-get update
  apt-get install -y python3 ca-certificates
fi
export REALITY_MANAGER_SOURCE
REALITY_MANAGER_SOURCE="$(readlink -f -- "${BASH_SOURCE[0]}")"
python3 - "$@" <<'PY_REALITY_MANAGER_EMBEDDED'
#!/usr/bin/env python3
"""无面板 REALITY 管理器：一个直出身份及多个独立住宅出口。"""
import argparse
import base64
import copy
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid
import zipfile

ROOT = Path("/etc/reality-manager")
BINARY = Path("/usr/local/lib/reality-manager/xray")
SERVICE = "reality-manager"
UNIT = Path("/etc/systemd/system/reality-manager.service")
VERSION = "26.9.9"
OLD_PATHS = [
    "/etc/x-ui", "/usr/local/x-ui", "/usr/bin/x-ui", "/usr/local/bin/x-ui",
    "/etc/systemd/system/x-ui.service", "/etc/systemd/system/x-ui.service.d",
    "/usr/lib/systemd/system/x-ui.service", "/etc/default/x-ui", "/etc/sysconfig/x-ui",
]


def run(args, check=True, timeout=40):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError("命令失败：" + str(args[0]) + "（退出码 " + str(result.returncode) + "）")
    return result.stdout.strip()


def ask(label, default=None, secret=False):
    suffix = " [回车保留]" if secret and default else (" [" + str(default) + "]" if default is not None else "")
    if secret:
        value = getpass.getpass(label + suffix + "：")
    else:
        with open("/dev/tty", "w") as tty:
            tty.write(label + suffix + "：")
            tty.flush()
        with open("/dev/tty", "r") as tty:
            value = tty.readline().strip()
    return value if value else (default if default is not None else "")


def host(value):
    if not isinstance(value, str) or not value or len(value) > 253:
        raise ValueError("地址不能为空或过长")
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?", value):
            raise ValueError("请输入不带协议和端口的 IP 或 ASCII 域名")
        if any(not p or len(p) > 63 or p.startswith("-") or p.endswith("-") for p in value.split(".")):
            raise ValueError("域名格式不正确")
        return value


def port(value):
    value = int(value)
    if not 1 <= value <= 65535:
        raise ValueError("端口必须为 1 到 65535")
    return value


def validate(state):
    host(state["address"])
    if ":" in state["address"]:
        raise ValueError("当前版本入口仅支持 IPv4 或指向 IPv4 的域名")
    host(state["sni"])
    port(state["port"])
    if not re.fullmatch(r"\d+\.\d+\.\d+", state["version"]):
        raise ValueError("核心版本格式不正确")
    for key in ("private_key", "public_key"):
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", state[key]):
            raise ValueError("REALITY 密钥格式不正确")
    if not re.fullmatch(r"[0-9a-f]{16}", state["short_id"]):
        raise ValueError("short ID 格式不正确")
    ids, names, uuids = set(), set(), set()
    if state["direct"]["id"] != "direct":
        raise ValueError("直出身份损坏")
    for node in nodes(state):
        node_id, name, uid = node["id"], node["name"], node["uuid"]
        uuid.UUID(uid)
        if not re.fullmatch(r"direct|[0-9a-f]{16}", node_id):
            raise ValueError("节点标识不合法")
        if not isinstance(name, str) or not 1 <= len(name) <= 60 or any(ord(c) < 32 for c in name):
            raise ValueError("节点名称须为 1 到 60 个可打印字符")
        if node_id in ids or name in names or uid in uuids:
            raise ValueError("节点标识、名称和 UUID 必须分别唯一")
        ids.add(node_id)
        names.add(name)
        uuids.add(uid)
        if node_id == "direct":
            continue
        p = node["proxy"]
        if p["type"] not in ("http", "https", "socks5"):
            raise ValueError("仅支持 HTTP、HTTPS 和 SOCKS5")
        host(p["host"])
        port(p["port"])
        if not isinstance(p["udp"], bool) or (p["type"] != "socks5" and p["udp"]):
            raise ValueError("HTTP/HTTPS 出口不支持 UDP")
        if not isinstance(p["username"], str) or not isinstance(p["password"], str):
            raise ValueError("认证信息必须为字符串")
        if bool(p["username"]) != bool(p["password"]):
            raise ValueError("账号密码必须同时填写，或同时留空使用 IP 白名单")
        if p["type"] == "socks5" and max(len(p["username"].encode()), len(p["password"].encode())) > 255:
            raise ValueError("SOCKS5 账号及密码不能超过 255 字节")
        if p["type"] == "https":
            host(p["tls_name"])


def nodes(state):
    return [state["direct"]] + state["residential"]


def identity(node):
    return "node-" + node["id"] + "@reality.invalid"


def outbound(node):
    p = node["proxy"]
    settings = {"address": p["host"], "port": p["port"]}
    if p["username"]:
        settings.update(user=p["username"], **{"pass": p["password"]})
    result = {"tag": "res-" + node["id"], "protocol": "socks" if p["type"] == "socks5" else "http", "settings": settings}
    if p["type"] == "https":
        result["streamSettings"] = {"network": "raw", "security": "tls", "tlsSettings": {"serverName": p["tls_name"], "allowInsecure": False}}
    return result


def configuration(state):
    validate(state)
    rules = []
    for node in state["residential"]:
        if not node["proxy"]["udp"]:
            rules.append({"type": "field", "user": [identity(node)], "network": "udp", "outboundTag": "block"})
        rules.append({"type": "field", "user": [identity(node)], "network": "tcp,udp", "outboundTag": "res-" + node["id"]})
    rules.append({"type": "field", "user": [identity(state["direct"])], "network": "tcp,udp", "outboundTag": "direct"})
    rules.append({"type": "field", "network": "tcp,udp", "outboundTag": "block"})
    # 原因：未命中的连接默认使用第一个出口；例如：遗漏新用户规则时可能意外直出；
    # 所以默认出口和最终规则均设为阻断，住宅身份只对应自己的出口，不配置故障回退。
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "reality", "listen": "0.0.0.0", "port": state["port"], "protocol": "vless",
            "settings": {"decryption": "none", "clients": [
                {"id": n["uuid"], "email": identity(n), "flow": "xtls-rprx-vision"} for n in nodes(state)]},
            "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
                "show": False, "target": state["sni"] + ":443", "xver": 0,
                "serverNames": [state["sni"]], "privateKey": state["private_key"], "shortIds": [state["short_id"]]}},
            "sniffing": {"enabled": False}
        }],
        "outbounds": [{"tag": "block", "protocol": "blackhole"}, {"tag": "direct", "protocol": "freedom"}] + [outbound(n) for n in state["residential"]],
        "routing": {"domainStrategy": "AsIs", "rules": rules}
    }


def exports(state):
    links, proxies = [], []
    for node in nodes(state):
        params = {"encryption": "none", "flow": "xtls-rprx-vision", "security": "reality", "sni": state["sni"],
                  "fp": "chrome", "pbk": state["public_key"], "sid": state["short_id"], "spx": "/", "type": "tcp"}
        links.append("vless://" + node["uuid"] + "@" + state["address"] + ":" + str(state["port"]) + "?" +
                     urllib.parse.urlencode(params) + "#" + urllib.parse.quote(node["name"]))
        # 原因：出口能力会变化而客户端身份应保持稳定；例如：将 HTTP 改为 SOCKS5；
        # 所以客户端统一允许发送 UDP，能否转发由 VPS 上的节点规则决定。
        proxies.append({"name": node["name"], "type": "vless", "server": state["address"], "port": state["port"],
                        "uuid": node["uuid"], "network": "tcp", "udp": True, "tls": True, "flow": "xtls-rprx-vision",
                        "servername": state["sni"], "client-fingerprint": "chrome",
                        "reality-opts": {"public-key": state["public_key"], "short-id": state["short_id"], "support-x25519mlkem768": True}})
    return "\n".join(links) + "\n", "proxies:\n" + "".join("  - " + json.dumps(p, ensure_ascii=False) + "\n" for p in proxies)


def client_config(state, node, local_port, address=None):
    return {"log": {"loglevel": "warning"}, "inbounds": [{"listen": "127.0.0.1", "port": local_port, "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
            "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": address or state["address"], "port": state["port"],
                "users": [{"id": node["uuid"], "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
                "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
                    "serverName": state["sni"], "fingerprint": "chrome", "password": state["public_key"], "shortId": state["short_id"], "spiderX": "/"}}}]}


def probe(binary, out=None, state=None, node=None):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        local_port = sock.getsockname()[1]
    cfg = client_config(state, node, local_port, "127.0.0.1") if state else {
        "log": {"loglevel": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": local_port, "protocol": "socks", "settings": {"auth": "noauth"}}],
        "outbounds": [out]}
    with tempfile.TemporaryDirectory(prefix="reality-probe-") as directory:
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(cfg), encoding="utf-8")
        path.chmod(0o600)
        process = subprocess.Popen([str(binary), "run", "-config", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.7)
            if process.poll() is not None:
                raise RuntimeError("探测核心无法启动")
            for url in ("https://api.ipify.org", "https://checkip.amazonaws.com"):
                result = subprocess.run(["curl", "-q", "--silent", "--fail", "--noproxy", "", "--proxy", "socks5h://127.0.0.1:" + str(local_port),
                                         "--connect-timeout", "7", "--max-time", "15", url], capture_output=True, text=True, timeout=18)
                if result.returncode == 0:
                    try:
                        return str(ipaddress.ip_address(result.stdout.strip()))
                    except ValueError:
                        pass
            raise RuntimeError("出口探测失败：请检查代理协议、地址、认证和网络")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()



def probe_udp(proxy, timeout=5):
    """检测上游 UDP：返回 supported、unsupported 或 unverified 及不含凭据的原因。
    使用同一 SOCKS5 控制连接发送 UDP ASSOCIATE，再通过其返回的中继查询公共 DNS。
    仅有效 DNS 响应代表本次验证成功；超时可能是网络或目的端限制，不能断言协议不支持。
    """
    if proxy["type"] != "socks5":
        return "unsupported", "HTTP/HTTPS 出口不支持本脚本的 UDP 转发"
    try:
        with socket.create_connection((proxy["host"], proxy["port"]), timeout) as control:
            deadline = time.monotonic() + timeout

            def receive(count):
                data = b""
                while len(data) < count:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError()
                    control.settimeout(remaining)
                    chunk = control.recv(count - len(data))
                    if not chunk:
                        raise OSError("控制连接提前关闭")
                    data += chunk
                return data

            method = 2 if proxy["username"] else 0
            control.settimeout(timeout)
            control.sendall(bytes([5, 1, method]))
            if receive(2) != bytes([5, method]):
                return "unverified", "SOCKS5 认证方式协商失败"
            if method == 2:
                user, password = proxy["username"].encode(), proxy["password"].encode()
                if not 1 <= len(user) <= 255 or not 1 <= len(password) <= 255:
                    return "unverified", "SOCKS5 凭据长度不合法"
                control.sendall(bytes([1, len(user)]) + user + bytes([len(password)]) + password)
                if receive(2) != b"\x01\x00":
                    return "unverified", "SOCKS5 账号认证失败"
            control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
            reply = receive(4)
            if reply[0] != 5 or reply[2] != 0:
                return "unverified", "SOCKS5 响应格式错误"
            if reply[1] == 7:
                return "unsupported", "上游返回 0x07：不支持 UDP ASSOCIATE"
            if reply[1] != 0:
                return "unverified", "UDP ASSOCIATE 被拒绝，返回码 0x%02x" % reply[1]
            if reply[3] == 1:
                relay = socket.inet_ntop(socket.AF_INET, receive(4))
            elif reply[3] == 4:
                relay = socket.inet_ntop(socket.AF_INET6, receive(16))
            elif reply[3] == 3:
                relay = receive(receive(1)[0]).decode("ascii")
            else:
                return "unverified", "UDP 中继地址格式不支持"
            relay_port = struct.unpack("!H", receive(2))[0]
            if relay in ("0.0.0.0", "::"):
                relay = control.getpeername()[0]
            if not relay_port:
                return "unverified", "上游返回无效 UDP 中继端口"
            addresses = socket.getaddrinfo(relay, relay_port, type=socket.SOCK_DGRAM)
            if not addresses:
                return "unverified", "UDP 中继地址无法解析"
            family, kind, protocol, _, endpoint = addresses[0]
            # 原因：握手成功不等于数据能通过，也不能让探测流量绕过代理；
            # 例如：上游接受 UDP ASSOCIATE，但其防火墙丢弃所有 UDP；
            # 所以 UDP socket 只连接上游中继，必须收到匹配请求的有效 DNS 应答才开启。
            with socket.socket(family, kind, protocol) as udp:
                udp.connect(endpoint)
                question = b"\x07example\x03com\x00\x00\x01\x00\x01"
                for resolver in ("1.1.1.1", "8.8.8.8"):
                    query_id = secrets.token_bytes(2)
                    query = query_id + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + question
                    header = b"\x00\x00\x00\x01" + socket.inet_aton(resolver) + struct.pack("!H", 53)
                    udp.send(header + query)
                    limit = time.monotonic() + timeout
                    while time.monotonic() < limit:
                        udp.settimeout(max(0.001, limit - time.monotonic()))
                        try:
                            packet = udp.recv(65535)
                        except (socket.timeout, ConnectionRefusedError):
                            break
                        if packet[:10] != header:
                            continue
                        dns = packet[10:]
                        if len(dns) < 12 + len(question) + 12:
                            continue
                        flags, qd, answers = struct.unpack("!HHH", dns[2:8])
                        if (dns[:2] == query_id and flags & 0x8000 and not flags & 0x7a0f
                                and qd == 1 and answers > 0 and dns[12:12 + len(question)] == question):
                            return "supported", "经住宅中继收到 " + resolver + " 的有效 UDP DNS 应答"
                return "unverified", "已建立 UDP ASSOCIATE，但两个探测目标均未返回有效应答"
    except (OSError, ValueError, UnicodeError, struct.error):
        return "unverified", "UDP 检测遇到连接、超时或协议错误"


def configure_udp(node):
    status, reason = probe_udp(node["proxy"])
    node["proxy"]["udp"] = status == "supported"
    print(node["name"] + "：UDP " + ("已验证可用，将开启" if status == "supported" else "保持阻断") + "；" + reason)
    return status


def safe_remove(path):
    path = Path(path)
    allowed = str(path) in OLD_PATHS or (path.parent == ROOT and re.fullmatch(r"gen-[0-9a-f]{32}", path.name))
    if not allowed or path.parent.resolve() != path.parent:
        raise RuntimeError("拒绝删除非预期路径")
    # 原因：符号链接和挂载点可能指向其他数据；例如：/etc/x-ui 被挂到另一块数据盘；
    # 所以只移除链接本身，遇到挂载点则停止，不跟随链接清除外部目录。
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        for parent, dirs, _ in os.walk(path, followlinks=False):
            if os.path.ismount(parent) or any(os.path.ismount(Path(parent) / d) for d in dirs):
                raise RuntimeError("清理目录含挂载点，请人工检查")
        shutil.rmtree(path)


def load_state():
    path = ROOT / "current"
    if not path.is_symlink() or path.resolve().parent != ROOT or not re.fullmatch(r"gen-[0-9a-f]{32}", path.resolve().name):
        raise RuntimeError("未找到有效安装，请先执行 deploy")
    state = json.loads((path / "state.json").read_text(encoding="utf-8"))
    validate(state)
    return state


def prepare(state, binary):
    import grp
    gid = grp.getgrnam(SERVICE).gr_gid
    ROOT.mkdir(mode=0o750, exist_ok=True)
    if ROOT.is_symlink():
        raise RuntimeError("配置根目录不能是符号链接")
    os.chmod(ROOT, 0o750)
    os.chown(ROOT, 0, gid)
    stage = ROOT / ("gen-" + uuid.uuid4().hex)
    stage.mkdir(mode=0o750)
    stage.chmod(0o750)
    os.chown(stage, 0, gid)
    try:
        links, yaml = exports(state)
        files = {"state.json": json.dumps(state, ensure_ascii=False, indent=2), "config.json": json.dumps(configuration(state), ensure_ascii=False, indent=2),
                 "links.txt": links, "clash-proxies.yaml": yaml}
        for name, content in files.items():
            path = stage / name
            path.write_text(content + "\n", encoding="utf-8")
            path.chmod(0o640 if name == "config.json" else 0o600)
            os.chown(path, 0, gid if name == "config.json" else 0)
        run([binary, "run", "-test", "-config", stage / "config.json"])
        return stage
    except Exception:
        safe_remove(stage)
        raise


def switch(stage):
    pending = ROOT / "current.new"
    if pending.exists() or pending.is_symlink():
        pending.unlink()
    pending.symlink_to(stage.name)
    os.replace(pending, ROOT / "current")


def apply(state, binary=BINARY):
    stage = prepare(state, binary)
    old = (ROOT / "current").resolve() if (ROOT / "current").is_symlink() else None
    try:
        switch(stage)
        run(["systemctl", "restart", SERVICE])
        time.sleep(1)
        if run(["systemctl", "is-active", SERVICE], check=False) != "active":
            raise RuntimeError("新配置启动失败")
    except Exception:
        # 原因：直接覆盖多个文件会造成配置和导出链接不一致；例如：写入一半时重启失败；
        # 所以通过同一目录切换全部文件，日常修改失败时恢复上一次有效配置。
        if old:
            switch(old)
            run(["systemctl", "restart", SERVICE], check=False)
            safe_remove(stage)
        raise
    if old and old != stage:
        safe_remove(old)


def proxy_input(existing=None):
    old = existing or {}
    kind = ask("住宅协议：socks5 / http / https", old.get("type", "socks5")).lower()
    if kind not in ("socks5", "http", "https"):
        raise ValueError("协议不支持")
    result = {"type": kind, "host": host(ask("住宅代理主机", old.get("host"))),
              "port": port(ask("住宅代理端口", old.get("port"))), "udp": False}
    auth = ask("认证：1=账号密码，2=IP 白名单", "1" if old.get("username", True) else "2")
    if auth not in ("1", "2"):
        raise ValueError("认证方式只能选 1 或 2")
    result["username"] = ask("代理账号", old.get("username")) if auth == "1" else ""
    result["password"] = ask("代理密码", old.get("password"), secret=True) if auth == "1" else ""
    if kind == "https":
        result["tls_name"] = host(ask("HTTPS 证书域名", old.get("tls_name", result["host"])))
    return result


def next_residential_name(state):
    used = {node["name"] for node in nodes(state)}
    index = 1
    while "VPS-ip" + str(index) in used:
        index += 1
    return "VPS-ip" + str(index)


def new_node(name, proxy=None):
    result = {"id": secrets.token_hex(8) if proxy else "direct", "name": name, "uuid": str(uuid.uuid4())}
    if proxy:
        result["proxy"] = proxy
    return result


def select_node(state):
    if not state["residential"]:
        raise ValueError("尚无住宅节点")
    for index, node in enumerate(state["residential"], 1):
        print(str(index) + ". " + node["name"])
    selected = int(ask("选择住宅节点编号")) - 1
    if not 0 <= selected < len(state["residential"]):
        raise ValueError("编号不存在")
    return selected


def fetch_binary(directory, version):
    machine = platform.machine()
    archive = {"x86_64": "Xray-linux-64.zip", "aarch64": "Xray-linux-arm64-v8a.zip"}.get(machine)
    if not archive:
        raise RuntimeError("仅支持 Linux amd64 / arm64")
    url = "https://github.com/XTLS/Xray-core/releases/download/v" + version + "/" + archive
    def download(address, limit):
        with urllib.request.urlopen(address, timeout=45) as response:
            data = response.read(limit + 1)
        if len(data) > limit:
            raise RuntimeError("下载文件超出限制")
        return data
    data = download(url, 150 * 1024 * 1024)
    digest = download(url + ".dgst", 16384).decode()
    expected = re.search(r"(?:SHA2?-?256|SHA256)[^\r\n=]*=\s*([a-fA-F0-9]{64})", digest, re.I)
    if not expected or hashlib.sha256(data).hexdigest() != expected.group(1).lower():
        raise RuntimeError("官方 SHA256 校验失败")
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        if bundle.getinfo("xray").file_size > 200 * 1024 * 1024:
            raise RuntimeError("核心大小异常")
        path = Path(directory) / "xray"
        path.write_bytes(bundle.read("xray"))
    path.chmod(0o755)
    if not run([path, "version"]).startswith("Xray " + version + " "):
        raise RuntimeError("下载的核心版本不匹配")
    return path


def preflight(selected_port):
    if platform.system() != "Linux" or os.geteuid() != 0 or not Path("/run/systemd/system").exists():
        raise RuntimeError("需要 root、Linux 和 systemd")
    os_release = Path("/etc/os-release").read_text()
    if not re.search(r"^ID=(?:\"?)(debian|ubuntu)(?:\"?)$", os_release, re.M):
        raise RuntimeError("当前仅支持 Debian / Ubuntu")
    for p in OLD_PATHS:
        path = Path(p)
        if path.exists() and not path.is_symlink() and path.is_dir():
            for parent, dirs, _ in os.walk(path):
                if os.path.ismount(parent) or any(os.path.ismount(Path(parent) / d) for d in dirs):
                    raise RuntimeError("3x-ui 目录含挂载点，停止自动卸载")
    if ROOT.is_symlink() or BINARY.parent.is_symlink():
        raise RuntimeError("安装目录不能是符号链接")
    unit = run(["systemctl", "cat", "x-ui"], check=False)
    if "ExecStart=" in unit and not re.search(r"^ExecStart=/usr/local/x-ui/x-ui\s*$", unit, re.M):
        raise RuntimeError("检测到自定义 3x-ui 服务，停止自动卸载")
    for env_path in ("/etc/default/x-ui", "/etc/sysconfig/x-ui"):
        if Path(env_path).exists() and re.search(r"XUI_DB|POSTGRES", Path(env_path).read_text(), re.I):
            raise RuntimeError("检测到自定义面板数据库，停止自动卸载")
    if shutil.which("docker"):
        if re.search(r"3x-ui|x-ui", run(["docker", "ps", "-a", "--format", "{{.Image}}"], check=False), re.I):
            raise RuntimeError("检测到容器面板，当前脚本仅卸载标准原生安装")
    if run(["systemctl", "is-active", "xray"], check=False) == "active":
        raise RuntimeError("检测到其他 xray.service，请先处理端口和服务冲突")
    listeners = run(["ss", "-H", "-ltnp", "sport = :" + str(selected_port)])
    for pid in re.findall(r"pid=(\d+)", listeners):
        exe = Path("/proc/" + pid + "/exe").resolve()
        if not str(exe).startswith("/usr/local/x-ui/") and exe != BINARY:
            raise RuntimeError("入口端口被其他服务占用")


def deploy():
    address = host(ask("VPS 公网 IPv4 或域名"))
    selected_port = port(ask("入口 TCP 端口", "443"))
    preflight(selected_port)
    sni = host(ask("REALITY 目标域名", "www.lovelive-anime.jp"))
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2"])
    with socket.create_connection((sni, 443), timeout=10) as sock:
        with context.wrap_socket(sock, server_hostname=sni) as tls:
            if tls.selected_alpn_protocol() != "h2":
                raise RuntimeError("目标未协商 h2，请更换 REALITY 目标")
    run(["apt-get", "update"], timeout=180)
    run(["apt-get", "install", "-y", "ca-certificates", "curl", "unzip", "iproute2"], timeout=180)
    version = ask("Xray 版本", VERSION)
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("版本格式不正确")
    with tempfile.TemporaryDirectory(prefix="reality-install-") as temp:
        binary = fetch_binary(temp, version)
        keys = run([binary, "x25519"])
        private = re.search(r"PrivateKey:\s*(\S+)", keys)
        public = re.search(r"(?:Password \(PublicKey\)|PublicKey|Password):\s*(\S+)", keys)
        if not private or not public:
            raise RuntimeError("无法解析核心生成的密钥")
        state = {"schema": 1, "version": version, "address": address, "port": selected_port, "sni": sni,
                 "private_key": private.group(1), "public_key": public.group(1), "short_id": secrets.token_hex(8),
                 "direct": new_node("VPS-direct"), "residential": []}
        count = int(ask("初次创建多少个住宅节点（之后可添加）", "1"))
        if not 0 <= count <= 100:
            raise ValueError("首次数量范围为 0 到 100")
        for index in range(count):
            name = ask("第 " + str(index + 1) + " 个住宅节点名称", next_residential_name(state))
            node = new_node(name, proxy_input())
            state["residential"].append(node)
            validate(state)
            print("住宅代理探测成功，出口：" + probe(binary, out=outbound(node)))
            configure_udp(node)
        validate(state)
        if not run(["getent", "passwd", SERVICE], check=False):
            run(["useradd", "--system", "--user-group", "--no-create-home", "--shell", "/usr/sbin/nologin", SERVICE])
        stage = prepare(state, binary)
        print("将删除标准 3x-ui 及其全部数据库/配置，不备份；重建所有节点身份，旧链接全部失效。")
        if ask("输入 REINSTALL 执行，其他输入取消") != "REINSTALL":
            safe_remove(stage)
            print("已取消，现有代理服务未更改。")
            return
        run(["systemctl", "disable", "--now", "x-ui"], check=False)
        run(["systemctl", "stop", SERVICE], check=False)
        for path in OLD_PATHS:
            safe_remove(path)
        BINARY.parent.mkdir(parents=True, exist_ok=True)
        BINARY.parent.chmod(0o755)
        shutil.copyfile(binary, BINARY.with_suffix(".new"))
        BINARY.with_suffix(".new").chmod(0o755)
        os.replace(BINARY.with_suffix(".new"), BINARY)
        UNIT.write_text("[Unit]\nDescription=REALITY direct and residential proxy\nAfter=network-online.target\nWants=network-online.target\n\n"
                        "[Service]\nUser=reality-manager\nGroup=reality-manager\n"
                        "ExecStart=/usr/local/lib/reality-manager/xray run -config /etc/reality-manager/current/config.json\n"
                        "Restart=on-failure\nRestartSec=3\nLimitNOFILE=65536\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n"
                        "CapabilityBoundingSet=CAP_NET_BIND_SERVICE\nNoNewPrivileges=true\nPrivateTmp=true\nProtectSystem=strict\nProtectHome=true\nUMask=0077\n\n"
                        "[Install]\nWantedBy=multi-user.target\n", encoding="utf-8")
        UNIT.chmod(0o644)
        run(["systemd-analyze", "verify", UNIT])
        switch(stage)
        for path in ROOT.glob("gen-*"):
            if path != stage:
                safe_remove(path)
        run(["systemctl", "daemon-reload"])
        run(["systemctl", "enable", "--now", SERVICE])
        time.sleep(1)
        if run(["systemctl", "is-active", SERVICE], check=False) != "active":
            raise RuntimeError("安装后服务未启动，请检查 journalctl -u reality-manager")
        source = os.environ.get("REALITY_MANAGER_SOURCE")
        if source:
            target = Path("/usr/local/sbin/reality-manager")
            if Path(source).resolve() != target.resolve():
                shutil.copyfile(source, target)
            target.chmod(0o700)
        print("部署成功。请在云安全组和系统防火墙放行 TCP " + str(selected_port) + "。")
        show_export(state)
        check(state)


def show_export(state):
    print("\n节点分享链接（不是在线订阅）：\n" + exports(state)[0])
    print(exports(state)[1])
    print("导出文件：/etc/reality-manager/current/links.txt 和 clash-proxies.yaml")


def check(state):
    failures = []
    for node in nodes(state):
        try:
            print(node["name"] + " -> " + probe(BINARY, state=state, node=node))
        except RuntimeError:
            failures.append(node["name"])
            print(node["name"] + " -> 探测失败")
    if failures:
        raise RuntimeError("部分节点探测失败；服务配置已保留，请检查对应上游或目标网络")


def execute(command):
    if command == "deploy":
        deploy()
        return
    if command == "status":
        print(run(["systemctl", "status", SERVICE, "--no-pager"], check=False))
        return
    if command == "logs":
        print(run(["journalctl", "-u", SERVICE, "-n", "60", "--no-pager"], check=False))
        return
    state = load_state()
    if command == "export":
        show_export(state)
    elif command == "check":
        check(state)
    elif command == "udp-check":
        previous = [n["proxy"]["udp"] for n in state["residential"]]
        for node in state["residential"]:
            configure_udp(node)
        if previous != [n["proxy"]["udp"] for n in state["residential"]]:
            apply(state)
            print("已应用 UDP 检测结果，分享链接不变。")
        else:
            print("UDP 配置无需变更，服务未重启。")
    elif command == "list":
        for node in nodes(state):
            p = node.get("proxy")
            print(node["name"] + (" -> " + p["type"] + "://" + p["host"] + ":" + str(p["port"]) if p else " -> VPS 直出"))
    elif command == "add":
        node = new_node(ask("新节点名称", next_residential_name(state)), proxy_input())
        state["residential"].append(node)
        validate(state)
        print("出口：" + probe(BINARY, out=outbound(node)))
        configure_udp(node)
        apply(state)
        show_export(state)
    elif command == "edit":
        index = select_node(state)
        state["residential"][index]["proxy"] = proxy_input(state["residential"][index]["proxy"])
        validate(state)
        print("出口：" + probe(BINARY, out=outbound(state["residential"][index])))
        configure_udp(state["residential"][index])
        apply(state)
        print("出口更新成功，所有分享链接保持不变。")
    elif command == "remove":
        index = select_node(state)
        removed = state["residential"].pop(index)
        apply(state)
        print("已删除 " + removed["name"] + "，此节点旧链接失效。")
    else:
        raise ValueError("未知命令")


def main():
    parser = argparse.ArgumentParser(description="无面板 REALITY 管理器；部署会清除旧配置且不备份。")
    parser.add_argument("command", nargs="?", default="menu", choices=["menu", "deploy", "add", "edit", "remove", "export", "list", "check", "status", "logs", "udp-check"])
    args = parser.parse_args()
    if platform.system() != "Linux" or os.geteuid() != 0:
        raise RuntimeError("请在 Linux VPS 上使用 root 运行")
    import fcntl
    os.umask(0o077)
    with open("/run/lock/reality-manager.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("另一个管理进程正在运行")
        if args.command != "menu":
            execute(args.command)
            return
        commands = {"1": "deploy", "2": "add", "3": "edit", "4": "remove", "5": "export",
                    "6": "list", "7": "check", "8": "status", "9": "logs", "10": "udp-check"}
        while True:
            print("\n1 部署/彻底重装  2 添加住宅  3 修改住宅  4 删除住宅\n5 导出链接/Clash  6 列表  7 出口检查  8 状态  9 日志  10 自动检测 UDP  0 退出")
            choice = ask("选择")
            if choice == "0":
                return
            try:
                execute(commands[choice])
            except (ValueError, RuntimeError, OSError, KeyError, subprocess.SubprocessError) as error:
                print("操作失败：" + (str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.SubprocessError) as error:
        print("错误：" + (str(error) if isinstance(error, (ValueError, RuntimeError)) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print("\n已中断。", file=sys.stderr)
        sys.exit(130)

PY_REALITY_MANAGER_EMBEDDED
