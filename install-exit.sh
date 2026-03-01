#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         PicoStream EXIT — Server 2 (Outside / Free)             ║
# ║   Runs slipstream-server + forwards to your 3x-ui panel         ║
# ║              github.com/amir6dev/PicoStream                     ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  Run on your OUTSIDE server (the one with 3x-ui)
#  bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-exit.sh)

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

VERSION="1.2.0"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picostream"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_FILE="${CONFIG_DIR}/exit.conf"
SLIPSTREAM_BIN="${INSTALL_DIR}/slipstream-server"
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
echo -e "  ${MAGENTA}EXIT SERVER (outside)  |  v${VERSION}  |  PicoStream${NC}"
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
    for p in curl openssl; do command -v "$p" &>/dev/null || miss+=("$p"); done
    if [ ${#miss[@]} -gt 0 ]; then
        [ "$PKG" = "apt" ] && apt-get update -qq
        case "$PKG" in
            apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "${miss[@]}" -qq ;;
            dnf|yum) $PKG install -y "${miss[@]}" ;;
        esac
    fi
    # libssl3
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

parse_v2ray_link() {
    local link="$1"
    if [[ "$link" =~ ^vless:// ]]; then
        V2RAY_PROTOCOL="vless"
        local body="${link#vless://}"
        V2RAY_UUID="${body%%@*}"
        local rest="${body#*@}"; local hp="${rest%%\?*}"
        V2RAY_PORT="${hp##*:}"
        V2RAY_PARAMS="${rest#*\?}"; V2RAY_PARAMS="${V2RAY_PARAMS%%#*}"
        return 0
    elif [[ "$link" =~ ^vmess:// ]]; then
        V2RAY_PROTOCOL="vmess"
        local b64="${link#vmess://}"; b64="${b64%%#*}"
        local json; json=$(echo "$b64" | base64 -d 2>/dev/null) || return 1
        V2RAY_UUID=$(echo "$json" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        V2RAY_PORT=$(echo "$json" | grep -o '"port":[0-9]*' | head -1 | grep -o '[0-9]*')
        V2RAY_PARAMS=""; return 0
    elif [[ "$link" =~ ^trojan:// ]]; then
        V2RAY_PROTOCOL="trojan"
        local body="${link#trojan://}"
        V2RAY_UUID="${body%%@*}"
        local rest="${body#*@}"; local hp="${rest%%\?*}"
        V2RAY_PORT="${hp##*:}"
        V2RAY_PARAMS="${rest#*\?}"; V2RAY_PARAMS="${V2RAY_PARAMS%%#*}"
        return 0
    fi
    return 1
}

gather_input() {
    step "Configuration"
    echo ""
    echo -e "  ${BOLD}Step 1 — 3x-ui V2Ray config${NC}"
    echo -e "  ${CYAN}1)${NC} Paste V2Ray link  ${CYAN}2)${NC} Enter manually"
    echo ""
    ask "Choose [1/2] (default: 1): "
    read -r MODE; MODE="${MODE:-1}"

    if [ "$MODE" = "1" ]; then
        ask "Paste V2Ray link: "; read -r LINK
        if parse_v2ray_link "$LINK"; then
            info "Parsed -> ${V2RAY_PROTOCOL} | port ${V2RAY_PORT} | UUID ${V2RAY_UUID:0:8}..."
        else
            warn "Cannot parse — switching to manual."
            MODE="2"
        fi
    fi
    if [ "$MODE" = "2" ]; then
        ask "3x-ui inbound port: "; read -r V2RAY_PORT
        ask "Protocol [vless/vmess/trojan]: "; read -r V2RAY_PROTOCOL; V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"
        ask "UUID: "; read -r V2RAY_UUID
        V2RAY_PARAMS=""
    fi

    if ss -tlnp 2>/dev/null | grep -q ":${V2RAY_PORT} "; then
        info "Port ${V2RAY_PORT} is listening. OK"
    else
        warn "Port ${V2RAY_PORT} not detected. Make sure 3x-ui is running."
    fi

    echo ""
    echo -e "  ${BOLD}Step 2 — DNS listen port${NC}"
    echo -e "  slipstream-server listens on UDP (relay server connects here)"
    ask "DNS tunnel port (default: 53): "
    read -r TUNNEL_PORT; TUNNEL_PORT="${TUNNEL_PORT:-53}"

    echo ""
    ask "This server's public IP (blank = auto-detect): "
    read -r SERVER_IP
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    info "Exit server IP: ${SERVER_IP}"
}

install_slipstream() {
    step "Installing slipstream-server"
    local fname="slipstream-server-linux-${ARCH}"
    info "Downloading: ${RELEASE_URL}/${fname}"
    curl -fsSL --max-time 60 "${RELEASE_URL}/${fname}" -o "${SLIPSTREAM_BIN}.tmp"
    mv "${SLIPSTREAM_BIN}.tmp" "$SLIPSTREAM_BIN"
    chmod +x "$SLIPSTREAM_BIN"
    info "Installed: $SLIPSTREAM_BIN"
}

generate_certs() {
    step "TLS certificates"
    mkdir -p "$CONFIG_DIR"
    CERT_FILE="${CONFIG_DIR}/cert.pem"; KEY_FILE="${CONFIG_DIR}/key.pem"
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then info "Reusing existing certs"; return; fi
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -days 3650 -nodes -subj "/CN=picostream-exit" 2>/dev/null
    chmod 600 "$KEY_FILE"
    info "Certificates generated"
}

free_port53() {
    if [ "$TUNNEL_PORT" = "53" ] && ss -ulnp 2>/dev/null | grep -q ":53 "; then
        info "Freeing port 53 from systemd-resolved..."
        mkdir -p /etc/systemd/resolved.conf.d
        echo -e "[Resolve]\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/picostream.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 1
    fi
}

create_service() {
    step "systemd service"
    cat > "${SYSTEMD_DIR}/picostream-exit.service" <<EOF
[Unit]
Description=PicoStream EXIT — slipstream-server
After=network.target

[Service]
Type=simple
ExecStart=${SLIPSTREAM_BIN} \\
    --dns-listen-host 0.0.0.0 \\
    --dns-listen-port ${TUNNEL_PORT} \\
    --target-address 127.0.0.1:${V2RAY_PORT} \\
    --cert ${CERT_FILE} \\
    --key  ${KEY_FILE}
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
    if systemctl is-active --quiet picostream-exit.service; then
        info "EXIT service running"
    else
        warn "Check logs: journalctl -u picostream-exit -n 30"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
SERVER_IP="${SERVER_IP}"
V2RAY_PORT="${V2RAY_PORT}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
V2RAY_UUID="${V2RAY_UUID}"
V2RAY_PARAMS="${V2RAY_PARAMS}"
TUNNEL_PORT="${TUNNEL_PORT}"
CERT_FILE="${CERT_FILE}"
KEY_FILE="${KEY_FILE}"
EOF
    chmod 600 "$CONFIG_FILE"
}

install_mgmt() {
    cat > /usr/local/bin/picostream-exit <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
[ -f /etc/picostream/exit.conf ] && source /etc/picostream/exit.conf
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
case "${1:-status}" in
    status)
        echo -e "\n${BOLD}=== PicoStream EXIT Status ===${NC}"
        systemctl is-active --quiet picostream-exit && \
            echo -e "  Service : ${GREEN}Running${NC}" || echo -e "  Service : ${RED}Stopped${NC}"
        echo -e "  UDP port: ${CYAN}${TUNNEL_PORT}${NC} (slipstream-server)"
        echo -e "  3x-ui   : ${CYAN}127.0.0.1:${V2RAY_PORT}${NC}"
        echo ""
        ;;
    logs)   journalctl -u picostream-exit -n 80 -f ;;
    restart) systemctl restart picostream-exit && echo -e "${GREEN}Restarted${NC}" ;;
    stop)    systemctl stop    picostream-exit && echo -e "${YELLOW}Stopped${NC}" ;;
    uninstall)
        systemctl stop picostream-exit 2>/dev/null; systemctl disable picostream-exit 2>/dev/null
        rm -f /etc/systemd/system/picostream-exit.service /usr/local/bin/slipstream-server
        rm -f /usr/local/bin/picostream-exit; rm -rf /etc/picostream; systemctl daemon-reload
        echo "Removed."
        ;;
    *) echo "Usage: picostream-exit [status|logs|restart|stop|uninstall]" ;;
esac
MGMT
    chmod +x /usr/local/bin/picostream-exit
}

show_result() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         PicoStream EXIT — Setup Complete!              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Exit server IP   :${NC} ${SERVER_IP}"
    echo -e "  ${CYAN}slipstream port  :${NC} ${YELLOW}UDP ${TUNNEL_PORT}${NC}  (relay connects here)"
    echo -e "  ${CYAN}3x-ui forwarding :${NC} → 127.0.0.1:${V2RAY_PORT}"
    echo ""
    echo -e "  ${BOLD}Now install the RELAY server:${NC}"
    echo -e "  On your relay/entry server run:"
    echo -e "  ${YELLOW}bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)${NC}"
    echo ""
    echo -e "  ${BOLD}Relay will ask for:${NC}"
    echo -e "   - Exit server IP   : ${CYAN}${SERVER_IP}${NC}"
    echo -e "   - slipstream port  : ${CYAN}${TUNNEL_PORT}${NC}"
    echo -e "   - V2Ray UUID       : ${CYAN}${V2RAY_UUID}${NC}"
    echo -e "   - Protocol         : ${CYAN}${V2RAY_PROTOCOL}${NC}"
    echo ""
    echo -e "  Management: ${CYAN}picostream-exit [status|logs|restart]${NC}"
    echo ""
}

main() {
    banner; detect_os; install_deps; gather_input
    install_slipstream; generate_certs; free_port53
    save_config; create_service; install_mgmt; show_result
}
main "$@"
