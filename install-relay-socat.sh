#!/bin/bash
# PicoStream TCP Relay — Simple socat forwarder
# Server 1 (entry) → forwards TCP to Server 2 (3x-ui)
# No DNS tunnel needed — pure TCP relay

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -ne "${BLUE}[?]${NC} $1"; }

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}     PicoStream TCP Relay — socat forwarder          ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Traffic: User → ${CYAN}TCP:LISTEN_PORT${NC} → relay → ${CYAN}TCP:TARGET_PORT${NC} → 3x-ui"
echo ""

# ─── Install socat ────────────────────────────────────────────────
if ! command -v socat &>/dev/null; then
    info "Installing socat..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y socat -qq
    elif command -v dnf &>/dev/null; then
        dnf install -y socat
    elif command -v yum &>/dev/null; then
        yum install -y socat
    else
        err "Cannot install socat — install manually: apt-get install socat"
    fi
fi
info "socat $(socat -V 2>&1 | head -1 | grep -o '[0-9.]*' | head -1) ready"

# ─── Input ────────────────────────────────────────────────────────
ask "Target server IP (3x-ui server): "
read -r TARGET_IP
[[ -z "$TARGET_IP" ]] && err "Target IP required"

ask "Target port on 3x-ui server (e.g. 443, 1400): "
read -r TARGET_PORT
[[ -z "$TARGET_PORT" ]] && err "Target port required"

ask "Listen port on THIS server (users connect here, default: ${TARGET_PORT}): "
read -r LISTEN_PORT
LISTEN_PORT="${LISTEN_PORT:-$TARGET_PORT}"

RELAY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
           hostname -I | awk '{print $1}')
info "Relay IP: $RELAY_IP"
info "Forwarding: ${RELAY_IP}:${LISTEN_PORT} → ${TARGET_IP}:${TARGET_PORT}"

# ─── Remove old rules ────────────────────────────────────────────
if [ -f /etc/systemd/system/picostream-relay.service ]; then
    systemctl stop picostream-relay.service 2>/dev/null || true
fi

# ─── Firewall ────────────────────────────────────────────────────
iptables -I INPUT -p tcp --dport "${LISTEN_PORT}" -j ACCEPT 2>/dev/null || true
info "Opened TCP:${LISTEN_PORT} in iptables"

# ─── Systemd service ─────────────────────────────────────────────
cat > /etc/systemd/system/picostream-relay.service <<EOF
[Unit]
Description=PicoStream TCP Relay (socat)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${LISTEN_PORT},fork,reuseaddr TCP:${TARGET_IP}:${TARGET_PORT}
Restart=always
RestartSec=3
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

# ─── Save config ─────────────────────────────────────────────────
mkdir -p /etc/picostream
cat > /etc/picostream/relay.conf <<EOF
RELAY_IP="${RELAY_IP}"
TARGET_IP="${TARGET_IP}"
TARGET_PORT="${TARGET_PORT}"
LISTEN_PORT="${LISTEN_PORT}"
EOF

# ─── Management CLI ───────────────────────────────────────────────
cat > /usr/local/bin/picostream-relay <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${B}=== PicoStream TCP Relay ===${N}"
        systemctl is-active --quiet picostream-relay && \
            echo -e "  Service : ${G}Running ✓${N}" || \
            echo -e "  Service : ${R}Stopped ✗${N}"
        echo -e "  Forward : TCP:${LISTEN_PORT} → ${C}${TARGET_IP}:${TARGET_PORT}${N}"
        echo "";;
    logs)    journalctl -u picostream-relay -n 60 -f ;;
    restart) systemctl restart picostream-relay && echo "Restarted" ;;
    stop)    systemctl stop picostream-relay ;;
    uninstall)
        # shellcheck source=/dev/null
        [ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
        systemctl stop picostream-relay 2>/dev/null || true
        systemctl disable picostream-relay 2>/dev/null || true
        rm -f /etc/systemd/system/picostream-relay.service
        rm -f /usr/local/bin/picostream-relay
        rm -f /etc/picostream/relay.conf
        systemctl daemon-reload
        echo "Removed.";;
    *) echo "picostream-relay [status|logs|restart|stop|uninstall]";;
esac
MGMT
chmod +x /usr/local/bin/picostream-relay

# ─── Result ───────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
if systemctl is-active --quiet picostream-relay.service; then
    echo -e "${GREEN}║  ✓  TCP Relay is RUNNING                             ║${NC}"
else
    echo -e "${RED}║  ✗  Service failed — run: picostream-relay logs      ║${NC}"
fi
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Relay   :${NC} ${RELAY_IP}:${LISTEN_PORT}"
echo -e "  ${BOLD}Target  :${NC} ${TARGET_IP}:${TARGET_PORT} (3x-ui)"
echo ""

# Get UUID and protocol from 3x-ui config if possible
echo -e "  ${BOLD}Client link — get UUID from 3x-ui panel, then use:${NC}"
echo -e "  ${YELLOW}vless://YOUR_UUID@${RELAY_IP}:${LISTEN_PORT}?security=none&type=tcp&encryption=none#PicoStream${NC}"
echo ""
echo -e "  Management: picostream-relay [status|logs|restart]"
echo ""
