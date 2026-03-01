# PicoStream

**DNS Tunnel layer for 3x-ui / V2Ray — Two-server architecture**

Users connect with a **normal V2Ray link** (VLESS/VMess/Trojan) — no special client app needed.  
Traffic is hidden inside DNS queries, bypassing firewalls that block 4% of ports.

```
User (v2rayNG / Hiddify — normal VLESS config)
         |
         | TCP — any port (443 / 80 / 8080)
         v
  ┌─────────────────────┐
  │   RELAY Server      │  ← Server 1 (can be in restricted zone)
  │  slipstream-client  │
  └─────────────────────┘
         |
         | DNS tunnel (UDP port 53)
         | traffic looks like normal DNS queries
         v
  ┌─────────────────────┐
  │   EXIT Server       │  ← Server 2 (outside / free zone)
  │  slipstream-server  │
  │  3x-ui panel        │
  └─────────────────────┘
         |
         v
      Internet
```

---

## Requirements

| | Relay (Server 1) | Exit (Server 2) |
|---|---|---|
| Location | Anywhere (even restricted) | Outside / free network |
| What runs | slipstream-client | slipstream-server + 3x-ui |
| Open ports | TCP ENTRY_PORT (e.g. 443) | UDP 53 |
| OS | Ubuntu 22.04+ / Debian 12+ | Ubuntu 22.04+ / Debian 12+ |

---

## Installation

### Step 1 — Exit Server (outside, with 3x-ui)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-exit.sh)
```

This installs `slipstream-server` and forwards traffic to your existing 3x-ui panel.

### Step 2 — Relay Server (entry point)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/amir6dev/PicoStream/main/install-relay.sh)
```

This installs `slipstream-client`, sets up iptables, and outputs a ready-to-use V2Ray link.

---

## How it works

1. User imports the V2Ray link (pointing to relay server's IP and entry port)
2. v2rayNG connects normally to relay server TCP port
3. Relay server's iptables redirects incoming TCP → local slipstream-client
4. slipstream-client wraps the traffic inside DNS queries and sends to exit server
5. DNS queries pass through public resolvers (1.1.1.1, 8.8.8.8) to exit server
6. Exit server's slipstream-server decodes DNS → forwards to 3x-ui
7. 3x-ui handles the actual V2Ray protocol and routes to internet

---

## Why DNS tunnel bypasses firewalls

Restrictive firewalls (like in Iran with 4% open networks) usually allow:
- UDP port 53 (DNS) — always open, queries to 1.1.1.1/8.8.8.8 look normal
- TCP port 80/443 — usually open for HTTP/HTTPS

PicoStream hides your entire traffic inside legitimate-looking DNS requests.

---

## Management

**Exit server:**
```bash
picostream-exit status
picostream-exit logs
picostream-exit restart
picostream-exit uninstall
```

**Relay server:**
```bash
picostream-relay status
picostream-relay logs
picostream-relay restart
picostream-relay link      # show client V2Ray link
picostream-relay uninstall
```

---

## Client Apps

Users import the generated V2Ray link — any standard app works:

| App | Platform |
|-----|----------|
| **v2rayNG** | Android |
| **Hiddify** | Android / iOS / Windows / macOS |
| **NekoRay** | Windows / Linux |
| **V2Box** | iOS |

---

## Firewall checklist

**Exit server:** open UDP 53 (or your chosen tunnel port)

**Relay server:** open TCP on your entry port (443, 80, 8080, etc.)

```bash
# UFW
ufw allow 53/udp       # exit server
ufw allow 443/tcp      # relay server

# firewalld
firewall-cmd --add-port=53/udp --permanent
firewall-cmd --add-port=443/tcp --permanent
firewall-cmd --reload
```

---

## Troubleshooting

**Relay logs:**
```bash
journalctl -u picostream-relay -n 50
```

**Exit logs:**
```bash
journalctl -u picostream-exit -n 50
```

**Test DNS tunnel from relay:**
```bash
nslookup google.com 1.1.1.1
```

**Check iptables redirect:**
```bash
iptables -t nat -L PREROUTING -n -v
```

---

## License

MIT — see [LICENSE](LICENSE)
