#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║           PicoStream — DNS Tunnel Layer for 3x-ui / V2Ray       ║
# ║      Wraps your V2Ray panel with a Slipstream DNS tunnel         ║
# ║                 github.com/amir6dev/PicoStream                   ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  How it works:
#  Client → DNS queries (1.1.1.1/8.8.8.8) → Your domain NS → slipstream-server → 3x-ui
#
#  Install:
#  bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install.sh)

set -e

[[ $EUID -ne 0 ]] && echo -e "\033[0;31m[ERROR]\033[0m Run as root (sudo -i)" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

VERSION="1.1.0"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/picostream"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_FILE="${CONFIG_DIR}/picostream.conf"
SLIPSTREAM_BIN="${INSTALL_DIR}/slipstream-server"
SCRIPT_CMD="/usr/local/bin/picostream"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()   { echo -e "${RED}[ERR]${NC}   $1"; }
ask()   { echo -ne "${BLUE}[?]${NC}    $1"; }
step()  { echo -e "\n${CYAN}━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

banner() {
cat <<'BANNER'

  ██████╗ ██╗ ██████╗ ██████╗ ███████╗████████╗██████╗ ███████╗ █████╗ ███╗   ███╗
  ██╔══██╗██║██╔════╝██╔═══██╗██╔════╝╚══██╔══╝██╔══██╗██╔════╝██╔══██╗████╗ ████║
  ██████╔╝██║██║     ██║   ██║███████╗   ██║   ██████╔╝█████╗  ███████║██╔████╔██║
  ██╔═══╝ ██║██║     ██║   ██║╚════██║   ██║   ██╔══██╗██╔══╝  ██╔══██║██║╚██╔╝██║
  ██║     ██║╚██████╗╚██████╔╝███████║   ██║   ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║
  ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝
BANNER
echo -e "  ${MAGENTA}DNS Tunnel -> 3x-ui / V2Ray  |  v${VERSION}  |  amir6dev${NC}"
echo -e "  ${YELLOW}https://github.com/amir6dev/PicoStream${NC}\n"
}

# ─── OS & Architecture ────────────────────────────────────────────────────────
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
        *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    info "OS: $OS_NAME | Arch: $ARCH | Package manager: $PKG"
}

pkg_install() {
    case "$PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" -qq ;;
        dnf|yum) $PKG install -y "$@" ;;
    esac
}

check_deps() {
    step "Checking dependencies"
    local miss=()
    for p in curl openssl iptables; do
        command -v "$p" &>/dev/null || miss+=("$p")
    done
    if [ ${#miss[@]} -gt 0 ]; then
        info "Installing: ${miss[*]}"
        [ "$PKG" = "apt" ] && apt-get update -qq
        pkg_install "${miss[@]}"
    fi

    # Slipstream requires libssl.so.3 (OpenSSL 3.x)
    # Ubuntu 22.04+ has it; Ubuntu 20.04 needs manual install
    if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
        info "Installing libssl3 (required by Slipstream)..."
        apt-get update -qq
        if ! apt-get install -y libssl3 2>/dev/null; then
            warn "libssl3 not in repos (Ubuntu 20.04). Downloading .deb directly..."
            local libssl_deb="/tmp/libssl3.deb"
            local libssl_url="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
            [ "$ARCH" = "arm64" ] && libssl_url="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
            [ "$ARCH" = "armv7" ] && libssl_url="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_armhf.deb"
            curl -fsSL "$libssl_url" -o "$libssl_deb" || { err "Failed to download libssl3."; exit 1; }
            dpkg -i "$libssl_deb" 2>/dev/null && rm -f "$libssl_deb" || {
                warn "libssl3 installed with dependency warnings (may still work)"
                rm -f "$libssl_deb"
            }
        fi
        info "libssl3 ready"
    fi

    info "All dependencies OK"
}

# ─── Config Load/Save ─────────────────────────────────────────────────────────
load_config() {
    # shellcheck source=/dev/null
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" && return 0
    return 1
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# PicoStream Config — $(date)
DOMAIN="${DOMAIN}"
TUNNEL_DOMAIN="${TUNNEL_DOMAIN}"
V2RAY_PORT="${V2RAY_PORT}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
V2RAY_UUID="${V2RAY_UUID}"
TUNNEL_PORT="${TUNNEL_PORT}"
V2RAY_PARAMS="${V2RAY_PARAMS}"
CERT_FILE="${CERT_FILE}"
KEY_FILE="${KEY_FILE}"
EOF
    chmod 600 "$CONFIG_FILE"
}

# ─── Parse V2Ray Link ──────────────────────────────────────────────────────────
parse_v2ray_link() {
    local link="$1"
    if [[ "$link" =~ ^vless:// ]]; then
        V2RAY_PROTOCOL="vless"
        local body="${link#vless://}"
        V2RAY_UUID="${body%%@*}"
        local rest="${body#*@}"
        local hostport="${rest%%\?*}"
        V2RAY_PORT="${hostport##*:}"
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
        local rest="${body#*@}"
        local hostport="${rest%%\?*}"
        V2RAY_PORT="${hostport##*:}"
        V2RAY_PARAMS="${rest#*\?}"; V2RAY_PARAMS="${V2RAY_PARAMS%%#*}"
        return 0
    fi
    return 1
}

# ─── DNS Setup Explanation ────────────────────────────────────────────────────
explain_dns_setup() {
    local server_ip="$1"
    local tunnel_domain="$2"

    echo ""
    echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║          IMPORTANT: DNS RECORD SETUP REQUIRED            ║${NC}"
    echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Slipstream DNS tunnel requires a domain with NS records"
    echo -e "  pointing to this server. Set these DNS records:"
    echo ""
    echo -e "  ${CYAN}In your domain DNS panel (Cloudflare / GoDaddy / etc.):${NC}"
    echo ""
    echo -e "  ${BOLD}Record 1 — A record (glue record):${NC}"
    echo -e "  ${GREEN}Type:  A${NC}"
    echo -e "  ${GREEN}Name:  ns1.${tunnel_domain}${NC}"
    echo -e "  ${GREEN}Value: ${server_ip}${NC}"
    echo ""
    echo -e "  ${BOLD}Record 2 — NS record (delegate subdomain):${NC}"
    echo -e "  ${GREEN}Type:  NS${NC}"
    echo -e "  ${GREEN}Name:  t.${tunnel_domain}${NC}   (or any subdomain you choose)"
    echo -e "  ${GREEN}Value: ns1.${tunnel_domain}${NC}"
    echo ""
    echo -e "  ${YELLOW}Wait ~5 minutes for DNS propagation, then test:${NC}"
    echo -e "  ${CYAN}nslookup t.${tunnel_domain} 1.1.1.1${NC}"
    echo ""
    echo -e "  ${BOLD}The TUNNEL_DOMAIN to use in client apps: ${GREEN}t.${tunnel_domain}${NC}${NC}"
    echo ""
}

# ─── Gather Input ─────────────────────────────────────────────────────────────
gather_input() {
    step "Configuration"
    echo ""
    echo -e "  ${BOLD}V2Ray config:${NC}"
    echo -e "  ${CYAN}1)${NC} Paste existing V2Ray / VLESS / VMess / Trojan link"
    echo -e "  ${CYAN}2)${NC} Enter manually"
    echo ""
    ask "Choose [1/2] (default: 1): "
    read -r INPUT_MODE
    INPUT_MODE="${INPUT_MODE:-1}"

    if [ "$INPUT_MODE" = "1" ]; then
        echo ""
        ask "Paste your V2Ray link: "
        read -r V2RAY_LINK
        if parse_v2ray_link "$V2RAY_LINK"; then
            info "Parsed -> Protocol: ${V2RAY_PROTOCOL} | Port: ${V2RAY_PORT} | UUID: ${V2RAY_UUID:0:8}..."
        else
            warn "Could not parse link. Switching to manual."
            INPUT_MODE="2"
        fi
    fi

    if [ "$INPUT_MODE" = "2" ]; then
        echo ""
        ask "Your 3x-ui inbound port (TCP): "
        read -r V2RAY_PORT
        ask "Protocol [vless/vmess/trojan] (default: vless): "
        read -r V2RAY_PROTOCOL; V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"
        ask "UUID / Password: "
        read -r V2RAY_UUID
        V2RAY_PARAMS=""
    fi

    # Check V2Ray port
    if ! ss -tlnp 2>/dev/null | grep -q ":${V2RAY_PORT} "; then
        warn "Port ${V2RAY_PORT} does not appear to be listening. Make sure 3x-ui is running."
    else
        info "Port ${V2RAY_PORT} is open. OK"
    fi

    # Server IP
    echo ""
    ask "Server IP (leave blank to auto-detect): "
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
                 curl -s4 --max-time 5 icanhazip.com 2>/dev/null || \
                 hostname -I | awk '{print $1}')
    fi
    info "Server IP: ${DOMAIN}"

    # Tunnel domain
    echo ""
    echo -e "  ${BOLD}DNS Tunnel Domain:${NC}"
    echo -e "  Slipstream hides traffic inside DNS queries. You need a domain"
    echo -e "  with NS records pointing to this server."
    echo ""
    ask "Your domain (e.g. example.com): "
    read -r BASE_DOMAIN

    if [ -z "$BASE_DOMAIN" ]; then
        warn "No domain provided. Using IP-only mode (less reliable on restricted networks)."
        TUNNEL_DOMAIN=""
    else
        TUNNEL_DOMAIN="t.${BASE_DOMAIN}"
        info "Tunnel domain: ${TUNNEL_DOMAIN}"
        explain_dns_setup "$DOMAIN" "$BASE_DOMAIN"
        ask "Have you set the DNS records above? [y/N]: "
        read -r DNS_READY
        if [[ ! "$DNS_READY" =~ ^[Yy]$ ]]; then
            warn "Continuing anyway. Set DNS records before using the tunnel."
        fi
    fi

    # Tunnel port
    echo ""
    echo -e "  ${BOLD}Tunnel port:${NC} (UDP port slipstream listens on)"
    echo -e "  ${CYAN}53${NC}   — DNS (most effective, requires opening port 53 UDP)"
    echo -e "  ${CYAN}5300${NC} — Safe alt if port 53 is already used by system DNS"
    echo ""
    ask "Tunnel port (default: 53): "
    read -r TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-53}"
}

# ─── Install Slipstream ────────────────────────────────────────────────────────
install_slipstream() {
    step "Installing Slipstream"
    local fname="slipstream-server-linux-${ARCH}"
    local url="${RELEASE_URL}/${fname}"
    info "Downloading: $url"
    if ! curl -fsSL --max-time 60 "$url" -o "${SLIPSTREAM_BIN}.tmp"; then
        err "Download failed."
        exit 1
    fi
    mv "${SLIPSTREAM_BIN}.tmp" "$SLIPSTREAM_BIN"
    chmod +x "$SLIPSTREAM_BIN"
    info "Installed at: $SLIPSTREAM_BIN"
}

# ─── TLS Certificates ─────────────────────────────────────────────────────────
generate_certs() {
    step "Generating TLS certificates"
    mkdir -p "$CONFIG_DIR"
    CERT_FILE="${CONFIG_DIR}/cert.pem"
    KEY_FILE="${CONFIG_DIR}/key.pem"
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        info "Existing certificates reused."
        return
    fi
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" \
        -out "$CERT_FILE" -days 3650 -nodes \
        -subj "/CN=${DOMAIN:-picostream}" 2>/dev/null
    chmod 600 "$KEY_FILE"
    info "Certificates created"
}

# ─── iptables (only if using port 53 and system DNS is on 53) ─────────────────
setup_iptables() {
    step "Configuring firewall"

    # If port 53, check if systemd-resolved is holding it
    if [ "$TUNNEL_PORT" = "53" ]; then
        if ss -ulnp 2>/dev/null | grep -q ":53 "; then
            info "Port 53 in use by system DNS. Freeing it..."
            # Disable systemd-resolved stub listener
            if [ -f /etc/systemd/resolved.conf ]; then
                sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
                echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
                systemctl restart systemd-resolved 2>/dev/null || true
                sleep 1
            fi
        fi
        info "Slipstream will listen directly on UDP:53"
        # No iptables redirect needed — slipstream listens on 53 directly
    else
        # For non-53 ports, just open in iptables
        iptables -I INPUT -p udp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || true
        info "Opened UDP:${TUNNEL_PORT} in iptables"
    fi
}

# ─── Systemd Service ──────────────────────────────────────────────────────────
create_service() {
    step "Creating systemd service"

    local domain_arg=""
    [ -n "$TUNNEL_DOMAIN" ] && domain_arg="--domain ${TUNNEL_DOMAIN} \\"$'\n    '

    cat > "${SYSTEMD_DIR}/slipstream-server.service" <<EOF
[Unit]
Description=PicoStream — Slipstream DNS Tunnel
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SLIPSTREAM_BIN} \\
    --dns-listen-host 0.0.0.0 \\
    --dns-listen-port ${TUNNEL_PORT} \\
    --target-address 127.0.0.1:${V2RAY_PORT} \\
    ${domain_arg}--cert ${CERT_FILE} \\
    --key  ${KEY_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=picostream

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable slipstream-server.service &>/dev/null
    systemctl restart slipstream-server.service
    sleep 2
    if systemctl is-active --quiet slipstream-server.service; then
        info "Service running"
    else
        warn "Service may have issues — run: journalctl -u slipstream-server -n 30"
    fi
}

# ─── Management CLI ───────────────────────────────────────────────────────────
install_management_script() {
    cat > "$SCRIPT_CMD" <<'MGMT'
#!/bin/bash
# shellcheck source=/dev/null
CONFIG_FILE="/etc/picostream/picostream.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

case "${1:-status}" in
    status)
        echo -e "\n${BOLD}=== PicoStream Status ===${NC}"
        if systemctl is-active --quiet slipstream-server; then
            echo -e "  Tunnel service : ${GREEN}Running${NC}"
        else
            echo -e "  Tunnel service : ${RED}Stopped${NC}"
        fi
        echo -e "  Tunnel port    : ${CYAN}${TUNNEL_PORT}${NC} (UDP)"
        echo -e "  V2Ray port     : ${CYAN}${V2RAY_PORT}${NC} (TCP)"
        echo -e "  Server IP      : ${CYAN}${DOMAIN}${NC}"
        [ -n "$TUNNEL_DOMAIN" ] && echo -e "  Tunnel domain  : ${CYAN}${TUNNEL_DOMAIN}${NC}"
        echo -e "  Protocol       : ${CYAN}${V2RAY_PROTOCOL}${NC}"
        echo ""
        ;;
    start)   systemctl start  slipstream-server && echo -e "${GREEN}[OK]${NC} Started" ;;
    stop)    systemctl stop   slipstream-server && echo -e "${YELLOW}[OK]${NC} Stopped" ;;
    restart) systemctl restart slipstream-server && echo -e "${GREEN}[OK]${NC} Restarted" ;;
    logs)    journalctl -u slipstream-server -n 80 -f ;;
    link)    [ -f "/etc/picostream/client_info.txt" ] && cat /etc/picostream/client_info.txt ;;
    uninstall)
        echo -e "${RED}Uninstalling PicoStream...${NC}"
        systemctl stop slipstream-server 2>/dev/null || true
        systemctl disable slipstream-server 2>/dev/null || true
        rm -f /etc/systemd/system/slipstream-server.service
        rm -f /etc/systemd/system/picostream-iptables.service
        rm -f /usr/local/bin/slipstream-server
        rm -f /usr/local/bin/picostream
        rm -rf /etc/picostream
        systemctl daemon-reload
        echo -e "${GREEN}[OK]${NC} Removed."
        ;;
    help|-h|--help)
        echo -e "\n  ${BOLD}picostream${NC} — management CLI\n"
        echo -e "  ${CYAN}picostream${NC}            Status"
        echo -e "  ${CYAN}picostream start${NC}      Start"
        echo -e "  ${CYAN}picostream stop${NC}       Stop"
        echo -e "  ${CYAN}picostream restart${NC}    Restart"
        echo -e "  ${CYAN}picostream logs${NC}       Live logs"
        echo -e "  ${CYAN}picostream link${NC}       Show client info"
        echo -e "  ${CYAN}picostream uninstall${NC}  Remove all"
        echo ""
        ;;
    *) echo "Unknown: $1 — run 'picostream help'"; exit 1 ;;
esac
MGMT
    chmod +x "$SCRIPT_CMD"
}

# ─── Client Info ──────────────────────────────────────────────────────────────
show_client_info() {
    step "Client setup instructions"

    cat > "${CONFIG_DIR}/client_info.txt" <<EOF
=======================================================
  PicoStream — Client Connection Guide
=======================================================

  Server IP     : ${DOMAIN}
  Tunnel Port   : ${TUNNEL_PORT} (UDP)
  Tunnel Domain : ${TUNNEL_DOMAIN:-"(not set — use IP mode)"}
  V2Ray Port    : ${V2RAY_PORT} (internal, not exposed)
  Protocol      : ${V2RAY_PROTOCOL}
  UUID          : ${V2RAY_UUID}

-------------------------------------------------------
  HOW TO CONNECT (choose your platform)
-------------------------------------------------------

  ANDROID:
  Install "Slipstream" Android app:
  https://github.com/AliRezaBeigy/slipstream-rust-deploy#android-client

  Settings in the app:
    Domain    : ${TUNNEL_DOMAIN:-${DOMAIN}}
    Resolvers : 1.1.1.1:53 and 8.8.8.8:53
    Mode      : V2Ray / VLESS
    V2Ray UUID: ${V2RAY_UUID}

  WINDOWS / macOS / LINUX:
  Download SlipStreamGUI:
  https://github.com/AliRezaBeigy/slipstream-rust-deploy#gui-client

  Or use command-line client:
    curl -Lo slipstream-client https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download/slipstream-client-linux-amd64
    chmod +x slipstream-client
    ./slipstream-client \\
      --resolver 1.1.1.1:53 \\
      --resolver 8.8.8.8:53 \\
      --domain ${TUNNEL_DOMAIN:-${DOMAIN}} \\
      --tcp-listen-port 10808

  Then in v2rayNG / Clash, add SOCKS5 proxy:
    Host: 127.0.0.1
    Port: 10808

-------------------------------------------------------
  Management: picostream help
EOF

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            PicoStream — Setup Complete!               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Server IP     :${NC} ${DOMAIN}"
    echo -e "  ${CYAN}Tunnel Port   :${NC} ${YELLOW}${TUNNEL_PORT}${NC} (UDP)"
    if [ -n "$TUNNEL_DOMAIN" ]; then
        echo -e "  ${CYAN}Tunnel Domain :${NC} ${YELLOW}${TUNNEL_DOMAIN}${NC}"
    fi
    echo -e "  ${CYAN}V2Ray Port    :${NC} ${V2RAY_PORT} (internal)"
    echo ""
    echo -e "  ${BOLD}━━━ Android ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Install: ${CYAN}Slipstream${NC} Android app"
    echo -e "  GitHub : https://github.com/AliRezaBeigy/slipstream-rust-deploy"
    echo -e "  Domain : ${YELLOW}${TUNNEL_DOMAIN:-$DOMAIN}${NC}"
    echo -e "  Resolvers: 1.1.1.1:53  and  8.8.8.8:53"
    echo ""
    echo -e "  ${BOLD}━━━ Windows / macOS / Linux ━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Download: ${CYAN}SlipStreamGUI${NC}"
    echo -e "  GitHub : https://github.com/AliRezaBeigy/slipstream-rust-deploy"
    echo ""
    echo -e "  ${BOLD}━━━ CLI client ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}./slipstream-client --resolver 1.1.1.1:53 --resolver 8.8.8.8:53 --domain ${TUNNEL_DOMAIN:-$DOMAIN} --tcp-listen-port 10808${NC}"
    echo -e "  Then set SOCKS5 proxy: 127.0.0.1:10808 in your app"
    echo ""
    echo -e "  Full guide: ${CYAN}picostream link${NC}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    banner
    detect_os
    check_deps

    if load_config; then
        step "Existing installation detected"
        echo -e "  ${YELLOW}PicoStream already installed${NC}"
        echo -e "  IP: ${DOMAIN} | Port: ${TUNNEL_PORT} | V2Ray: ${V2RAY_PORT}"
        echo ""
        ask "Reconfigure? [y/N]: "
        read -r REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "No changes. Run 'picostream help'."
            exit 0
        fi
        systemctl stop slipstream-server 2>/dev/null || true
    fi

    gather_input
    install_slipstream
    generate_certs
    setup_iptables
    save_config
    create_service
    install_management_script
    show_client_info
}

main "$@"
