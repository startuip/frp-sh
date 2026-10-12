# frp.sh — frp 一键安装与管理脚本

用一个 Bash 脚本在 Linux 上安装、配置和管理 [frp](https://github.com/fatedier/frp) 内网穿透：

- 一键下载安装 **frps**（服务端）和 **frpc**（客户端），自动注册为 systemd 服务并设置开机自启
- 交互式添加、修改、删除穿透规则，支持 **TCP / UDP / HTTP / HTTPS**
- 改规则时 frpc **热重载**，不重启、不断开已有连接；配置校验不通过会**自动回滚**
- 从 GitHub 直连下载，失败时**自动切换加速镜像**，下载后做 SHA256 校验
- 一键升级、卸载，查看服务状态和日志
- 中文交互菜单 + 命令行子命令，可以手动操作，也可以写进自动化脚本

---

## 目录

- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [交互菜单](#交互菜单)
- [命令行用法](#命令行用法)
- [穿透规则示例](#穿透规则示例)
- [文件位置](#文件位置)
- [工作原理](#工作原理)
- [常见问题](#常见问题)

---

## 系统要求

| 项目 | 要求 |
|---|---|
| 系统 | 使用 systemd 的 Linux 发行版（Ubuntu、Debian、CentOS / RHEL、Rocky、Fedora 等） |
| 权限 | root（或 `sudo`） |
| 依赖 | bash ≥ 4、`curl` 或 `wget`、`tar` |
| CPU 架构 | amd64、arm64、armv7、armv5/6、riscv64、loong64、mips / mipsle / mips64 / mips64le |
| frp 版本 | ≥ 0.52.0（脚本使用 TOML 配置格式），默认安装最新版 |

> 不支持没有 systemd 的系统（如 Alpine、OpenWrt），脚本会直接提示并退出。

---

## 快速开始

### 1. 下载脚本

在需要安装的机器上（公网服务器和内网机器都需要）下载最新发布版本：

```bash
curl -fsSL https://github.com/startuip/frp-sh/releases/latest/download/frp.sh -o frp.sh
```

国内服务器访问 GitHub 较慢或失败时，改用加速镜像：

```bash
curl -fsSL https://gh-proxy.com/https://github.com/startuip/frp-sh/releases/latest/download/frp.sh -o frp.sh
```

- 需要固定版本时，把地址中的 `latest/download` 换成 `download/<版本号>`，例如 `download/v1.0.0`；
  所有版本见 [Releases](https://github.com/startuip/frp-sh/releases)
- 没有 curl 时可以用 wget：`wget -O frp.sh <上面的地址>`
- 机器无法访问外网时，可以在别处下载后用 `scp frp.sh root@your-server:/root/` 复制过去

下载后运行 `sudo bash frp.sh` 即可进入交互菜单；也可以按下面的步骤用命令完成安装。

### 2. 在公网服务器上安装 frps

```bash
sudo bash frp.sh install frps
```

不传参数时使用默认值：监听 `7000` 端口，并自动生成随机 token。安装完成后会打印连接信息：

```
============ frps 连接信息 ============
  服务器地址 : 10.0.0.5（云服务器请使用公网 IP）
  监听端口   : 7000
  token      : 3f9a...e21c
  防火墙/安全组需放行: 7000/tcp，以及 tcp/udp 规则使用的远程端口

  在客户端机器上执行以下命令安装 frpc:
    bash frp.sh install frpc --server 10.0.0.5 --port 7000 --token 3f9a...e21c
```

> 云服务器上显示的通常是内网 IP，请替换成公网 IP；并记得在**云厂商安全组**中放行相应端口。

### 3. 在内网机器上安装 frpc

复制上一步打印的命令（把 IP 换成服务器公网 IP）：

```bash
sudo bash frp.sh install frpc --server 1.2.3.4 --port 7000 --token 3f9a...e21c
```

脚本会检查 frpc 是否已成功连接到服务器，并给出提示。

### 4. 添加穿透规则

例如把内网机器的 SSH（22 端口）映射到服务器的 6000 端口：

```bash
sudo bash frp.sh proxy add tcp ssh 22 6000
```

之后就可以通过 `ssh -p 6000 用户名@服务器公网IP` 连接内网机器了。

> 不想记命令的话，直接运行 `sudo bash frp.sh`，在菜单里一步步操作即可。

---

## 交互菜单

```bash
sudo bash frp.sh
```

```
==============================================
          frp 安装管理脚本  v1.0.0
==============================================
  frps 服务端: v0.71.0  运行中 (开机自启)
  frpc 客户端: 未安装

  1. 服务端 frps 管理
  2. 客户端 frpc 管理
  3. 穿透规则管理
  4. 升级 frp
  0. 退出
```

| 菜单 | 包含的操作 |
|---|---|
| 服务端 frps 管理 | 安装 / 重新安装、修改配置（端口、token、域名转发）、启动、停止、重启、查看状态和连接信息、查看日志、卸载 |
| 客户端 frpc 管理 | 安装 / 重新安装、修改服务器连接（地址、端口、token）、启动、停止、重启、查看状态、查看日志、卸载 |
| 穿透规则管理 | 显示当前规则列表；添加、修改、删除规则；查看每条规则的在线状态 |
| 升级 frp | 将已安装的 frps / frpc 升级到最新版或指定版本 |

输入时的约定：

- 方括号里是默认值，例如 `本地服务 IP [127.0.0.1]:`，直接回车即可使用
- 修改配置或规则时，当前值会作为默认值显示，只需修改想改的项
- 对可选项输入 `-` 可以清空当前值（例如取消已设置的域名）
- 选择规则时可以输入序号或规则名称，直接回车取消
- 查看实时日志时按 `Ctrl+C` 返回菜单

---

## 命令行用法

```
frp.sh [命令] [参数]        不带命令时进入交互菜单
```

### 安装 / 维护

| 命令 | 说明 |
|---|---|
| `install frps [--port 7000] [--token T] [--http-port 80] [--https-port 443] [--subdomain-host D]` | 安装服务端 |
| `install frpc --server ADDR [--port 7000] [--token T]` | 安装客户端，`--server` 必填 |
| `upgrade [frps\|frpc\|all]` | 升级到最新版（或 `--version` 指定的版本），默认 `all` |
| `uninstall frps\|frpc [--purge]` | 卸载；`--purge` 同时删除配置文件 |

frps 参数说明：

| 参数 | 对应配置项 | 说明 |
|---|---|---|
| `--port` | `bindPort` | frps 监听端口，默认 7000 |
| `--token` | `auth.token` | 认证令牌，默认随机生成；客户端需填写相同的值 |
| `--http-port` | `vhostHTTPPort` | 传入即启用 HTTP 域名转发（http 类型规则需要） |
| `--https-port` | `vhostHTTPSPort` | 传入即启用 HTTPS 域名转发（https 类型规则需要） |
| `--subdomain-host` | `subDomainHost` | 子域名的根域名，例如 `example.com` |

frpc 参数说明：

| 参数 | 对应配置项 | 说明 |
|---|---|---|
| `--server` | `serverAddr` | frps 服务器的 IP 或域名（必填） |
| `--port` | `serverPort` | frps 端口，默认 7000 |
| `--token` | `auth.token` | 与服务端一致；服务端没设置 token 时可不传 |

### 服务管理

| 命令 | 说明 |
|---|---|
| `start frps\|frpc` | 启动（同时设置开机自启） |
| `stop frps\|frpc` | 停止 |
| `restart frps\|frpc` | 重启 |
| `status frps\|frpc` | 查看服务状态；frps 会同时显示连接信息，frpc 会同时显示各规则状态 |
| `log frps\|frpc [-f]` | 查看最近 100 行日志，`-f` 实时跟踪 |

### 穿透规则（在 frpc 所在机器上执行）

| 命令 | 说明 |
|---|---|
| `proxy list` | 列出所有规则 |
| `proxy status` | 查看每条规则的在线状态（需 frpc 正在运行） |
| `proxy add tcp\|udp NAME LOCAL_PORT REMOTE_PORT [--local-ip IP] [--encrypt] [--compress]` | 添加端口映射规则 |
| `proxy add http\|https NAME LOCAL_PORT (--domain a.com,b.com \| --subdomain web) [--local-ip IP] [--encrypt] [--compress]` | 添加域名转发规则 |
| `proxy del NAME` | 删除规则 |

- `NAME` 只能包含字母、数字、`_` 和 `-`，且不能与已有规则重名
- `--local-ip` 默认为 `127.0.0.1`；要转发局域网内其他设备时填写对应 IP
- `--encrypt` / `--compress` 分别开启传输加密、传输压缩
- 修改规则目前只能在交互菜单中进行；命令行下可以先删除再添加

### 通用选项

| 选项 | 说明 |
|---|---|
| `--version V` | 指定 frp 版本，例如 `--version 0.70.0`（需 ≥ 0.52.0），也可以用来降级 |
| `--mirror URL` | 指定 GitHub 加速镜像前缀，例如 `https://gh-proxy.com/`，优先于直连使用 |
| `-y`, `--yes` | 不提问：使用默认值，并自动确认所有操作 |
| `-h`, `--help`, `help` | 显示帮助 |

参数也可以写成 `--token=xxx` 的形式。

### 环境变量

| 变量 | 说明 |
|---|---|
| `FRP_MIRROR` | 同 `--mirror` |
| `FRP_GITHUB_BASE` | 替换直连地址 `https://github.com`，用于自建的 release 镜像（路径结构需与 GitHub 相同） |

### 非交互模式与退出码

- 在终端中执行子命令时，缺少**必填项**（如 `--server`）会提示输入，可选项直接使用默认值
- 在没有终端的环境中（cron、CI、`ssh host 'cmd'` 等），缺少必填项直接报错退出
- 删除、卸载、重新安装等需要确认的操作，在没有终端的环境中**默认不执行**，需加 `-y`
- 成功时退出码为 `0`；失败或操作未执行时为非 `0`，可在脚本中判断

```bash
# 自动化部署示例
bash frp.sh install frpc -y --server 1.2.3.4 --token "$FRP_TOKEN" || exit 1
bash frp.sh proxy add tcp ssh 22 6000 || exit 1
```

---

## 穿透规则示例

### SSH（TCP）

```bash
frp.sh proxy add tcp ssh 22 6000
# 访问: ssh -p 6000 user@服务器IP
```

### 远程桌面 RDP，转发局域网内另一台 Windows（TCP）

```bash
frp.sh proxy add tcp rdp 3389 13389 --local-ip 192.168.1.100
# 访问: 远程桌面连接 服务器IP:13389
```

### DNS / 游戏服务器（UDP）

```bash
frp.sh proxy add udp dns 53 6053
```

TCP 和 UDP 规则可以使用相同的远程端口，同类型的规则之间不能重复。

### 网站：自定义域名（HTTP）

前提：

1. frps 安装时启用了 HTTP 域名转发，例如 `install frps --http-port 80`
2. 域名已经解析（A 记录）到 frps 服务器的公网 IP

```bash
frp.sh proxy add http blog 8080 --domain blog.example.com
# 多个域名用逗号分隔，支持通配符
frp.sh proxy add http shop 8081 --domain 'shop.example.com,*.shop.example.com'
# 访问: http://blog.example.com
```

> 如果 `vhostHTTPPort` 不是 80，访问时需要带上该端口，例如 `vhostHTTPPort` 为 8000 时访问 `http://blog.example.com:8000`。

### 网站：子域名（HTTP）

服务端设置根域名后，客户端只需要填写前缀，适合规则较多的情况：

```bash
# 服务端
frp.sh install frps --http-port 80 --subdomain-host example.com
# 客户端
frp.sh proxy add http blog 8080 --subdomain blog
# 访问: http://blog.example.com（需要将 *.example.com 泛解析到服务器）
```

### HTTPS 网站

```bash
frp.sh proxy add https web 443 --domain www.example.com
```

https 类型按 SNI 将 TLS 流量**原样透传**到本地服务，证书由本地服务自己提供；frps 需要启用 `--https-port`。

---

## 文件位置

| 用途 | 路径 |
|---|---|
| 程序 | `/usr/local/bin/frps`、`/usr/local/bin/frpc` |
| 服务端配置 | `/etc/frp/frps.toml` |
| 客户端主配置 | `/etc/frp/frpc.toml`（服务器连接信息） |
| 穿透规则 | `/etc/frp/proxies.d/<规则名>.toml`，每条规则一个文件 |
| 配置备份 | `/etc/frp/frps.toml.bak`、`/etc/frp/frpc.toml.bak`（修改配置前自动生成） |
| systemd 服务 | `/etc/systemd/system/frps.service`、`/etc/systemd/system/frpc.service` |
| 日志 | systemd journal，`journalctl -u frps` / `journalctl -u frpc` |

配置文件权限为 `600`（其中包含 token），只有 root 可读。

生成的规则文件示例（`/etc/frp/proxies.d/blog.toml`）：

```toml
[[proxies]]
name = "blog"
type = "http"
localIP = "127.0.0.1"
localPort = 8080
customDomains = ["blog.example.com"]
```

---

## 工作原理

**一条规则一个文件。** frpc 主配置中通过
`includes = ["/etc/frp/proxies.d/*.toml"]` 引入规则目录。添加、修改、删除规则就是写入或删除对应的文件，
不需要修改主配置。

**热重载。** frpc 主配置开启了只监听本机的管理接口（`127.0.0.1:7400`，账号密码随机生成）。
规则变更后脚本执行 `systemctl reload frpc`（即 `frpc reload`），新规则立即生效，frpc 进程不重启，已有连接不中断。
这个接口同时用于 `proxy status` 查询规则在线状态。

**校验与回滚。** 每次写入规则后都会运行 `frpc verify` 检查完整配置；校验不通过时自动恢复原文件，并显示 frp 给出的错误信息。

**下载顺序。** 依次尝试：`--mirror` / `FRP_MIRROR` 指定的镜像 → GitHub 直连 → 内置镜像
（`gh-proxy.com`、`ghfast.top`、`ghproxy.net`）。连接超时、下载速度长时间过低、文件损坏或 SHA256 校验失败时，都会切换到下一个下载源。

**重新安装时保留配置。** 已有配置时，菜单中会询问是否重新配置（默认保留）；命令行下只有传入了配置参数
（如 `--token`、`--server`）才会重写配置。

---

## 常见问题

### GitHub 下载很慢或失败

脚本会自动切换内置镜像。如果内置镜像都不可用，可以指定一个可用的镜像：

```bash
bash frp.sh install frpc --mirror https://你的镜像/ --server 1.2.3.4 --token xxx
```

如果连获取最新版本号都失败（GitHub API 无法访问），脚本会请你手动输入版本号，或在命令行使用 `--version 0.71.0`。

### frpc 提示「暂未连接到 frps」

按以下顺序排查：

1. `frp.sh log frpc` 查看具体错误
2. 服务器地址、端口是否正确：`frp.sh status frpc`
3. token 是否与服务端一致（服务端在 `frp.sh status frps` 中查看）
4. 服务器防火墙和云厂商安全组是否放行了 frps 端口（默认 7000/tcp）

修改连接信息：菜单「客户端 frpc 管理 → 修改服务器连接」。

### 规则添加成功但无法访问

1. `frp.sh proxy status` 查看规则状态和 Error 列，例如：
   - `port already used`：服务器上该远程端口已被占用，换一个端口
   - `subdomain is not supported`：服务端未设置 `subDomainHost`
2. 服务器防火墙 / 安全组是否放行了该远程端口
3. 本地服务是否正在运行：在 frpc 所在机器上执行 `curl 127.0.0.1:本地端口` 测试
4. http/https 规则：服务端是否启用了对应的域名转发端口，域名是否解析到服务器 IP

### 可以手动编辑配置文件吗？

可以，但需要注意：

- 脚本按「一行一个键」的格式读取配置；手动编辑时请保持这个格式，否则菜单中显示的默认值可能不准确
- 通过菜单「修改配置」会**重新生成**整个 `frps.toml` / `frpc.toml`，手动添加的其他配置项（例如 Dashboard）会被覆盖；
  原文件会备份为 `.bak`
- 手动修改后执行 `frp.sh restart frps` 或 `frp.sh restart frpc` 生效；规则文件改动可以通过 `systemctl reload frpc` 热重载

### 如何彻底卸载

```bash
frp.sh uninstall frpc --purge
frp.sh uninstall frps --purge
```

不带 `--purge` 时只删除程序和服务，配置保留在 `/etc/frp`，之后重新安装可以直接沿用。
程序已经卸载后，也可以再次执行带 `--purge` 的卸载命令来清理残留配置。

### 同一台机器可以同时安装 frps 和 frpc 吗？

可以，两者互不影响。注意 frpc 的本地管理接口占用 `127.0.0.1:7400`，请避免其他程序使用该端口。
