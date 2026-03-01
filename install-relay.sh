#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  PicoStream RELAY — Iran/Entry Server  ║
# ║  github.com/amir6dev/PicoStream  ║
# ╚══════════════════════════════════════════════════════════════════╝
#
#  :
#  :  bash install-relay.sh
#  :  bash install-relay.sh --offline
#
#  :  slipstream-client  :
#  scp slipstream-client-linux-amd64 root@IRAN_IP:/tmp/slipstream-client

set -e
[[ $EUID -ne 0 ]] && echo "[ERROR] Run as root (sudo -i)" && exit 1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -ne "${BLUE}[?]${NC} $1"; }
step() { echo -e "\n${CYAN}── $1 ──────────────────────────────────────${NC}"; }

CLIENT_BIN="/usr/local/bin/slipstream-client"
CONFIG_DIR="/etc/picostream"
RELEASE_URL="https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download"
OFFLINE_MODE=0

# ─── Parse args ──────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
  --offline|-o) OFFLINE_MODE=1 ;;
  esac
done

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  PicoStream RELAY — Iran/Entry Server Setup  ${NC}"
if [ "$OFFLINE_MODE" = "1" ]; then
echo -e "${YELLOW}  (Offline Mode)  ${NC}"
fi
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
  PKG="none"
fi

case "$(uname -m)" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="armv7" ;;
  *) err "Unsupported arch: $(uname -m)" ;;
esac
info "OS: ${NAME:-Linux} | Arch: $ARCH"

# ─── Install deps ( ) ─────────────────────────────────────
step "Dependencies"
if [ "$OFFLINE_MODE" = "0" ] && [ "$PKG" != "none" ]; then
  if [ "$PKG" = "apt" ]; then
  info "Trying apt-get update (10s timeout)..."
  timeout 10 apt-get update -qq 2>/dev/null || warn "apt-get update skipped (no internet or slow)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl iptables -qq 2>/dev/null || \
  warn "apt install failed — continuing with what's available"
  elif [ "$PKG" = "dnf" ]; then
  dnf install -y curl iptables 2>/dev/null || warn "dnf failed"
  elif [ "$PKG" = "yum" ]; then
  yum install -y curl iptables 2>/dev/null || warn "yum failed"
  fi
else
  warn "Offline mode — skipping package install"
fi

# Check required tools
command -v iptables &>/dev/null || err "iptables not found. Install: apt-get install -y iptables"

# libssl3
if [ "$PKG" = "apt" ] && ! ldconfig -p 2>/dev/null | grep -q "libssl.so.3"; then
  if [ "$OFFLINE_MODE" = "0" ]; then
  if ! apt-get install -y libssl3 2>/dev/null; then
  warn "Downloading libssl3..."
  if [ "$ARCH" = "arm64" ]; then
  LIBSSL_URL="http://ports.ubuntu.com/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_arm64.deb"
  else
  LIBSSL_URL="http://security.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3_3.0.2-0ubuntu1.21_amd64.deb"
  fi
  curl -fsSL "$LIBSSL_URL" -o /tmp/libssl3.deb 2>/dev/null && \
  dpkg -i /tmp/libssl3.deb 2>/dev/null || true
  rm -f /tmp/libssl3.deb
  fi
  else
  # Offline: check /tmp for pre-uploaded deb
  if [ -f /tmp/libssl3.deb ]; then
  info "Installing libssl3 from /tmp/libssl3.deb..."
  dpkg -i /tmp/libssl3.deb 2>/dev/null || true
  else
  warn "libssl3 not found. If slipstream-client fails, upload libssl3.deb to /tmp/"
  fi
  fi
fi
info "Dependencies checked"

# ─── Input ────────────────────────────────────────────────────────
step "Configuration"
echo ""
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
echo -e "  ${BOLD}DNS resolvers${NC} (  ):"
echo -e "  ${CYAN}8.8.8.8${NC} Google  |  ${CYAN}8.8.4.4${NC} Google  |  ${CYAN}1.1.1.1${NC} Cloudflare"
ask "  Resolvers (default: 8.8.8.8,8.8.4.4): "
read -r RESOLVERS_INPUT
RESOLVERS_INPUT="${RESOLVERS_INPUT:-8.8.8.8,8.8.4.4}"

echo ""
echo -e "  ${BOLD}Entry port${NC} —  ‌:"
echo -e "  ${CYAN}443${NC}  |  ${CYAN}80${NC}  |  ${CYAN}8443${NC}  |  ${CYAN}2053${NC}"
ask "  Entry port (default: 443): "
read -r ENTRY_PORT
ENTRY_PORT="${ENTRY_PORT:-443}"

if [ "$OFFLINE_MODE" = "1" ]; then
  RELAY_IP=$(hostname -I | awk '{print $1}')
  ask "  This server public IP (detected: ${RELAY_IP}, press Enter to confirm): "
  read -r RELAY_IP_INPUT
  [ -n "$RELAY_IP_INPUT" ] && RELAY_IP="$RELAY_IP_INPUT"
else
  RELAY_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null ||     curl -s4 --max-time 5 icanhazip.com 2>/dev/null ||     hostname -I | awk '{print $1}')
fi
info "Relay IP: $RELAY_IP"

# ─── Install slipstream-client ────────────────────────────────────
step "Installing slipstream-client"

if [ -f "$CLIENT_BIN" ] && [ "$OFFLINE_MODE" = "0" ]; then
  warn "Binary already exists at $CLIENT_BIN — skipping download"
  info "To reinstall, delete it first: rm -f $CLIENT_BIN"

elif [ "$OFFLINE_MODE" = "1" ]; then
  # Offline: look for pre-uploaded binary
  FOUND_BIN=""
  for path in \
  "/tmp/slipstream-client" \
  "/tmp/slipstream-client-linux-${ARCH}" \
  "/root/slipstream-client" \
  "/home/slipstream-client"; do
  if [ -f "$path" ]; then
  FOUND_BIN="$path"
  break
  fi
  done

  if [ -n "$FOUND_BIN" ]; then
  cp "$FOUND_BIN" "$CLIENT_BIN"
  chmod +x "$CLIENT_BIN"
  info "Binary installed from: $FOUND_BIN"
  else
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  Binary not found! Upload it first:  ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}  :${NC}"
  echo -e "  ${YELLOW}# :${NC}"
  echo -e "  curl -Lo slipstream-client-linux-${ARCH} \\"
  echo -e "  ${CYAN}https://github.com/Fox-Fig/slipstream-rust-deploy/releases/latest/download/slipstream-client-linux-${ARCH}${NC}"
  echo ""
  echo -e "  ${YELLOW}#  :${NC}"
  echo -e "  ${CYAN}scp slipstream-client-linux-${ARCH} root@${RELAY_IP}:/tmp/slipstream-client${NC}"
  echo ""
  echo -e "  :  ${YELLOW}bash install-relay.sh --offline${NC}"
  echo ""
  exit 1
  fi

else
  # Online: download from GitHub
  info "Downloading slipstream-client (${ARCH})..."
  if curl -fsSL --max-time 90 \
  "${RELEASE_URL}/slipstream-client-linux-${ARCH}" \
  -o "${CLIENT_BIN}.tmp" 2>/dev/null; then
  mv "${CLIENT_BIN}.tmp" "$CLIENT_BIN"
  chmod +x "$CLIENT_BIN"
  info "Downloaded and installed"
  else
  echo ""
  echo -e "${RED}Download failed! Try offline mode:${NC}"
  echo ""
  echo -e "  ${BOLD}  /  :${NC}"
  echo -e "  curl -Lo slipstream-client \\"
  echo -e "  ${CYAN}${RELEASE_URL}/slipstream-client-linux-${ARCH}${NC}"
  echo -e "  ${CYAN}scp slipstream-client root@${RELAY_IP}:/tmp/slipstream-client${NC}"
  echo ""
  echo -e "  : ${YELLOW}bash install-relay.sh --offline${NC}"
  echo ""
  exit 1
  fi
fi

# Verify binary works
"$CLIENT_BIN" --help &>/dev/null || \
"$CLIENT_BIN" --version &>/dev/null || \
"$CLIENT_BIN" --resolver 8.8.8.8:53 --domain test.example.com \
  --tcp-listen-host 127.0.0.1 --tcp-listen-port 19999 &>/dev/null & \
sleep 1 && kill $! 2>/dev/null || true
info "Binary OK"

# ─── Build resolver args for service ─────────────────────────────
RESOLVER_LINES=""
IFS=',' read -ra RES_ARR <<< "$RESOLVERS_INPUT"
for r in "${RES_ARR[@]}"; do
  r=$(echo "$r" | tr -d ' ')
  [[ "$r" != *:* ]] && r="${r}:53"
  RESOLVER_LINES="${RESOLVER_LINES}  --resolver ${r} \\"$'\n'
done

# ─── Systemd service ─────────────────────────────────────────────
step "Creating systemd service"
cat > /etc/systemd/system/picostream-relay.service <<EOF
[Unit]
Description=PicoStream RELAY — slipstream-client
After=network.target

[Service]
Type=simple
ExecStart=${CLIENT_BIN} \\
${RESOLVER_LINES}  --domain ${TUNNEL_DOMAIN} \\
  --tcp-listen-host 0.0.0.0 \\
  --tcp-listen-port ${ENTRY_PORT}
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
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
case "${1:-status}" in
  status)
  echo -e "\n${B}=== PicoStream RELAY ===${N}"
  systemctl is-active --quiet picostream-relay && \
  echo -e "  Service  : ${G}Running ✓${N}" || echo -e "  Service  : ${R}Stopped ✗${N}"
  echo -e "  Port  : TCP ${ENTRY_PORT}"
  echo -e "  Domain  : ${C}${TUNNEL_DOMAIN}${N}"
  echo -e "  Resolver : ${C}${RESOLVERS_INPUT}${N}"
  echo "";;
  logs)  journalctl -u picostream-relay -n 60 -f ;;
  restart) systemctl restart picostream-relay && echo "Restarted" ;;
  link)
  echo ""
  echo -e "\033[1mClient link:\033[0m"
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
  echo -e "${GREEN}║  ✓  RELAY is RUNNING  ║${NC}"
else
  echo -e "${RED}║  ✗  Service failed — run: picostream-relay logs  ║${NC}"
fi
echo -e "${GREEN}╚═════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Traffic path:${NC}"
echo -e "  User → ${CYAN}TCP:${ENTRY_PORT}${NC} → DNS:${RESOLVERS_INPUT} → ${CYAN}${TUNNEL_DOMAIN}${NC} → exit → 3x-ui"
echo ""
echo -e "  ${BOLD}${YELLOW} :${NC}"
echo ""
echo -e "  ${YELLOW}${CLIENT_LINK}${NC}"
echo ""
echo -e "  ${BOLD}Management:${NC} picostream-relay [status|logs|restart|link]"
echo ""
