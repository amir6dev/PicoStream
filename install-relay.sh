#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║        PicoStream RELAY — سرور ایران (entry point)              ║
# ║        github.com/amir6dev/PicoStream                           ║
# ╚══════════════════════════════════════════════════════════════════╝
# bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)
#
# معماری:
# User (VLESS) → TCP:ENTRY_PORT → slipstream-client → DNS → exit server → 3x-ui

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root (sudo -i)" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -ne "${BLUE}[?]${NC} $1"; }

CLIENT_BIN="/usr/local/bin/slipstream-client"
CONFIG_DIR="/etc/picostream"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     PicoStream RELAY — Iran/Entry Server Setup      ${NC}"
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
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl iptables-persistent -qq 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl iptables -qq
elif [ "$PKG" = "dnf" ]; then
    dnf install -y curl iptables
elif [ "$PKG" = "yum" ]; then
    yum install -y curl iptables
fi

# libssl3
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
echo -e "  ${BOLD}اطلاعات از سرور خارج (exit server):${NC}"
ask "  Tunnel domain (e.g. t.example.com): "
read -r TUNNEL_DOMAIN
[[ -z "$TUNNEL_DOMAIN" ]] && err "Domain required"

ask "  UUID: "
read -r V2RAY_UUID
[[ -z "$V2RAY_UUID" ]] && err "UUID required"

ask "  Protocol [vless/vmess/trojan] (default: vless): "
read -r V2RAY_PROTOCOL
V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"

echo ""
echo -e "  ${BOLD}DNS resolvers:${NC}"
echo -e "  باید همون resolvers که روی exit زدی بزنی"
echo -e "  مثال: ${CYAN}8.8.8.8,8.8.4.4${NC}"
ask "  Resolvers (default: 8.8.8.8,8.8.4.4): "
read -r RESOLVERS_INPUT
RESOLVERS_INPUT="${RESOLVERS_INPUT:-8.8.8.8,8.8.4.4}"

echo ""
echo -e "  ${BOLD}Entry port${NC} — پورتی که کاربران بهش وصل می‌شن:"
echo -e "  ${CYAN}443${NC}  |  ${CYAN}80${NC}  |  ${CYAN}8443${NC}  |  ${CYAN}2053${NC}  |  هر پورت دیگه"
ask "  Entry port (default: 443): "
read -r ENTRY_PORT
ENTRY_PORT="${ENTRY_PORT:-443}"

RELAY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
           curl -s4 --max-time 5 icanhazip.com 2>/dev/null || \
           hostname -I | awk '{print $1}')
info "Relay IP: $RELAY_IP"

# ─── Download slipstream-client ───────────────────────────────────
info "Downloading slipstream-client..."
curl -fsSL --max-time 90 \
    "${RELEASE_URL}/slipstream-client-linux-${ARCH}" \
    -o "${CLIENT_BIN}.tmp" || err "Download failed"
mv "${CLIENT_BIN}.tmp" "$CLIENT_BIN"
chmod +x "$CLIENT_BIN"
info "slipstream-client installed"

# ─── Build resolver args ──────────────────────────────────────────
RESOLVER_ARGS=""
IFS=',' read -ra RES_ARR <<< "$RESOLVERS_INPUT"
for r in "${RES_ARR[@]}"; do
    r=$(echo "$r" | tr -d ' ')
    [[ "$r" != *:* ]] && r="${r}:53"
    RESOLVER_ARGS="${RESOLVER_ARGS}    --resolver ${r} \\"$'\n'
done
# remove trailing backslash-newline, add final args
RESOLVER_ARGS="${RESOLVER_ARGS}    --domain ${TUNNEL_DOMAIN} \\"$'\n'
RESOLVER_ARGS="${RESOLVER_ARGS}    --tcp-listen-host 0.0.0.0 \\"$'\n'
RESOLVER_ARGS="${RESOLVER_ARGS}    --tcp-listen-port ${ENTRY_PORT}"

# ─── Systemd service ─────────────────────────────────────────────
cat > /etc/systemd/system/picostream-relay.service <<EOF
[Unit]
Description=PicoStream RELAY — slipstream-client
After=network.target

[Service]
Type=simple
ExecStart=${CLIENT_BIN} \\
${RESOLVER_ARGS}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-relay

[Install]
WantedBy=multi-user.target
EOF

# ─── Firewall ────────────────────────────────────────────────────
iptables -I INPUT -p tcp --dport "${ENTRY_PORT}" -j ACCEPT 2>/dev/null || true
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

systemctl daemon-reload
systemctl enable picostream-relay.service &>/dev/null
systemctl restart picostream-relay.service
sleep 2

# ─── Save config ─────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
cat > "${CONFIG_DIR}/relay.conf" <<EOF
RELAY_IP="${RELAY_IP}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
ENTRY_PORT="${ENTRY_PORT}"
V2RAY_UUID="${V2RAY_UUID}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
RESOLVERS_INPUT="${RESOLVERS_INPUT}"
EOF
chmod 600 "${CONFIG_DIR}/relay.conf"

# ─── Build client link ───────────────────────────────────────────
case "$V2RAY_PROTOCOL" in
    vless)
        CLIENT_LINK="vless://${V2RAY_UUID}@${RELAY_IP}:${ENTRY_PORT}?security=none&type=tcp&encryption=none#PicoStream"
        ;;
    trojan)
        CLIENT_LINK="trojan://${V2RAY_UUID}@${RELAY_IP}:${ENTRY_PORT}?security=none&type=tcp#PicoStream"
        ;;
    vmess)
        JSON="{\"v\":\"2\",\"ps\":\"PicoStream\",\"add\":\"${RELAY_IP}\",\"port\":\"${ENTRY_PORT}\",\"id\":\"${V2RAY_UUID}\",\"net\":\"tcp\",\"tls\":\"none\"}"
        CLIENT_LINK="vmess://$(echo "$JSON" | base64 -w0)"
        ;;
    *)
        CLIENT_LINK="vless://${V2RAY_UUID}@${RELAY_IP}:${ENTRY_PORT}?security=none&type=tcp&encryption=none#PicoStream"
        ;;
esac
echo "$CLIENT_LINK" > "${CONFIG_DIR}/client_link.txt"

# ─── Management CLI ───────────────────────────────────────────────
cat > /usr/local/bin/picostream-relay <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream RELAY ===${N}"
        systemctl is-active --quiet picostream-relay && \
            echo -e "  Service  : ${G}Running ✓${N}" || echo -e "  Service  : ${R}Stopped ✗${N}"
        echo -e "  Users    → TCP:${ENTRY_PORT}"
        echo -e "  DNS      → ${C}${TUNNEL_DOMAIN}${N}"
        echo -e "  Resolver : ${C}${RESOLVERS_INPUT}${N}"
        echo "";;
    logs)    journalctl -u picostream-relay -n 60 -f ;;
    restart) systemctl restart picostream-relay && echo "Restarted" ;;
    link)
        echo ""
        # shellcheck source=/dev/null
        [ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
        echo -e "${B}Client link:${N}"
        cat /etc/picostream/client_link.txt 2>/dev/null
        echo "";;
    uninstall)
        # shellcheck source=/dev/null
        [ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
        systemctl stop picostream-relay 2>/dev/null || true
        systemctl disable picostream-relay 2>/dev/null || true
        rm -f /etc/systemd/system/picostream-relay.service
        rm -f /usr/local/bin/slipstream-client
        rm -f /usr/local/bin/picostream-relay
        rm -f /etc/picostream/relay.conf
        rm -f /etc/picostream/client_link.txt
        systemctl daemon-reload
        echo "Removed.";;
    *) echo "picostream-relay [status|logs|restart|link|uninstall]";;
esac
MGMT
chmod +x /usr/local/bin/picostream-relay

# ─── Result ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════════════╗${NC}"
if systemctl is-active --quiet picostream-relay.service; then
    echo -e "${GREEN}║  ✓  RELAY server is RUNNING                             ║${NC}"
else
    echo -e "${RED}║  ✗  Service failed — run: picostream-relay logs         ║${NC}"
fi
echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}مسیر traffic:${NC}"
echo -e "  ${YELLOW}User${NC} → ${CYAN}TCP:${ENTRY_PORT}${NC} → slipstream → ${CYAN}DNS${NC} → exit → ${CYAN}3x-ui${NC}"
echo ""
echo -e "  ${BOLD}${YELLOW}لینک کاربر (import در v2rayNG / Hiddify):${NC}"
echo ""
echo -e "  ${YELLOW}${CLIENT_LINK}${NC}"
echo ""
echo -e "  ${BOLD}Management:${NC} picostream-relay [status|logs|restart|link]"
echo ""
