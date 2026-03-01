#!/bin/bash
# PicoStream RELAY — سرور ایران (entry point)
# bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)
#
# معماری:
# کاربر (VLESS) → TCP:ENTRY_PORT → iptables → slipstream-client:10808 → DNS UDP:53 → EXIT → 3x-ui
set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -ne "${BLUE}[?]${NC} $1"; }

CLIENT_BIN="/usr/local/bin/slipstream-client"
CONFIG_DIR="/etc/picostream"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"
DOMAIN_LABEL="tunnel.picostream.internal"
LOCAL_PORT=10808

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     PicoStream RELAY — Iran/Entry Server Setup      ${NC}"
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
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y curl iptables -qq ;;
    dnf|yum) $PKG install -y curl iptables ;;
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
ask "Exit server IP (IP سرور خارج): "
read -r EXIT_IP
[[ -z "$EXIT_IP" ]] && err "Exit IP required"

echo ""
echo -e "  ${BOLD}Entry port${NC} — پورتی که کاربران بهش وصل می‌شن:"
echo -e "  ${CYAN}443${NC}  |  ${CYAN}80${NC}  |  ${CYAN}8443${NC}  |  هر پورت دیگه"
ask "Entry port (default: 443): "
read -r ENTRY_PORT
ENTRY_PORT="${ENTRY_PORT:-443}"

ask "UUID (همون UUID 3x-ui): "
read -r V2RAY_UUID
[[ -z "$V2RAY_UUID" ]] && err "UUID required"

ask "Protocol [vless/vmess/trojan] (default: vless): "
read -r V2RAY_PROTOCOL
V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"

RELAY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
info "Relay IP: $RELAY_IP"

# Download slipstream-client
info "Downloading slipstream-client (${ARCH})..."
curl -fsSL --max-time 90 "${RELEASE_URL}/slipstream-client-linux-${ARCH}" \
    -o "${CLIENT_BIN}.tmp" || err "Download failed. Check: ${RELEASE_URL}"
mv "${CLIENT_BIN}.tmp" "$CLIENT_BIN"
chmod +x "$CLIENT_BIN"
info "slipstream-client installed"

# iptables: TCP ENTRY_PORT → LOCAL_PORT
info "Setting up iptables: TCP:${ENTRY_PORT} → :${LOCAL_PORT}"
iptables -t nat -D PREROUTING -p tcp --dport "${ENTRY_PORT}" \
    -j REDIRECT --to-port "${LOCAL_PORT}" 2>/dev/null || true
iptables -t nat -A PREROUTING -p tcp --dport "${ENTRY_PORT}" \
    -j REDIRECT --to-port "${LOCAL_PORT}"
iptables -I INPUT -p tcp --dport "${ENTRY_PORT}" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport "${LOCAL_PORT}" -j ACCEPT 2>/dev/null || true

# Persist iptables
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
cat > /etc/systemd/system/picostream-relay-iptables.service <<EOF
[Unit]
Description=PicoStream iptables restore
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable picostream-relay-iptables.service &>/dev/null

# Systemd service for slipstream-client
cat > /etc/systemd/system/picostream-relay.service <<EOF
[Unit]
Description=PicoStream RELAY — slipstream-client
After=network.target

[Service]
Type=simple
ExecStart=${CLIENT_BIN} \\
    --resolver ${EXIT_IP}:53 \\
    --domain ${DOMAIN_LABEL} \\
    --tcp-listen-host 0.0.0.0 \\
    --tcp-listen-port ${LOCAL_PORT}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream-relay

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable picostream-relay.service &>/dev/null
systemctl restart picostream-relay.service
sleep 2

# Save config
mkdir -p "$CONFIG_DIR"
cat > "${CONFIG_DIR}/relay.conf" <<EOF
RELAY_IP="${RELAY_IP}"
EXIT_IP="${EXIT_IP}"
ENTRY_PORT="${ENTRY_PORT}"
LOCAL_PORT="${LOCAL_PORT}"
V2RAY_UUID="${V2RAY_UUID}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
DOMAIN_LABEL="${DOMAIN_LABEL}"
EOF
chmod 600 "${CONFIG_DIR}/relay.conf"

# Build client link
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

# Management CLI
cat > /usr/local/bin/picostream-relay <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; Y='\033[1;33m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream RELAY ===${N}"
        systemctl is-active --quiet picostream-relay && \
            echo -e "  Service    : ${G}Running ✓${N}" || echo -e "  Service    : ${R}Stopped${N}"
        echo -e "  Users      → TCP:${ENTRY_PORT} (entry)"
        echo -e "  Tunnel     → UDP:53 → ${C}${EXIT_IP}${N}"
        echo "";;
    logs)    journalctl -u picostream-relay -n 60 -f ;;
    restart) systemctl restart picostream-relay && echo "Restarted" ;;
    link)
        echo ""
        echo -e "${B}Client link:${N}"
        cat /etc/picostream/client_link.txt
        echo "";;
    uninstall)
        # shellcheck source=/dev/null
        [ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
        systemctl stop picostream-relay picostream-relay-iptables 2>/dev/null || true
        systemctl disable picostream-relay picostream-relay-iptables 2>/dev/null || true
        iptables -t nat -D PREROUTING -p tcp --dport "${ENTRY_PORT}" \
            -j REDIRECT --to-port "${LOCAL_PORT}" 2>/dev/null || true
        rm -f /etc/systemd/system/picostream-relay*.service
        rm -f /usr/local/bin/slipstream-client /usr/local/bin/picostream-relay
        rm -f /etc/picostream/relay.conf /etc/picostream/client_link.txt
        systemctl daemon-reload; echo "Removed.";;
    *) echo "picostream-relay [status|logs|restart|link|uninstall]";;
esac
MGMT
chmod +x /usr/local/bin/picostream-relay

# Final output
echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════════════╗${NC}"
systemctl is-active --quiet picostream-relay.service && \
    echo -e "${GREEN}║  ✓  RELAY server is RUNNING                             ║${NC}" || \
    echo -e "${RED}║  ✗  Service failed — run: picostream-relay logs         ║${NC}"
echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Traffic flow:${NC}"
echo -e "  ${YELLOW}User${NC} → ${CYAN}TCP:${ENTRY_PORT}${NC} → relay → ${CYAN}DNS UDP:53${NC} → ${EXIT_IP} → 3x-ui → Internet"
echo ""
echo -e "  ${BOLD}${YELLOW}Import this link in v2rayNG / Hiddify:${NC}"
echo -e ""
echo -e "  ${YELLOW}${CLIENT_LINK}${NC}"
echo ""
echo -e "  ${BOLD}Management:${NC} picostream-relay [status|logs|restart|link]"
echo ""
