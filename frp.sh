#!/usr/bin/env bash
#
# frp.sh —— frp (frps / frpc) 安装与管理脚本
#
#   直接运行进入交互菜单；也可使用子命令非交互调用，详见: frp.sh help
#   frp 项目地址: https://github.com/fatedier/frp
#
set -o pipefail
shopt -s nullglob

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "需要 bash 4.0 或更高版本" >&2
    exit 1
fi

# ================================ 常量 ================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME=${0##*/}
readonly FRP_REPO="fatedier/frp"
readonly GITHUB_BASE=${FRP_GITHUB_BASE:-https://github.com}
readonly GITHUB_API=${FRP_GITHUB_API:-https://api.github.com}
readonly MIN_VERSION="0.52.0" # 从该版本起 frp 支持 TOML 配置

# GitHub 加速镜像（URL 前缀），直连失败时依次尝试
MIRRORS=(https://gh-proxy.com/ https://ghfast.top/ https://ghproxy.net/)

readonly BIN_DIR=/usr/local/bin
readonly CONF_DIR=/etc/frp
readonly PROXY_DIR=$CONF_DIR/proxies.d
readonly UNIT_DIR=/etc/systemd/system
readonly FRPS_CONF=$CONF_DIR/frps.toml
readonly FRPC_CONF=$CONF_DIR/frpc.toml
readonly FRPC_ADMIN_PORT=7400

if [[ -t 1 ]]; then
    RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m'
    GRAY=$'\e[90m' BOLD=$'\e[1m' NC=$'\e[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" GRAY="" BOLD="" NC=""
fi

# ================================ 全局状态 ================================

declare -A OPT=() # 命令行传入的预设值，键为去掉 -- 的选项名
ASSUME_YES=0      # -y：不提问，使用默认值并自动确认
CLI_MODE=1        # 1 = 子命令模式（只询问必填项），0 = 交互菜单
ANS=""            # ask / select_proxy 的返回值
P_TYPE=""         # 正在编辑的穿透规则类型与名称，供校验函数使用
P_NAME=""
TMP_ROOT=""
PKG_DIR=""

# ================================ 工具函数 ================================

info()  { printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()   { error "$*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
hint()  { printf '%s  %s%s\n' "$GRAY" "$*" "$NC"; }

interactive() { [[ -t 0 && $ASSUME_YES != 1 ]]; }
menu_mode()   { [[ $CLI_MODE != 1 ]] && interactive; }
yn()          { if [[ -n $1 ]]; then echo y; else echo n; fi; }

# 创建本次运行的临时目录（不要在 $(...) 中调用，否则 trap 会立即清理）
tmpdir() {
    if [[ -z $TMP_ROOT ]]; then
        TMP_ROOT=$(mktemp -d -t frp-sh.XXXXXX) || die "无法创建临时目录"
        trap 'rm -rf "$TMP_ROOT"' EXIT
    fi
}

# ask <选项名> <提示> <默认值> [校验函数]  → 结果写入 ANS
#   已通过 --<选项名> 传入时直接使用；交互菜单中提示输入；
#   子命令模式下只有默认值不合法（即必填项）时才提示；非交互时使用默认值
ask() {
    local __key=$1 __prompt=$2 __def=$3 __check=${4:-not_empty} __val
    if [[ -n ${OPT[$__key]+x} ]]; then
        __val=${OPT[$__key]}
        "$__check" "$__val" || die "参数 --$__key 的值无效: '$__val'"
    elif interactive && { [[ $CLI_MODE != 1 ]] || ! "$__check" "$__def" 2>/dev/null; }; then
        while :; do
            read -r -p "$__prompt${__def:+ [$__def]}: " __val || die "输入已中断"
            [[ -z $__val ]] && __val=$__def
            [[ $__val == - ]] && __val=""
            "$__check" "$__val" && break
            warn "输入无效，请重新输入"
        done
    else
        __val=$__def
        "$__check" "$__val" 2>/dev/null || die "缺少参数 --$__key（$__prompt）"
    fi
    ANS=$__val
}

# confirm <提示> [默认 y|n]
confirm() {
    local def=${2:-n} a
    if ! interactive; then
        [[ $ASSUME_YES == 1 || $def == y ]] && return 0
        warn "非交互模式下默认不执行：$1（可加 -y 自动确认）"
        return 1
    fi
    while :; do
        if [[ $def == y ]]; then
            read -r -p "$1 [Y/n]: " a || return 1
        else
            read -r -p "$1 [y/N]: " a || return 1
        fi
        case ${a:-$def} in
            [yY] | [yY][eE][sS]) return 0 ;;
            [nN] | [nN][oO]) return 1 ;;
        esac
    done
}

# confirm_opt <选项名> <提示> <默认 y|n>：命令行传了该选项即为“是”，
# 交互菜单中询问，子命令模式下取默认值
confirm_opt() {
    [[ -n ${OPT[$1]+x} ]] && return 0
    if menu_mode; then
        confirm "$2" "$3"
        return
    fi
    [[ $3 == y ]]
}

pause() { read -r -p "按回车键继续..." _ || true; }
clear_screen() { [[ -t 1 ]] && printf '\033[H\033[2J'; }

random_token() {
    if have openssl; then
        openssl rand -hex 16
    else
        tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32
    fi
}

# ------------------------------ 校验函数 ------------------------------

not_empty() { [[ -n $1 ]]; }
is_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
is_label() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
is_domain() { [[ ${#1} -le 253 && $1 =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
is_ipv4() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local n
    for n in "${BASH_REMATCH[@]:1}"; do ((10#$n <= 255)) || return 1; done
}
is_host() { is_ipv4 "$1" || is_domain "$1" || is_label "$1" || [[ $1 =~ ^[0-9A-Fa-f:]+:[0-9A-Fa-f:.]*$ ]]; }
is_token() { [[ -n $1 && $1 != *[[:space:]]* && $1 != *'"'* && $1 != *\\* ]]; }
is_version() { [[ ${1#v} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
is_domain_list() {
    local d items
    IFS=, read -ra items <<<"${1//[[:space:]]/}"
    ((${#items[@]})) || return 1
    for d in "${items[@]}"; do is_domain "$d" || return 1; done
}
is_proxy_type() { [[ $1 =~ ^(tcp|udp|http|https|[1-4])$ ]]; }

opt_token()       { [[ -z $1 ]] || is_token "$1"; }
opt_domain()      { [[ -z $1 ]] || is_domain "$1"; }
opt_version()     { [[ -z $1 ]] || is_version "$1"; }
opt_domain_list() { [[ -z $1 ]] || { is_domain_list "$1" && domains_free "$1"; }; }

is_new_name() {
    is_name "$1" || { warn "名称只能包含字母、数字、下划线和短横线"; return 1; }
    [[ ! -e $PROXY_DIR/$1.toml ]] || { warn "规则 $1 已存在"; return 1; }
}

# 同类型规则之间远程端口不能重复
is_free_remote_port() {
    is_port "$1" || return 1
    local f
    for f in "$PROXY_DIR"/*.toml; do
        [[ $(basename "$f" .toml) == "$P_NAME" ]] && continue
        if [[ $(toml_get type "$f") == "$P_TYPE" && $(toml_get remotePort "$f") == "$1" ]]; then
            warn "远程端口 $1 已被规则 $(basename "$f" .toml) 使用"
            return 1
        fi
    done
}

# 同类型规则之间域名不能重复
domains_free() {
    local f d used items
    IFS=, read -ra items <<<"${1//[[:space:]]/}"
    for f in "$PROXY_DIR"/*.toml; do
        [[ $(basename "$f" .toml) == "$P_NAME" || $(toml_get type "$f") != "$P_TYPE" ]] && continue
        used=",$(toml_list customDomains "$f"),"
        for d in "${items[@]}"; do
            if [[ $used == *",$d,"* ]]; then
                warn "域名 $d 已被规则 $(basename "$f" .toml) 使用"
                return 1
            fi
        done
    done
}

# ------------------------------ TOML 读写 ------------------------------

# toml_get <键> <文件>：读取 “键 = 值” 中的值并去掉引号（仅适用于本脚本生成的文件）
toml_get() {
    [[ -f $2 ]] || return 0
    sed -n "s/^[[:space:]]*${1//./\\.}[[:space:]]*=[[:space:]]*//p" "$2" | head -n1 |
        sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/'
}

# ["a.com", "b.com"] → a.com,b.com
toml_list() { toml_get "$1" "$2" | tr -d '[]" '; }

# a.com,b.com → ["a.com", "b.com"]
toml_arr() {
    local item items out=""
    IFS=, read -ra items <<<"${1//[[:space:]]/}"
    for item in "${items[@]}"; do
        [[ -n $item ]] && out+="${out:+, }\"$item\""
    done
    printf '[%s]' "$out"
}

# write_file <目标> <权限>：从 stdin 读取内容并原子写入
write_file() {
    local tmp="$1.tmp.$$"
    cat >"$tmp" && chmod "$2" "$tmp" && mv -f "$tmp" "$1"
}

# ------------------------------ 环境检查 ------------------------------

need_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行（例如: sudo bash $SCRIPT_NAME）"; }

check_deps() {
    { have systemctl && [[ -d /run/systemd/system ]]; } || die "本脚本需要 systemd 作为服务管理器"
    have curl || have wget || die "需要 curl 或 wget，请先安装"
    have tar || die "需要 tar，请先安装"
}

is_little_endian() { [[ $(printf '\001\000' | od -An -tu2 | tr -d ' ') == 1 ]]; }

detect_arch() {
    local m
    m=$(uname -m)
    case $m in
        x86_64 | amd64) echo amd64 ;;
        aarch64 | arm64) echo arm64 ;;
        armv7* | armv8l) echo arm_hf ;;
        armv5* | armv6* | arm) echo arm ;;
        riscv64) echo riscv64 ;;
        loongarch64) echo loong64 ;;
        mips) if is_little_endian; then echo mipsle; else echo mips; fi ;;
        mips64) if is_little_endian; then echo mips64le; else echo mips64; fi ;;
        *) die "不支持的 CPU 架构: $m" ;;
    esac
}

ver_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$2" ]]; } # $1 >= $2

conf_of() { if [[ $1 == frps ]]; then echo "$FRPS_CONF"; else echo "$FRPC_CONF"; fi; }
is_installed() { [[ -x $BIN_DIR/$1 ]]; }
is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
bin_version() { "$BIN_DIR/$1" -v 2>/dev/null; }

# ================================ 下载 ================================

http_fetch() { # <url> → stdout
    if have curl; then
        curl -fsSL --connect-timeout 8 --max-time 30 "$1"
    else
        wget -qO- --timeout=15 --tries=1 "$1"
    fi
}

http_download() { # <url> <文件>；速度持续过低时视为失败，以便切换下载源
    if have curl; then
        curl -fL --progress-bar --connect-timeout 10 --speed-limit 30720 --speed-time 20 -o "$2" "$1"
    else
        wget -q --show-progress --timeout=20 --tries=2 -O "$2" "$1"
    fi
}

http_location() { # <url> → 重定向目标
    if have curl; then
        curl -fsSI --connect-timeout 8 --max-time 15 "$1"
    else
        wget -S --spider --max-redirect=0 --timeout=15 "$1" 2>&1
    fi | sed -n 's/^[[:space:]]*[Ll]ocation:[[:space:]]*//p' | tr -d '\r' | head -n1
}

get_latest_version() {
    local v loc
    v=$(http_fetch "$GITHUB_API/repos/$FRP_REPO/releases/latest" 2>/dev/null |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)
    if ! is_version "$v"; then
        loc=$(http_location "$GITHUB_BASE/$FRP_REPO/releases/latest")
        v=${loc##*/tag/}
        v=${v#v}
    fi
    if is_version "$v"; then printf '%s' "$v"; fi
}

# 确定要安装的版本 → ANS
resolve_version() {
    local v=${OPT[version]:-}
    if [[ -z $v ]] && menu_mode; then
        ask version "frp 版本号（直接回车使用最新版）" "" opt_version
        v=$ANS
    fi
    if [[ -z $v ]]; then
        info "正在获取 frp 最新版本号..."
        v=$(get_latest_version)
        if [[ -z $v ]]; then
            warn "无法获取最新版本号（可能无法访问 GitHub）"
            interactive || die "请使用 --version 指定版本，例如 --version 0.71.0"
            ask version "请输入要安装的版本号（例如 0.71.0）" "" is_version
            v=$ANS
        fi
    fi
    v=${v#v}
    is_version "$v" || die "版本号格式无效: $v"
    ver_ge "$v" "$MIN_VERSION" || die "本脚本使用 TOML 配置，需要 frp >= $MIN_VERSION"
    ANS=$v
}

# fetch_release <版本>：下载并校验安装包，解压目录写入 PKG_DIR
fetch_release() {
    local ver=$1 arch file rel src url expected m
    arch=$(detect_arch) || exit 1
    file="frp_${ver}_linux_${arch}.tar.gz"
    rel="$FRP_REPO/releases/download/v$ver"
    tmpdir

    local sources=()
    m=${OPT[mirror]:-${FRP_MIRROR:-}}
    [[ -n $m ]] && sources+=("${m%/}/https://github.com")
    sources+=("$GITHUB_BASE")
    for m in "${MIRRORS[@]}"; do
        [[ " ${sources[*]} " == *" ${m%/}/https://github.com "* ]] || sources+=("${m%/}/https://github.com")
    done

    for src in "${sources[@]}"; do
        url="$src/$rel/$file"
        info "下载 $url"
        rm -f "$TMP_ROOT/$file"
        if ! http_download "$url" "$TMP_ROOT/$file"; then
            warn "下载失败，尝试下一个下载源"
            continue
        fi
        if ! tar -tzf "$TMP_ROOT/$file" >/dev/null 2>&1; then
            warn "安装包损坏，尝试下一个下载源"
            continue
        fi
        expected=$(http_fetch "$src/$rel/frp_sha256_checksums.txt" 2>/dev/null | awk -v f="$file" '$2 == f { print $1 }')
        if [[ -z $expected ]] || ! have sha256sum; then
            warn "无法获取校验文件，跳过 SHA256 校验"
        elif [[ $(sha256sum "$TMP_ROOT/$file" | awk '{print $1}') != "$expected" ]]; then
            warn "SHA256 校验失败，尝试下一个下载源"
            continue
        else
            info "SHA256 校验通过"
        fi
        tar -xzf "$TMP_ROOT/$file" -C "$TMP_ROOT" || die "解压失败"
        PKG_DIR="$TMP_ROOT/frp_${ver}_linux_${arch}"
        [[ -x $PKG_DIR/frps && -x $PKG_DIR/frpc ]] || die "安装包内容异常: $file"
        return 0
    done
    die "所有下载源均失败。可使用 --mirror 指定其他 GitHub 加速镜像，或用 --version 指定版本"
}

install_binary() { # frps|frpc
    { install -m 755 "$PKG_DIR/$1" "$BIN_DIR/.$1.new" && mv -f "$BIN_DIR/.$1.new" "$BIN_DIR/$1"; } ||
        die "安装 $BIN_DIR/$1 失败"
    info "已安装 $BIN_DIR/$1 (v$(bin_version "$1"))"
}

# ================================ 配置文件 ================================

configure_frps() {
    local f=$FRPS_CONF cur_port cur_token cur_http cur_https cur_sub
    cur_port=$(toml_get bindPort "$f")
    cur_token=$(toml_get auth.token "$f")
    cur_http=$(toml_get vhostHTTPPort "$f")
    cur_https=$(toml_get vhostHTTPSPort "$f")
    cur_sub=$(toml_get subDomainHost "$f")

    local port token http="" https="" sub=""
    ask port "frps 监听端口 (bindPort)" "${cur_port:-7000}" is_port
    port=$ANS
    ask token "认证令牌 token（客户端需填写相同的值）" "${cur_token:-$(random_token)}" is_token
    token=$ANS
    if confirm_opt http-port "是否启用 HTTP 域名转发（http 类型穿透需要）？" "$(yn "$cur_http")"; then
        ask http-port "HTTP 端口 (vhostHTTPPort)" "${cur_http:-80}" is_port
        http=$ANS
    fi
    if confirm_opt https-port "是否启用 HTTPS 域名转发（https 类型穿透需要）？" "$(yn "$cur_https")"; then
        ask https-port "HTTPS 端口 (vhostHTTPSPort)" "${cur_https:-443}" is_port
        https=$ANS
    fi
    if [[ -n $http$https ]]; then
        ask subdomain-host "子域名的根域名 subDomainHost（可选，输入 - 清空）" "$cur_sub" opt_domain
        sub=$ANS
    fi

    mkdir -p "$CONF_DIR"
    [[ -f $f ]] && cp -p "$f" "$f.bak"
    {
        echo "# 由 $SCRIPT_NAME 生成"
        echo "bindPort = $port"
        echo 'auth.method = "token"'
        echo "auth.token = \"$token\""
        if [[ -n $http ]]; then echo "vhostHTTPPort = $http"; fi
        if [[ -n $https ]]; then echo "vhostHTTPSPort = $https"; fi
        if [[ -n $sub ]]; then echo "subDomainHost = \"$sub\""; fi
    } | write_file "$f" 600 || die "写入 $f 失败"
    info "已写入配置 $f"
}

configure_frpc() {
    local f=$FRPC_CONF cur_server cur_port cur_token cur_pass
    cur_server=$(toml_get serverAddr "$f")
    cur_port=$(toml_get serverPort "$f")
    cur_token=$(toml_get auth.token "$f")
    cur_pass=$(toml_get webServer.password "$f")

    local server port token
    ask server "frps 服务器地址（IP 或域名）" "$cur_server" is_host
    server=$ANS
    ask port "frps 服务器端口 (serverPort)" "${cur_port:-7000}" is_port
    port=$ANS
    ask token "认证令牌 token（与服务端一致，没有则直接回车）" "$cur_token" opt_token
    token=$ANS

    mkdir -p "$CONF_DIR" "$PROXY_DIR"
    [[ -f $f ]] && cp -p "$f" "$f.bak"
    {
        echo "# 由 $SCRIPT_NAME 生成；穿透规则保存在 $PROXY_DIR/ 下，每条规则一个文件"
        echo "serverAddr = \"$server\""
        echo "serverPort = $port"
        if [[ -n $token ]]; then
            echo 'auth.method = "token"'
            echo "auth.token = \"$token\""
        fi
        echo "loginFailExit = false"
        echo
        echo "# 本地管理接口，供 frpc reload / frpc status 使用"
        echo 'webServer.addr = "127.0.0.1"'
        echo "webServer.port = $FRPC_ADMIN_PORT"
        echo 'webServer.user = "admin"'
        echo "webServer.password = \"${cur_pass:-$(random_token)}\""
        echo
        echo "includes = [\"$PROXY_DIR/*.toml\"]"
    } | write_file "$f" 600 || die "写入 $f 失败"
    info "已写入配置 $f"
}

verify_conf() { # frps|frpc
    local out
    if ! out=$("$BIN_DIR/$1" verify -c "$(conf_of "$1")" 2>&1); then
        error "$1 配置校验失败:"
        printf '%s\n' "$out" >&2
        return 1
    fi
}

# 本次运行中命令行是否传入了配置项（用于重装时决定是否重写配置）
has_conf_opts() {
    local k
    for k in port token server http-port https-port subdomain-host; do
        [[ -n ${OPT[$k]+x} ]] && return 0
    done
    return 1
}

# ================================ systemd ================================

write_unit() { # frps|frpc
    local c=$1 desc="frp server" reload=""
    if [[ $c == frpc ]]; then
        desc="frp client"
        reload="ExecReload=$BIN_DIR/frpc reload -c $FRPC_CONF"
    fi
    write_file "$UNIT_DIR/$c.service" 644 <<EOF || die "写入 systemd 服务文件失败"
[Unit]
Description=$desc ($c)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_DIR/$c -c $(conf_of "$c")
$reload
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 设置开机自启并（重新）启动，随后检查是否运行正常
start_service() {
    local c=$1
    systemctl enable "$c" >/dev/null 2>&1
    systemctl restart "$c"
    sleep 2
    if is_active "$c"; then
        info "$c 已启动"
    else
        error "$c 启动失败，最近日志:"
        journalctl -u "$c" -n 20 --no-pager >&2
        return 1
    fi
}

# check_frpc_login <起始时间>：等待 frpc 日志中出现登录成功
check_frpc_login() {
    local i
    for i in 1 2 3 4 5 6; do
        if journalctl -u frpc --since "$1" --no-pager -q 2>/dev/null | grep -q 'login to server success'; then
            info "已成功连接到 frps 服务器"
            return 0
        fi
        sleep 1
    done
    warn "暂未连接到 frps，请检查服务器地址、端口、token 和防火墙；查看日志: $SCRIPT_NAME log frpc"
}

state_line() {
    local c=$1 s
    if ! is_installed "$c"; then
        printf '%s未安装%s' "$GRAY" "$NC"
        return
    fi
    if is_active "$c"; then s="${GREEN}运行中${NC}"; else s="${RED}已停止${NC}"; fi
    if systemctl is-enabled --quiet "$c" 2>/dev/null; then s+=" ${GRAY}(开机自启)${NC}"; fi
    printf 'v%s  %s' "$(bin_version "$c")" "$s"
}

show_log() { # <组件> [follow]
    if [[ ${2:-} == follow ]]; then
        info "实时日志，按 Ctrl+C 退出"
        trap ':' INT
        journalctl -u "$1" -n 50 -f --no-pager
        trap - INT
    else
        journalctl -u "$1" -n 100 --no-pager
    fi
}

service_action() { # start|stop|restart|status|log <组件>
    local a=$1 c=$2
    is_installed "$c" || die "$c 未安装"
    case $a in
        start)
            if is_active "$c"; then info "$c 已在运行"; else start_service "$c"; fi
            ;;
        restart) start_service "$c" ;;
        stop) systemctl stop "$c" && info "$c 已停止" ;;
        status)
            systemctl status "$c" --no-pager -l
            if [[ $c == frps ]]; then
                show_frps_info
            elif is_active frpc; then
                echo
                "$BIN_DIR/frpc" status -c "$FRPC_CONF"
            fi
            ;;
        log) show_log "$c" "$([[ -n ${OPT[follow]+x} ]] && echo follow)" ;;
    esac
}

# ================================ 安装 / 升级 / 卸载 ================================

install_component() { # frps|frpc
    local c=$1 conf ver since
    conf=$(conf_of "$c")
    if is_installed "$c"; then
        confirm "$c 已安装 (v$(bin_version "$c"))，是否重新安装？" n || return 0
    fi
    resolve_version
    ver=$ANS

    # 先完成配置再下载，下载期间无需值守
    local reconf=y
    if [[ -f $conf ]]; then
        if [[ $CLI_MODE == 1 ]]; then
            has_conf_opts || reconf=n
        else
            confirm "检测到已有配置 $conf，是否重新配置？（否则保留原配置）" n || reconf=n
        fi
    fi
    if [[ $reconf == y ]]; then "configure_$c"; else info "保留现有配置 $conf"; fi
    [[ $c == frpc ]] && mkdir -p "$PROXY_DIR"

    fetch_release "$ver"
    install_binary "$c"
    verify_conf "$c" || return 1
    write_unit "$c"
    since=$(date '+%Y-%m-%d %H:%M:%S')
    start_service "$c" || return 1

    if [[ $c == frps ]]; then
        show_frps_info
    else
        check_frpc_login "$since"
        if menu_mode; then
            if confirm "是否现在添加一条穿透规则？" y; then proxy_add; fi
        else
            info "添加穿透规则示例: $SCRIPT_NAME proxy add tcp ssh 22 6000"
        fi
    fi
}

show_frps_info() {
    local f=$FRPS_CONF port token http https sub ip ports
    [[ -f $f ]] || return 0
    port=$(toml_get bindPort "$f")
    token=$(toml_get auth.token "$f")
    http=$(toml_get vhostHTTPPort "$f")
    https=$(toml_get vhostHTTPSPort "$f")
    sub=$(toml_get subDomainHost "$f")
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    ip=${ip:-<服务器IP>}
    ports="$port/tcp"
    [[ -n $http ]] && ports+=", $http/tcp"
    [[ -n $https ]] && ports+=", $https/tcp"

    echo
    printf '%s============ frps 连接信息 ============%s\n' "$CYAN" "$NC"
    printf '  服务器地址 : %s（云服务器请使用公网 IP）\n' "$ip"
    printf '  监听端口   : %s\n' "$port"
    printf '  token      : %s\n' "${token:-（未设置）}"
    if [[ -n $http ]]; then printf '  HTTP 端口  : %s\n' "$http"; fi
    if [[ -n $https ]]; then printf '  HTTPS 端口 : %s\n' "$https"; fi
    if [[ -n $sub ]]; then printf '  子域名根域 : %s\n' "$sub"; fi
    printf '  防火墙/安全组需放行: %s，以及 tcp/udp 规则使用的远程端口\n' "$ports"
    echo
    echo "  在客户端机器上执行以下命令安装 frpc:"
    printf '    bash %s install frpc --server %s --port %s%s\n' "$SCRIPT_NAME" "$ip" "$port" "${token:+ --token $token}"
    echo
}

reconfigure_component() { # frps|frpc
    local c=$1 conf since
    conf=$(conf_of "$c")
    is_installed "$c" || die "$c 未安装"
    "configure_$c"
    if ! verify_conf "$c"; then
        [[ -f $conf.bak ]] && mv -f "$conf.bak" "$conf" && warn "已恢复原配置"
        return 1
    fi
    since=$(date '+%Y-%m-%d %H:%M:%S')
    start_service "$c" || return 1
    if [[ $c == frpc ]]; then check_frpc_login "$since"; else show_frps_info; fi
}

upgrade_component() { # frps|frpc|all
    local which=${1:-all} c ver old comps=() installed=() todo=()
    case $which in
        all) comps=(frps frpc) ;;
        frps | frpc) comps=("$which") ;;
        *) die "未知组件: $which（可选 frps / frpc / all）" ;;
    esac
    for c in "${comps[@]}"; do is_installed "$c" && installed+=("$c"); done
    ((${#installed[@]})) || die "未安装 ${which/all/frps 或 frpc}"

    resolve_version
    ver=$ANS
    for c in "${installed[@]}"; do
        if [[ $(bin_version "$c") == "$ver" ]]; then
            info "$c 已是 v$ver，无需升级"
        else
            todo+=("$c")
        fi
    done
    ((${#todo[@]})) || return 0

    fetch_release "$ver"
    for c in "${todo[@]}"; do
        old=$(bin_version "$c")
        install_binary "$c"
        write_unit "$c"
        if is_active "$c"; then start_service "$c" || return 1; fi
        info "$c: v$old → v$ver"
    done
}

uninstall_component() { # frps|frpc
    local c=$1 conf
    conf=$(conf_of "$c")
    if is_installed "$c" || [[ -f $UNIT_DIR/$c.service ]]; then
        confirm "确认卸载 $c？" n || return 1
        systemctl disable --now "$c" >/dev/null 2>&1
        rm -f "$UNIT_DIR/$c.service" "$BIN_DIR/$c"
        systemctl daemon-reload
        info "已卸载 $c"
    else
        warn "$c 未安装"
        # 程序已卸载但配置仍在时，允许单独清理配置
        [[ -f $conf || ($c == frpc && -d $PROXY_DIR) ]] || return 0
    fi

    local purge=n
    if [[ -n ${OPT[purge]+x} ]]; then
        purge=y
    elif menu_mode && confirm "是否同时删除 $c 的配置文件？" n; then
        purge=y
    fi
    if [[ $purge == y ]]; then
        rm -f "$conf" "$conf.bak"
        [[ $c == frpc ]] && rm -rf "$PROXY_DIR"
        rmdir "$CONF_DIR" 2>/dev/null
        info "已删除 $c 的配置文件"
    else
        info "配置文件已保留在 $CONF_DIR"
    fi
}

# ================================ 穿透规则 ================================

require_frpc() {
    { is_installed frpc && [[ -f $FRPC_CONF ]]; } || die "请先安装 frpc"
    mkdir -p "$PROXY_DIR"
}

proxy_names() {
    local f
    for f in "$PROXY_DIR"/*.toml; do basename "$f" .toml; done
}

proxy_list() {
    require_frpc
    local f name type remote flags files=("$PROXY_DIR"/*.toml)
    if ((${#files[@]} == 0)); then
        info "暂无穿透规则"
        return 0
    fi
    printf '%s  %s%*s  %s%*s  %s%*s  %s%s\n' "$BOLD" 名称 16 "" 类型 2 "" 本地地址 13 "" "远程端口 / 域名" "$NC"
    for f in "${files[@]}"; do
        name=$(basename "$f" .toml)
        type=$(toml_get type "$f")
        case $type in
            tcp | udp) remote=$(toml_get remotePort "$f") ;;
            *)
                remote=$(toml_list customDomains "$f")
                [[ -z $remote ]] && remote="子域名 $(toml_get subdomain "$f")"
                ;;
        esac
        flags=""
        [[ $(toml_get transport.useEncryption "$f") == true ]] && flags+=" [加密]"
        [[ $(toml_get transport.useCompression "$f") == true ]] && flags+=" [压缩]"
        printf '  %-20s  %-6s  %-21s  %s%s%s%s\n' "$name" "$type" \
            "$(toml_get localIP "$f"):$(toml_get localPort "$f")" "$remote" "$GRAY" "$flags" "$NC"
    done
}

# select_proxy <提示> → ANS=规则名称（可输入序号或名称）
select_proxy() {
    local names i a
    mapfile -t names < <(proxy_names)
    if ((${#names[@]} == 0)); then
        info "暂无穿透规则"
        return 1
    fi
    for i in "${!names[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${names[i]}"; done
    while :; do
        read -r -p "$1（序号或名称，直接回车取消）: " a || return 1
        [[ -z $a ]] && return 1
        if [[ $a =~ ^[0-9]+$ ]] && ((a >= 1 && a <= ${#names[@]})); then
            ANS=${names[a - 1]}
            return 0
        fi
        if [[ -f $PROXY_DIR/$a.toml ]]; then
            ANS=$a
            return 0
        fi
        warn "没有这条规则: $a"
    done
}

# commit_proxy <名称> [新文件]：写入（或删除）规则文件，校验失败自动回滚，成功后热重载
commit_proxy() {
    local name=$1 new=${2:-} dst="$PROXY_DIR/$1.toml" bak="" out
    tmpdir
    if [[ -f $dst ]]; then
        bak="$TMP_ROOT/$name.bak"
        cp -p "$dst" "$bak"
    fi
    if [[ -n $new ]]; then install -m 600 "$new" "$dst"; else rm -f "$dst"; fi
    if ! out=$("$BIN_DIR/frpc" verify -c "$FRPC_CONF" 2>&1); then
        if [[ -n $bak ]]; then cp -p "$bak" "$dst"; else rm -f "$dst"; fi
        error "配置校验失败，已回滚:"
        printf '%s\n' "$out" >&2
        return 1
    fi
    reload_frpc
}

reload_frpc() {
    if ! is_active frpc; then
        warn "frpc 未运行，规则将在 frpc 下次启动时生效"
        return 0
    fi
    if systemctl reload frpc >/dev/null 2>&1; then
        info "frpc 已热重载，规则已生效"
    else
        warn "热重载失败，改为重启 frpc"
        start_service frpc
    fi
}

# proxy_wizard [已有规则名]：添加或修改一条规则
proxy_wizard() {
    local edit=${1:-} f="" d_type="" d_lip="" d_lport="" d_rport="" d_domains="" d_sub="" d_enc="" d_comp=""
    if [[ -n $edit ]]; then
        f="$PROXY_DIR/$edit.toml"
        d_type=$(toml_get type "$f")
        d_lip=$(toml_get localIP "$f")
        d_lport=$(toml_get localPort "$f")
        d_rport=$(toml_get remotePort "$f")
        d_domains=$(toml_list customDomains "$f")
        d_sub=$(toml_get subdomain "$f")
        [[ $(toml_get transport.useEncryption "$f") == true ]] && d_enc=y
        [[ $(toml_get transport.useCompression "$f") == true ]] && d_comp=y
    fi

    local type name lip lport rport="" domains="" sub="" enc=n comp=n
    if menu_mode; then hint "类型: 1) tcp  2) udp  3) http  4) https"; fi
    ask type "穿透类型" "${d_type:-tcp}" is_proxy_type
    case $ANS in 1) type=tcp ;; 2) type=udp ;; 3) type=http ;; 4) type=https ;; *) type=$ANS ;; esac
    P_TYPE=$type

    if [[ -n $edit ]]; then
        name=$edit
    else
        ask name "规则名称（字母、数字、_、-）" "" is_new_name
        name=$ANS
    fi
    P_NAME=$name

    ask local-ip "本地服务 IP" "${d_lip:-127.0.0.1}" is_host
    lip=$ANS
    ask local-port "本地服务端口" "$d_lport" is_port
    lport=$ANS

    case $type in
        tcp | udp)
            ask remote-port "服务器上开放的远程端口 (remotePort)" "$d_rport" is_free_remote_port
            rport=$ANS
            ;;
        http | https)
            if menu_mode; then
                hint "需要 frps 已启用 $type 域名转发，并将域名解析到 frps 服务器"
                [[ $type == https ]] && hint "https 类型按 SNI 透传 TLS，本地服务需自行提供 HTTPS"
            fi
            ask domain "自定义域名，多个用逗号分隔（留空则改用子域名，输入 - 清空）" "$d_domains" opt_domain_list
            domains=${ANS//[[:space:]]/}
            if [[ -z $domains ]]; then
                ask subdomain "子域名（需 frps 设置 subDomainHost）" "$d_sub" is_label
                sub=$ANS
            fi
            ;;
    esac

    confirm_opt encrypt "是否启用传输加密 (useEncryption)？" "${d_enc:-n}" && enc=y
    confirm_opt compress "是否启用传输压缩 (useCompression)？" "${d_comp:-n}" && comp=y

    tmpdir
    {
        echo "[[proxies]]"
        echo "name = \"$name\""
        echo "type = \"$type\""
        echo "localIP = \"$lip\""
        echo "localPort = $lport"
        if [[ -n $rport ]]; then echo "remotePort = $rport"; fi
        if [[ -n $domains ]]; then echo "customDomains = $(toml_arr "$domains")"; fi
        if [[ -n $sub ]]; then echo "subdomain = \"$sub\""; fi
        if [[ $enc == y ]]; then echo "transport.useEncryption = true"; fi
        if [[ $comp == y ]]; then echo "transport.useCompression = true"; fi
    } >"$TMP_ROOT/$name.toml"

    commit_proxy "$name" "$TMP_ROOT/$name.toml" || return 1
    if [[ -n $edit ]]; then info "已修改规则 $name"; else info "已添加规则 $name"; fi
    case $type in
        tcp | udp) info "访问方式: <frps 服务器 IP>:$rport ($type)" ;;
        *)
            local host=${domains%%,*}
            [[ $domains == *,* ]] && host+=" 等"
            info "访问方式: $type://${host:-$sub.<subDomainHost>}（使用 frps 的 vhost${type^^}Port 端口）"
            ;;
    esac
}

proxy_add() {
    require_frpc
    proxy_wizard
}

proxy_edit() {
    require_frpc
    select_proxy "要修改的规则" || return 0
    proxy_wizard "$ANS"
}

proxy_del() {
    require_frpc
    local name
    if [[ -n ${OPT[name]:-} ]]; then
        name=${OPT[name]}
        [[ -f $PROXY_DIR/$name.toml ]] || die "规则 $name 不存在"
    else
        select_proxy "要删除的规则" || return 0
        name=$ANS
    fi
    confirm "确认删除规则 $name？" n || return 1
    commit_proxy "$name" && info "已删除规则 $name"
}

proxy_status() {
    require_frpc
    is_active frpc || die "frpc 未运行"
    "$BIN_DIR/frpc" status -c "$FRPC_CONF"
}

# ================================ 交互菜单 ================================

# 在子 shell 中执行菜单项，die 只会中止当前操作而不会退出菜单
run() {
    ("$@")
    pause
}

banner() {
    clear_screen
    printf '%s==============================================%s\n' "$CYAN" "$NC"
    printf '%s          frp 安装管理脚本  v%s%s\n' "$BOLD" "$SCRIPT_VERSION" "$NC"
    printf '%s==============================================%s\n' "$CYAN" "$NC"
    printf '  frps 服务端: %s\n' "$(state_line frps)"
    printf '  frpc 客户端: %s\n' "$(state_line frpc)"
    echo
}

log_menu() {
    local n
    echo "  1. 最近 100 行"
    echo "  2. 实时跟踪（Ctrl+C 退出）"
    read -r -p "请选择 [1-2]: " n || return 0
    case $n in
        1) show_log "$1" ;;
        2) show_log "$1" follow ;;
    esac
}

menu_component() { # frps|frpc
    local c=$1 n title conf_item
    if [[ $c == frps ]]; then
        title="服务端 frps" conf_item="修改配置（端口 / token / 域名转发）"
    else
        title="客户端 frpc" conf_item="修改服务器连接（地址 / 端口 / token）"
    fi
    while :; do
        banner
        printf '%s[%s]%s\n' "$BOLD" "$title" "$NC"
        echo "  1. 安装 / 重新安装"
        echo "  2. $conf_item"
        echo "  3. 启动"
        echo "  4. 停止"
        echo "  5. 重启"
        echo "  6. 查看运行状态"
        echo "  7. 查看日志"
        echo "  8. 卸载"
        echo "  0. 返回上级"
        read -r -p "请选择 [0-8]: " n || exit 0
        case $n in
            1) run install_component "$c" ;;
            2) run reconfigure_component "$c" ;;
            3) run service_action start "$c" ;;
            4) run service_action stop "$c" ;;
            5) run service_action restart "$c" ;;
            6) run service_action status "$c" ;;
            7) run log_menu "$c" ;;
            8) run uninstall_component "$c" ;;
            0) return ;;
        esac
    done
}

menu_proxy() {
    local n
    while :; do
        banner
        printf '%s[穿透规则管理]%s\n' "$BOLD" "$NC"
        if is_installed frpc && [[ -f $FRPC_CONF ]]; then
            (proxy_list)
        else
            warn "frpc 尚未安装，请先在「客户端 frpc」菜单中安装"
        fi
        echo
        echo "  1. 添加规则"
        echo "  2. 修改规则"
        echo "  3. 删除规则"
        echo "  4. 查看在线状态"
        echo "  0. 返回上级"
        read -r -p "请选择 [0-4]: " n || exit 0
        case $n in
            1) run proxy_add ;;
            2) run proxy_edit ;;
            3) run proxy_del ;;
            4) run proxy_status ;;
            0) return ;;
        esac
    done
}

menu_main() {
    CLI_MODE=0
    interactive || die "交互菜单需要在终端中运行；非交互使用请参考: $SCRIPT_NAME help"
    local n
    while :; do
        banner
        echo "  1. 服务端 frps 管理"
        echo "  2. 客户端 frpc 管理"
        echo "  3. 穿透规则管理"
        echo "  4. 升级 frp"
        echo "  0. 退出"
        read -r -p "请选择 [0-4]: " n || exit 0
        case $n in
            1) menu_component frps ;;
            2) menu_component frpc ;;
            3) menu_proxy ;;
            4) run upgrade_component all ;;
            0 | q) exit 0 ;;
        esac
    done
}

# ================================ 命令行 ================================

usage() {
    cat <<EOF
frp 安装管理脚本 v$SCRIPT_VERSION

用法: $SCRIPT_NAME [命令] [参数]        不带命令时进入交互菜单

安装 / 维护:
  install frps [--port 7000] [--token T] [--http-port 80] [--https-port 443] [--subdomain-host D]
  install frpc --server ADDR [--port 7000] [--token T]
  upgrade [frps|frpc|all]             升级到最新版（或 --version 指定的版本）
  uninstall frps|frpc [--purge]       卸载；--purge 同时删除配置

服务管理:
  start|stop|restart|status frps|frpc
  log frps|frpc [-f]                  查看日志，-f 实时跟踪

穿透规则（frpc）:
  proxy list                          列出规则
  proxy status                        查看规则在线状态
  proxy add tcp|udp NAME LOCAL_PORT REMOTE_PORT [--local-ip IP] [--encrypt] [--compress]
  proxy add http|https NAME LOCAL_PORT (--domain a.com,b.com | --subdomain web) [--local-ip IP]
  proxy del NAME

通用选项:
  --version V      指定 frp 版本（默认最新版，需 >= $MIN_VERSION）
  --mirror URL     GitHub 加速镜像前缀，例如 https://gh-proxy.com/
  -y, --yes        不提问：使用默认值并自动确认

环境变量:
  FRP_MIRROR       同 --mirror
  FRP_GITHUB_BASE  替换直连地址 https://github.com（例如自建的 release 镜像）

示例:
  $SCRIPT_NAME install frps --token mytoken --http-port 80
  $SCRIPT_NAME install frpc --server 1.2.3.4 --token mytoken
  $SCRIPT_NAME proxy add tcp ssh 22 6000
  $SCRIPT_NAME proxy add http blog 8080 --domain blog.example.com
EOF
}

need_comp() { [[ ${1:-} == frps || ${1:-} == frpc ]] || die "请指定 frps 或 frpc"; }

proxy_cli() {
    local sub=${1:-list}
    shift
    case $sub in
        list | ls) proxy_list ;;
        status) proxy_status ;;
        add)
            (($# >= 2)) || die "用法: $SCRIPT_NAME proxy add <tcp|udp|http|https> <名称> <本地端口> [远程端口]"
            OPT[type]=$1 OPT[name]=$2
            [[ -n ${3:-} ]] && OPT[local-port]=$3
            if [[ -n ${4:-} ]]; then
                case $1 in
                    tcp | udp) OPT[remote-port]=$4 ;;
                    *) OPT[domain]=$4 ;;
                esac
            fi
            if [[ $1 == http || $1 == https ]] && [[ -z ${OPT[domain]:-}${OPT[subdomain]:-} ]]; then
                die "http/https 规则需要 --domain 或 --subdomain"
            fi
            proxy_add
            ;;
        del | rm | delete)
            [[ -n ${1:-} ]] || die "用法: $SCRIPT_NAME proxy del <名称>"
            OPT[name]=$1
            proxy_del
            ;;
        *) die "未知的 proxy 子命令: $sub（可选 list / status / add / del）" ;;
    esac
}

main() {
    local args=()
    while (($#)); do
        case $1 in
            -y | --yes) ASSUME_YES=1 ;;
            -f | --follow) OPT[follow]=1 ;;
            --encrypt | --compress | --purge) OPT[${1#--}]=1 ;;
            --version | --mirror | --port | --token | --server | --http-port | --https-port | \
                --subdomain-host | --local-ip | --local-port | --remote-port | --domain | --subdomain)
                (($# >= 2)) || die "$1 需要一个参数"
                OPT[${1#--}]=$2
                shift
                ;;
            --*=*)
                set -- "${1%%=*}" "${1#*=}" "${@:2}"
                continue
                ;;
            -h | --help) args=(help) ;;
            -*) die "未知选项: $1（查看帮助: $SCRIPT_NAME help）" ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    set -- "${args[@]}"

    local cmd=${1:-menu}
    (($#)) && shift
    if [[ $cmd == help ]]; then
        usage
        return 0
    fi
    need_root
    check_deps

    case $cmd in
        menu) menu_main ;;
        install) need_comp "${1:-}" && install_component "$1" ;;
        uninstall) need_comp "${1:-}" && uninstall_component "$1" ;;
        upgrade) upgrade_component "${1:-all}" ;;
        start | stop | restart | status | log) need_comp "${1:-}" && service_action "$cmd" "$1" ;;
        proxy) proxy_cli "$@" ;;
        *) die "未知命令: $cmd（查看帮助: $SCRIPT_NAME help）" ;;
    esac
}

main "$@"
