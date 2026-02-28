#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║           PicoStream — DNS Tunnel Layer for 3x-ui / V2Ray       ║
# ║        Wraps your existing V2Ray panel with a DNS tunnel         ║
# ║                 github.com/amir6dev/PicoStream                   ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  Install:
#  bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install.sh)

set -e

[[ $EUID -ne 0 ]] && echo -e "\033[0;31m[ERROR]\033[0m Run as root (sudo -i)" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

VERSION="1.0.0"
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

    # Slipstream binary requires libssl.so.3 (OpenSSL 3.x)
    # Ubuntu 22.04+ has it in repos; Ubuntu 20.04 needs manual .deb install
    if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
        info "libssl.so.3 not found — installing libssl3 (required by Slipstream)..."
        apt-get update -qq
        if apt-get install -y libssl3 2>/dev/null; then
            info "libssl3 installed from repo"
        else
            # Ubuntu 20.04 fallback: download .deb directly from Ubuntu 22.04 archive
            warn "libssl3 not in repos (Ubuntu 20.04). Downloading .deb directly..."
            local libssl_deb="/tmp/libssl3.deb"
            local libssl_url="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
            if [ "$ARCH" = "arm64" ]; then
                libssl_url="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
            elif [ "$ARCH" = "armv7" ]; then
                libssl_url="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_armhf.deb"
            fi
            curl -fsSL "$libssl_url" -o "$libssl_deb" || \
                { err "Failed to download libssl3. Check internet connection."; exit 1; }
            dpkg -i "$libssl_deb" && rm -f "$libssl_deb" || \
                { err "Failed to install libssl3."; exit 1; }
            info "libssl3 installed from .deb"
        fi
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
V2RAY_PORT="${V2RAY_PORT}"
V2RAY_PROTOCOL="${V2RAY_PROTOCOL}"
V2RAY_UUID="${V2RAY_UUID}"
TUNNEL_PORT="${TUNNEL_PORT}"
INTERNAL_PORT="${INTERNAL_PORT}"
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
        V2RAY_PARAMS="${rest#*\?}"
        V2RAY_PARAMS="${V2RAY_PARAMS%%#*}"
        return 0
    elif [[ "$link" =~ ^vmess:// ]]; then
        V2RAY_PROTOCOL="vmess"
        local b64="${link#vmess://}"
        b64="${b64%%#*}"
        local json
        json=$(echo "$b64" | base64 -d 2>/dev/null) || { err "Invalid vmess link"; return 1; }
        V2RAY_UUID=$(echo "$json" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        V2RAY_PORT=$(echo "$json" | grep -o '"port":[0-9]*' | head -1 | grep -o '[0-9]*')
        V2RAY_PARAMS=""
        return 0
    elif [[ "$link" =~ ^trojan:// ]]; then
        V2RAY_PROTOCOL="trojan"
        local body="${link#trojan://}"
        V2RAY_UUID="${body%%@*}"
        local rest="${body#*@}"
        local hostport="${rest%%\?*}"
        V2RAY_PORT="${hostport##*:}"
        V2RAY_PARAMS="${rest#*\?}"
        V2RAY_PARAMS="${V2RAY_PARAMS%%#*}"
        return 0
    fi
    return 1
}

# ─── Gather User Input ────────────────────────────────────────────────────────
gather_input() {
    step "Configuration"
    echo ""
    echo -e "  ${BOLD}Configuration options:${NC}"
    echo -e "  ${CYAN}1)${NC} Paste your existing V2Ray / VLESS / VMess / Trojan link"
    echo -e "  ${CYAN}2)${NC} Enter details manually"
    echo ""
    ask "Choose [1/2] (default: 1): "
    read -r INPUT_MODE
    INPUT_MODE="${INPUT_MODE:-1}"

    if [ "$INPUT_MODE" = "1" ]; then
        echo ""
        ask "Paste your V2Ray link: "
        read -r V2RAY_LINK
        if parse_v2ray_link "$V2RAY_LINK"; then
            info "Parsed OK -> Protocol: ${V2RAY_PROTOCOL} | Port: ${V2RAY_PORT} | UUID: ${V2RAY_UUID:0:8}..."
        else
            warn "Could not parse link. Switching to manual mode."
            INPUT_MODE="2"
        fi
    fi

    if [ "$INPUT_MODE" = "2" ]; then
        echo ""
        ask "Your 3x-ui inbound port (TCP): "
        read -r V2RAY_PORT
        ask "Protocol [vless/vmess/trojan] (default: vless): "
        read -r V2RAY_PROTOCOL
        V2RAY_PROTOCOL="${V2RAY_PROTOCOL:-vless}"
        ask "UUID / Password: "
        read -r V2RAY_UUID
        V2RAY_PARAMS=""
    fi

    # Check if V2Ray port is listening
    if ! ss -tlnp 2>/dev/null | grep -q ":${V2RAY_PORT} " && \
       ! netstat -tlnp 2>/dev/null | grep -q ":${V2RAY_PORT} "; then
        warn "Port ${V2RAY_PORT} does not appear to be open."
        warn "Make sure 3x-ui is running and the inbound is enabled."
    else
        info "Port ${V2RAY_PORT} is listening. OK"
    fi

    # Tunnel port selection
    echo ""
    echo -e "  ${BOLD}Select tunnel port:${NC}"
    echo -e "  The tunnel listens on this UDP port and forwards traffic to your V2Ray panel."
    echo ""
    echo -e "  ${CYAN}53  ${NC} — DNS port  (bypasses most firewalls)"
    echo -e "  ${CYAN}80  ${NC} — HTTP port (rarely blocked)"
    echo -e "  ${CYAN}443 ${NC} — HTTPS port"
    echo -e "  ${CYAN}8080${NC} — HTTP alt"
    echo -e "  Or enter any custom port number."
    echo ""
    ask "Tunnel port (default: 53): "
    read -r TUNNEL_PORT
    TUNNEL_PORT="${TUNNEL_PORT:-53}"

    # Pick internal port that doesn't conflict
    INTERNAL_PORT=$((5000 + RANDOM % 300))
    while ss -ulnp 2>/dev/null | grep -q ":${INTERNAL_PORT} " || \
          [ "$INTERNAL_PORT" = "$TUNNEL_PORT" ] || \
          [ "$INTERNAL_PORT" = "$V2RAY_PORT" ]; do
        INTERNAL_PORT=$((5000 + RANDOM % 300))
    done
    info "Internal Slipstream port: ${INTERNAL_PORT}"

    echo ""
    ask "Server domain or IP (leave blank to auto-detect): "
    read -r DOMAIN
    if [ -z "$DOMAIN" ]; then
        DOMAIN=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || \
                 curl -s4 --max-time 5 icanhazip.com 2>/dev/null || \
                 hostname -I | awk '{print $1}')
    fi
    info "Server: ${DOMAIN}"
}

# ─── Install Slipstream ────────────────────────────────────────────────────────
install_slipstream() {
    step "Installing Slipstream"

    # Check if prebuilt binary will work (needs libssl.so.3 + libc6 >= 2.34)
    # Ubuntu 20.04 has libc6 2.31 — must build from source
    local needs_build=false
    if [ "$PKG" = "apt" ]; then
        local libc_ver
        libc_ver=$(dpkg -l libc6 2>/dev/null | grep "^ii" | awk '{print $3}' | cut -d'-' -f1)
        # Compare: if libc6 < 2.34, prebuilt won't work
        if [ -n "$libc_ver" ]; then
            local major minor
            major=$(echo "$libc_ver" | cut -d'.' -f1)
            minor=$(echo "$libc_ver" | cut -d'.' -f2)
            if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 34 ]; }; then
                warn "libc6 ${libc_ver} detected (need >= 2.34) — building Slipstream from source..."
                needs_build=true
            fi
        fi
    fi

    if [ "$needs_build" = true ]; then
        build_slipstream_from_source
        return
    fi

    local fname="slipstream-server-linux-${ARCH}"
    local url="${RELEASE_URL}/${fname}"

    info "Downloading: $url"
    if ! curl -fsSL --max-time 60 "$url" -o "${SLIPSTREAM_BIN}.tmp"; then
        warn "Download failed, falling back to source build..."
        build_slipstream_from_source
        return
    fi
    mv "${SLIPSTREAM_BIN}.tmp" "$SLIPSTREAM_BIN"
    chmod +x "$SLIPSTREAM_BIN"

    # Quick test — if binary fails to run, build from source
    if ! "$SLIPSTREAM_BIN" --version &>/dev/null && ! "$SLIPSTREAM_BIN" --help &>/dev/null; then
        warn "Prebuilt binary failed to run (likely missing libssl.so.3), building from source..."
        build_slipstream_from_source
        return
    fi
    info "Installed at: $SLIPSTREAM_BIN"
}

build_slipstream_from_source() {
    step "Building Slipstream from source (Ubuntu 20.04 compatibility)"
    info "This will take 15-25 minutes. Please wait..."

    # Install build dependencies
    [ "$PKG" = "apt" ] && apt-get update -qq &&         DEBIAN_FRONTEND=noninteractive apt-get install -y             build-essential cmake pkg-config libssl-dev git curl -qq
    [ "$PKG" = "dnf" ] && dnf install -y gcc make cmake pkgconfig openssl-devel git curl
    [ "$PKG" = "yum" ] && yum install -y gcc make cmake pkgconfig openssl-devel git curl

    # Install Rust if not present
    if ! command -v cargo &>/dev/null; then
        info "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    else
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env" 2>/dev/null || true
    fi

    # Clone source
    local src_dir="/tmp/slipstream-src"
    rm -rf "$src_dir"
    info "Cloning slipstream-rust source..."
    git clone --depth=1 https://github.com/Mygod/slipstream-rust.git "$src_dir" ||     git clone --depth=1 https://github.com/Fox-Fig/slipstream-rust-plus.git "$src_dir" ||     { err "Failed to clone source. Check internet connection."; exit 1; }

    cd "$src_dir"
    git submodule update --init --recursive

    info "Compiling... (this takes a while)"
    cargo build --release -p slipstream-server 2>&1 | tail -5

    if [ ! -f "target/release/slipstream-server" ]; then
        err "Build failed. Check logs above."
        exit 1
    fi

    cp target/release/slipstream-server "$SLIPSTREAM_BIN"
    chmod +x "$SLIPSTREAM_BIN"
    rm -rf "$src_dir"
    info "Slipstream built and installed from source"
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env" 2>/dev/null || true
}

# ─── TLS Certificates ─────────────────────────────────────────────────────────
generate_certs() {
    step "Generating TLS certificates"
    mkdir -p "$CONFIG_DIR"

    CERT_FILE="${CONFIG_DIR}/cert.pem"
    KEY_FILE="${CONFIG_DIR}/key.pem"

    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        info "Existing certificates found, reusing."
        return
    fi

    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" \
        -out "$CERT_FILE" -days 3650 -nodes \
        -subj "/CN=${DOMAIN}/O=PicoStream" 2>/dev/null || \
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" \
        -out "$CERT_FILE" -days 3650 -nodes \
        -subj "/CN=picostream" 2>/dev/null

    chmod 600 "$KEY_FILE"
    info "Certificates created"
}

# ─── iptables ─────────────────────────────────────────────────────────────────
setup_iptables() {
    step "Setting up iptables (UDP:${TUNNEL_PORT} -> :${INTERNAL_PORT})"

    # Remove any old rule
    iptables -t nat -D PREROUTING -p udp --dport "${TUNNEL_PORT}" \
        -j REDIRECT --to-port "${INTERNAL_PORT}" 2>/dev/null || true

    iptables -t nat -A PREROUTING -p udp --dport "${TUNNEL_PORT}" \
        -j REDIRECT --to-port "${INTERNAL_PORT}"

    # Save rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    # Restore on reboot
    cat > "${SYSTEMD_DIR}/picostream-iptables.service" <<EOF
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
    systemctl enable picostream-iptables.service &>/dev/null
    info "iptables rule added"
}

# ─── Systemd Service ──────────────────────────────────────────────────────────
create_service() {
    step "Creating systemd service"
    cat > "${SYSTEMD_DIR}/slipstream-server.service" <<EOF
[Unit]
Description=PicoStream — Slipstream Tunnel
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SLIPSTREAM_BIN} \\
    --listen 0.0.0.0:${INTERNAL_PORT} \\
    --target 127.0.0.1:${V2RAY_PORT} \\
    --cert ${CERT_FILE} \\
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
        info "Service is running"
    else
        warn "Service may have issues — run: journalctl -u slipstream-server -n 50"
    fi
}

# ─── Management CLI ───────────────────────────────────────────────────────────
install_management_script() {
    cat > "$SCRIPT_CMD" <<'MGMT'
#!/bin/bash
CONFIG_FILE="/etc/picostream/picostream.conf"
# shellcheck source=/dev/null
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
        echo -e "  Server         : ${CYAN}${DOMAIN}${NC}"
        echo -e "  Protocol       : ${CYAN}${V2RAY_PROTOCOL}${NC}"
        echo ""
        ;;
    start)
        systemctl start slipstream-server && echo -e "${GREEN}[OK]${NC} Started"
        ;;
    stop)
        systemctl stop slipstream-server && echo -e "${YELLOW}[OK]${NC} Stopped"
        ;;
    restart)
        systemctl restart slipstream-server && echo -e "${GREEN}[OK]${NC} Restarted"
        ;;
    logs)
        journalctl -u slipstream-server -n 80 -f
        ;;
    link)
        [ -f "/etc/picostream/client_info.txt" ] && cat /etc/picostream/client_info.txt || \
            echo "No client info found. Re-run the installer."
        ;;
    uninstall)
        echo -e "${RED}Uninstalling PicoStream...${NC}"
        systemctl stop slipstream-server 2>/dev/null || true
        systemctl disable slipstream-server 2>/dev/null || true
        systemctl stop picostream-iptables 2>/dev/null || true
        systemctl disable picostream-iptables 2>/dev/null || true
        [ -f /etc/picostream/picostream.conf ] && source /etc/picostream/picostream.conf
        iptables -t nat -D PREROUTING -p udp --dport "${TUNNEL_PORT}" \
            -j REDIRECT --to-port "${INTERNAL_PORT}" 2>/dev/null || true
        rm -f /etc/systemd/system/slipstream-server.service
        rm -f /etc/systemd/system/picostream-iptables.service
        rm -f /usr/local/bin/slipstream-server
        rm -f /usr/local/bin/picostream
        rm -rf /etc/picostream
        systemctl daemon-reload
        echo -e "${GREEN}[OK]${NC} PicoStream has been removed."
        ;;
    help|-h|--help)
        echo ""
        echo -e "  ${BOLD}picostream${NC} — PicoStream tunnel manager"
        echo ""
        echo -e "  ${CYAN}picostream${NC}            Show status"
        echo -e "  ${CYAN}picostream start${NC}      Start tunnel"
        echo -e "  ${CYAN}picostream stop${NC}       Stop tunnel"
        echo -e "  ${CYAN}picostream restart${NC}    Restart tunnel"
        echo -e "  ${CYAN}picostream logs${NC}       Live logs"
        echo -e "  ${CYAN}picostream link${NC}       Show client link"
        echo -e "  ${CYAN}picostream uninstall${NC}  Remove PicoStream"
        echo ""
        ;;
    *)
        echo "Unknown command: $1  — run 'picostream help'"
        exit 1
        ;;
esac
MGMT
    chmod +x "$SCRIPT_CMD"
}

# ─── Client Link ──────────────────────────────────────────────────────────────
generate_client_link() {
    step "Client connection info"

    local client_link=""
    case "$V2RAY_PROTOCOL" in
        vless)
            local params="${V2RAY_PARAMS:-security=none&type=tcp&encryption=none}"
            client_link="vless://${V2RAY_UUID}@${DOMAIN}:${TUNNEL_PORT}?${params}#PicoStream-${TUNNEL_PORT}"
            ;;
        vmess)
            local json="{\"v\":\"2\",\"ps\":\"PicoStream-${TUNNEL_PORT}\",\"add\":\"${DOMAIN}\",\"port\":\"${TUNNEL_PORT}\",\"id\":\"${V2RAY_UUID}\",\"net\":\"tcp\",\"tls\":\"none\"}"
            client_link="vmess://$(echo "$json" | base64 -w0)"
            ;;
        trojan)
            client_link="trojan://${V2RAY_UUID}@${DOMAIN}:${TUNNEL_PORT}?security=none&type=tcp#PicoStream-${TUNNEL_PORT}"
            ;;
        *)
            client_link="vless://${V2RAY_UUID}@${DOMAIN}:${TUNNEL_PORT}?security=none&type=tcp&encryption=none#PicoStream-${TUNNEL_PORT}"
            ;;
    esac

    cat > "${CONFIG_DIR}/client_info.txt" <<EOF
=======================================================
  PicoStream — Client Connection Info
=======================================================

  Protocol  : ${V2RAY_PROTOCOL}
  Server    : ${DOMAIN}
  Tunnel    : UDP port ${TUNNEL_PORT}  ->  V2Ray port ${V2RAY_PORT} (TCP)
  UUID      : ${V2RAY_UUID}

  Client Link:
  ${client_link}

  Import in:  v2rayNG / Hiddify / NekoRay / V2Box
  Management: picostream help
EOF

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            PicoStream — Setup Complete!               ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Protocol  :${NC} ${V2RAY_PROTOCOL}"
    echo -e "  ${CYAN}Server    :${NC} ${DOMAIN}"
    echo -e "  ${CYAN}Tunnel    :${NC} UDP ${YELLOW}${TUNNEL_PORT}${NC}  ->  TCP ${V2RAY_PORT}"
    echo ""
    echo -e "  ${BOLD}Client Link:${NC}"
    echo -e "  ${YELLOW}${client_link}${NC}"
    echo ""
    echo -e "  ${GREEN}Import this link in v2rayNG / Hiddify / NekoRay${NC}"
    echo -e "  ${CYAN}Run 'picostream help' for management commands${NC}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    banner
    detect_os
    check_deps

    if load_config; then
        step "Existing installation detected"
        echo ""
        echo -e "  ${YELLOW}PicoStream is already installed.${NC}"
        echo -e "  Server: ${DOMAIN} | Tunnel Port: ${TUNNEL_PORT} | V2Ray Port: ${V2RAY_PORT}"
        echo ""
        ask "Reconfigure? [y/N]: "
        read -r REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "No changes made. Run 'picostream help' to manage."
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
    generate_client_link
}

main "$@"
