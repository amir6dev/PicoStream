#!/bin/bash
# PicoStream EXIT — سرور خارج (با 3x-ui)
# bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-exit.sh)
set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

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
DOMAIN_LABEL="tunnel.picostream.internal"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     PicoStream EXIT — Outside Server Setup          ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# OS + Arch
[ -f /etc/os-release ] && source /etc/os-release
command -v apt-get &>/dev/null && PKG="apt" || \
command -v dnf     &>/dev/null && PKG="dnf" || \
command -v yum     &>/dev/null && PKG="yum" || err "Unsupported package manager"
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    *) err "Unsupported arch: $(uname -m)" ;;
esac
info "OS: $NAME | Arch: $ARCH"

# Deps
[ "$PKG" = "apt" ] && apt-get update -qq
case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl -qq ;;
    dnf|yum) $PKG install -y curl openssl ;;
esac

# libssl3
if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
    if ! apt-get install -y libssl3 2>/dev/null; then
        warn "libssl3 not in repos — downloading directly..."
        URL="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
        [ "$ARCH" = "arm64" ] && URL="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
        curl -fsSL "$URL" -o /tmp/libssl3.deb && dpkg -i /tmp/libssl3.deb 2>/dev/null || true
        rm -f /tmp/libssl3.deb
    fi
fi

# Input
echo ""
ask "3x-ui inbound port (e.g. 443, 1400, 8443): "
read -r V2RAY_PORT
[[ -z "$V2RAY_PORT" ]] && err "Port required"

ask "UUID (از 3x-ui): "
read -r V2RAY_UUID
[[ -z "$V2RAY_UUID" ]] && err "UUID required"

ask "Protocol [vless/vmess/trojan] (default: vless): "
read -r V2RAY_PROTOCOL
V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
info "Server IP: $SERVER_IP"

# Check 3x-ui port
ss -tlnp 2>/dev/null | grep -q ":${V2RAY_PORT} " && \
    info "Port ${V2RAY_PORT} is listening ✓" || \
    warn "Port ${V2RAY_PORT} not detected — make sure 3x-ui inbound is ON"

# Free port 53
if ss -ulnp 2>/dev/null | grep -q ":53 "; then
    info "Freeing port 53 from systemd-resolved..."
    mkdir -p /etc/systemd/resolved.conf.d
    echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/picostream.conf
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 1
fi

# Download slipstream-server
info "Downloading slipstream-server (${ARCH})..."
curl -fsSL --max-time 90 "${RELEASE_URL}/slipstream-server-linux-${ARCH}" \
    -o "${SLIPSTREAM_BIN}.tmp" || err "Download failed"
mv "${SLIPSTREAM_BIN}.tmp" "$SLIPSTREAM_BIN"
chmod +x "$SLIPSTREAM_BIN"
info "slipstream-server installed"

# Certs
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
        -days 3650 -nodes -subj "/CN=picostream" 2>/dev/null
    chmod 600 "$KEY"
    info "TLS certificates generated"
else
    info "TLS certificates reused"
fi

# Systemd service
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
    --domain ${DOMAIN_LABEL} \\
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

# Save config
cat > "${CONFIG_DIR}/exit.conf" <<EOF
SERVER_IP="${SERVER_IP}"
V2RAY_PORT="${V2RAY_PORT}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
V2RAY_UUID="${V2RAY_UUID}"
DOMAIN_LABEL="${DOMAIN_LABEL}"
CERT="${CERT}"
KEY="${KEY}"
EOF
chmod 600 "${CONFIG_DIR}/exit.conf"

# Management CLI
cat > /usr/local/bin/picostream-exit <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/exit.conf ] && source /etc/picostream/exit.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream EXIT ===${N}"
        systemctl is-active --quiet picostream-exit && \
            echo -e "  Service : ${G}Running ✓${N}" || echo -e "  Service : ${R}Stopped${N}"
        echo -e "  UDP 53  → 127.0.0.1:${V2RAY_PORT} (3x-ui)"
        echo -e "  Domain  : ${C}${DOMAIN_LABEL}${N}"
        echo "";;
    logs)    journalctl -u picostream-exit -n 60 -f ;;
    restart) systemctl restart picostream-exit && echo "Restarted" ;;
    stop)    systemctl stop picostream-exit ;;
    uninstall)
        systemctl stop picostream-exit 2>/dev/null; systemctl disable picostream-exit 2>/dev/null
        rm -f /etc/systemd/system/picostream-exit.service
        rm -f /usr/local/bin/slipstream-server /usr/local/bin/picostream-exit
        rm -rf /etc/picostream; systemctl daemon-reload; echo "Removed.";;
    *) echo "picostream-exit [status|logs|restart|stop|uninstall]";;
esac
MGMT
chmod +x /usr/local/bin/picostream-exit

# Result
echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════════════╗${NC}"
systemctl is-active --quiet picostream-exit.service && \
    echo -e "${GREEN}║  ✓  EXIT server is RUNNING                              ║${NC}" || \
    echo -e "${RED}║  ✗  Service failed — check logs                         ║${NC}"
echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Exit server IP   :${NC} ${YELLOW}${SERVER_IP}${NC}"
echo -e "  ${BOLD}Listens on       :${NC} UDP:53"
echo -e "  ${BOLD}Forwards to      :${NC} 127.0.0.1:${V2RAY_PORT} (3x-ui)"
echo -e "  ${BOLD}Domain label     :${NC} ${CYAN}${DOMAIN_LABEL}${NC}"
echo ""
echo -e "  ${BOLD}━━━ Now run on RELAY server (ایران) ━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)${NC}"
echo ""
echo -e "  Relay will ask for:"
echo -e "  → Exit IP   : ${CYAN}${SERVER_IP}${NC}"
echo -e "  → UUID      : ${CYAN}${V2RAY_UUID}${NC}"
echo -e "  → Protocol  : ${CYAN}${V2RAY_PROTOCOL}${NC}"
echo ""
echo -e "  ${BOLD}Management:${NC} picostream-exit [status|logs|restart]"
echo ""
