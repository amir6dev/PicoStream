#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║        PicoStream RELAY — Server 1 (Entry / Restricted)         ║
# ║   Receives normal VLESS traffic, tunnels via DNS to exit server  ║
# ║              github.com/amir6dev/PicoStream                     ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  Run on your RELAY server (entry point for users)
#  bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)
#
#  Architecture:
#  User (VLESS) → relay:ENTRY_PORT → slipstream-client → DNS UDP:53 → exit:TUNNEL_PORT → 3x-ui

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

VERSION="1.2.0"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picostream"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_FILE="${CONFIG_DIR}/relay.conf"
CLIENT_BIN="${INSTALL_DIR}/slipstream-client"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"

info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC}   $1"; }
ask()  { echo -ne "${BLUE}[?]${NC}    $1"; }
step() { echo -e "\n${CYAN}━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

banner() {
cat <<'BANNER'

  ██████╗ ██╗ ██████╗ ██████╗ ███████╗████████╗██████╗ ███████╗ █████╗ ███╗   ███╗
  ██╔══██╗██║██╔════╝██╔═══██╗██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔══██╗████╗ ████║
  ██████╔╝██║██║     ██║   ██║███████╗   ██║   ██████╔╝█████╗  ███████║██╔████╔██║
  ██╔═══╝ ██║██║     ██║   ██║╚════██║   ██║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║
  ██║     ██║╚██████╗╚██████╔╝███████║   ██║   ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║
  ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝
BANNER
echo -e "  ${MAGENTA}RELAY SERVER (entry point)  |  v${VERSION}  |  PicoStream${NC}"
echo -e "  ${YELLOW}https://github.com/amir6dev/PicoStream${NC}\n"
}

detect_os() {
    [ -f /etc/os-release ] && source /etc/os-release || { err "Cannot detect OS"; exit 1; }
    OS_NAME="$NAME"
    command -v apt-get &>/dev/null && PKG="apt" || \
    command -v dnf     &>/dev/null && PKG="dnf" || \
    command -v yum     &>/dev/null && PKG="yum" || \
    { err "Unsupported package manager"; exit 1; }
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l)        ARCH="armv7" ;;
        *) err "Unsupported arch"; exit 1 ;;
    esac
    info "OS: $OS_NAME | Arch: $ARCH"
}

install_deps() {
    step "Dependencies"
    local miss=()
    for p in curl iptables; do command -v "$p" &>/dev/null || miss+=("$p"); done
    if [ ${#miss[@]} -gt 0 ]; then
        [ "$PKG" = "apt" ] && apt-get update -qq
        case "$PKG" in
            apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss[@]}" -qq ;;
            dnf|yum) $PKG install -y "${miss[@]}" ;;
        esac
    fi
    # libssl3 for client binary
    if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
        apt-get update -qq
        if ! apt-get install -y libssl3 2>/dev/null; then
            local url="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
            [ "$ARCH" = "arm64" ] && url="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
            curl -fsSL "$url" -o /tmp/libssl3.deb
            dpkg -i /tmp/libssl3.deb 2>/dev/null || true
            rm -f /tmp/libssl3.deb
        fi
    fi
    info "Dependencies OK"
}

gather_input() {
    step "Configuration"
    echo ""
    echo -e "  ${BOLD}EXIT server info (the outside server with 3x-ui):${NC}"
    echo ""
    ask "Exit server IP: "
    read -r EXIT_IP

    ask "Exit server DNS tunnel port (default: 53): "
    read -r EXIT_TUNNEL_PORT; EXIT_TUNNEL_PORT="${EXIT_TUNNEL_PORT:-53}"

    echo ""
    echo -e "  ${BOLD}3x-ui panel info (from your exit server):${NC}"
    echo ""
    ask "Protocol [vless/vmess/trojan] (default: vless): "
    read -r V2RAY_PROTOCOL; V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"
    ask "UUID: "
    read -r V2RAY_UUID
    ask "Extra params (from 3x-ui link, leave blank for default): "
    read -r V2RAY_PARAMS

    echo ""
    echo -e "  ${BOLD}Relay entry port:${NC}"
    echo -e "  This is the port your USERS connect to with v2rayNG/Hiddify."
    echo -e "  Choose a port that works in restricted networks:"
    echo -e "  ${CYAN}80${NC}  — HTTP  |  ${CYAN}443${NC} — HTTPS  |  ${CYAN}8080${NC} — alt  |  ${CYAN}2083${NC} — alt"
    echo ""
    ask "Entry port for users (default: 443): "
    read -r ENTRY_PORT; ENTRY_PORT="${ENTRY_PORT:-443}"

    # Internal port for slipstream-client TCP listener
    LOCAL_TCP_PORT=10808
    while ss -tlnp 2>/dev/null | grep -q ":${LOCAL_TCP_PORT} "; do
        LOCAL_TCP_PORT=$((LOCAL_TCP_PORT + 1))
    done
    info "Internal slipstream-client port: ${LOCAL_TCP_PORT}"

    echo ""
    ask "This relay server's public IP (blank = auto-detect): "
    read -r RELAY_IP
    [ -z "$RELAY_IP" ] && RELAY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    info "Relay server IP: ${RELAY_IP}"

    echo ""
    echo -e "  ${BOLD}DNS resolvers:${NC} (slipstream sends DNS queries through these)"
    echo -e "  Default: 1.1.1.1 and 8.8.8.8 (Cloudflare + Google)"
    echo -e "  These must be reachable from this server on UDP:53"
    RESOLVER1="1.1.1.1:53"
    RESOLVER2="8.8.8.8:53"
    info "Resolvers: ${RESOLVER1}  ${RESOLVER2}"
}

install_client() {
    step "Installing slipstream-client"
    # Try to get client binary (Fox-Fig deploy has it)
    local fname="slipstream-client-linux-${ARCH}"
    local url="${RELEASE_URL}/${fname}"
    info "Downloading: $url"
    if curl -fsSL --max-time 60 "$url" -o "${CLIENT_BIN}.tmp" 2>/dev/null; then
        mv "${CLIENT_BIN}.tmp" "$CLIENT_BIN"
        chmod +x "$CLIENT_BIN"
        info "slipstream-client installed"
    else
        err "Could not download slipstream-client binary."
        err "Try: https://github.com/Fox-Fig/slipstream-rust-deploy/releases"
        exit 1
    fi
}

setup_iptables() {
    step "iptables — TCP:${ENTRY_PORT} → 127.0.0.1:${LOCAL_TCP_PORT}"

    # Remove old rules
    iptables -t nat -D PREROUTING -p tcp --dport "${ENTRY_PORT}" \
        -j REDIRECT --to-port "${LOCAL_TCP_PORT}" 2>/dev/null || true

    # Redirect incoming TCP on ENTRY_PORT → slipstream-client local listener
    iptables -t nat -A PREROUTING -p tcp --dport "${ENTRY_PORT}" \
        -j REDIRECT --to-port "${LOCAL_TCP_PORT}"

    # Allow the entry port
    iptables -I INPUT -p tcp --dport "${ENTRY_PORT}" -j ACCEPT 2>/dev/null || true

    # Save
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # Restore on reboot
    cat > "${SYSTEMD_DIR}/picostream-relay-iptables.service" <<EOF
[Unit]
Description=PicoStream RELAY iptables
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable picostream-relay-iptables.service &>/dev/null
    info "iptables: TCP:${ENTRY_PORT} → :${LOCAL_TCP_PORT}"
}

create_service() {
    step "systemd service — slipstream-client"
    cat > "${SYSTEMD_DIR}/picostream-relay.service" <<EOF
[Unit]
Description=PicoStream RELAY — slipstream-client
After=network.target

[Service]
Type=simple
ExecStart=${CLIENT_BIN} \\
    --resolver ${RESOLVER1} \\
    --resolver ${RESOLVER2} \\
    --tcp-listen-host 0.0.0.0 \\
    --tcp-listen-port ${LOCAL_TCP_PORT} \\
    --server ${EXIT_IP}:${EXIT_TUNNEL_PORT}
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
    if systemctl is-active --quiet picostream-relay.service; then
        info "RELAY service running"
    else
        warn "Check: journalctl -u picostream-relay -n 30"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
RELAY_IP="${RELAY_IP}"
EXIT_IP="${EXIT_IP}"
EXIT_TUNNEL_PORT="${EXIT_TUNNEL_PORT}"
ENTRY_PORT="${ENTRY_PORT}"
LOCAL_TCP_PORT="${LOCAL_TCP_PORT}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
V2RAY_UUID="${V2RAY_UUID}"
V2RAY_PARAMS="${V2RAY_PARAMS}"
RESOLVER1="${RESOLVER1}"
RESOLVER2="${RESOLVER2}"
EOF
    chmod 600 "$CONFIG_FILE"
}

install_mgmt() {
    cat > /usr/local/bin/picostream-relay <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${BOLD}=== PicoStream RELAY Status ===${NC}"
        systemctl is-active --quiet picostream-relay && \
            echo -e "  Service      : ${GREEN}Running${NC}" || echo -e "  Service      : ${RED}Stopped${NC}"
        echo -e "  Entry port   : ${CYAN}TCP ${ENTRY_PORT}${NC} (users connect here)"
        echo -e "  Tunnel       : ${CYAN}DNS UDP → ${EXIT_IP}:${EXIT_TUNNEL_PORT}${NC}"
        echo ""
        ;;
    logs)    journalctl -u picostream-relay -n 80 -f ;;
    restart) systemctl restart picostream-relay && echo -e "${GREEN}Restarted${NC}" ;;
    link)    [ -f /etc/picostream/client_link.txt ] && cat /etc/picostream/client_link.txt ;;
    uninstall)
        systemctl stop picostream-relay 2>/dev/null; systemctl disable picostream-relay 2>/dev/null
        systemctl stop picostream-relay-iptables 2>/dev/null; systemctl disable picostream-relay-iptables 2>/dev/null
        # shellcheck source=/dev/null
        [ -f /etc/picostream/relay.conf ] && source /etc/picostream/relay.conf
        iptables -t nat -D PREROUTING -p tcp --dport "${ENTRY_PORT}" \
            -j REDIRECT --to-port "${LOCAL_TCP_PORT}" 2>/dev/null || true
        rm -f /etc/systemd/system/picostream-relay*.service
        rm -f /usr/local/bin/slipstream-client /usr/local/bin/picostream-relay
        rm -f /etc/picostream/relay.conf /etc/picostream/client_link.txt
        systemctl daemon-reload; echo "Removed."
        ;;
    *) echo "Usage: picostream-relay [status|logs|restart|link|uninstall]" ;;
esac
MGMT
    chmod +x /usr/local/bin/picostream-relay
}

generate_client_link() {
    step "Client connection link"

    local params="${V2RAY_PARAMS:-security=none&type=tcp&encryption=none}"
    local client_link=""

    case "$V2RAY_PROTOCOL" in
        vless)
            client_link="vless://${V2RAY_UUID}@${RELAY_IP}:${ENTRY_PORT}?${params}#PicoStream-Relay"
            ;;
        trojan)
            client_link="trojan://${V2RAY_UUID}@${RELAY_IP}:${ENTRY_PORT}?security=none&type=tcp#PicoStream-Relay"
            ;;
        vmess)
            local json="{\"v\":\"2\",\"ps\":\"PicoStream-Relay\",\"add\":\"${RELAY_IP}\",\"port\":\"${ENTRY_PORT}\",\"id\":\"${V2RAY_UUID}\",\"net\":\"tcp\",\"tls\":\"none\"}"
            client_link="vmess://$(echo "$json" | base64 -w0)"
            ;;
        *)
            client_link="vless://${V2RAY_UUID}@${RELAY_IP}:${ENTRY_PORT}?security=none&type=tcp&encryption=none#PicoStream-Relay"
            ;;
    esac

    cat > "${CONFIG_DIR}/client_link.txt" <<EOF
=======================================================
  PicoStream — User Connection Link
=======================================================

  Server  : ${RELAY_IP}:${ENTRY_PORT}  (relay entry)
  Protocol: ${V2RAY_PROTOCOL}
  UUID    : ${V2RAY_UUID}

  Traffic path:
  User → TCP:${ENTRY_PORT} → DNS tunnel (UDP:53) → 3x-ui on exit server

  Import this link in v2rayNG / Hiddify / NekoRay:
  ${client_link}

EOF

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        PicoStream RELAY — Setup Complete!              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Traffic path:${NC}"
    echo -e "  ${YELLOW}User${NC} → ${CYAN}TCP:${ENTRY_PORT}${NC} → ${YELLOW}relay${NC} → ${CYAN}DNS UDP:53${NC} → ${YELLOW}exit server${NC} → ${CYAN}3x-ui${NC} → Internet"
    echo ""
    echo -e "  ${BOLD}Client link (import in v2rayNG / Hiddify):${NC}"
    echo -e "  ${YELLOW}${client_link}${NC}"
    echo ""
    echo -e "  ${GREEN}Users connect with normal v2ray apps — no special client needed!${NC}"
    echo ""
    echo -e "  Management: ${CYAN}picostream-relay [status|logs|restart|link]${NC}"
    echo ""
}

main() {
    banner; detect_os; install_deps; gather_input
    install_client; setup_iptables
    save_config; create_service; install_mgmt; generate_client_link
}
main "$@"
