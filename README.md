# PicoStream

**DNS Tunnel layer for 3x-ui / V2Ray panels**  
Wrap your existing V2Ray inbound with a UDP tunnel on any port (53, 80, 443, 8080, ...) to bypass restrictive firewalls.

```
Client (Iran/restricted network)
        |
        v
 UDP port 53 / 80 / 443  (your choice)
        |
        v
  Slipstream tunnel
        |
        v
  127.0.0.1:YOUR_V2RAY_PORT  (3x-ui inbound)
        |
        v
     Internet
```

---

## Requirements

| Item | Notes |
|------|-------|
| VPS / Server | Ubuntu 20+, Debian 10+, CentOS 7+, Rocky 8+ |
| 3x-ui panel | Already installed with at least one active inbound |
| Open UDP port | The tunnel port you choose must be open in your firewall |
| Root access | Required for iptables and systemd |

---

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install.sh)
```

The script will ask you:
1. **Your V2Ray link** (paste from 3x-ui) — OR — enter port/UUID manually
2. **Tunnel port** — which UDP port to expose (default: 53)
3. **Server domain or IP** (auto-detected if left blank)

---

## What it does

- Installs **Slipstream** (lightweight Rust DNS tunnel binary)
- Sets up an **iptables** rule: `UDP:TUNNEL_PORT → :INTERNAL_PORT`
- Creates a **systemd service** that auto-starts on reboot
- Generates a **new client link** with your chosen tunnel port
- Provides a **`picostream`** CLI for management

---

## Management

```bash
picostream          # Show status
picostream start    # Start tunnel
picostream stop     # Stop tunnel
picostream restart  # Restart tunnel
picostream logs     # Live logs
picostream link     # Show client connection link
picostream uninstall  # Remove everything
```

---

## Client Apps

Import the generated link in any of these:

| App | Platform |
|-----|----------|
| **v2rayNG** | Android |
| **Hiddify** | Android / iOS / Windows / macOS |
| **NekoRay** | Windows / Linux |
| **V2Box** | iOS |
| **Clash Meta** | All platforms |

---

## Port Selection Guide

| Port | Protocol | Notes |
|------|----------|-------|
| **53** | DNS (UDP) | Passes through almost all firewalls |
| **80** | HTTP | Usually allowed, even on restricted networks |
| **443** | HTTPS | Encrypted traffic, rarely inspected |
| **8080** | HTTP alt | Good alternative to 80 |
| **2053** | DNS alt | Used by some CDNs |

> **Note:** Make sure the chosen port is open in your VPS firewall / security group (both inbound UDP).

---

## Firewall / Security Group

Open the tunnel port in your VPS provider's firewall **and** in the server's own firewall:

```bash
# UFW (Ubuntu/Debian)
ufw allow TUNNEL_PORT/udp

# firewalld (CentOS/Rocky)
firewall-cmd --add-port=TUNNEL_PORT/udp --permanent
firewall-cmd --reload

# iptables direct
iptables -I INPUT -p udp --dport TUNNEL_PORT -j ACCEPT
```

---

## Troubleshooting

**Service not starting**
```bash
journalctl -u slipstream-server -n 50
```

**Check iptables rule**
```bash
iptables -t nat -L PREROUTING -n -v
```

**Check V2Ray port is listening**
```bash
ss -tlnp | grep V2RAY_PORT
```

**Connection timeout on client**
- Make sure UDP is open on your VPS firewall for the tunnel port
- Verify 3x-ui inbound is enabled and running
- Try port 53 if other ports are blocked

---

## Uninstall

```bash
picostream uninstall
```

This removes: Slipstream binary, systemd services, iptables rules, config files.  
Your 3x-ui panel is **not** touched.

---

## How it differs from PicoTun

| | PicoTun | PicoStream |
|---|---------|-----------|
| V2Ray | Installs its own Xray | Uses your existing 3x-ui |
| Setup | Full stack | Tunnel layer only |
| Complexity | Higher | Minimal |
| Use case | Fresh VPS | Already have 3x-ui |

---

## License

MIT — see [LICENSE](LICENSE)
