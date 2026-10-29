# WireGuard VPN

WireGuard and StreamHub port forwarding for a router behind a VPS with a public IPv4 address. The VPS provides the public endpoint; the router keeps the tunnel open from its own network and publishes one Haivision StreamHub.

It is the StreamHub-only edition of [HAIBOX WireGuard](https://github.com/simonemessina92/haibox-wireguard): same wizard, Web UI, apply/rollback and persistence, without the other HAIBOX devices.

## Install

On a Debian or Ubuntu VPS, run as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/simonemessina92/wireguard-VPN/main/install.sh)
```

The installer downloads the latest Golden release, checks its SHA-256 file and starts the setup menu. Choose **INSTALL + WEB UI**, then open `https://VPS_PUBLIC_IP:65000`. WireGuard uses UDP `443` by default. The first login is `admin` / `password`; you must change that password before setup continues.

Use a separate test VPS for development builds:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/simonemessina92/wireguard-VPN/develop/install-dev.sh)
```

## First setup

The wizard asks for the router LAN address and subnet, applies the VPS configuration and shows the WireGuard profile for the router. Copy or download the `.conf`, or use its QR code. A separate tab offers a Remote VPN Client profile for a phone or computer. Once the router tunnel is reachable, finish the wizard to open Overview.

## What it includes

- **Overview:** WireGuard Router and Remote VPN Client peers, StreamHub status, Public Services links and a four-minute RX/TX graph for Router, StreamHub and other VPN traffic.
- **Configuration:** core network values, StreamHub IP, extra port forwards, DMZ and an optional **Domain** for Public Services links. The domain changes Web UI links only; DNS is configured separately.
- **VPN Profiles:** router and Remote VPN Client configurations with copy, download and QR actions.
- **Apply and persistence:** validation, backup and rollback on failure; saved rules and services survive a VPS reboot.
- **Remove All** from Configuration (type `REMOVE`) or the terminal menu (type `YES`).
- **Credential reset:** run the script with `--reset-webui-credentials` (or menu option 9) to restore `admin` / `password`.

The router provides full-tunnel Internet access through the VPS. StreamHub ports use public DNAT and WireGuard-side hairpin rules. The Remote VPN Client reaches the LAN without using the VPS as its general Internet gateway.

## Default addresses

| Component | Address |
|---|---|
| Router LAN | `192.168.10.1/24` |
| StreamHub | `192.168.10.101` |
| VPS WireGuard | `10.66.66.1` |
| Router WireGuard | `10.66.66.2` |
| Remote VPN Client | `10.66.66.3` |

## StreamHub ports

Forwarded unchanged (public port = StreamHub port), from the StreamHub 4.4 network port requirements:

| Protocol | Ports |
|---|---|
| TCP | `443`, `1935`, `5322`, `7900`, `7901-7940`, `8444`, `8884`, `8885`, `8888`, `8891`, `8893`, `8896`, FTP `20`, `21`, `12000-12009` |
| UDP | `5010-5026`, `5353`, `5959-5999`, `6960-6999`, `7900-7940`, `7960-7999`, `20000-20100`, `20400-20499` |

The VPS must have a public IPv4 address, root access, UDP `443` available for WireGuard and TCP `65000` available for the Web UI unless you change those ports.

[v1.0 script](https://github.com/simonemessina92/wireguard-VPN/releases/download/v1.0/wireguard-vpn_v1.0.sh) · [SHA-256](https://github.com/simonemessina92/wireguard-VPN/releases/download/v1.0/wireguard-vpn_v1.0.sh.sha256) · [Changelog](CHANGELOG.md) · [Release notes](releases/)

WireGuard is a registered trademark of Jason A. Donenfeld. This project is not affiliated with or endorsed by the WireGuard project.

Maintained by Simone Messina.
