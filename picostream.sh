#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║              PicoStream — DNS Tunnel Installer                   ║
# ║              github.com/amir6dev/PicoStream                      ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/picostream.sh)
#
# Architecture:
#   User (VLESS) → Relay [Xray + ss-local + slipstream-client]
#                       → DNS tunnel (UDP:53 via 8.8.8.8)
#                           → Exit [slipstream-server + ss-server]
#                               → Internet

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root (sudo -i)" && exit 1

# ── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -ne "${BLUE}[?]${NC} $1"; }
step() { echo -e "\n${CYAN}── $1 ──────────────────────────────────────────────${NC}"; }

# ── Constants ───────────────────────────────────────────────────────
RELEASE_BASE="https://github.com/Fox-Fig/slipstream-rust-plus-deploy/releases/latest/download"
XRAY_RELEASE="https://github.com/XTLS/Xray-core/releases/latest/download"
CONFIG_DIR="/etc/picostream"
VERSION="2.1.0"

# ── Detect system ───────────────────────────────────────────────────
detect_system() {
    [ -f /etc/os-release ] && source /etc/os-release || err "Cannot detect OS"

    if command -v apt-get &>/dev/null; then
        PKG="apt"
    elif command -v dnf &>/dev/null; then
        PKG="dnf"
    elif command -v yum &>/dev/null; then
        PKG="yum"
    else
        err "Unsupported package manager"
    fi

    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) err "Unsupported arch: $(uname -m)" ;;
    esac

    info "OS: ${NAME} | Arch: ${ARCH} | PKG: ${PKG}"
}

# ── Install base deps ───────────────────────────────────────────────
install_base_deps() {
    step "Dependencies"
    if [ "$PKG" = "apt" ]; then
        apt-get update -qq 2>/dev/null || warn "apt update skipped"
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            curl openssl uuid-runtime unzip shadowsocks-libev -qq 2>/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            curl openssl uuid-runtime unzip -qq
    elif [ "$PKG" = "dnf" ]; then
        dnf install -y curl openssl util-linux unzip shadowsocks-libev 2>/dev/null || \
        dnf install -y curl openssl util-linux unzip
    elif [ "$PKG" = "yum" ]; then
        yum install -y curl openssl util-linux unzip shadowsocks-libev 2>/dev/null || \
        yum install -y curl openssl util-linux unzip
    fi

    # libssl3 (required by slipstream binary)
    if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
        if ! apt-get install -y libssl3 2>/dev/null; then
            warn "Downloading libssl3 manually..."
            if [ "$ARCH" = "arm64" ]; then
                LURL="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
            else
                LURL="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
            fi
            curl -fsSL "$LURL" -o /tmp/libssl3.deb 2>/dev/null
            dpkg -i /tmp/libssl3.deb 2>/dev/null || true
            rm -f /tmp/libssl3.deb
        fi
    fi
    info "Dependencies ready"
}

# ── Download slipstream binary ──────────────────────────────────────
download_slipstream() {
    local mode="$1"   # server or client
    local bin="/usr/local/bin/slipstream-${mode}"
    info "Downloading slipstream-${mode}-plus (${ARCH})..."
    curl -fsSL --max-time 120 \
        "${RELEASE_BASE}/slipstream-${mode}-linux-${ARCH}" \
        -o "${bin}.tmp" || err "Download failed: slipstream-${mode}"
    mv "${bin}.tmp" "$bin"
    chmod +x "$bin"
    info "slipstream-${mode} installed"
}

# ── Generate TLS cert ───────────────────────────────────────────────
generate_certs() {
    local domain="$1"
    mkdir -p "$CONFIG_DIR"
    CERT="${CONFIG_DIR}/cert.pem"
    KEY="${CONFIG_DIR}/key.pem"
    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
            -days 3650 -nodes -subj "/CN=${domain}" 2>/dev/null
        chmod 600 "$KEY"
        info "TLS certificate generated"
    else
        info "TLS certificate reused"
    fi
}

# ── Free port 53 from systemd-resolved ─────────────────────────────
free_port_53() {
    if ss -ulnp 2>/dev/null | grep -q ":53 "; then
        info "Freeing port 53 from systemd-resolved..."
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' \
            > /etc/systemd/resolved.conf.d/picostream.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 1
        info "Port 53 freed"
    fi
}

# ── Generate UUID ───────────────────────────────────────────────────
gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    uuidgen 2>/dev/null || \
    openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/'
}

# ── Get public IP ───────────────────────────────────────────────────
get_public_ip() {
    curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
    curl -s4 --max-time 5 icanhazip.com 2>/dev/null || \
    hostname -I | awk '{print $1}'
}

# ══════════════════════════════════════════════════════════════════════
# EXIT SERVER INSTALLER
# ══════════════════════════════════════════════════════════════════════
install_exit() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}     PicoStream EXIT — Outside Server Setup          ${NC}"
    echo -e "${CYAN}     slipstream-server + shadowsocks-server          ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    detect_system
    install_base_deps

    # ── Input ────────────────────────────────────────────────────────
    step "Configuration"
    ask "Tunnel domain (e.g. s.hispeedvpn.org): "
    read -r TUNNEL_DOMAIN
    [[ -z "$TUNNEL_DOMAIN" ]] && err "Domain required"

    SS_PASSWORD=$(openssl rand -base64 24)
    SS_PORT=8388
    SS_METHOD="aes-256-gcm"
    SERVER_IP=$(get_public_ip)

    info "Server IP    : $SERVER_IP"
    info "SS password  : $SS_PASSWORD  (save this for relay setup)"
    info "SS method    : $SS_METHOD"

    free_port_53
    download_slipstream "server"
    generate_certs "$TUNNEL_DOMAIN"

    # ── Shadowsocks server ───────────────────────────────────────────
    step "Shadowsocks server"
    mkdir -p /etc/shadowsocks-libev
    SS_CONFIG="/etc/shadowsocks-libev/picostream.json"
    cat > "$SS_CONFIG" <<EOF
{
    "server": "127.0.0.1",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mode": "tcp_only",
    "timeout": 300,
    "fast_open": false
}
EOF

    cat > /etc/systemd/system/picostream-ss-server.service <<EOF
[Unit]
Description=PicoStream Shadowsocks Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ss-server -c ${SS_CONFIG}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-ss-server

[Install]
WantedBy=multi-user.target
EOF

    # ── slipstream-server ────────────────────────────────────────────
    step "slipstream-server"
    cat > /etc/systemd/system/picostream-exit.service <<EOF
[Unit]
Description=PicoStream EXIT — slipstream-server-plus
After=network.target picostream-ss-server.service

[Service]
Type=simple
ExecStart=/usr/local/bin/slipstream-server \
    --dns-listen-host 0.0.0.0 \
    --dns-listen-port 53 \
    --target-address 127.0.0.1:${SS_PORT} \
    --domain ${TUNNEL_DOMAIN} \
    --cert ${CERT} \
    --key  ${KEY}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-exit

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    for svc in picostream-ss-server picostream-exit; do
        systemctl enable "$svc" &>/dev/null
        systemctl restart "$svc"
        sleep 1
        systemctl is-active --quiet "$svc" && \
            info "$svc: Running" || warn "$svc: check logs"
    done

    # ── Save config ──────────────────────────────────────────────────
    mkdir -p "$CONFIG_DIR"
    cat > "${CONFIG_DIR}/exit.conf" <<EOF
SERVER_IP="${SERVER_IP}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
SS_PORT="${SS_PORT}"
SS_PASSWORD="${SS_PASSWORD}"
SS_METHOD="${SS_METHOD}"
CERT="${CERT}"
KEY="${KEY}"
EOF
    chmod 600 "${CONFIG_DIR}/exit.conf"

    # ── Management CLI ───────────────────────────────────────────────
    install_exit_cli

    # ── Result ───────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    systemctl is-active --quiet picostream-exit && \
        echo -e "${GREEN}║  ✓  EXIT server is RUNNING                               ║${NC}" || \
        echo -e "${RED}║  ✗  Check: picostream-exit logs                          ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Server IP    :${NC} ${YELLOW}${SERVER_IP}${NC}"
    echo -e "  ${BOLD}Domain       :${NC} ${CYAN}${TUNNEL_DOMAIN}${NC}"
    echo -e "  ${BOLD}SS password  :${NC} ${YELLOW}${SS_PASSWORD}${NC}"
    echo -e "  ${BOLD}SS method    :${NC} ${SS_METHOD}"
    echo ""
    echo -e "  ${BOLD}Run on RELAY server:${NC}"
    echo -e "  ${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/picostream.sh)${NC}"
    echo ""
    echo -e "  Relay will ask for:"
    echo -e "  → Tunnel domain : ${CYAN}${TUNNEL_DOMAIN}${NC}"
    echo -e "  → Exit IP       : ${CYAN}${SERVER_IP}${NC}"
    echo -e "  → SS password   : ${CYAN}${SS_PASSWORD}${NC}"
    echo ""
}

install_exit_cli() {
    cat > /usr/local/bin/picostream-exit <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/exit.conf ] && source /etc/picostream/exit.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream EXIT ===${N}"
        for svc in picostream-exit picostream-ss-server; do
            systemctl is-active --quiet "$svc" && \
                echo -e "  ${svc}: ${G}Running ✓${N}" || \
                echo -e "  ${svc}: ${R}Stopped ✗${N}"
        done
        echo -e "  Domain : ${C}${TUNNEL_DOMAIN}${N}"
        echo -e "  UDP:53 → 127.0.0.1:${SS_PORT} (shadowsocks)"
        echo "";;
    logs)
        echo "--- slipstream-server ---"
        journalctl -u picostream-exit -n 30 --no-pager
        echo "--- shadowsocks-server ---"
        journalctl -u picostream-ss-server -n 30 --no-pager;;
    restart)
        systemctl restart picostream-ss-server picostream-exit
        echo "Restarted";;
    stop)
        systemctl stop picostream-exit picostream-ss-server;;
    uninstall)
        systemctl stop picostream-exit picostream-ss-server 2>/dev/null || true
        systemctl disable picostream-exit picostream-ss-server 2>/dev/null || true
        rm -f /etc/systemd/system/picostream-exit.service
        rm -f /etc/systemd/system/picostream-ss-server.service
        rm -f /usr/local/bin/slipstream-server
        rm -f /usr/local/bin/picostream-exit
        rm -rf /etc/picostream
        systemctl daemon-reload
        echo "Removed.";;
    *) echo "picostream-exit [status|logs|restart|stop|uninstall]";;
esac
MGMT
    chmod +x /usr/local/bin/picostream-exit
}

# ══════════════════════════════════════════════════════════════════════
# RELAY SERVER INSTALLER
# ══════════════════════════════════════════════════════════════════════
install_relay() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}     PicoStream RELAY — Entry Server Setup           ${NC}"
    echo -e "${CYAN}     Xray (VLESS) + ss-local + slipstream-client     ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    detect_system
    install_base_deps

    # ── Input ────────────────────────────────────────────────────────
    step "Configuration"
    echo -e "  ${BOLD}Info from EXIT server output:${NC}"
    ask "  Tunnel domain (e.g. s.hispeedvpn.org): "
    read -r TUNNEL_DOMAIN
    [[ -z "$TUNNEL_DOMAIN" ]] && err "Domain required"

    ask "  Exit server IP: "
    read -r EXIT_IP
    [[ -z "$EXIT_IP" ]] && err "Exit IP required"

    ask "  SS password (from exit server output): "
    read -r SS_PASSWORD
    [[ -z "$SS_PASSWORD" ]] && err "SS password required"

    ask "  SS method (default: aes-256-gcm): "
    read -r SS_METHOD
    SS_METHOD="${SS_METHOD:-aes-256-gcm}"

    echo ""
    echo -e "  ${BOLD}DNS resolvers for tunnel:${NC}"
    echo -e "  ${CYAN}8.8.8.8,8.8.4.4${NC}  |  ${CYAN}1.1.1.1,8.8.8.8${NC}  |  or exit IP directly"
    ask "  Resolvers (default: 8.8.8.8,8.8.4.4): "
    read -r RESOLVERS_INPUT
    RESOLVERS_INPUT="${RESOLVERS_INPUT:-8.8.8.8,8.8.4.4}"

    echo ""
    echo -e "  ${BOLD}Entry port for users:${NC}"
    echo -e "  ${CYAN}443${NC}  |  ${CYAN}80${NC}  |  ${CYAN}8443${NC}  |  ${CYAN}2053${NC}"
    ask "  Entry port (default: 443): "
    read -r VLESS_PORT
    VLESS_PORT="${VLESS_PORT:-443}"

    VLESS_UUID=$(gen_uuid)
    RELAY_IP=$(get_public_ip)
    SS_SERVER_PORT=8388
    SLIP_SOCKS_PORT=10808
    SS_LOCAL_PORT=1080

    info "Relay IP      : $RELAY_IP"
    info "VLESS UUID    : $VLESS_UUID"
    info "Entry port    : $VLESS_PORT"
    info "Resolvers     : $RESOLVERS_INPUT"

    # ── Build resolver args ──────────────────────────────────────────
    RESOLVER_ARGS=""
    IFS=',' read -ra RES_ARR <<< "$RESOLVERS_INPUT"
    for r in "${RES_ARR[@]}"; do
        r=$(echo "$r" | tr -d ' ')
        [[ "$r" != *:* ]] && r="${r}:53"
        RESOLVER_ARGS="${RESOLVER_ARGS}    --resolver ${r} \\"$'\n'
    done

    # ── slipstream-client ────────────────────────────────────────────
    step "slipstream-client-plus"
    download_slipstream "client"

    cat > /etc/systemd/system/picostream-slipstream.service <<EOF
[Unit]
Description=PicoStream slipstream-client-plus
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/slipstream-client \\
${RESOLVER_ARGS}    --domain ${TUNNEL_DOMAIN} \\
    --tcp-listen-host 127.0.0.1 \\
    --tcp-listen-port ${SLIP_SOCKS_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-slipstream

[Install]
WantedBy=multi-user.target
EOF

    # ── ss-local ─────────────────────────────────────────────────────
    step "ss-local (Shadowsocks client)"
    mkdir -p "$CONFIG_DIR"
    SS_LOCAL_CONFIG="${CONFIG_DIR}/ss-local.json"
    cat > "$SS_LOCAL_CONFIG" <<EOF
{
    "server": "${EXIT_IP}",
    "server_port": ${SS_SERVER_PORT},
    "local_address": "127.0.0.1",
    "local_port": ${SS_LOCAL_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mode": "tcp_only",
    "timeout": 300
}
EOF

    cat > /etc/systemd/system/picostream-ss-local.service <<EOF
[Unit]
Description=PicoStream ss-local
After=network.target picostream-slipstream.service

[Service]
Type=simple
ExecStart=/usr/bin/ss-local -c ${SS_LOCAL_CONFIG} --socks5-proxy 127.0.0.1:${SLIP_SOCKS_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-ss-local

[Install]
WantedBy=multi-user.target
EOF

    # ── Xray ─────────────────────────────────────────────────────────
    step "Xray"
    if ! command -v xray &>/dev/null; then
        info "Downloading Xray..."
        TMP_DIR=$(mktemp -d)
        if [ "$ARCH" = "arm64" ]; then
            XURL="${XRAY_RELEASE}/Xray-linux-arm64-v8a.zip"
        else
            XURL="${XRAY_RELEASE}/Xray-linux-64.zip"
        fi
        curl -fsSL --max-time 120 "$XURL" -o "${TMP_DIR}/xray.zip" \
            || err "Xray download failed"
        unzip -q "${TMP_DIR}/xray.zip" -d "$TMP_DIR"
        mv "${TMP_DIR}/xray" /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        rm -rf "$TMP_DIR"
        info "Xray installed"
    else
        info "Xray already installed"
    fi

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": ${VLESS_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${VLESS_UUID}", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {"network": "tcp"}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "socks",
      "settings": {
        "servers": [{"address": "127.0.0.1", "port": ${SS_LOCAL_PORT}}]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF

    cat > /etc/systemd/system/picostream-xray.service <<EOF
[Unit]
Description=PicoStream Xray (VLESS)
After=network.target picostream-ss-local.service

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-xray

[Install]
WantedBy=multi-user.target
EOF

    # ── Firewall ─────────────────────────────────────────────────────
    iptables -I INPUT -p tcp --dport "${VLESS_PORT}" -j ACCEPT 2>/dev/null || true
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # ── Start services ───────────────────────────────────────────────
    step "Starting services"
    systemctl daemon-reload
    for svc in picostream-slipstream picostream-ss-local picostream-xray; do
        systemctl enable "$svc" &>/dev/null
        systemctl restart "$svc"
        sleep 1
        systemctl is-active --quiet "$svc" && \
            info "$svc: Running" || warn "$svc: check logs"
    done

    # ── Save config ──────────────────────────────────────────────────
    CLIENT_LINK="vless://${VLESS_UUID}@${RELAY_IP}:${VLESS_PORT}?security=none&type=tcp&encryption=none#PicoStream"

    cat > "${CONFIG_DIR}/relay.conf" <<EOF
RELAY_IP="${RELAY_IP}"
EXIT_IP="${EXIT_IP}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
VLESS_PORT="${VLESS_PORT}"
VLESS_UUID="${VLESS_UUID}"
SS_PASSWORD="${SS_PASSWORD}"
SS_METHOD="${SS_METHOD}"
RESOLVERS_INPUT="${RESOLVERS_INPUT}"
SLIP_SOCKS_PORT="${SLIP_SOCKS_PORT}"
SS_LOCAL_PORT="${SS_LOCAL_PORT}"
EOF
    chmod 600 "${CONFIG_DIR}/relay.conf"
    echo "$CLIENT_LINK" > "${CONFIG_DIR}/client_link.txt"

    # ── Management CLI ───────────────────────────────────────────────
    install_relay_cli

    # ── Result ───────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓  RELAY server setup complete!                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Traffic path:${NC}"
    echo -e "  User → VLESS:${VLESS_PORT} → Xray → ss-local → slipstream → DNS → exit → internet"
    echo ""
    echo -e "  ${BOLD}${YELLOW}Import this link in v2rayNG / Hiddify:${NC}"
    echo ""
    echo -e "  ${YELLOW}${CLIENT_LINK}${NC}"
    echo ""
    echo -e "  ${BOLD}Management:${NC} picostream-relay [status|logs|restart|link]"
    echo ""
}

install_relay_cli() {
    cat > /usr/local/bin/picostream-relay <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream RELAY ===${N}"
        for svc in picostream-xray picostream-ss-local picostream-slipstream; do
            systemctl is-active --quiet "$svc" && \
                echo -e "  $svc: ${G}Running ✓${N}" || \
                echo -e "  $svc: ${R}Stopped ✗${N}"
        done
        echo -e "  Users  → VLESS TCP:${VLESS_PORT}"
        echo -e "  Tunnel → DNS → ${C}${TUNNEL_DOMAIN}${N}"
        echo -e "  Resolvers: ${C}${RESOLVERS_INPUT}${N}"
        echo "";;
    logs)
        for svc in picostream-xray picostream-ss-local picostream-slipstream; do
            echo "--- $svc ---"
            journalctl -u "$svc" -n 20 --no-pager
        done;;
    restart)
        systemctl restart picostream-slipstream picostream-ss-local picostream-xray
        echo "All services restarted";;
    link)
        echo ""
        cat /etc/picostream/client_link.txt 2>/dev/null
        echo "";;
    uninstall)
        # shellcheck source=/dev/null
        [ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
        for svc in picostream-xray picostream-ss-local picostream-slipstream; do
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done
        rm -f /usr/local/bin/slipstream-client
        rm -f /usr/local/bin/xray
        rm -f /usr/local/bin/picostream-relay
        rm -rf /etc/picostream /usr/local/etc/xray
        systemctl daemon-reload
        echo "Removed.";;
    *) echo "picostream-relay [status|logs|restart|link|uninstall]";;
esac
MGMT
    chmod +x /usr/local/bin/picostream-relay
}

# ══════════════════════════════════════════════════════════════════════
# MAIN MENU
# ══════════════════════════════════════════════════════════════════════
clear
echo ""
echo -e "${CYAN}  ██████╗ ██╗ ██████╗ ██████╗ ███████╗████████╗██████╗ ███████╗ █████╗ ███╗   ███╗${NC}"
echo -e "${CYAN}  ██╔══██╗██║██╔════╝██╔═══██╗██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔══██╗████╗ ████║${NC}"
echo -e "${CYAN}  ██████╔╝██║██║     ██║   ██║███████╗   ██║   ██████╔╝█████╗  ███████║██╔████╔██║${NC}"
echo -e "${CYAN}  ██╔═══╝ ██║██║     ██║   ██║╚════██║   ██║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║${NC}"
echo -e "${CYAN}  ██║     ██║╚██████╗╚██████╔╝███████║   ██║   ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║${NC}"
echo -e "${CYAN}  ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝${NC}"
echo ""
echo -e "  ${BOLD}DNS Tunnel VPN  •  v${VERSION}  •  github.com/amir6dev/PicoStream${NC}"
echo ""
echo -e "${CYAN}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Architecture:${NC}"
echo -e "  User (VLESS) → ${CYAN}RELAY${NC} [Xray+ss-local+slipstream] → DNS:53 → ${CYAN}EXIT${NC} [slipstream+ss-server] → Internet"
echo ""
echo -e "  ${BOLD}Select role for this server:${NC}"
echo ""
echo -e "   ${GREEN}[1]${NC}  ${BOLD}EXIT server${NC}   — Outside server (main server, needs domain NS record)"
echo -e "               slipstream-server + shadowsocks-server"
echo ""
echo -e "   ${GREEN}[2]${NC}  ${BOLD}RELAY server${NC}  — Entry server (closer to users)"
echo -e "               Xray (VLESS) + ss-local + slipstream-client"
echo ""
echo -e "   ${RED}[0]${NC}  Exit"
echo ""
echo -e "${CYAN}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
ask "  Your choice [1/2/0]: "
read -r CHOICE
echo ""

case "$CHOICE" in
    1) install_exit ;;
    2) install_relay ;;
    0) echo "Bye."; exit 0 ;;
    *) err "Invalid choice: $CHOICE" ;;
esac
