# CLAUDE.md — WireGuard VPN

Guidance for Claude Code sessions working in this repository. The script runs
on VPSs that carry live StreamHub traffic. Correctness and safety matter more
than speed.

This project is the StreamHub-only edition of
[`simonemessina92/haibox-wireguard`](https://github.com/simonemessina92/haibox-wireguard)
(forked from v6.8). Never modify that repository from work on this one.

## 1. What the project is

A single Bash script, `wireguard-vpn.sh`, run as root on a Debian/Ubuntu VPS
(systemd) with a public IPv4 address. It turns the VPS into the public endpoint
for a router and its LAN with one Haivision StreamHub.

The script:

- installs WireGuard, iptables, Python 3 and helpers;
- writes `wg0` (VPS server), the router peer profile (full tunnel) and an
  optional Remote VPN Client profile (LAN-only split tunnel);
- builds NAT/forwarding in owned chains `WGVPN_NAT` and `WGVPN_FWD`: Internet
  breakout (MASQUERADE), public DNAT to the StreamHub, WireGuard-side hairpin
  DNAT, SNAT to the VPS WireGuard IP, extra port-forward rules and optional DMZ;
- persists everything (`wgvpn-wg-rules.service`, `wg-quick@wg0`, sysctl);
- generates and runs an HTTPS Web UI (Python, port 65000) with login,
  first-run wizard, dashboard, configuration editor, VPN profiles/QR codes and
  Remove All.

## 2. Repository layout

| Path | Purpose |
|---|---|
| `wireguard-vpn.sh` | The whole product. Bash + an embedded Python Web UI. |
| `install.sh` | Production installer: latest GitHub Release asset, verifies `.sha256`, installs to `/root/wireguard-vpn.sh`. |
| `install-dev.sh` | Development installer from the `develop` branch (no checksum), installs to `/root/wireguard-vpn-dev.sh`. Test VPSs only. |
| `CHANGELOG.md` | Release history (`[Unreleased]` on top). |
| `releases/` | Release notes, one file per Golden, and the release procedure. |
| `.github/release-request.json` | Release trigger (does not exist until the first release). |
| `.github/workflows/release.yml` | Publishes a release when `release-request.json` changes on `main`. |
| `.github/workflows/release-notes.yml` | Updates notes of the current release when `releases/*.md` changes on `main`. |

## 3. Structure of `wireguard-vpn.sh`

Same layout as HAIBOX WireGuard: header (`# Version X.Y` on line 5), constants,
helpers, state load/save, `write_webui_app()` with the Web UI in the quoted
heredoc `<<'PYEOF'` … `PYEOF`, then WireGuard, firewall, persistence, health,
`remove_all`, `validate_config`, `apply_runtime` (lock + backup + rollback),
`menu` and the entry point.

Critical coupling — do not break:

- `validate_config` extracts the Web UI source by splitting on the first
  `<<'PYEOF'\n` and the next `\nPYEOF`. Bash and the Web UI share one validator.
- The Web UI calls the installed self-copy `/usr/local/sbin/wireguard-vpn`
  with flags (`--web-apply`, `--web-test`, `--health`, `--create-remote-client`,
  `--ensure-webui-input`, `--print-webui-access`, `--reset-webui-credentials`,
  `--web-remove`). A new flag goes in both `run_noninteractive_command` and the
  allow-list at the end of the file; unknown flags must fail.
- StreamHub ports live in two places that must match: the `dnat_*` calls in
  `iptables_apply_rules` and `STREAMHUB_TCP_PORTS` / `STREAMHUB_UDP_PORTS` in the
  Web UI (used for collision validation).
- The version string appears on line 5, `SCRIPT_VERSION`, `RELEASE_CHANNEL`,
  `server_version = "WireGuardVPN-WebUI/X.Y"`, the System Health banner and the
  menu banner.

## 4. Checks you can run here (static only)

Never run `wireguard-vpn.sh`, `install.sh` or `install-dev.sh` in a Claude
session: they require root and rewrite networking on the host.

```bash
bash -n wireguard-vpn.sh install.sh install-dev.sh
grep -c $'\r' wireguard-vpn.sh            # must print 0
tmp="$(mktemp -d)"
sed -n "/<<'PYEOF'$/,/^PYEOF$/p" wireguard-vpn.sh | sed '1d;$d' > "$tmp/webui.py"
python3 -m py_compile "$tmp/webui.py"
shellcheck -S warning wireguard-vpn.sh install.sh install-dev.sh
# Accepted: SC2034 label (extra rule parser), SC1090 non-constant source.
```

Offline validator smoke test:

```bash
python3 -I - wireguard-vpn.sh <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text(encoding="utf-8")
app = src.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
ns = {"__name__": "wgvpn_validation"}
exec(compile(app, "wgvpn_webui.py", "exec"), ns)
st = dict(ns["DEFAULTS"], PUB_IP="203.0.113.10", PUB_IFACE="eth0")
_, errors, _ = ns["apply_form_values"]({k: [v] for k, v in st.items()}, st)
print("errors:", errors)                     # expected: []
PY
```

Static checks are never sufficient: a Golden is declared only after testing on
a real VPS + router + StreamHub and Simone's confirmation.

## 5. Branches and workflow

- `main` — the current Golden only (byte-identical to the latest release asset
  once releases exist).
- `develop` — development; feature branches merge here through PRs.

1. Claude develops on `develop` (feature branch + PR).
2. Simone installs the `develop` build on a test VPS with `install-dev.sh`.
3. Only when Simone writes **"golden"** for that build does Claude bring it to
   `main` and publish the release. Never push to `main` or create a release
   without that explicit word for that specific build.
4. After the release, align `develop` with `main`.

Commit messages: short imperative English (`fix: …`, `feat: …`, `docs: …`).
All repository text is in English. Talk to Simone in Italian.

## 6. Safety rules

- Never print, log, commit or upload WireGuard keys, generated `.conf`
  profiles, `/root/wgvpn_webui_auth.conf`, the Web UI TLS key, password hashes,
  VPS public IPs or support bundles.
- Never modify a published release asset or move a tag.
- Keep: apply serialization (`/run/wgvpn-apply.lock`), backup + rollback, key
  reuse (no silent rotation), both DNAT paths (public and `-i wg0 -d PUB_IP`
  hairpin), router online only after an active reachability check, idempotent
  rules in owned chains.
- Keep it a single deployable script.
- Upgrades in place must keep configuration, keys, profiles and Web UI
  credentials.
