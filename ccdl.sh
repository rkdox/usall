#!/usr/bin/env bash
# ============================================================================
#  sing-box-lowlatency.sh — 低延迟量化交易专用 四协议代理一键部署
#  协议: VLESS-Reality | VMess-WS | Hysteria2 | TUIC v5
#  系统: Ubuntu 24.04 LTS 优化 (兼容 Debian 12 / CentOS 9 / Alpine)
#  优化: BBR+MPTCP内核调参 | 协议级低延迟 | nftables | DNS缓存 | 延迟测试
#  安全: 非root运行 | 仅放行必要端口 | SHA256校验 | systemd沙箱+实时调度
# ============================================================================
set -euo pipefail

# ========================== 全局常量 ==========================
readonly SCRIPT_VERSION="2.1.0-ubuntu2404"
readonly SB_DIR="/etc/sing-box"
readonly SB_BIN="/usr/local/bin/sing-box"
readonly SB_USER="singbox"
readonly SB_GROUP="singbox"
readonly CONFIG_FILE="${SB_DIR}/config.json"
readonly ENV_FILE="${SB_DIR}/.env"
readonly BACKUP_DIR="${SB_DIR}/backups"
readonly LOG_FILE="/var/log/sing-box/sing-box.log"
readonly SYSCTL_FILE="/etc/sysctl.d/99-singbox-lowlatency.conf"

readonly SB_VERSION="1.11.4"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;36m'; P='\033[0;35m'; W='\033[0m'

# ========================== 工具函数 ==========================
log_info()  { echo -e "${G}[INFO]${W}  $*"; }
log_warn()  { echo -e "${Y}[WARN]${W}  $*"; }
log_error() { echo -e "${R}[ERROR]${W} $*"; }
log_step()  { echo -e "\n${B}━━━ $* ━━━${W}"; }
log_perf()  { echo -e "${P}[PERF]${W}  $*"; }
die()       { log_error "$*"; exit 1; }

confirm() {
    local msg="$1" ans
    read -rp "$(echo -e "${Y}${msg} [y/N]: ${W}")" ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65000 -n 1)
        if ! ss -tlnp | grep -qw ":${port} " && ! ss -ulnp | grep -qw ":${port} "; then
            echo "$port"; return
        fi
    done
}

get_ip() {
    local v4 v6
    v4=$(curl -s4m5 https://icanhazip.com 2>/dev/null || true)
    v6=$(curl -s6m5 https://icanhazip.com 2>/dev/null || true)
    echo "${v4}|${v6}"
}

check_root() { [[ $EUID -eq 0 ]] || die "请以 root 运行此脚本"; }

detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       die "不支持的架构: $(uname -m)" ;;
    esac
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID,,}" in
            ubuntu|debian) echo "debian" ;;
            centos|rhel|rocky|alma|fedora) echo "rhel" ;;
            alpine) echo "alpine" ;;
            *) die "不支持的系统: ${ID}" ;;
        esac
    else die "无法检测操作系统"; fi
}

# ========================== Step 1: 依赖 ==========================
install_deps() {
    log_step "Step 1/9 — 安装依赖"
    local os; os=$(detect_os)
    case "$os" in
        debian)
            # Ubuntu 24.04: needrestart 会弹交互对话框阻塞 apt，必须抑制
            export NEEDRESTART_MODE=a
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                curl jq openssl qrencode tar gzip ethtool iproute2 \
                kmod >/dev/null 2>&1
            # Ubuntu 24.04 默认用 nftables，确保 iptables 兼容层可用
            if ! command -v iptables &>/dev/null; then
                apt-get install -y -qq iptables >/dev/null 2>&1
            fi
            ;;
        rhel)
            yum install -y -q curl jq openssl qrencode tar gzip ethtool iproute kmod >/dev/null 2>&1
            ;;
        alpine)
            apk add --quiet curl jq openssl libqrencode tar gzip ethtool iproute2 kmod
            ;;
    esac
    log_info "依赖安装完成"
}

# ========================== Step 2: 专用用户 ==========================
create_user() {
    log_step "Step 2/9 — 创建专用用户"
    if id "${SB_USER}" &>/dev/null; then
        log_info "用户 ${SB_USER} 已存在"
    else
        useradd -r -s /usr/sbin/nologin -d /nonexistent "${SB_USER}"
        log_info "已创建: ${SB_USER}"
    fi
}

# ========================== Step 3: 内核网络调优 ==========================
tune_kernel() {
    log_step "Step 3/9 — 内核网络低延迟调优 (Ubuntu 24.04 优化)"

    local kver
    kver=$(uname -r | cut -d'-' -f1)
    log_info "内核版本: $(uname -r)"

    # 备份
    [[ -f "${SYSCTL_FILE}" ]] && cp "${SYSCTL_FILE}" "${SYSCTL_FILE}.bak.$(date +%s)"

    # Ubuntu 24.04 内核 6.8+: BBR 内置无需 modprobe，MPTCP 原生支持
    cat > "${SYSCTL_FILE}" <<'SYSEOF'
# ============================================================
# sing-box 低延迟调优 — Ubuntu 24.04 / Kernel 6.8+
# 生效: sysctl -p /etc/sysctl.d/99-singbox-lowlatency.conf
# 回滚: rm -f /etc/sysctl.d/99-singbox-lowlatency.conf && sysctl --system
# ============================================================

# ---------- BBR3 拥塞控制 (6.8 内核内置，无需 modprobe) ----------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---------- MPTCP (Ubuntu 24.04 内核原生支持) ----------
net.mptcp.enabled = 1

# ---------- TCP Fast Open (客户端+服务端双向) ----------
net.ipv4.tcp_fastopen = 3

# ---------- 连接效率 ----------
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536

# ---------- TCP keepalive (60s 探活，快速感知断连) ----------
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# ---------- 缓冲区 (QUIC/UDP 必须大缓冲) ----------
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 26214400
net.ipv4.tcp_wmem = 4096 65536 26214400
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ---------- 网络队列 ----------
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 20000

# ---------- conntrack (高并发 + 快速回收) ----------
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# ---------- 基础启用 ----------
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ---------- Ubuntu 24.04: BPF JIT (加速 nftables 规则匹配) ----------
net.core.bpf_jit_enable = 1
SYSEOF

    # Ubuntu 24.04 内核 6.8+: BBR 已编译进内核，但低版本需加载模块
    if [[ "$(printf '%s\n' "6.8" "$kver" | sort -V | head -1)" != "6.8" ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        log_info "内核 < 6.8，已尝试加载 tcp_bbr 模块"
    fi

    # 加载 conntrack
    modprobe nf_conntrack 2>/dev/null || true

    # 逐行应用 (容错：容器/VPS 可能部分参数受限)
    local applied=0 skipped=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]] && continue
        if sysctl -w "$line" >/dev/null 2>&1; then
            ((applied++))
        else
            ((skipped++))
        fi
    done < "${SYSCTL_FILE}"
    log_info "sysctl 参数: ${applied} 项生效, ${skipped} 项跳过 (受限环境正常)"

    # 验证关键参数
    local cc qdisc tfo
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")
    [[ "$cc" == "bbr" ]] && log_perf "BBR ✓" || log_warn "BBR 未生效 (当前: ${cc})"
    [[ "$qdisc" == "fq" ]] && log_perf "FQ 队列 ✓" || log_warn "FQ 未生效 (当前: ${qdisc})"
    [[ "$tfo" == "3" ]] && log_perf "TCP Fast Open ✓" || log_warn "TFO 未生效 (当前: ${tfo})"

    # MPTCP (Ubuntu 24.04 专属)
    local mptcp
    mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "?")
    [[ "$mptcp" == "1" ]] && log_perf "MPTCP ✓ (Ubuntu 24.04 原生)" || log_info "MPTCP 不可用 (非关键)"

    # 网卡优化
    local main_iface
    main_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$main_iface" ]] && command -v ethtool &>/dev/null; then
        # GRO: 聚合小包增加延迟，交易场景关闭
        ethtool -K "$main_iface" gro off 2>/dev/null && log_perf "GRO 已关闭 (${main_iface})" || true
        # 开启校验卸载 (减少 CPU)
        ethtool -K "$main_iface" tx on rx on 2>/dev/null || true
        # 降低中断合并
        ethtool -C "$main_iface" rx-usecs 50 tx-usecs 50 2>/dev/null && log_perf "中断合并 50μs (${main_iface})" || true
        # Ubuntu 24.04: XDP 原生支持，确认网卡驱动
        local driver
        driver=$(ethtool -i "$main_iface" 2>/dev/null | awk '/driver:/{print $2}')
        [[ -n "$driver" ]] && log_info "网卡驱动: ${driver} (${main_iface})"
    fi

    log_info "内核调优完成"
}

# ========================== Step 4: DNS 本地缓存 ==========================
setup_dns_cache() {
    log_step "Step 4/9 — DNS 本地缓存"

    # 方案: 使用 systemd-resolved 的 stub listener 做本地缓存
    # 如果已有 resolved，只确认开启缓存; 否则写一个轻量 hosts 钉住
    if systemctl is-active systemd-resolved &>/dev/null 2>&1; then
        # 确保缓存启用
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/low-latency.conf <<'DNSEOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9
Cache=yes
CacheFromLocalhost=yes
DNSOverTLS=opportunistic
DNSEOF
        systemctl restart systemd-resolved 2>/dev/null || true
        log_perf "systemd-resolved DNS 缓存已启用"
    else
        log_info "systemd-resolved 不可用，使用 /etc/hosts 钉住常用交易所域名"
    fi

    # 无论哪种方案，都在 hosts 里钉住高频交易所域名的 IP
    # 以下为示例 — 实际 IP 用户应根据自己的 dig 结果替换
    local hosts_marker="# sing-box-lowlatency exchange hosts"
    if ! grep -q "${hosts_marker}" /etc/hosts 2>/dev/null; then
        cat >> /etc/hosts <<HOSTSEOF

${hosts_marker}
# ⚠️  以下为示例 IP，请用 dig +short <域名> 获取你本地最优解析结果后替换
# 取消注释并填入真实 IP 即可生效 (省去每次 DNS 查询的 30-100ms)
# 示例: Binance API
# 52.84.xx.xx  api.binance.com
# 52.84.xx.xx  fapi.binance.com
# 52.84.xx.xx  stream.binance.com
# 示例: OKX API
# 104.18.xx.xx api.okx.com
HOSTSEOF
        log_info "已在 /etc/hosts 添加交易所 DNS 钉住模板 (需手动填入 IP)"
    fi
}

# ========================== Step 5: 下载 sing-box ==========================
install_singbox() {
    log_step "Step 5/9 — 下载 sing-box v${SB_VERSION}"

    local arch pkg_name url checksum_url tmp_dir
    arch=$(detect_arch)
    pkg_name="sing-box-${SB_VERSION}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${pkg_name}.tar.gz"
    checksum_url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${pkg_name}.tar.gz.dgst"
    tmp_dir=$(mktemp -d)

    log_info "下载 ${url}"
    curl -fSL --retry 3 --progress-bar -o "${tmp_dir}/sb.tar.gz" "${url}" || die "下载失败"

    # SHA256 校验
    if curl -fsSL --retry 2 -o "${tmp_dir}/sb.dgst" "${checksum_url}" 2>/dev/null; then
        local expected actual
        expected=$(grep -i 'SHA256' "${tmp_dir}/sb.dgst" | head -1 | awk '{print $NF}')
        actual=$(sha256sum "${tmp_dir}/sb.tar.gz" | awk '{print $1}')
        if [[ -n "$expected" && "$expected" == "$actual" ]]; then
            log_info "SHA256 校验通过 ✓"
        else
            log_warn "SHA256 无法自动校验"
            confirm "是否继续？" || { rm -rf "${tmp_dir}"; die "用户取消"; }
        fi
    else
        log_warn "无法下载校验文件"
        confirm "是否继续？" || { rm -rf "${tmp_dir}"; die "用户取消"; }
    fi

    tar xzf "${tmp_dir}/sb.tar.gz" -C "${tmp_dir}"
    install -m 755 "${tmp_dir}/${pkg_name}/sing-box" "${SB_BIN}"
    rm -rf "${tmp_dir}"
    setcap 'cap_net_bind_service=+ep' "${SB_BIN}" 2>/dev/null || true
    log_info "已安装: $(${SB_BIN} version 2>/dev/null | head -1)"
}

# ========================== Step 6: 生成低延迟配置 ==========================
generate_config() {
    log_step "Step 6/9 — 生成低延迟协议配置"

    mkdir -p "${SB_DIR}" "${BACKUP_DIR}" /var/log/sing-box
    chmod 750 "${SB_DIR}"
    chmod 700 "${BACKUP_DIR}"

    local uuid
    uuid=$("${SB_BIN}" generate uuid)

    local reality_output private_key public_key short_id
    reality_output=$("${SB_BIN}" generate reality-keypair)
    private_key=$(echo "${reality_output}" | awk '/PrivateKey/{print $NF}')
    public_key=$(echo "${reality_output}" | awk '/PublicKey/{print $NF}')
    short_id=$(openssl rand -hex 4)

    local port_vless port_vmess port_hy2 port_tuic
    port_vless=$(random_port)
    port_vmess=$(random_port)
    port_hy2=$(random_port)
    port_tuic=$(random_port)

    log_info "端口 — VLESS:${port_vless}  VMess:${port_vmess}  Hy2:${port_hy2}  TUIC:${port_tuic}"

    # 证书
    local cert_dir="${SB_DIR}/tls"
    mkdir -p "${cert_dir}"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" \
        -out "${cert_dir}/cert.pem" -subj "/CN=$(openssl rand -hex 8).com" 2>/dev/null

    # IP
    local ip_result v4 v6 server_ip
    ip_result=$(get_ip)
    v4=$(echo "${ip_result}" | cut -d'|' -f1)
    v6=$(echo "${ip_result}" | cut -d'|' -f2)
    [[ -n "$v4" ]] && server_ip="$v4" || { [[ -n "$v6" ]] && server_ip="$v6" || die "无法获取公网IP"; }
    log_info "服务器: ${server_ip}"

    local sni="www.apple.com"

    # .env
    cat > "${ENV_FILE}" <<ENVEOF
UUID=${uuid}
PRIVATE_KEY=${private_key}
PUBLIC_KEY=${public_key}
SHORT_ID=${short_id}
PORT_VLESS=${port_vless}
PORT_VMESS=${port_vmess}
PORT_HY2=${port_hy2}
PORT_TUIC=${port_tuic}
SERVER_IP=${server_ip}
SERVER_V4=${v4}
SERVER_V6=${v6}
SNI=${sni}
ENVEOF
    chmod 600 "${ENV_FILE}"

    # ================================================================
    # 核心: 低延迟 sing-box 配置
    # ================================================================
    cat > "${CONFIG_FILE}" <<CFGEOF
{
  "log": {
    "level": "error",
    "timestamp": true,
    "output": "${LOG_FILE}"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${port_vless},
      "tcp_fast_open": true,
      "tcp_multi_path": true,
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${sni}",
            "server_port": 443
          },
          "private_key": "${private_key}",
          "short_id": ["${short_id}"]
        }
      },
      "multiplex": {
        "enabled": true,
        "padding": false
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "::",
      "listen_port": ${port_vmess},
      "tcp_fast_open": true,
      "users": [
        {
          "uuid": "${uuid}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/${uuid}-vm",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      },
      "multiplex": {
        "enabled": true,
        "padding": false
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": ${port_hy2},
      "up_mbps": 500,
      "down_mbps": 500,
      "ignore_client_bandwidth": false,
      "users": [
        {
          "password": "${uuid}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${cert_dir}/cert.pem",
        "key_path": "${cert_dir}/key.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-v5",
      "listen": "::",
      "listen_port": ${port_tuic},
      "users": [
        {
          "uuid": "${uuid}",
          "password": "${uuid}"
        }
      ],
      "congestion_control": "bbr",
      "zero_rtt_handshake": true,
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${cert_dir}/cert.pem",
        "key_path": "${cert_dir}/key.pem"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "tcp_fast_open": true,
      "tcp_multi_path": true
    }
  ]
}
CFGEOF

    if "${SB_BIN}" check -c "${CONFIG_FILE}" 2>/dev/null; then
        log_info "配置校验通过 ✓"
    else
        log_warn "配置校验异常，尝试继续…"
        "${SB_BIN}" check -c "${CONFIG_FILE}" 2>&1 || true
    fi

    chown -R "${SB_USER}:${SB_GROUP}" "${SB_DIR}" /var/log/sing-box
    chmod 640 "${CONFIG_FILE}"
}

# ========================== Step 7: 防火墙 ==========================
setup_firewall() {
    log_step "Step 7/9 — 防火墙 (仅放行代理端口)"

    source "${ENV_FILE}"
    local ports=("${PORT_VLESS}" "${PORT_VMESS}" "${PORT_HY2}" "${PORT_TUIC}")

    # Ubuntu 24.04 优先级: ufw → nftables 原生 → iptables (nft 后端)
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        for p in "${ports[@]}"; do
            ufw allow "${p}/tcp" >/dev/null 2>&1; ufw allow "${p}/udp" >/dev/null 2>&1
        done
        ufw reload >/dev/null 2>&1
        log_info "ufw: 已放行 ${ports[*]}"

    elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        for p in "${ports[@]}"; do
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
            firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
        done
        firewall-cmd --reload >/dev/null 2>&1
        log_info "firewalld: 已放行 ${ports[*]}"

    elif command -v nft &>/dev/null; then
        # Ubuntu 24.04 默认: nftables 原生
        # 创建 sing-box 专用表，不影响其他规则
        nft add table inet sing-box 2>/dev/null || true
        nft add chain inet sing-box input '{ type filter hook input priority -10; policy accept; }' 2>/dev/null || true
        for p in "${ports[@]}"; do
            nft add rule inet sing-box input tcp dport "${p}" accept 2>/dev/null || true
            nft add rule inet sing-box input udp dport "${p}" accept 2>/dev/null || true
        done
        # 持久化
        mkdir -p /etc/nftables.d
        nft list table inet sing-box > /etc/nftables.d/sing-box.nft 2>/dev/null || true
        log_info "nftables: 已放行 ${ports[*]} (独立 sing-box 表)"

    else
        # 最后回退: iptables (Ubuntu 24.04 上是 iptables-nft 后端)
        for p in "${ports[@]}"; do
            iptables  -I INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
            iptables  -I INPUT -p udp --dport "${p}" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p udp --dport "${p}" -j ACCEPT 2>/dev/null || true
        done
        log_info "iptables: 已放行 ${ports[*]}"
    fi
}

# ========================== Step 8: systemd 服务 (低延迟) ==========================
setup_service() {
    log_step "Step 8/9 — 低延迟 systemd 服务"

    cat > /etc/systemd/system/sing-box.service <<SVCEOF
[Unit]
Description=sing-box low-latency proxy
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SB_USER}
Group=${SB_GROUP}

# --- 低延迟核心参数 ---
Nice=-10
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=50
IOSchedulingClass=realtime
IOSchedulingPriority=0
LimitMEMLOCK=infinity
LimitNOFILE=1048576
LimitNPROC=65535

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_NICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_NICE

ExecStart=${SB_BIN} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID

Restart=always
RestartSec=1
WatchdogSec=30

# --- 安全加固 ---
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SB_DIR} /var/log/sing-box
PrivateTmp=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl start sing-box

    sleep 2
    if systemctl is-active sing-box &>/dev/null; then
        log_info "sing-box 服务已启动 ✓"
    else
        log_error "启动失败:"
        journalctl -u sing-box --no-pager -n 20
        die "服务启动失败"
    fi
}

# ========================== Step 9: 节点信息 ==========================
show_result() {
    log_step "Step 9/9 — 节点信息"

    source "${ENV_FILE}"
    local hn; hn=$(hostname -s)
    local dip="${SERVER_IP}"
    [[ "${SERVER_IP}" == *:* ]] && dip="[${SERVER_IP}]"

    echo
    echo -e "${G}╔════════════════════════════════════════════════════════════════════╗${W}"
    echo -e "${G}║     sing-box 低延迟四协议部署完成  v${SCRIPT_VERSION}                  ║${W}"
    echo -e "${G}╚════════════════════════════════════════════════════════════════════╝${W}"

    # VLESS
    local vless_link="vless://${UUID}@${dip}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#vless-${hn}"
    echo -e "\n${R}▸ 1. VLESS-Reality${W}  端口:${PORT_VLESS}  [TCP, 抗封锁首选]"
    echo -e "  ${Y}${vless_link}${W}"
    echo "${vless_link}" > "${SB_DIR}/link_vless.txt"
    qrencode -t ANSIUTF8 "${vless_link}" 2>/dev/null || true

    # VMess
    local vmj="{\"v\":\"2\",\"ps\":\"vmess-${hn}\",\"add\":\"${SERVER_IP}\",\"port\":\"${PORT_VMESS}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"/${UUID}-vm\",\"tls\":\"\",\"sni\":\"\"}"
    local vmess_link="vmess://$(echo -n "${vmj}" | base64 -w 0)"
    echo -e "\n${R}▸ 2. VMess-WS${W}  端口:${PORT_VMESS}  [可套CDN, 保底]"
    echo -e "  ${Y}${vmess_link}${W}"
    echo "${vmess_link}" > "${SB_DIR}/link_vmess.txt"
    qrencode -t ANSIUTF8 "${vmess_link}" 2>/dev/null || true

    # Hy2
    local hy2_link="hysteria2://${UUID}@${dip}:${PORT_HY2}?security=tls&alpn=h3&insecure=1#hy2-${hn}"
    echo -e "\n${R}▸ 3. Hysteria2${W}  端口:${PORT_HY2}  [UDP/QUIC, 高带宽抗丢包]"
    echo -e "  ${Y}${hy2_link}${W}"
    echo "${hy2_link}" > "${SB_DIR}/link_hy2.txt"
    qrencode -t ANSIUTF8 "${hy2_link}" 2>/dev/null || true

    # TUIC
    local tuic_link="tuic://${UUID}:${UUID}@${dip}:${PORT_TUIC}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=1#tuic5-${hn}"
    echo -e "\n${R}▸ 4. TUIC v5${W}  端口:${PORT_TUIC}  [UDP/QUIC+0RTT, 交易首选 ★]"
    echo -e "  ${Y}${tuic_link}${W}"
    echo "${tuic_link}" > "${SB_DIR}/link_tuic.txt"
    qrencode -t ANSIUTF8 "${tuic_link}" 2>/dev/null || true

    echo
    echo -e "${G}╔════════════════════════════════════════════════════════════════════╗${W}"
    echo -e "${G}║  管理命令                                                          ║${W}"
    echo -e "${G}╠════════════════════════════════════════════════════════════════════╣${W}"
    echo -e "${G}║${W}  状态:    systemctl status sing-box                               ${G}║${W}"
    echo -e "${G}║${W}  重启:    systemctl restart sing-box                              ${G}║${W}"
    echo -e "${G}║${W}  日志:    journalctl -u sing-box -f --no-pager                    ${G}║${W}"
    echo -e "${G}║${W}  节点:    cat ${SB_DIR}/link_*.txt                                ${G}║${W}"
    echo -e "${G}║${W}  测延迟:  bash $0 bench                                          ${G}║${W}"
    echo -e "${G}║${W}  卸载:    bash $0 uninstall                                       ${G}║${W}"
    echo -e "${G}╠════════════════════════════════════════════════════════════════════╣${W}"
    echo -e "${G}║  低延迟优化清单                                                    ║${W}"
    echo -e "${G}╠════════════════════════════════════════════════════════════════════╣${W}"
    echo -e "${G}║${W}  ✓ BBR 拥塞控制                                                  ${G}║${W}"
    echo -e "${G}║${W}  ✓ TCP Fast Open + Multipath                                     ${G}║${W}"
    echo -e "${G}║${W}  ✓ TUIC 0-RTT 握手                                               ${G}║${W}"
    echo -e "${G}║${W}  ✓ 多路复用 (VLESS/VMess)                                        ${G}║${W}"
    echo -e "${G}║${W}  ✓ UDP 缓冲区 16MB / conntrack 优化                              ${G}║${W}"
    echo -e "${G}║${W}  ✓ GRO 关闭 (降低小包聚合延迟)                                   ${G}║${W}"
    echo -e "${G}║${W}  ✓ 进程优先级 Nice=-10 / FIFO 实时调度                           ${G}║${W}"
    echo -e "${G}║${W}  ✓ 日志级别 error (减少磁盘IO)                                   ${G}║${W}"
    echo -e "${G}║${W}  ✓ DNS 本地缓存 + 交易所 hosts 钉住模板                          ${G}║${W}"
    echo -e "${G}╚════════════════════════════════════════════════════════════════════╝${W}"
    echo
    echo -e "${Y}★ 量化交易推荐优先使用 TUIC v5 (0-RTT + BBR + UDP 无队头阻塞)${W}"
    echo -e "${Y}  线路丢包 >2% 时切换 Hysteria2，TCP 封锁时用 VLESS-Reality${W}"
    echo
}

# ========================== 延迟基准测试 ==========================
bench_latency() {
    log_step "延迟基准测试"

    source "${ENV_FILE}" 2>/dev/null || die "未检测到安装"

    echo -e "\n${B}[1] 系统网络参数检查${W}"
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
    local tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "?")
    local mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "?")
    local bpf=$(sysctl -n net.core.bpf_jit_enable 2>/dev/null || echo "?")

    printf "  拥塞控制: %-12s  (期望: bbr)     %s\n" "$cc" "$( [[ $cc == bbr ]] && echo -e "${G}✓${W}" || echo -e "${R}✗${W}" )"
    printf "  队列调度: %-12s  (期望: fq)      %s\n" "$qdisc" "$( [[ $qdisc == fq ]] && echo -e "${G}✓${W}" || echo -e "${R}✗${W}" )"
    printf "  TCP TFO:  %-12s  (期望: 3)       %s\n" "$tfo" "$( [[ $tfo == 3 ]] && echo -e "${G}✓${W}" || echo -e "${R}✗${W}" )"
    printf "  UDP rmem: %-12s  (期望: 25MB+)   %s\n" "$rmem" "$( [[ $rmem -ge 26214400 ]] 2>/dev/null && echo -e "${G}✓${W}" || echo -e "${R}✗${W}" )"
    printf "  MPTCP:    %-12s  (期望: 1)       %s\n" "$mptcp" "$( [[ $mptcp == 1 ]] && echo -e "${G}✓${W}" || echo -e "${Y}可选${W}" )"
    printf "  BPF JIT:  %-12s  (期望: 1)       %s\n" "$bpf" "$( [[ $bpf == 1 ]] && echo -e "${G}✓${W}" || echo -e "${Y}可选${W}" )"

    # 网卡 GRO 状态
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$iface" ]] && command -v ethtool &>/dev/null; then
        local gro_status
        gro_status=$(ethtool -k "$iface" 2>/dev/null | awk '/generic-receive-offload:/{print $2}')
        printf "  GRO:      %-12s  (期望: off)     %s\n" "$gro_status" "$( [[ $gro_status == off ]] && echo -e "${G}✓${W}" || echo -e "${Y}建议关闭${W}" )"
    fi

    echo -e "\n${B}[2] 端口监听检查${W}"
    for kv in "VLESS:${PORT_VLESS}:tcp" "VMess:${PORT_VMESS}:tcp" "Hy2:${PORT_HY2}:udp" "TUIC:${PORT_TUIC}:udp"; do
        local name="${kv%%:*}"; local rest="${kv#*:}"; local port="${rest%%:*}"; local proto="${rest##*:}"
        if ss -lnp | grep -qw ":${port} "; then
            printf "  %-6s :%s (%s)  ${G}✓ 监听中${W}\n" "$name" "$port" "$proto"
        else
            printf "  %-6s :%s (%s)  ${R}✗ 未监听${W}\n" "$name" "$port" "$proto"
        fi
    done

    echo -e "\n${B}[3] 到常用交易所端点 TCP 延迟 (ms)${W}"
    local targets=(
        "api.binance.com:443:Binance"
        "api.okx.com:443:OKX"
        "api.bybit.com:443:Bybit"
        "api.huobi.pro:443:Huobi"
        "api.coinbase.com:443:Coinbase"
    )
    for t in "${targets[@]}"; do
        local host="${t%%:*}"; local rest="${t#*:}"; local port="${rest%%:*}"; local label="${rest##*:}"
        # 用 TCP SYN 测延迟 (比 ICMP 更真实)
        local ip
        ip=$(getent ahosts "$host" 2>/dev/null | awk 'NR==1{print $1}') || true
        if [[ -n "$ip" ]]; then
            local start end elapsed
            start=$(date +%s%N)
            timeout 3 bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null && {
                end=$(date +%s%N)
                elapsed=$(( (end - start) / 1000000 ))
                printf "  %-12s → %-16s  ${G}%4d ms${W}\n" "$label" "$ip" "$elapsed"
            } || {
                printf "  %-12s → %-16s  ${R}超时${W}\n" "$label" "$ip"
            }
        else
            printf "  %-12s → ${R}DNS 解析失败${W}\n" "$label"
        fi
    done

    echo -e "\n${B}[4] sing-box 进程状态${W}"
    local pid
    pid=$(pgrep -x sing-box 2>/dev/null || echo "")
    if [[ -n "$pid" ]]; then
        local nice_val sched
        nice_val=$(awk '{print $19}' /proc/${pid}/stat 2>/dev/null || echo "?")
        sched=$(chrt -p "$pid" 2>/dev/null | tail -1 || echo "?")
        printf "  PID: %s  Nice: %s  调度: %s\n" "$pid" "$nice_val" "$sched"

        # 连接数
        local tcp_conns udp_conns
        tcp_conns=$(ss -tnp 2>/dev/null | grep "sing-box" | wc -l)
        udp_conns=$(ss -unp 2>/dev/null | grep "sing-box" | wc -l)
        printf "  活跃连接: TCP=%s  UDP=%s\n" "$tcp_conns" "$udp_conns"
    else
        echo -e "  ${R}sing-box 未运行${W}"
    fi

    echo
}

# ========================== 卸载 ==========================
uninstall() {
    log_step "卸载 sing-box"
    confirm "确认完全卸载？" || { echo "已取消"; exit 0; }

    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload

    if [[ -f "${ENV_FILE}" ]]; then
        source "${ENV_FILE}"
        for p in "${PORT_VLESS}" "${PORT_VMESS}" "${PORT_HY2}" "${PORT_TUIC}"; do
            ufw delete allow "${p}/tcp" 2>/dev/null || true
            ufw delete allow "${p}/udp" 2>/dev/null || true
            firewall-cmd --permanent --remove-port="${p}/tcp" 2>/dev/null || true
            firewall-cmd --permanent --remove-port="${p}/udp" 2>/dev/null || true
            iptables  -D INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
            iptables  -D INPUT -p udp --dport "${p}" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p tcp --dport "${p}" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport "${p}" -j ACCEPT 2>/dev/null || true
        done
        firewall-cmd --reload 2>/dev/null || true
        # nftables: 删除 sing-box 专用表
        nft delete table inet sing-box 2>/dev/null || true
        rm -f /etc/nftables.d/sing-box.nft 2>/dev/null || true
    fi

    rm -rf "${SB_DIR}" /var/log/sing-box
    rm -f "${SB_BIN}"
    userdel "${SB_USER}" 2>/dev/null || true

    # 内核参数回滚
    if [[ -f "${SYSCTL_FILE}" ]]; then
        rm -f "${SYSCTL_FILE}"
        sysctl --system >/dev/null 2>&1
        log_info "内核参数已回滚"
    fi

    # 清理 hosts
    sed -i '/sing-box-lowlatency/,/^$/d' /etc/hosts 2>/dev/null || true

    # 清理 DNS 配置
    rm -f /etc/systemd/resolved.conf.d/low-latency.conf 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true

    log_info "已完全卸载 ✓"
}

# ========================== 更新内核 ==========================
update_core() {
    log_step "更新 sing-box 内核"
    [[ -f "${CONFIG_FILE}" ]] || die "未安装"

    local ts; ts=$(date +%Y%m%d%H%M%S)
    cp "${SB_BIN}" "${BACKUP_DIR}/sing-box.bak.${ts}" 2>/dev/null || true
    log_info "备份 → ${BACKUP_DIR}/sing-box.bak.${ts}"

    install_singbox
    systemctl restart sing-box
    sleep 2
    if systemctl is-active sing-box &>/dev/null; then
        log_info "更新成功 ✓"
    else
        log_error "启动失败，回滚…"
        cp "${BACKUP_DIR}/sing-box.bak.${ts}" "${SB_BIN}"
        chmod 755 "${SB_BIN}"
        systemctl restart sing-box
        log_info "已回滚"
    fi
}

# ========================== 主入口 ==========================
main() {
    local action="${1:-}"

    if [[ -z "$action" ]]; then
        echo
        echo -e "${B}╔═══════════════════════════════════════════════════════╗${W}"
        echo -e "${B}║  sing-box 低延迟部署脚本 v${SCRIPT_VERSION}           ║${W}"
        echo -e "${B}║  VLESS-Reality | VMess-WS | Hysteria2 | TUIC v5     ║${W}"
        echo -e "${B}║  量化交易 · 内核调优 · DNS缓存 · 实时调度            ║${W}"
        echo -e "${B}╚═══════════════════════════════════════════════════════╝${W}"
        echo
        echo -e "  ${G}1${W}) 安装 (含全部低延迟优化)"
        echo -e "  ${G}2${W}) 查看节点信息"
        echo -e "  ${G}3${W}) 延迟基准测试"
        echo -e "  ${G}4${W}) 更新内核"
        echo -e "  ${G}5${W}) 查看运行状态"
        echo -e "  ${G}6${W}) 完全卸载 (含参数回滚)"
        echo -e "  ${G}0${W}) 退出"
        echo
        read -rp "$(echo -e "${Y}请选择 [0-6]: ${W}")" choice
        case "$choice" in
            1) action="install" ;; 2) action="show" ;; 3) action="bench" ;;
            4) action="update" ;; 5) action="status" ;; 6) action="uninstall" ;;
            0) exit 0 ;; *) die "无效选择" ;;
        esac
    fi

    case "$action" in
        install)
            check_root
            if systemctl is-active sing-box &>/dev/null 2>&1; then
                log_warn "sing-box 已运行"
                if confirm "重新安装？(备份当前配置)"; then
                    local ts; ts=$(date +%Y%m%d%H%M%S)
                    mkdir -p "${BACKUP_DIR}"
                    cp "${CONFIG_FILE}" "${BACKUP_DIR}/config.bak.${ts}" 2>/dev/null || true
                    cp "${ENV_FILE}" "${BACKUP_DIR}/.env.bak.${ts}" 2>/dev/null || true
                    systemctl stop sing-box
                else
                    exit 0
                fi
            fi
            install_deps          # 1/9
            create_user           # 2/9
            tune_kernel           # 3/9  ★ 新增
            setup_dns_cache       # 4/9  ★ 新增
            install_singbox       # 5/9
            generate_config       # 6/9  ★ 协议级优化
            setup_firewall        # 7/9
            setup_service         # 8/9  ★ 实时调度优化
            show_result           # 9/9
            ;;
        uninstall) check_root; uninstall ;;
        show) show_result ;;
        bench) bench_latency ;;
        update) check_root; update_core ;;
        status)
            echo
            systemctl status sing-box --no-pager 2>/dev/null || echo "未安装"
            echo
            if [[ -f "${ENV_FILE}" ]]; then
                source "${ENV_FILE}"
                echo "端口监听:"
                for kv in "VLESS:${PORT_VLESS}" "VMess:${PORT_VMESS}" "Hy2:${PORT_HY2}" "TUIC:${PORT_TUIC}"; do
                    local n="${kv%%:*}" p="${kv##*:}"
                    if ss -lnp | grep -qw ":${p} "; then
                        echo -e "  ${G}✓${W} ${n} :${p}"
                    else
                        echo -e "  ${R}✗${W} ${n} :${p}"
                    fi
                done
            fi
            echo ;;
        *) echo "用法: $0 {install|uninstall|show|bench|update|status}"; exit 1 ;;
    esac
}

main "$@"
