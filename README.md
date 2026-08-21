# XrayProxy — 一键部署 VLESS+REALITY 节点 + 带认证的 HTTP/SOCKS5 代理

一条命令在你的服务器上部署：

1. **VLESS + REALITY 节点**（443，用于 FlClash / v2rayN 科学上网，抗封锁）
2. **HTTP 代理**（默认 20080，**带用户名密码认证**，用于 Switch/PS5/Xbox 等主机设置代理）
3. **SOCKS5 代理**（默认 20081，带认证，支持 UDP）

> 典型场景：Nintendo Switch 走代理加速 eShop 下载/联机（填服务器地址+端口+账号密码即可，主机不用装任何客户端）。

## 一键安装

**海外服务器：**

```bash
bash <(curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)
```

**大陆服务器（GitHub 不可达时走镜像）：**

```bash
bash <(curl -sSL https://ghproxy.net/https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)
```

要求：Ubuntu / Debian / CentOS，root 权限，服务器能访问 GitHub（或自动走镜像）。

## 可配置项（环境变量，均有默认值）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `XRAY_PORT` | `443` | VLESS+REALITY 端口 |
| `HTTP_PORT` | `20080` | HTTP 代理端口 |
| `SOCKS_PORT` | `20081` | SOCKS5 代理端口 |
| `PROXY_USER` | `switch` | 代理用户名 |
| `PROXY_PASS` | 必填/交互输入 | 代理密码，**出于安全性必须显式设置**（见下） |
| `REALITY_SNI` | 自动挑选 | 伪装 SNI（默认从微软/苹果等候选自动选可用的） |
| `UUID` | 自动生成 | VLESS 客户端 ID |
| `GH_MIRROR` | 自动 | 手动指定 GitHub 镜像前缀 |

## 代理密码怎么设置（安全性要求）

密码**不会**由脚本静默生成，**默认在执行过程中通过交互终端输入**：

**方式一：交互式输入（默认，推荐）**

```bash
bash <(curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)
# 或
curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh | bash
```

脚本执行到密码步骤时，会通过交互终端（`/dev/tty`）提示你输入密码：

- 输入时直接显示（可见输入，方便确认没打错）
- 需要输入两次确认
- **密码不能为空**

因为脚本直接从 `/dev/tty` 读取输入，**`bash <(curl ...)` 和 `curl ... | bash` 两种方式都能交互输入**。

**方式二：环境变量指定（纯自动化场景）**

```bash
PROXY_PASS=你的密码 bash <(curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)
```

> ⚠️ 若脚本无法打开交互终端（如 CI 等无终端环境）且未设置 `PROXY_PASS`，会**拒绝安装**并给出提示——这是有意为之，防止密码被隐式产生。

**示例：**

```bash
PROXY_USER=myuser PROXY_PASS=mypass XRAY_PORT=8443 bash <(curl -sSL https://raw.githubusercontent.com/MokuMMk/splatoonfast/main/xray-proxy.sh)
```

## 安装后你会得到

- FlClash / v2rayN 可直接导入的 `vless://` 链接
- Switch 主机代理配置参数（服务器地址 / 端口 / 用户名 / 密码）
- 完整信息保存在 `/root/xray-proxy-info.txt`

## Switch 配置示例

设置 → 互联网 → 互联网设置 → 你的网络 → 更改设置 → 代理服务器设置 → 手动：

| 项目 | 值 |
|---|---|
| 服务器地址 | 你的服务器 IP |
| 端口 | `20080` |
| 用户名 | `switch`（或你自定义的） |
| 密码 | 脚本输出/你设置的 |

## 常见问题

**Q: 443 端口被占用（比如 nginx）？**
用 `XRAY_PORT=8443` 换端口重跑，或在服务器上释放 443。

**Q: 改代理密码？**
`vim /usr/local/etc/xray/config.json`，改 `http-proxy` 和 `socks-proxy` 两处的 `user`/`pass`，然后 `systemctl restart xray`。

**Q: 想限制代理只给自家 IP 用（更安全）？**
在服务器上把代理端口限制为你的家庭 IP（家庭宽带动态 IP 变了需要更新）：
```bash
# 允许你的 IP 访问代理端口, 其余一律拒绝
iptables -I INPUT -p tcp --dport 20080 -s 你的家庭IP -j ACCEPT
iptables -I INPUT -p tcp --dport 20080 -j DROP
# 20081 (SOCKS5) 同理
```

**Q: 为什么联机对战加速不明显？**
HTTP 代理只转发 TCP 流量；纯 UDP/P2P 的对战数据（如 Splatoon 的对战流）不走代理。加速 UDP 需要路由器/PC 上的 TUN 隧道（Clash/Sing-box），本脚本的 VLESS 节点可作为其服务端。

**Q: 云厂商安全组？**
记得在云控制台放行 `443 / 20080 / 20081`（或你自定义的端口）。

## 技术细节

- 安装方式：优先 XTLS 官方安装脚本，失败自动降级为直接下载官方二进制
- 路由：HTTP/SOCKS 代理入口直连出口（不受 geoip:cn 阻断规则影响）；VLESS 入口保留 bt/私有网段/国内 IP/广告域名阻断
- 幂等：重复执行会备份旧配置（`config.json.bak.<时间戳>`）后覆盖
- 自检：安装完成后自动经代理访问 Google 验证连通性

## 许可证

[MIT License](LICENSE) © 2026 Moku Yui
