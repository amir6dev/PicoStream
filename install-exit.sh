#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         PicoStream EXIT — سرور خارج (با 3x-ui)                 ║
# ║         github.com/amir6dev/PicoStream                          ║
# ╚══════════════════════════════════════════════════════════════════╝
# bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-exit.sh)

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root (sudo -i)" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -ne "${BLUE}[?]${NC} $1"; }

SLIPSTREAM_BIN="/usr/local/bin/slipstream-server"
CONFIG_DIR="/etc/picostream"
CERT="${CONFIG_DIR}/cert.pem"
KEY="${CONFIG_DIR}/key.pem"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     PicoStream EXIT — Outside Server Setup          ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─── Detect OS ───────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
    source /etc/os-release
else
    err "Cannot detect OS"
fi

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
info "OS: $NAME | Arch: $ARCH | PKG: $PKG"

# ─── Install deps ─────────────────────────────────────────────────
if [ "$PKG" = "apt" ]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl -qq
elif [ "$PKG" = "dnf" ]; then
    dnf install -y curl openssl
elif [ "$PKG" = "yum" ]; then
    yum install -y curl openssl
fi

# libssl3 (required by slipstream binary)
if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
    if ! apt-get install -y libssl3 2>/dev/null; then
        warn "libssl3 not in repos — downloading..."
        if [ "$ARCH" = "arm64" ]; then
            LIBSSL_URL="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
        else
            LIBSSL_URL="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
        fi
        curl -fsSL "$LIBSSL_URL" -o /tmp/libssl3.deb
        dpkg -i /tmp/libssl3.deb 2>/dev/null || true
        rm -f /tmp/libssl3.deb
    fi
    info "libssl3 ready"
fi

# ─── Input ────────────────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}3x-ui panel info:${NC}"
ask "  3x-ui inbound port (e.g. 443, 1400): "
read -r V2RAY_PORT
[[ -z "$V2RAY_PORT" ]] && err "Port required"

ask "  UUID: "
read -r V2RAY_UUID
[[ -z "$V2RAY_UUID" ]] && err "UUID required"

ask "  Protocol [vless/vmess/trojan] (default: vless): "
read -r V2RAY_PROTOCOL
V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"

echo ""
echo -e "  ${BOLD}Tunnel domain:${NC}"
echo -e "  This is the NS-delegated subdomain pointing to this server."
echo -e "  Example: ${CYAN}t.example.com${NC}"
ask "  Tunnel domain (e.g. t.example.com): "
read -r TUNNEL_DOMAIN
[[ -z "$TUNNEL_DOMAIN" ]] && err "Domain required"

echo ""
ask "  DNS resolvers (comma-separated, e.g. 8.8.8.8,8.8.4.4): "
read -r RESOLVERS_INPUT
RESOLVERS_INPUT="${RESOLVERS_INPUT:-8.8.8.8,8.8.4.4}"

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
            curl -s4 --max-time 5 icanhazip.com 2>/dev/null || \
            hostname -I | awk '{print $1}')
info "Server IP: $SERVER_IP"

# Verify 3x-ui port
if ss -tlnp 2>/dev/null | grep -q ":${V2RAY_PORT} "; then
    info "3x-ui port ${V2RAY_PORT} is listening ✓"
else
    warn "Port ${V2RAY_PORT} not detected — make sure 3x-ui inbound is enabled"
fi

# ─── Free port 53 ────────────────────────────────────────────────
if ss -ulnp 2>/dev/null | grep -q ":53 "; then
    info "Freeing port 53 from systemd-resolved..."
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/picostream.conf
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 1
fi

# ─── Download slipstream-server ───────────────────────────────────
info "Downloading slipstream-server..."
curl -fsSL --max-time 90 \
    "${RELEASE_URL}/slipstream-server-linux-${ARCH}" \
    -o "${SLIPSTREAM_BIN}.tmp" || err "Download failed"
mv "${SLIPSTREAM_BIN}.tmp" "$SLIPSTREAM_BIN"
chmod +x "$SLIPSTREAM_BIN"
info "slipstream-server installed"

# ─── TLS certs ───────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
        -days 3650 -nodes -subj "/CN=${TUNNEL_DOMAIN}" 2>/dev/null
    chmod 600 "$KEY"
    info "TLS certificates generated"
else
    info "TLS certificates reused"
fi

# ─── Build resolver args ──────────────────────────────────────────
RESOLVER_ARGS=""
IFS=',' read -ra RES_ARR <<< "$RESOLVERS_INPUT"
for r in "${RES_ARR[@]}"; do
    r=$(echo "$r" | tr -d ' ')
    # add :53 if no port specified
    [[ "$r" != *:* ]] && r="${r}:53"
    RESOLVER_ARGS="${RESOLVER_ARGS}    --resolver ${r} \\"$'\n'
done

# ─── Systemd service ─────────────────────────────────────────────
cat > /etc/systemd/system/picostream-exit.service <<EOF
[Unit]
Description=PicoStream EXIT — slipstream-server
After=network.target

[Service]
Type=simple
ExecStart=${SLIPSTREAM_BIN} \\
    --dns-listen-host 0.0.0.0 \\
    --dns-listen-port 53 \\
    --target-address 127.0.0.1:${V2RAY_PORT} \\
    --domain ${TUNNEL_DOMAIN} \\
    --cert ${CERT} \\
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
systemctl enable picostream-exit.service &>/dev/null
systemctl restart picostream-exit.service
sleep 2

# ─── Save config ─────────────────────────────────────────────────
cat > "${CONFIG_DIR}/exit.conf" <<EOF
SERVER_IP="${SERVER_IP}"
V2RAY_PORT="${V2RAY_PORT}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
V2RAY_UUID="${V2RAY_UUID}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
RESOLVERS_INPUT="${RESOLVERS_INPUT}"
CERT="${CERT}"
KEY="${KEY}"
EOF
chmod 600 "${CONFIG_DIR}/exit.conf"

# ─── Management CLI ───────────────────────────────────────────────
cat > /usr/local/bin/picostream-exit <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/exit.conf ] && source /etc/picostream/exit.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream EXIT ===${N}"
        systemctl is-active --quiet picostream-exit && \
            echo -e "  Service : ${G}Running ✓${N}" || echo -e "  Service : ${R}Stopped ✗${N}"
        echo -e "  UDP:53  → 127.0.0.1:${V2RAY_PORT} (3x-ui)"
        echo -e "  Domain  : ${C}${TUNNEL_DOMAIN}${N}"
        echo "";;
    logs)    journalctl -u picostream-exit -n 60 -f ;;
    restart) systemctl restart picostream-exit && echo "Restarted" ;;
    stop)    systemctl stop picostream-exit ;;
    uninstall)
        systemctl stop picostream-exit 2>/dev/null
        systemctl disable picostream-exit 2>/dev/null
        rm -f /etc/systemd/system/picostream-exit.service
        rm -f /usr/local/bin/slipstream-server
        rm -f /usr/local/bin/picostream-exit
        rm -rf /etc/picostream
        systemctl daemon-reload
        echo "Removed.";;
    *) echo "picostream-exit [status|logs|restart|stop|uninstall]";;
esac
MGMT
chmod +x /usr/local/bin/picostream-exit

# ─── Result ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════════════╗${NC}"
if systemctl is-active --quiet picostream-exit.service; then
    echo -e "${GREEN}║  ✓  EXIT server is RUNNING                              ║${NC}"
else
    echo -e "${RED}║  ✗  Service failed — run: picostream-exit logs          ║${NC}"
fi
echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Server IP     :${NC} ${YELLOW}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Tunnel domain :${NC} ${CYAN}${TUNNEL_DOMAIN}${NC}"
echo -e "  ${BOLD}Forwards to   :${NC} 127.0.0.1:${V2RAY_PORT}"
echo -e "  ${BOLD}UUID          :${NC} ${V2RAY_UUID}"
echo ""
echo -e "  ${BOLD}━━━ Cloudflare DNS Setup (اگه نزدی) ━━━━━━━━━━━━━━━━━━━${NC}"
TDOMAIN_BASE="${TUNNEL_DOMAIN#*.}"
TDOMAIN_SUB="${TUNNEL_DOMAIN%%.*}"
echo -e "  Type: A   | Name: ns1.${TDOMAIN_BASE}      | Value: ${SERVER_IP}"
echo -e "  Type: NS  | Name: ${TDOMAIN_SUB}.${TDOMAIN_BASE}  | Value: ns1.${TDOMAIN_BASE}"
echo ""
echo -e "  ${BOLD}━━━ Run on RELAY server (ایران) ━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)${NC}"
echo ""
echo -e "  Relay will ask for:"
echo -e "  → Tunnel domain : ${CYAN}${TUNNEL_DOMAIN}${NC}"
echo -e "  → UUID          : ${CYAN}${V2RAY_UUID}${NC}"
echo -e "  → Protocol      : ${CYAN}${V2RAY_PROTOCOL}${NC}"
echo -e "  → Resolvers     : ${CYAN}${RESOLVERS_INPUT}${NC}"
echo ""
