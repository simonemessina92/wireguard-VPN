# Changelog

All notable WireGuard VPN releases are recorded here. Development builds are not Golden releases until they pass physical regression testing and receive explicit approval.

## [Unreleased]

## [1.0] — 2026-10-29

First version, derived from HAIBOX WireGuard v6.8.

- Publishes a single StreamHub with the same port set as HAIBOX WireGuard.
- Removed Proxmox, Makito X4E, HSG/HMG, Windows Orchestrator and the router admin/LuCI port forwards, with their settings and UDP ranges.
- Overview shows WireGuard Router and Remote VPN Client peers, StreamHub status and Router/StreamHub/Other VPN traffic.
- Extra Port Forwarding, DMZ, Domain, VPN Profiles and Remove All are unchanged.
- WireGuard logo and red accents in the Web UI. Files, services and iptables chains use the `wgvpn` / `WGVPN_` names.
