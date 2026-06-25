<div align="center">

# ⚡ VELAR

### The open router OS that doesn't feel like 2009.

**A full firewall, router, and network security platform — built on Debian 12, wrapped in a UI you'll actually want to use.**

[![Debian 12](https://img.shields.io/badge/Debian-12%20Bookworm-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![FastAPI](https://img.shields.io/badge/Backend-FastAPI-009688?logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com/)
[![Vue 3](https://img.shields.io/badge/Frontend-Vue%203-4FC08D?logo=vuedotjs&logoColor=white)](https://vuejs.org/)
[![nftables](https://img.shields.io/badge/Firewall-nftables-orange)](https://netfilter.org/projects/nftables/)
[![Suricata](https://img.shields.io/badge/IDS%2FIPS-Suricata%208-c0392b)](https://suricata.io/)
[![License](https://img.shields.io/badge/License-See%20LICENSE-lightgrey)](#license)

[**Quick Install**](#-quick-install) · [**Features**](#-whats-inside) · [**Docs**](#-documentation) · [**API Reference**](#-api-reference) · [**Screenshots**](#-screenshots)

</div>

---

## Why Velar?

Commodity x86-64 or ARM64 hardware. One install script. A router that does what a $2,000 appliance does — firewall, VPN, IDS/IPS, multi-WAN failover, VLANs — through an interface that doesn't look like it was designed for a CRT monitor.

No license tiers. No paywalled modules. No "contact sales" buttons. Every feature ships in the base image.

```bash
wget https://raw.githubusercontent.com/your-org/velar/main/velar_install.sh
chmod +x velar_install.sh
sudo ./velar_install.sh
```

That's the whole install. Answer a few prompts, grab coffee, get a router.

---

## 🧩 What's inside

| | |
|---|---|
| 🔥 **nftables Firewall** | Stateful rules, NAT, DNAT/port forwarding, drag-to-reorder, service profiles |
| 🌐 **Multi-WAN / SD-WAN** | Automatic failover, health checks, symmetric routing across links |
| 🏷️ **VLANs (802.1Q)** | Per-VLAN firewall policy, DHCP, and DNS — segment your network in clicks |
| 📡 **DHCP — ISC KEA** | Subnets, pools, static reservations, live lease tracking, MariaDB-backed |
| 🧭 **DNS — Unbound** | Recursive resolver, local records, split-horizon forward zones, cache stats |
| 🛡️ **IDS/IPS — Suricata 8** | Emerging Threats ruleset, IDS or inline-block mode, live alert feed |
| 🚫 **Web & App Control** | Domain blocklists, nDPI-based app fingerprinting, per-VLAN policy |
| 🔐 **WireGuard VPN** | Multiple tunnels, road-warrior and site-to-site, QR-ready peer configs |
| 🧑‍💻 **REST API** | Every single feature above is fully scriptable — see the [API Reference](#-api-reference) |
| 🔑 **Security that's actually there** | TOTP 2FA, rate limiting, account lockout, full audit log |
| 💾 **Backups** | One-click export/restore, scheduled snapshots, remote SFTP targets |
| 🖥️ **Web Terminal** | SSH into the box without leaving the browser |

---

## 📸 Screenshots

> _Drop your dashboard / firewall / VLAN screenshots here before publishing —
> a GIF of the SD-WAN failover or the live Suricata alert feed sells this hard._

<div align="center">
<img src="docs/assets/dashboard.png" width="800" alt="Velar Dashboard">
</div>

---

## 🖥️ Requirements

| Component | Minimum | Recommended |
|---|---|---|
| OS | Debian 12 (Bookworm), x86-64 or ARM64 | same |
| CPU | 64-bit, 2 cores | 4+ cores |
| RAM | 2 GB | 4 GB+ |
| Storage | 16 GB | 32 GB SSD |
| NICs | 2 | 3+ (for VLAN trunking / multi-WAN) |

---

## 🚀 Quick Install

```bash
wget https://raw.githubusercontent.com/fernandofriasn/Velar-Firewall/main/install_script.sh
chmod +x velar_install.sh
sudo ./velar_install.sh
```

The installer asks for your WAN/LAN interfaces, a WireGuard subnet, and admin credentials — then handles everything: nftables, KEA, Unbound, WireGuard, Suricata (with the Emerging Threats ruleset), MariaDB, and the web panel itself, fronted by nginx.

When it's done:

```
Panel web : http://<your-server-ip>
Usuario   : admin
```

Full walkthrough → [`docs/getting-started/installation.md`](docs/getting-started/installation.md)

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Browser (UI)                         │
│                    Vue 3 · compiled, static                  │
└───────────────────────────┬───────────────────────────────────┘
                            │  nginx (port 80, reverse proxy)
┌───────────────────────────┴───────────────────────────────────┐
│                      Velar API · FastAPI                      │
│   auth · firewall · dhcp · dns · vlans · sdwan · wireguard …  │
└──────┬──────────┬──────────┬──────────┬──────────┬────────────┘
       │          │          │          │          │
   nftables   KEA DHCP    Unbound   Suricata   WireGuard
                            │
                        MariaDB
              (users · sessions · leases · audit log)
```

Every box in that diagram down to MariaDB ships and self-configures from the install script. Nothing is a separate download or a "premium add-on."

---

## 📚 Documentation

| Section | |
|---|---|
| **Getting Started** | [Installation](docs/getting-started/installation.md) · [First Boot](docs/getting-started/first-boot.md) · [Interface Assignment](docs/getting-started/interface-assignment.md) |
| **Networking** | [Interfaces](docs/networking/interfaces.md) · [VLANs](docs/networking/vlans.md) · [DHCP Server](docs/networking/dhcp-server.md) · [DNS Resolver](docs/networking/dns-resolver.md) · [Static Routes](docs/networking/static-routes.md) |
| **Firewall** | [Rules](docs/firewall/firewall-rules.md) · [NAT & Port Forwarding](docs/firewall/nat-port-forwarding.md) |
| **Security** | [IDS/IPS](docs/security/ids-ips.md) · [Web Filter](docs/security/web-filter.md) · [Application Control](docs/security/application-control.md) · [WireGuard VPN](docs/security/wireguard.md) |
| **System** | [Backups](docs/system/backups.md) · [Logs](docs/system/logs.md) · [Users & Roles](docs/system/users-roles.md) · [Updates](docs/system/updates.md) |

---

## 🔌 API Reference

Every module in Velar is a REST endpoint before it's a UI screen. Auth, firewall, VLANs, DHCP, DNS, WireGuard, SD-WAN, Suricata, system stats — all scriptable.

```http
POST /api/auth/login
GET  /api/firewall/rules
POST /api/vlans/
GET  /api/sdwan/status
POST /api/wireguard/peers
```

Full reference with request/response examples → [`docs/api-reference.pdf`](docs/api-reference.pdf)

All endpoints require an `X-Session-Token` header (from `/api/auth/login`), except login itself.

---

## 🤝 Contributing

Issues and PRs are welcome. If you're planning something bigger than a small fix, open an issue first so we're not duplicating work.

```bash
git clone https://github.com/your-org/velar.git
cd velar
```

Frontend dev:
```bash
cd router-ui && npm install && npm run dev
```

Backend dev:
```bash
cd router-api && python3 -m venv venv && venv/bin/pip install -r requirements.txt
venv/bin/python main.py
```

---

## 📄 License

> _Fill this in once you've decided — MIT/AGPL for open core, or "proprietary, contact us" for closed. Either way, say it here so nobody has to ask._

---

<div align="center">

**Built for people who think a router's web UI shouldn't feel like punishment.**

[Report a bug](../../issues) · [Request a feature](../../issues) · [Discussions](../../discussions)

</div>
