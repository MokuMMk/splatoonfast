#!/usr/bin/env bash
# ============================================================================
# XrayProxy 一键安装脚本
#   一键部署: VLESS + REALITY (默认443) + HTTP 代理(带认证) + SOCKS5 代理(带认证)
#   适用系统: Ubuntu / Debian / CentOS (需 root)
#
#   用法(海外服务器):
#     bash <(curl -sSL https://raw.githubusercontent.com/<用户名>/<仓库>/main/xray-proxy.sh)
#   用法(大陆服务器, GitHub 走镜像):
#     bash <(curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/<用户名>/<仓库>/main/xray-proxy.sh)
#
#   可选环境变量(均有默认值):
#     XRAY_PORT=443       VLESS+REALITY 端口
#     HTTP_PORT=20080     HTTP 代理端口
#     SOCKS_PORT=20081    SOCKS5 代理端口
#     PROXY_USER=switch   代理用户名
#     PROXY_PASS=         代理密码: 默认在执行过程中通过交互终端输入(隐藏显示, 两次确认, 不能为空);
#                         自动化场景可用环境变量指定
#     REALITY_SNI=自动    伪装 SNI(默认从微软/苹果等候选自动挑选可用的)
#     UUID=自动           VLESS 客户端 ID
#     GH_MIRROR=          手动指定 GitHub 镜像前缀
#
#   示例: PROXY_USER=myuser PROXY_PASS=mypass XRAY_PORT=8443 bash <(curl -sSL ...)
#
#   Copyright (c) 2026 Moku Yui (https://github.com/MokuMMk)
#   License: MIT License (见仓库 LICENSE 文件)
# ============================================================================
set -euo pipefail

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_CYAN='\033[0;36m'; C_NC='\033[0m'
info(){ echo -e "${C_GREEN}[INFO]${C_NC} $*"; }
warn(){ echo -e "${C_YELLOW}[WARN]${C_NC} $*"; }
err(){  echo -e "${C_RED}[ERROR]${C_NC} $*"; }
ok(){   echo -e "${C_CYAN}[OK]${C_NC} $*"; }

# ---------------- 配置 ----------------
XRAY_PORT="${XRAY_PORT:-443}"
HTTP_PORT="${HTTP_PORT:-20080}"
SOCKS_PORT="${SOCKS_PORT:-20081}"
PROXY_USER="${PROXY_USER:-switch}"
PROXY_PASS="${PROXY_PASS:-}"
REALITY_SNI="${REALITY_SNI:-}"
UUID="${UUID:-}"
FLOW="xtls-rprx-vision"
GH_MIRROR="${GH_MIRROR:-}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,22p' "$0"
  exit 0
fi

# ---------------- 前置检查 ----------------
[ "$(id -u)" -eq 0 ] || { err "请以 root 运行 (sudo bash $0)"; exit 1; }
command -v curl    >/dev/null 2>&1 || { err "缺少 curl，请先安装: apt install curl / yum install curl"; exit 1; }
command -v openssl >/dev/null 2>&1 || { err "缺少 openssl，请先安装"; exit 1; }

json_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

install_pkg(){ # 静默安装系统包(失败不阻断)
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$@" >/dev/null 2>&1 || true
  fi
}

# 端口是否被"非 xray"进程占用
port_busy_by_other(){
  ss -tlnp 2>/dev/null | grep -E ":$1 " | grep -vq "xray"
}

# 从候选里挑选服务器可正常访问的 TLS 站点作为 REALITY 伪装
pick_sni(){
  for s in www.microsoft.com www.apple.com www.amazon.com www.cloudflare.com; do
    if curl -skI --max-time 6 "https://$s" >/dev/null 2>&1; then
      echo "$s"; return 0
    fi
  done
  echo "www.microsoft.com"
}

# ---------------- 端口冲突检查 ----------------
for p in "$XRAY_PORT" "$HTTP_PORT" "$SOCKS_PORT"; do
  if port_busy_by_other "$p"; then
    err "端口 $p 已被其他程序占用。可用环境变量换端口: XRAY_PORT= / HTTP_PORT= / SOCKS_PORT="
    exit 1
  fi
done

# ---------------- 安装 Xray ----------------
install_xray(){
  if command -v xray >/dev/null 2>&1 || [ -x /usr/local/bin/xray ]; then
    ok "检测到已安装 Xray: $(/usr/local/bin/xray version 2>/dev/null | head -1 || true)"
    return 0
  fi
  if [ -z "$GH_MIRROR" ] && ! curl -sI --max-time 8 https://github.com >/dev/null 2>&1; then
    warn "GitHub 直连不可达，自动使用镜像 ..."
    GH_MIRROR="https://ghproxy.net/https://github.com"
  fi
  local base="https://github.com"
  [ -n "$GH_MIRROR" ] && base="$GH_MIRROR"
  info "正在安装 Xray ..."
  # 方式一: XTLS 官方安装脚本
  if curl -fsSL --max-time 30 "$base/XTLS/Xray-install/raw/main/install-release.sh" -o /tmp/xray-install-release.sh 2>/dev/null \
     && bash /tmp/xray-install-release.sh install; then
    ok "Xray 安装成功 (官方脚本)"
    return 0
  fi
  warn "官方安装脚本不可用，尝试手动安装 ..."
  # 方式二: 直接下载官方二进制
  local arch
  case "$(uname -m)" in
    x86_64|amd64)       arch="64" ;;
    aarch64|arm64)      arch="arm64-v8a" ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
  command -v unzip >/dev/null 2>&1 || install_pkg unzip
  mkdir -p /usr/local/etc/xray /usr/local/share/xray /var/log/xray /tmp/xray-linux
  curl -fsSL --max-time 120 "$base/XTLS/Xray-core/releases/latest/download/Xray-linux-$arch.zip" -o /tmp/xray.zip
  unzip -oq /tmp/xray.zip -d /tmp/xray-linux
  install -m 755 /tmp/xray-linux/xray /usr/local/bin/xray
  # 路由规则所需的 geoip/geosite 数据(失败则自动降级为无 geo 规则)
  curl -fsSL --max-time 60 "$base/XTLS/Xray-core/releases/latest/download/geoip.dat"   -o /usr/local/share/xray/geoip.dat   || true
  curl -fsSL --max-time 60 "$base/XTLS/Xray-core/releases/latest/download/geosite.dat" -o /usr/local/share/xray/geosite.dat || true
  cat > /etc/systemd/system/xray.service <<SERVICE
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  ok "Xray 安装成功 (手动安装)"
}
install_xray

# ---------------- 代理密码(安全性: 必须显式设置) ----------------
# 默认在执行过程中通过交互终端(/dev/tty)输入, 兼容 bash <(curl -sSL ...) 与 curl ... | bash 两种安装方式;
# 纯自动化环境(无终端)可用环境变量 PROXY_PASS 指定
if [ -n "$PROXY_PASS" ]; then
  ok "使用环境变量 PROXY_PASS 指定的代理密码"
elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
  info "请输入代理密码(输入时不会显示):"
  read -r -s PROXY_PASS < /dev/tty
  echo > /dev/tty
  if [ -z "$PROXY_PASS" ]; then
    err "密码不能为空, 安装中止(安全性要求)"
    exit 1
  fi
  info "请再次输入确认:"
  read -r -s PROXY_PASS_CONFIRM < /dev/tty
  echo > /dev/tty
  if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ]; then
    err "两次输入的密码不一致, 安装中止"
    exit 1
  fi
  ok "密码已确认"
else
  err "无法打开交互终端(/dev/tty), 无法输入密码。请:"
  err "  1) 在真实终端中运行: bash <(curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)"
  err "  2) 或自动化场景设置环境变量: PROXY_PASS=你的密码 bash <(curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)"
  exit 1
fi

# ---------------- 生成密钥与参数 ----------------
[ -n "$UUID" ]      || UUID=$(/usr/local/bin/xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
[ -n "$REALITY_SNI" ] || REALITY_SNI=$(pick_sni)
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | sed -n 's/^PrivateKey: *//p')
PUBLIC_KEY=$(echo "$KEYS" | sed -n 's/^Password (PublicKey): *//p')
SHORT_ID=$(openssl rand -hex 8)

# ---------------- 生成配置 ----------------
RULES='{"ruleTag":"proxy-direct","inboundTag":["http-proxy","socks-proxy"],"outboundTag":"direct"}'
if [ -f /usr/local/share/xray/geoip.dat ]; then
  RULES="$RULES,
    {\"ruleTag\":\"bt\",\"protocol\":[\"bittorrent\"],\"outboundTag\":\"block\"},
    {\"ruleTag\":\"private-ip\",\"ip\":[\"geoip:private\"],\"outboundTag\":\"block\"},
    {\"ruleTag\":\"cn-ip\",\"ip\":[\"geoip:cn\"],\"outboundTag\":\"block\"}"
fi
if [ -f /usr/local/share/xray/geosite.dat ]; then
  RULES="$RULES,
    {\"ruleTag\":\"ad-domain\",\"domain\":[\"geosite:category-ads-all\"],\"outboundTag\":\"block\"}"
fi

mkdir -p /usr/local/etc/xray
if [ -f /usr/local/etc/xray/config.json ]; then
  cp -f /usr/local/etc/xray/config.json "/usr/local/etc/xray/config.json.bak.$(date +%Y%m%d%H%M%S)"
  warn "检测到旧配置，已备份"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
  },
  "routing": {
    "rules": [
      $RULES
    ]
  },
  "inbounds": [
    {
      "tag": "VLESS-Vision-REALITY",
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "vless@xtls.reality",
            "id": "$UUID",
            "flow": "$FLOW",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_SNI:443",
          "xver": 0,
          "serverNames": [
            "$REALITY_SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    },
    {
      "tag": "http-proxy",
      "listen": "0.0.0.0",
      "port": $HTTP_PORT,
      "protocol": "http",
      "settings": {
        "accounts": [
          {
            "user": "$(json_escape "$PROXY_USER")",
            "pass": "$(json_escape "$PROXY_PASS")"
          }
        ]
      }
    },
    {
      "tag": "socks-proxy",
      "listen": "0.0.0.0",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "udp": true,
        "accounts": [
          {
            "user": "$(json_escape "$PROXY_USER")",
            "pass": "$(json_escape "$PROXY_PASS")"
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

# ---------------- 校验并启动 ----------------
if ! /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  err "配置校验失败，请手动检查: /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json"
  exit 1
fi
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable xray  >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if ! systemctl is-active xray >/dev/null 2>&1; then
  err "Xray 启动失败，最近日志:"
  journalctl -u xray -n 20 --no-pager 2>/dev/null || true
  exit 1
fi
ok "Xray 已启动并设为开机自启"

# ---------------- 防火墙放行 ----------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
  ufw allow "$XRAY_PORT/tcp" >/dev/null 2>&1 || true
  ufw allow "$HTTP_PORT/tcp" >/dev/null 2>&1 || true
  ufw allow "$SOCKS_PORT/tcp" >/dev/null 2>&1 || true
  ok "ufw 已放行 $XRAY_PORT / $HTTP_PORT / $SOCKS_PORT"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$XRAY_PORT/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="$HTTP_PORT/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="$SOCKS_PORT/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "firewalld 已放行 $XRAY_PORT / $HTTP_PORT / $SOCKS_PORT"
fi

# ---------------- 获取公网 IP ----------------
IP=""
for u in "https://api.ipify.org" "https://ifconfig.me" "https://ipinfo.io/ip"; do
  IP=$(curl -s4 --max-time 8 "$u" 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
  [ -n "$IP" ] && break
done
if [ -z "$IP" ]; then
  warn "无法自动获取公网 IP，链接中请手动替换 YOUR_SERVER_IP"
  IP="YOUR_SERVER_IP"
fi

# ---------------- 代理自检 ----------------
TEST_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -x "http://$PROXY_USER:$PROXY_PASS@127.0.0.1:$HTTP_PORT" https://www.google.com 2>/dev/null || true)
if [ "$TEST_CODE" = "200" ]; then
  ok "代理自检通过: 经代理访问 Google 返回 200"
else
  warn "代理自检未通过(返回码 $TEST_CODE)。请检查: 云厂商安全组/防火墙是否放行 $HTTP_PORT、$SOCKS_PORT"
fi

# ---------------- 输出信息 ----------------
LINK="vless://$UUID@$IP:$XRAY_PORT?encryption=none&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&flow=$FLOW#$IP-REALITY"

cat > /root/xray-proxy-info.txt <<INFO
========== XrayProxy 安装信息 (生成时间: $(date)) ==========

【1. VLESS+REALITY 节点 (FlClash / v2rayN 导入)】
$LINK

【2. Switch / 游戏主机 代理设置 (带认证)】
  服务器地址: $IP
  端口:       $HTTP_PORT
  用户名:     $PROXY_USER
  密码:       $PROXY_PASS
  (SOCKS5 端口: $SOCKS_PORT，UDP 已开启)

【3. 管理命令】
  重启:  systemctl restart xray
  状态:  systemctl status xray
  日志:  tail -f /var/log/xray/error.log

【4. 修改账号密码】
  vim /usr/local/etc/xray/config.json
  改 http-proxy 和 socks-proxy 两处的 "user"/"pass"，保存后 systemctl restart xray

【5. 提醒】
  - 云厂商安全组需放行 $XRAY_PORT / $HTTP_PORT / $SOCKS_PORT
  - HTTP/SOCKS 代理是明文协议，仅建议用于游戏主机/下载等场景; 科学上网请用 VLESS+REALITY 节点
  - 旧配置备份: /usr/local/etc/xray/config.json.bak.*
INFO

echo
echo -e "${C_GREEN}================ 部署完成 ================${C_NC}"
echo -e "${C_CYAN}VLESS+REALITY 节点 (FlClash/v2rayN 导入):${C_NC}"
echo "  $LINK"
echo
echo -e "${C_CYAN}Switch/主机代理设置:${C_NC}"
echo "  服务器地址: $IP"
echo "  端口:       $HTTP_PORT"
echo "  用户名:     $PROXY_USER"
echo "  密码:       $PROXY_PASS"
echo
echo -e "${C_YELLOW}完整信息已保存到 /root/xray-proxy-info.txt${C_NC}"
echo -e "${C_GREEN}==========================================${C_NC}"
exit 0
