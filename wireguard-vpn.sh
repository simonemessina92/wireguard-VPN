#!/usr/bin/env bash
set -euo pipefail

# WireGuard VPN
# Version 1.0
# Simone Messina

STATE_FILE="/root/wgvpn_wg_state.conf"
APPLIED_STATE_FILE="/root/wgvpn_wg_applied.conf"
ROUTER_CONF_OUT="/root/wgvpn_router_wg.conf"
REMOTE_CLIENT_CONF_OUT="/root/wgvpn_remote_client_wg.conf"

WG_NAME="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_NAME}.conf"

SYSCTL_FILE="/etc/sysctl.d/99-wgvpn-wg.conf"
UNIT_NAME="wgvpn-wg-rules.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
RULES_FILE="/etc/wgvpn-wg-rules.v4"

WEBUI_DIR="/opt/wgvpn-webui"
WEBUI_APP="${WEBUI_DIR}/wgvpn_webui.py"
WEBUI_CERT_FILE="${WEBUI_DIR}/wgvpn_webui.crt"
WEBUI_KEY_FILE="${WEBUI_DIR}/wgvpn_webui.key"
WEBUI_AUTH_FILE="/root/wgvpn_webui_auth.conf"
WEBUI_SERVICE_NAME="wgvpn-webui.service"
WEBUI_SERVICE_FILE="/etc/systemd/system/${WEBUI_SERVICE_NAME}"
SCRIPT_INSTALL_PATH="/usr/local/sbin/wireguard-vpn"
WEBUI_RULE_COMMENT="WGVPN_WEBUI"

TAG_CHAIN_NAT="WGVPN_NAT"
TAG_CHAIN_FWD="WGVPN_FWD"
TAG_CHAIN_STATS="WGVPN_STATS"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLU}[INFO]${NC} $*"; }
ok()  { echo -e "${GRN}[OK]${NC}   $*"; }
warn(){ echo -e "${YLW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC}  $*" 1>&2; }

need_root() { [[ "${EUID}" -eq 0 ]] || { err "Run as root."; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
iptables() { command iptables -w 10 "$@"; }
pause() { read -r -p "Press Enter to continue... " _; }

script_real_path() {
  readlink -f "$0" 2>/dev/null || echo "$0"
}

normalize_yes_no() {
  case "${1:-N}" in
    Y|y|YES|yes|Yes|TRUE|true|1) echo "Y" ;;
    *) echo "N" ;;
  esac
}

valid_tcp_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1024 && "$1" <= 65535 ))
}

valid_webui_user() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

EULA_FLAG="/root/.wgvpn_eula_accepted"

show_eula_if_needed() {
  if [[ -f "${EULA_FLAG}" ]]; then
    return 0
  fi

  clear || true
  cat <<'EOF'
=====================================================================
WIREGUARD VPN - SOFTWARE NOTICE
=====================================================================

WireGuard VPN was developed by Simone Messina.

This software configures networking, routing, firewall, NAT, WireGuard,
and service exposure on the host where it is executed. Review the
configuration before applying it to production systems.

The software is provided "as is", without warranty of any kind.
The author assumes no responsibility or liability for damages,
misconfigurations, service interruptions, security incidents, or data
loss resulting from its use.

The copyright and software license for this project are defined by the
LICENSE file distributed with the project repository.

By proceeding, you confirm that you understand that this software can
modify the network and firewall configuration of the VPS.
=====================================================================
EOF

  echo
  read -r -p "Do you accept these terms and wish to continue? [Y/N]: " ans
  case "${ans}" in
    Y|y)
      touch "${EULA_FLAG}"
      ok "Terms accepted."
      sleep 1
      ;;
    *)
      err "Terms not accepted. Exiting."
      exit 1
      ;;
  esac
}

default_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

default_public_ip() {
  if have_cmd curl; then
    curl -4 -s --max-time 3 https://ifconfig.me || true
  fi
}

cidr_prefix() { echo "$1" | awk -F'/' '{print $2}'; }

load_state() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
  fi
}

load_webui_auth() {
  if [[ -f "${WEBUI_AUTH_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${WEBUI_AUTH_FILE}"
  fi
}

save_state() {
  local key value temporary
  temporary="$(mktemp "${STATE_FILE}.XXXXXX")"
  for key in LAN_CIDR ROUTER_LAN_IP STREAMHUB_IP \
    UFW_WAS_ACTIVE PYTHON3_INSTALLED_BY_SCRIPT WG_PORT WG_TUN_CIDR WG_VPS_IP WG_GL_IP REMOTE_CLIENT_IP \
    PUB_IFACE PUB_IP \
    WEBUI_ENABLED WEBUI_PORT WEBUI_USER WEBUI_BIND EXTRA_PF_RULES DMZ_IP PUBLIC_DOMAIN; do
    value="${!key}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '%s="%s"\n' "${key}" "${value}" >> "${temporary}"
  done
  chmod 600 "${temporary}"
  mv -f "${temporary}" "${STATE_FILE}"
}

init_defaults() {
  LAN_CIDR="${LAN_CIDR:-192.168.10.0/24}"
  ROUTER_LAN_IP="${ROUTER_LAN_IP:-192.168.10.1}"
  STREAMHUB_IP="${STREAMHUB_IP:-192.168.10.101}"

  UFW_WAS_ACTIVE="$(normalize_yes_no "${UFW_WAS_ACTIVE:-N}")"
  PYTHON3_INSTALLED_BY_SCRIPT="$(normalize_yes_no "${PYTHON3_INSTALLED_BY_SCRIPT:-N}")"

  WG_PORT="${WG_PORT:-443}"
  WG_TUN_CIDR="${WG_TUN_CIDR:-10.66.66.0/24}"
  WG_VPS_IP="${WG_VPS_IP:-10.66.66.1}"
  WG_GL_IP="${WG_GL_IP:-10.66.66.2}"
  REMOTE_CLIENT_IP="${REMOTE_CLIENT_IP:-10.66.66.3}"

  PUB_IFACE="${PUB_IFACE:-$(default_iface)}"
  PUB_IP="${PUB_IP:-$(default_public_ip)}"

  WEBUI_ENABLED="$(normalize_yes_no "${WEBUI_ENABLED:-N}")"
  WEBUI_PORT="${WEBUI_PORT:-65000}"
  WEBUI_USER="${WEBUI_USER:-admin}"
  WEBUI_BIND="${WEBUI_BIND:-0.0.0.0}"
  EXTRA_PF_RULES="${EXTRA_PF_RULES:-}"
  DMZ_IP="${DMZ_IP:-}"
  PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"

  # Fixed defaults from your StreamHub PDF + chosen fixed range
  STREAMHUB_UDP_7900_FROM="7900"
  STREAMHUB_UDP_7900_TO="7940"

  # StreamHub UDP ranges (fixed defaults)
  MOJOPRO_RETURN_FROM="5010"
  MOJOPRO_RETURN_TO="5026"
  NDI_CONN_UDP_FROM="5961"
  NDI_CONN_UDP_TO="5999"
  NDI_IN_UDP_FROM="6960"
  NDI_IN_UDP_TO="6999"
  NDI_OUT_UDP_FROM="7960"
  NDI_OUT_UDP_TO="7999"
  LIVE_GUEST_FROM="20000"
  LIVE_GUEST_TO="20100"
  SIP_UDP_FROM="20400"
  SIP_UDP_TO="20499"
  SIP_MOJO_UDP_FROM="7901"
  SIP_MOJO_UDP_TO="7940"
}

print_webui_access() {
  echo
  if [[ "${WEBUI_ENABLED}" != "Y" ]]; then
    warn "Web UI is not enabled yet."
    return
  fi
  echo "Web UI access:"
  echo "  URL:      https://${PUB_IP:-SERVER_IP}:${WEBUI_PORT}"
  echo "  Username: ${WEBUI_USER}"
  echo
}

print_extra_pf_rules() {
  echo "  --- Extra Port Forwarding Rules ---"
  if [[ -z "${EXTRA_PF_RULES:-}" ]]; then
    echo "  None"
    echo
    return
  fi

  local row proto public_from public_to target_ip target_from target_to label public_spec target_spec
  local -a rows
  IFS=';' read -ra rows <<< "${EXTRA_PF_RULES}"
  for row in "${rows[@]}"; do
    [[ -n "${row}" ]] || continue
    IFS='|' read -r proto public_from public_to target_ip target_from target_to label <<< "${row}"
    [[ -n "${proto}" && -n "${public_from}" && -n "${public_to}" && -n "${target_ip}" && -n "${target_from}" && -n "${target_to}" ]] || continue
    public_spec="${public_from}"
    target_spec="${target_ip}:${target_from}"
    [[ "${public_from}" != "${public_to}" ]] && public_spec="${public_from}-${public_to}"
    [[ "${target_from}" != "${target_to}" ]] && target_spec="${target_ip}:${target_from}-${target_to}"
    echo "  ${proto^^} ${public_spec} -> ${target_spec}"
  done
  echo
}

print_config() {
  echo
  echo "Current configuration:"
  echo "  LAN CIDR:                ${LAN_CIDR}"
  echo "  Router LAN IP:           ${ROUTER_LAN_IP}"
  echo "  StreamHub IP:            ${STREAMHUB_IP}"
  echo "  DMZ destination:         ${DMZ_IP:-disabled}"
  echo
  echo "  WireGuard UDP port:      ${WG_PORT}"
  echo "  WG tunnel CIDR:          ${WG_TUN_CIDR}"
  echo "  VPS WG IP:               ${WG_VPS_IP}"
  echo "  Router WG IP:            ${WG_GL_IP}"
  echo "  Remote VPN Client WG IP: ${REMOTE_CLIENT_IP}"
  echo
  echo "  VPS public iface:        ${PUB_IFACE:-UNKNOWN}"
  echo "  VPS public IPv4:         ${PUB_IP:-UNKNOWN}"
  echo
  echo "  --- Web UI ---"
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    echo "  Enabled:                 yes"
    echo "  User:                    ${WEBUI_USER}"
    echo "  Bind:                    ${WEBUI_BIND}:${WEBUI_PORT}"
    echo "  URL:                     https://${PUB_IP:-SERVER_IP}:${WEBUI_PORT}"
  else
    echo "  Enabled:                 no"
  fi
  echo
  echo "  --- StreamHub ---"
  echo "  Web/Services TCP:        7900, 7901-7940, 443, 8444, 8888, 8891, 8893, 8896, 8884, 8885, 5322, 1935"
  echo "  FTP TCP:                 20, 21, 12000-12009"
  echo "  UDP fixed:               ${STREAMHUB_UDP_7900_FROM}-${STREAMHUB_UDP_7900_TO}"
  echo "  UDP ranges:              5010-5026, 5353, 5959-5960, 5961-5999, 6960-6999, 7960-7999, 20000-20100, 20400-20499, 7901-7940"
  echo "  NDI conn UDP:            ${NDI_CONN_UDP_FROM}-${NDI_CONN_UDP_TO}"
  echo "  NDI input UDP:           ${NDI_IN_UDP_FROM}-${NDI_IN_UDP_TO}"
  echo "  NDI output UDP:          ${NDI_OUT_UDP_FROM}-${NDI_OUT_UDP_TO}"
  echo "  SIP UDP:                 ${SIP_UDP_FROM}-${SIP_UDP_TO}"
  echo "  SIP MoJoPro UDP:         ${SIP_MOJO_UDP_FROM}-${SIP_MOJO_UDP_TO}"
  echo "  Live Guest UDP:          ${LIVE_GUEST_FROM}-${LIVE_GUEST_TO}"
  echo "  MoJoPro return UDP:      ${MOJOPRO_RETURN_FROM}-${MOJOPRO_RETURN_TO}"
  echo
  print_extra_pf_rules
  echo "  --- Quick public access ---"
  echo "  StreamHub Web:           https://${PUB_IP}:443"
  echo "  StreamHub Alt Web:       https://${PUB_IP}:8444"
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    echo "  Web UI:                  https://${PUB_IP}:${WEBUI_PORT}"
  fi
  echo
}

prompt_config() {
  print_config
  echo "Edit core values (press Enter to keep current)."
  echo

  read -r -p "LAN CIDR [${LAN_CIDR}]: " v; [[ -n "${v}" ]] && LAN_CIDR="${v}"
  read -r -p "Router LAN IP [${ROUTER_LAN_IP}]: " v; [[ -n "${v}" ]] && ROUTER_LAN_IP="${v}"
  read -r -p "StreamHub IP [${STREAMHUB_IP}]: " v; [[ -n "${v}" ]] && STREAMHUB_IP="${v}"

  read -r -p "WireGuard UDP port [${WG_PORT}]: " v; [[ -n "${v}" ]] && WG_PORT="${v}"
  read -r -p "WG tunnel CIDR [${WG_TUN_CIDR}]: " v; [[ -n "${v}" ]] && WG_TUN_CIDR="${v}"
  read -r -p "VPS WG IP [${WG_VPS_IP}]: " v; [[ -n "${v}" ]] && WG_VPS_IP="${v}"
  read -r -p "Router WG IP [${WG_GL_IP}]: " v; [[ -n "${v}" ]] && WG_GL_IP="${v}"
  read -r -p "Remote VPN Client WG IP [${REMOTE_CLIENT_IP}]: " v; [[ -n "${v}" ]] && REMOTE_CLIENT_IP="${v}"

  read -r -p "VPS public iface [${PUB_IFACE}]: " v; [[ -n "${v}" ]] && PUB_IFACE="${v}"
  read -r -p "VPS public IPv4 [${PUB_IP}]: " v; [[ -n "${v}" ]] && PUB_IP="${v}"

  save_state
  ok "Saved ${STATE_FILE}"
}

automatic_webui_setup() {
  WEBUI_USER="${WEBUI_USER:-admin}"
  WEBUI_PORT="${WEBUI_PORT:-65000}"
  WEBUI_BIND="0.0.0.0"
  WEBUI_ENABLED="Y"
  if [[ ! -s "${WEBUI_AUTH_FILE}" ]]; then
    WEBUI_USER="admin"
    WEBUI_PASSWORD="password"
    WEBUI_FORCE_PASSWORD_CHANGE="Y"
    ok "Initial Web UI credentials configured: admin / password"
    warn "A new password will be required at the first login."
  else
    ok "Existing Web UI credentials preserved."
  fi
}

install_deps() {
  have_cmd apt-get && have_cmd systemctl || { err "Debian/Ubuntu with systemd is required."; exit 1; }
  log "Installing packages..."
  if ! dpkg -s python3 >/dev/null 2>&1; then
    PYTHON3_INSTALLED_BY_SCRIPT="Y"
  fi
  apt-get update -y
  apt-get install -y wireguard wireguard-tools iptables iproute2 iputils-ping curl ca-certificates python3 openssl util-linux qrencode
  save_state
  ok "Packages installed."
}

install_self_copy() {
  local src
  src="$(script_real_path)"
  [[ -f "${src}" ]] || { err "Cannot locate the running script on disk."; exit 1; }
  if [[ "${src}" != "${SCRIPT_INSTALL_PATH}" ]]; then
    install -D -m 700 "${src}" "${SCRIPT_INSTALL_PATH}"
  fi
  ok "Installed script copy to ${SCRIPT_INSTALL_PATH}"
}

write_webui_auth() {
  [[ -n "${WEBUI_PASSWORD:-}" ]] || { err "Web UI password is empty."; exit 1; }
  python3 - "${WEBUI_USER}" "${WEBUI_AUTH_FILE}" "${WEBUI_FORCE_PASSWORD_CHANGE:-N}" 3<<< "${WEBUI_PASSWORD}" <<'PY'
import hashlib
import os
import secrets
import signal
import sys

user = sys.argv[1]
with os.fdopen(3, "r", encoding="utf-8") as password_input:
    password = password_input.read()[:-1]
out_path = sys.argv[2]
force_password_change = sys.argv[3]
salt = secrets.token_hex(16)
iterations = 200000
digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), bytes.fromhex(salt), iterations).hex()

def esc(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')

content = "\n".join([
    f'WEBUI_USER="{esc(user)}"',
    f'WEBUI_PASS_SALT="{salt}"',
    f'WEBUI_PASS_ITERATIONS="{iterations}"',
    f'WEBUI_PASS_HASH="{digest}"',
    f'WEBUI_FORCE_PASSWORD_CHANGE="{force_password_change}"',
]) + "\n"

with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(content)

os.chmod(out_path, 0o600)
PY
  unset WEBUI_PASSWORD
  ok "Wrote ${WEBUI_AUTH_FILE}"
}

write_webui_cert() {
  mkdir -p "${WEBUI_DIR}"

  if [[ -s "${WEBUI_CERT_FILE}" && -s "${WEBUI_KEY_FILE}" ]]; then
    ok "Using existing Web UI TLS certificate."
    return
  fi

  local cert_host san_ext
  cert_host="${PUB_IP:-wgvpn-webui.local}"
  if [[ "${cert_host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    san_ext="subjectAltName=IP:${cert_host}"
  else
    san_ext="subjectAltName=DNS:${cert_host}"
  fi

  if openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "${WEBUI_KEY_FILE}" \
      -out "${WEBUI_CERT_FILE}" \
      -subj "/CN=${cert_host}" \
      -addext "${san_ext}" >/dev/null 2>&1; then
    :
  else
    warn "OpenSSL -addext failed; generating Web UI certificate without SAN."
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "${WEBUI_KEY_FILE}" \
      -out "${WEBUI_CERT_FILE}" \
      -subj "/CN=${cert_host}" >/dev/null 2>&1
  fi

  chmod 600 "${WEBUI_CERT_FILE}" "${WEBUI_KEY_FILE}"
  ok "Wrote Web UI TLS certificate: ${WEBUI_CERT_FILE}"
}

write_webui_app() {
  mkdir -p "${WEBUI_DIR}"
  cat > "${WEBUI_APP}" <<'PYEOF'
#!/usr/bin/env python3
import base64
import hashlib
import hmac
import html
import io
import ipaddress
import json
import os
import platform
import re
import secrets
import signal
import socket
import ssl
import subprocess
import sys
import tarfile
import time
import tempfile
import threading
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, unquote

STATE_FILE = "/root/wgvpn_wg_state.conf"
AUTH_FILE = "/root/wgvpn_webui_auth.conf"
ROUTER_CONF_OUT = "/root/wgvpn_router_wg.conf"
REMOTE_CLIENT_CONF_OUT = "/root/wgvpn_remote_client_wg.conf"
SCRIPT_PATH = "/usr/local/sbin/wireguard-vpn"
WEBUI_SERVICE_NAME = "wgvpn-webui.service"
CERT_FILE = "/opt/wgvpn-webui/wgvpn_webui.crt"
KEY_FILE = "/opt/wgvpn-webui/wgvpn_webui.key"
APPLIED_STATE_FILE = "/root/wgvpn_wg_applied.conf"
SCRIPT_VERSION = "1.0"
RELEASE_CHANNEL = "GOLDEN"
WIZARD_PENDING_FILE = "/root/wgvpn_wizard_pending"
LOGO_URL = (
    "data:image/png;base64,"
    "iVBORw0KGgoAAAANSUhEUgAAAdgAAACMCAMAAADob0j+AAAAwFBMVEUAAACIFxr+/v6IFxmHFhqIFxmHFxmHGRqHFxqHFhqQJiny"
    "5ueXNjjSqKnIlpexaGrauLi4dnjq1teqAADixseiSkyoVliAAADCiImLHSD/AACIJCSeQkSZADOKECG+gIKcPUCsXmDOn6Dv3+De"
    "v8DfwMG9f4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAABUt9BhAAAAQHRSTlMA/v+M0rEuE29P////////////A////wL//wEH/wUP//////////8AAAAAAAAAAAAAAAAAAAAA"
    "AAAAAAAAAAAAsKoVwAAADxFJREFUeNrtXdl26rgSjZFly/OADRgISU5O3///xAt40qwSBGLOUj306m4DdrRVu0aV397ulDAMgyAI"
    "w/c3J/+AhAFBCPuxR0t83GBEoiB06/OSmEYIe3rxMYoCt1KvBarPKmmRJaurJHW52zAajEmwdkv2CqgSTlN7GOPNrlyN0lQsO+PI"
    "8fKy5RCJ/NtVZV6k1389VqPmrrLU47A9uOVbrLIiuTGN84uW/vnfV5t+bia1LVvuY8gZ3EVKgNR+0hVaQQRo/cgt4yvBeiXkopFA"
    "mwuecrR1a/kCJMzIMROR/Z8YBDmtXY5EHkjaWkR2I34MO1u7EHVVZiLSIs/yvOoD100ms7MyZD3kPOQlq2tLWdX6WwbqNfapq7Y7"
    "f7qqaD52SvvbslZb102z0kvaMUpc06EtcemohdLwFdpaC2zBQZ8caUvrklG/GeT4Bn+pSFYWkqSOjpeBq9kTjq2QLZnvusBnyVFO"
    "bgPsis0gE7fGy41eC5OS5rR8eg7ZF+Dha77JYFY3aRpfRP5th+xScfVisOdUOGRfCFfPg3pPf+Vfdx7Uc+NXH4ZqUep09Cz19+Wf"
    "l/9QkLFD9pmyxTBYVQmKrNqkNJDHMouVv+Li2ecJgcCaKlOKtWcjvstBLcrAFtA8hFGwW/HnyMm/N35N7ZB1ZvY5AmmX8Lq0Lapd"
    "nkn5OLMD1nNkvJyME+UZ5WLE8+HI+GUjHTpJIaqtxgt2ZLxgImbdY1lTTH10ZLwshbVWV1V9p7L5FeRW/sGCLXGtNFFP7FT2tUJY"
    "VmOvpRup3n63TmVfVWENga0FHbvM4rIUlvKh6rvo2KnsMhX2QsqyUk/SOiv72gp7kd09dOxUdkkxLN9pnNyRYHQqu5gYFljLKzuX"
    "fvpVIfZmtS12eZZlebUZKjpddjOyvkPgQWKZJW5zxg9OyiJWpSxKx8Wv4jrFO6k5vfjAbQI42+5aFhfpOikTxKumlVZ7QL6x4+KH"
    "yBqO64e29z/2uvK2rgrHxb/KxGljbg0vbwp6HBf/JhMX5ubwXIZs67h40T7xDnReshORLR0XL5mJc+hJ2Li+wcoyOYrwItIJyNcr"
    "e9mV0+XKg2dJrQOC/WnA6+nfyE6Aj8NmXprYd7gx+WKsNLu+qs7X584eOg5bGGWGo2XP08A/ZF/n+KblIyHLdsVIZXYDZdGAPLqa"
    "EMiWyScLnje3BeWabE6vt4I5BtzhIKhfqCIXX7U7H5dzXqtobcEDNSAmtvu2AbYWBlQA/OIAwsW+qufiJGyOHxVdZ+5iIzXykwZ2"
    "JGNOZQvLSDaSN5MHygJu9NDu83mGDibBdffQs9bR/mVNbGqH6yrxPtn/sbP0nhRcTJRR70OZeOI0cpJa3YU2CgCiWOmwxPKj+Cp2"
    "pWKOYm1bCcAAoHxV/1v4yFh45GFx8ljkL5iNw5sUtp7INa4kJZ0dtxcgJR5RN7HSG0BPZOI9VqM3zq9bYqdAcIuFZai1yyWx7M4a"
    "2JNRBXu0ZVz8SCYmOuzesfdYt+2hvlNiSv4KQW7D/S+AjeXoVQZVn52QfPgwbAOEzzJcIkgqhNAvfNoirQQzo6nY9uBTDxqRs8h3"
    "QHC5xFmQ/fkZIzENonhu5oUokXA1OFlXAFpzUr8QgK2sa7KRiYuDXlclodDIxPQia3xCHI1+7NrsqSODfxRSxhepPyq7FMkcA42i"
    "+bPzJkPNR4GdU5wDKuc7PmH8YRxKrY8HQ5HhSP8pSVpqVG8gsDMUZmBDY42CEC166ktbX0YFBLT7kTldYnaKa8AAkS7hbOof61o7"
    "kfBuJMkThwIXv49rDwZ2nGtiBpbYOEd2wEYS38JoGiMDz+Lp58wnMVaQZANLxl9eY5tS5BdE4OJg1FSBiyefGA6s5+9hwPb7fvsA"
    "YLfyWImAXBG1AR2V1pwp/uSTD2b4ky62nxKEDOUaMq6CwMVovCIASwJBCB2h9MBGgULC4SmgGQgrYCN5KZr06AgSITre73+OucwF"
    "+eYwtoA1umQMExf2JwLwm56Lp4odz8XraXkEYKUUGs23W5sMaGR1HtAG2LUv39FEGZIPiZJQdacpExbCwtgK1nRIf+yT66IobgGW"
    "K8SFs55yXDxnJ2DADmz3DgG2V5P9A4CNFN0jamAHrCL1nYbf9Le3APulOrxDK+jxhulP8jzTVoIzx8UTE0OBDablNAKLrVJaFsD2"
    "FrbnTwQE9m12oxV3CmazbR4BtFuBIpeWxrG5YRAf1ndL+Lz5GK/sZ3CAwB6m7xuB9a2S/BbA9qwRRsID6IDF04+o7hRMiTBz4ukD"
    "BuyGSjNV1rUd2R/DcHFIaynDxcF8BQhsCNdYFbCEk8gS2Pfhh7fCDe7SWCo8I7ZUXJg+1ghFg/Q2YIM5LOFQZrh4ZuIH2FhPX/Hn"
    "2mfhwJLxxoLKaoANTTZ2ongMAbaAqd+YkUhivkux8W4DluFihpdPHn8ltAA2sPCKHwTsYfrdvS/jaLlXjPVeMbtrzcC2MJiS6Q07"
    "/HGBLxiwvm4xQtY7pbiYYmJJHBsKMsaDVBzrY1aQmYrvBJbMEPEBVQ+s+NwB8YU4Vr1tAwCwHYhY2wnX8sYZxopOGF8W+xBuMYkC"
    "WNPd1qYneQywB4oI9j57S4vME1KTTASp2tWQDEUzHMsS54wUNwNL8S9mt3XIecKBLbDaXDE2hzvRLMgeWEJbAE5lLXLFSOdhAYDN"
    "AO8PLYbkhTgZCDx0HCtWg0xArrkFJxwTw4H1tdUdzCcotsaCthWwIWO5OZW1qO4gdUwEAnZjrsemw9zTCvYaWSiwE2pEGhT4dAbZ"
    "Bljy/gYEFpBStAeWsCVJ9h4EUG38IY3tBLB4d+jiB+epd2zumUwtecz9yLOCixsylbpABSzrFg3eR3SQpJm1HWHoR4ENeVebUdke"
    "ENab61mGbqEwAwsZPp0ZhhLHTVl00je1q9/NAgJ25GLJwZyBcBgmNoU7/c9gKvNrBHbwkg4/CWz/hYOCFmThDhZ4Q32nMdiFACt7"
    "2dkfairx2U+Oiwb8Pm+LjvoBN8kfS6grCAjsoA3EBlhi7C+1BTYUQyzaAMiADQVbpb7TuEtAZyj/kx7kyL8GdWx3qpPuOziu0mTC"
    "kAdWal8oySdrgN37HJBmYM2tMbZeMdEHMkRZ6aL/GvWd0NDLCxrdtVE0/H+ctbUqE82JyjuBHbhYRod9hMlmNoyZp4Db+mZgh4XC"
    "hvZdClisB/Zk8B6lwG75HakEdnIKYDPZpEcB8tgrtEMpms4G2EDf9YyVTV8IDiy/9QHAGtpPh+o3MgGL2a5H9QoQdd6c+ktVwO5n"
    "cwxadMmbJ/+m6hehWc3bG0V6aHmtVOhQsiPMwPZbf3pFFwDYcQcRHa7DDxJlWX4//g2DueTbhv1J7RW5YsL+qSpgqXOmsAEUhZhP"
    "auvVT+Lq6ZhQtvrTg+8tgOW2PgTY6YiHBLCAPdcZKW3K1OaO5GnxuTlCAeywIw9aYLeIehzgoGK2ubj+NJ6szO1gVVmxSHmZiGES"
    "pLqDaCQgwM6HsnhjsSecQ9/bT/9dAYu3pStvEqr2NdUddkdKgR23GQIlnUehc8BNHBsmPl00emf1Bh5FEmCrdK1C0TZDgO3PZPhb"
    "OLAz6yP6k9vxrB316JhLELEFN6xUWEpllWU7ZkeKvXFj9ef85TXfVKU3sw1FsqnhpcDNMc6upZ47neKZi0/KCsvWDthhCQkFrK8U"
    "zOrs9eDzBbVw6gZlre+4mCgKRrV9nz8aqBV2VNm9GthhR+6pVZkflKa+A+93mjKL5YRrq8c1qbq+nyY53ukUs82iUi5Gb5bADosS"
    "AhrGJ90KMXBH0p/jVxxpFHZWWXWhnd6Rat8arQXvEmhn61ivr8lHvBn9KgudVU3yOejTUsy6woAN+Q4KQPF/CxwuotkBaC85nSKo"
    "7JYYYmGqg8LwOBazii/z4ZNUi2tddSlljr+hdtbXd4CGyjzu1hpYynldw59KCpkf8a6yagf4kT7OnfapsecJq4HFSvYwGtq8aT2N"
    "31RuvI5tV/17n+90gWG2dTwXn6+wg78u5BdQ/64w3OhqP98v7fh6Ye4bIp9fR1mh9kREVcHkcDXV1POpnury5/pIvRT9D3DAnr+H"
    "2QO0b/Zj49VxTp56nTC4YHef77QsCQi6Fv/OCymsI70Fosvn+q2Bke6TD31YKKLH4mNXKEd5fVexF38kt74E2g3J/HHZwsxrOYSn"
    "8nxT83Xm6T/SS//dZ2Kd3CwAIzsSbCl/B2XWhzVx1dxak3XvVHqAGI3s56SlaSeb/UN5vrJXBTf/jIl9MTFFsjtqtERlfHW3pDYA"
    "UNmtg+EB4oMSTtf2RAE1cRSx2FmcOSZeHhfT2f5adIkrUFk+dky8tICHOWDFz4JR1ea62vYwwNqB8GQuLllbmcC6/FNLLnZM/Gwu"
    "ZtODcQr1inawSTOmyo6TB/nFKQdPAT2WE1sZWewQeJQoqkB/uXg0B5vOzGZ0vHOdnuw+MT5wXRb80VeNHlYW3pPvgtgnpxVHtauz"
    "6tiJJ2V1ByRTixKPU9gnq+z1lF2SFbNiJvA3m8FbFp3CPltlN6skbzVoZT8DrFPYZ6tsu9GjZQFs5hR2WVaWEzgVx2CNdQr7S7Es"
    "LTW4HHeEOk8uhv299JPynCz8rE/lWmJ+T7bmPtQ/4LRDBsw9uld4/1qWQpN2yMApRVVDG967ZV8CGbfQBsQKWARwRPwU2WM7t1jp"
    "F8fAzzmP+FmescnMlrAKerYC+U6uDLsYM1uYh7SJ1VgVZWPXN/E8MZyW7SAdiEIno/z8ju8M7IIcqHxlamfrshVs/qnDdUnIprLT"
    "6wxZ15L3P7t2mCUIsp741IyVvfSjlr6x3eG6fJ1VvK69LrOskR+Irh2uL+FB7VaWsnF+02sg29jhKqnYYYfrr8WzvjUZq2ZSiB1v"
    "yJXWfzEHhaxnocpHyKQuj/g6dFzBgW0dDS9PafH9DpTgOEWuTrcEpfXv1FleX5FT12XIgdxjZ2vOvmIXvC6Ij1XQpsaoh5th4GBd"
    "HLT+LYY2+XKwLl32kdyNSjM1ruysYuRgfS21TeXj9xIGVvrNVE5eBdu44rtlkqxgUHWO8AtgGyEJuN3mI6uvhZ2kyaqWHvkZOF19"
    "nQjoMgDU/OYGRAKXEX5F3Q0ug1vxZ0wb0y7+vA5xDU5ugf4FnzkMgyAIQ6egi5L/A6s50H0lyQTGAAAAAElFTkSuQmCC"
)

STATE_KEYS = [
    "PYTHON3_INSTALLED_BY_SCRIPT",
    "LAN_CIDR",
    "ROUTER_LAN_IP",
    "STREAMHUB_IP",
    "UFW_WAS_ACTIVE",
    "WG_PORT",
    "WG_TUN_CIDR",
    "WG_VPS_IP",
    "WG_GL_IP",
    "REMOTE_CLIENT_IP",
    "PUB_IFACE",
    "PUB_IP",
    "WEBUI_ENABLED",
    "WEBUI_PORT",
    "WEBUI_USER",
    "WEBUI_BIND",
    "EXTRA_PF_RULES",
    "DMZ_IP",
    "PUBLIC_DOMAIN",
]

DEFAULTS = {
    "LAN_CIDR": "192.168.10.0/24",
    "ROUTER_LAN_IP": "192.168.10.1",
    "STREAMHUB_IP": "192.168.10.101",
    "UFW_WAS_ACTIVE": "N",
    "WG_PORT": "443",
    "WG_TUN_CIDR": "10.66.66.0/24",
    "WG_VPS_IP": "10.66.66.1",
    "WG_GL_IP": "10.66.66.2",
    "REMOTE_CLIENT_IP": "10.66.66.3",
    "PUB_IFACE": "",
    "PUB_IP": "",
    "WEBUI_ENABLED": "Y",
    "WEBUI_PORT": "65000",
    "WEBUI_USER": "admin",
    "WEBUI_BIND": "0.0.0.0",
    "EXTRA_PF_RULES": "",
    "DMZ_IP": "",
    "PUBLIC_DOMAIN": "",
}

STREAMHUB_TCP_PORTS = [
    (7900, 7900, "StreamHub TCP 7900"),
    (7901, 7940, "StreamHub TCP 7901-7940"),
    (443, 443, "StreamHub HTTPS"),
    (8444, 8444, "StreamHub alternate HTTPS"),
    (8888, 8888, "StreamHub TCP 8888"),
    (8891, 8891, "StreamHub TCP 8891"),
    (8893, 8893, "StreamHub TCP 8893"),
    (8896, 8896, "StreamHub TCP 8896"),
    (8884, 8884, "StreamHub TCP 8884"),
    (8885, 8885, "StreamHub TCP 8885"),
    (5322, 5322, "StreamHub TCP 5322"),
    (1935, 1935, "StreamHub RTMP"),
    (20, 21, "StreamHub FTP"),
    (12000, 12009, "StreamHub passive FTP"),
]

STREAMHUB_UDP_PORTS = [
    (7900, 7940, "StreamHub UDP 7900-7940"),
    (5010, 5026, "StreamHub MoJoPro return"),
    (5353, 5353, "StreamHub mDNS"),
    (5959, 5960, "StreamHub UDP 5959-5960"),
    (5961, 5999, "StreamHub NDI connection"),
    (6960, 6999, "StreamHub NDI input"),
    (7960, 7999, "StreamHub NDI output"),
    (20000, 20100, "StreamHub Live Guest"),
    (20400, 20499, "StreamHub SIP"),
]

USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
SESSION_COOKIE_NAME = "wgvpn_session"
SESSION_STORAGE_KEY = "wgvpn_ui_tab"
SESSION_TTL_SECONDS = 8 * 60 * 60
SESSIONS: Dict[str, Dict[str, object]] = {}
NETWORK_WINDOW_MS = 4 * 60 * 1000
NETWORK_HISTORY = deque(maxlen=240)
NETWORK_HISTORY_LOCK = threading.Lock()


def load_shell_kv(path: str) -> Dict[str, str]:
    data: Dict[str, str] = {}
    file_path = Path(path)
    if not file_path.exists():
        return data
    for raw_line in file_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
            value = re.sub(r'\\([\\"$`])', lambda match: match.group(1), value)
        data[key.strip()] = value
    return data


def shell_escape(value: str) -> str:
    return re.sub(r'([\\"$`])', lambda match: "\\" + match.group(1), value)


def atomic_write(path: str, content: str) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".wgvpn-", dir=str(Path(path).parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            os.chmod(temporary, 0o600)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def merged_state() -> Dict[str, str]:
    state = dict(DEFAULTS)
    state.update(load_shell_kv(STATE_FILE))
    auth = load_shell_kv(AUTH_FILE)
    if auth.get("WEBUI_USER"):
        state["WEBUI_USER"] = auth["WEBUI_USER"]
    return state


def write_state(values: Dict[str, str]) -> None:
    state = merged_state()
    state.update(values)
    lines = [f'{key}="{shell_escape(str(state.get(key, "")))}"' for key in STATE_KEYS]
    atomic_write(STATE_FILE, "\n".join(lines) + "\n")


def applied_state() -> Optional[Dict[str, str]]:
    path = Path("/root/wgvpn_wg_applied.conf")
    if not path.exists():
        return None
    raw = load_shell_kv(str(path))
    if not raw:
        return None
    state = dict(DEFAULTS)
    state.update(raw)
    return state


def password_change_required() -> bool:
    return load_shell_kv(AUTH_FILE).get("WEBUI_FORCE_PASSWORD_CHANGE", "N").upper() == "Y"


def wizard_pending() -> bool:
    return Path(WIZARD_PENDING_FILE).exists()


def write_auth(user: str, password: Optional[str] = None, force_password_change: Optional[bool] = None) -> None:
    auth = load_shell_kv(AUTH_FILE)
    if password:
        salt = secrets.token_hex(16)
        iterations = 200000
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            bytes.fromhex(salt),
            iterations,
        ).hex()
    else:
        salt = auth.get("WEBUI_PASS_SALT", "")
        iterations = int(auth.get("WEBUI_PASS_ITERATIONS", "200000"))
        digest = auth.get("WEBUI_PASS_HASH", "")
        if not salt or not digest:
            raise ValueError("Missing stored password hash. Set a new password.")

    if force_password_change is None:
        force_password_change = auth.get("WEBUI_FORCE_PASSWORD_CHANGE", "N").upper() == "Y"
    content = "\n".join([
        f'WEBUI_USER="{shell_escape(user)}"',
        f'WEBUI_PASS_SALT="{salt}"',
        f'WEBUI_PASS_ITERATIONS="{iterations}"',
        f'WEBUI_PASS_HASH="{digest}"',
        f'WEBUI_FORCE_PASSWORD_CHANGE="{"Y" if force_password_change else "N"}"',
    ]) + "\n"
    atomic_write(AUTH_FILE, content)


def verify_credentials(user: str, password: str) -> bool:
    auth = load_shell_kv(AUTH_FILE)
    if not auth:
        return False
    if not user or not password:
        return False
    try:
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            bytes.fromhex(auth["WEBUI_PASS_SALT"]),
            int(auth["WEBUI_PASS_ITERATIONS"]),
        ).hex()
    except Exception:
        return False
    return hmac.compare_digest(user, auth.get("WEBUI_USER", "")) and hmac.compare_digest(
        digest,
        auth.get("WEBUI_PASS_HASH", ""),
    )


def prune_sessions() -> None:
    now = time.time()
    for session_id, payload in list(SESSIONS.items()):
        if float(payload.get("expires", 0)) <= now:
            SESSIONS.pop(session_id, None)


def create_session(user: str) -> str:
    prune_sessions()
    session_id = secrets.token_urlsafe(32)
    SESSIONS[session_id] = {
        "user": user,
        "expires": time.time() + SESSION_TTL_SECONDS,
        "started_ms": int(time.time() * 1000),
    }
    return session_id


def set_session_flash(
    session_id: str,
    message: str,
    output: str = "",
    level: str = "info",
    state: Optional[Dict[str, str]] = None,
) -> None:
    payload = SESSIONS.get(session_id)
    if payload is not None:
        payload["flash"] = {
            "message": message,
            "output": output,
            "level": level,
            "state": state,
        }


def pop_session_flash(session_id: str) -> Dict[str, object]:
    payload = SESSIONS.get(session_id)
    if payload is None:
        return {}
    flash = payload.pop("flash", {})
    return flash if isinstance(flash, dict) else {}


def get_session_id_from_cookie(cookie_header: Optional[str]) -> Optional[str]:
    if not cookie_header:
        return None
    jar = SimpleCookie()
    try:
        jar.load(cookie_header)
    except Exception:
        return None
    morsel = jar.get(SESSION_COOKIE_NAME)
    return morsel.value if morsel else None


def get_active_session_id(cookie_header: Optional[str]) -> Optional[str]:
    prune_sessions()
    session_id = get_session_id_from_cookie(cookie_header)
    if not session_id:
        return None
    payload = SESSIONS.get(session_id)
    if not payload:
        return None
    payload["expires"] = time.time() + SESSION_TTL_SECONDS
    return session_id


def destroy_session(session_id: Optional[str]) -> None:
    if session_id:
        SESSIONS.pop(session_id, None)
    if not SESSIONS:
        with NETWORK_HISTORY_LOCK:
            NETWORK_HISTORY.clear()


def esc(value: object) -> str:
    return html.escape(str(value or ""))


def bool_checked(value: str) -> str:
    return "checked" if value == "Y" else ""


def input_row(label: str, name: str, value: str, input_type: str = "text", placeholder: str = "") -> str:
    placeholder_attr = f' placeholder="{esc(placeholder)}"' if placeholder else ""
    return (
        f'<label class="field">'
        f'<span>{esc(label)}</span>'
        f'<input type="{input_type}" name="{name}" value="{esc(value)}"{placeholder_attr}>'
        f"</label>"
    )


def option_selected(value: str, selected: str) -> str:
    return "selected" if value == selected else ""


def empty_extra_rule() -> Dict[str, str]:
    return {
        "proto": "udp",
        "public_from": "",
        "public_to": "",
        "target_ip": "",
        "target_from": "",
        "target_to": "",
        "label": "",
    }


def parse_extra_rules(raw_value: str) -> List[Dict[str, str]]:
    rules: List[Dict[str, str]] = []
    for row in (raw_value or "").split(";"):
        if not row:
            continue
        parts = row.split("|", 6)
        if len(parts) < 6:
            continue
        while len(parts) < 7:
            parts.append("")
        proto = parts[0].strip().lower()
        if proto not in ("tcp", "udp"):
            continue
        rules.append({
            "proto": proto,
            "public_from": parts[1].strip(),
            "public_to": parts[2].strip(),
            "target_ip": parts[3].strip(),
            "target_from": parts[4].strip(),
            "target_to": parts[5].strip(),
            "label": unquote(parts[6].strip()),
        })
    return rules


def encode_extra_rules(rules: List[Dict[str, str]]) -> str:
    rows: List[str] = []
    for rule in rules:
        rows.append("|".join([
            rule["proto"].lower(),
            rule["public_from"],
            rule["public_to"],
            rule["target_ip"],
            rule["target_from"],
            rule["target_to"],
            quote(rule.get("label", "")[:64], safe="-_.~"),
        ]))
    return ";".join(rows)


def range_text(first: str, last: str) -> str:
    return first if first == last else f"{first}-{last}"


def extra_rule_row(rule: Dict[str, str]) -> str:
    proto = rule.get("proto", "udp").lower()
    if proto not in ("tcp", "udp"):
        proto = "udp"
    port_value = range_text(rule.get("public_from", ""), rule.get("public_to", ""))
    return f"""
      <div class="extra-rule-row" data-extra-rule>
        <div class="extra-rule-head">
          <strong>{esc(rule.get("label") or "Extra rule")}</strong>
          <button class="danger small-button" type="button" data-remove-extra-rule>Remove</button>
        </div>
        <div class="extra-rule-grid">
          <label class="field">
            <span>Protocol</span>
            <select name="EXTRA_RULE_PROTO">
              <option value="udp" {option_selected(proto, "udp")}>UDP</option>
              <option value="tcp" {option_selected(proto, "tcp")}>TCP</option>
            </select>
          </label>
          {input_row("IP Address", "EXTRA_RULE_TARGET_IP", rule.get("target_ip", ""))}
          {input_row("Public port / range", "EXTRA_RULE_PORT", port_value)}
          {input_row("Local port / range", "EXTRA_RULE_TARGET_PORT", range_text(rule.get("target_from", ""), rule.get("target_to", "")))}
          {input_row("Label", "EXTRA_RULE_LABEL", rule.get("label", ""))}
        </div>
      </div>
"""


def extra_rule_form_rows(state: Dict[str, str]) -> str:
    rules = parse_extra_rules(state.get("EXTRA_PF_RULES", ""))
    if not rules:
        rules = [empty_extra_rule()]
    return "".join(extra_rule_row(rule) for rule in rules)


def extra_rules_summary_rows(state: Dict[str, str]) -> str:
    rules = parse_extra_rules(state.get("EXTRA_PF_RULES", ""))
    if not rules:
        return summary_row(
            "Extra rules",
            "None",
            "No custom forwarding rules configured",
            value_class="disabled",
        )

    rows: List[str] = []
    for index, rule in enumerate(rules, start=1):
        label = rule.get("label") or f"Extra rule {index}"
        public_range = range_text(rule["public_from"], rule["public_to"])
        target_range = range_text(rule["target_from"], rule["target_to"])
        rows.append(summary_row(
            label,
            f'{rule["proto"].upper()} {public_range}',
            f'To {rule["target_ip"]}:{target_range}',
        ))
    return "".join(rows)


DMZ_EXCLUSION_CACHE: Dict[str, object] = {}


def dmz_exclusion_rows(state: Dict[str, str]) -> str:
    relevant = ("WG_PORT", "WEBUI_PORT", "EXTRA_PF_RULES")
    cache_key = tuple(state.get(key, "") for key in relevant)
    if DMZ_EXCLUSION_CACHE.get("key") == cache_key and time.monotonic() - float(DMZ_EXCLUSION_CACHE.get("time", 0)) < 30:
        return str(DMZ_EXCLUSION_CACHE["html"])
    reserved = standard_port_reservations(state)
    for rule in parse_extra_rules(state.get("EXTRA_PF_RULES", "")):
        reserved[rule["proto"]].append((int(rule["public_from"]), int(rule["public_to"]), rule.get("label") or "Extra rule"))
    # Show the VPS listener exclusions that are also protected during Apply.
    try:
        output = subprocess.run(["ss", "-H", "-lntu"], capture_output=True, text=True, timeout=2, check=False)
        if output.returncode == 0:
            for line in output.stdout.splitlines():
                fields = line.split()
                if len(fields) < 5 or fields[0] not in ("tcp", "udp") or fields[4].startswith(("127.", "[::1]:", "::1:")):
                    continue
                match = re.search(r":(\d+)$", fields[4])
                if match:
                    port = int(match.group(1))
                    if 1 <= port <= 65535 and not any(first <= port <= last for first, last, _ in reserved[fields[0]]):
                        reserved[fields[0]].append((port, port, "VPS listener"))
    except (OSError, subprocess.SubprocessError):
        pass
    html = "".join(
        f'<div class="summary-row"><strong>{esc(proto.upper() + " " + range_text(str(first), str(last)))}</strong><span>{esc(label)}</span></div>'
        for proto in ("tcp", "udp") for first, last, label in sorted(reserved[proto])
    )
    DMZ_EXCLUSION_CACHE.update(key=cache_key, time=time.monotonic(), html=html)
    return html


def summary_row(label: str, value: str, note: str = "", href: str = "", value_class: str = "") -> str:
    note_html = f"<small>{esc(note)}</small>" if note else ""
    value_classes = "summary-value"
    if value_class:
        value_classes += f" {value_class}"
    if href:
        value_html = (
            f'<a class="{value_classes}" href="{esc(href)}" target="_blank" rel="noopener">{esc(value)}</a>'
        )
    else:
        value_html = f'<div class="{value_classes}">{esc(value)}</div>'
    return (
        '<div class="summary-row">'
        '<div class="summary-copy">'
        f'<strong>{esc(label)}</strong>'
        f'{note_html}'
        '</div>'
        f'{value_html}'
        '</div>'
    )


def management_rows(state: Dict[str, str]) -> str:
    host = state.get("PUB_IP") or "SERVER_IP"
    web_port = state.get("WEBUI_PORT", DEFAULTS["WEBUI_PORT"])
    web_url = f"https://{host}:{web_port}"
    wireguard_note = "%s <-> %s" % (
        state.get("WG_VPS_IP", DEFAULTS["WG_VPS_IP"]),
        state.get("WG_GL_IP", DEFAULTS["WG_GL_IP"]),
    )
    return "".join([
        summary_row("Control Panel", web_url, "Browser access to this panel", web_url),
        summary_row("WireGuard", "UDP %s" % state.get("WG_PORT", DEFAULTS["WG_PORT"]), wireguard_note),
        summary_row(
            "Public Network",
            state.get("PUB_IFACE", DEFAULTS["PUB_IFACE"]),
            "IPv4 %s" % state.get("PUB_IP", DEFAULTS["PUB_IP"]),
        ),
    ])


def public_link_host(state: Dict[str, str]) -> str:
    return state.get("PUBLIC_DOMAIN", "") or state.get("PUB_IP") or "SERVER_IP"


def validate_public_domain(raw: str) -> str:
    domain = raw.strip().lower().rstrip(".")
    if not domain or len(domain) > 253 or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in domain.split(".")
    ):
        raise ValueError("Enter a hostname such as streamhub.example.com, without https://, a port or a path.")
    return domain


def public_service_links(state: Dict[str, str]) -> str:
    host = public_link_host(state)
    services = [
        ("StreamHub", f"https://{host}:443"),
    ]
    return "".join(
        f'<a class="service-link" href="{esc(url)}" target="_blank" rel="noopener">'
        f'<span>{esc(label)}</span><span class="external-icon" aria-hidden="true">↗</span></a>'
        for label, url in services
    )


def redirect_details(state: Dict[str, str]) -> str:
    rows = [
        ("StreamHub HTTPS", "TCP 443", state.get("STREAMHUB_IP", DEFAULTS["STREAMHUB_IP"]), "443"),
        ("StreamHub Alt HTTPS", "TCP 8444", state.get("STREAMHUB_IP", DEFAULTS["STREAMHUB_IP"]), "8444"),
        ("StreamHub HTTP", "TCP 8888", state.get("STREAMHUB_IP", DEFAULTS["STREAMHUB_IP"]), "8888"),
        ("StreamHub SSH", "TCP 5322", state.get("STREAMHUB_IP", DEFAULTS["STREAMHUB_IP"]), "5322"),
        ("StreamHub RTMP", "TCP 1935", state.get("STREAMHUB_IP", DEFAULTS["STREAMHUB_IP"]), "1935"),
    ]
    return "".join(
        '<div class="redirect-row">'
        f'<strong>{esc(label)}</strong><span>{esc(public_port)}</span>'
        f'<code>{esc(target_ip)}:{esc(target_port)}</code></div>'
        for label, public_port, target_ip, target_port in rows
    )


def router_config_text() -> str:
    path = Path(ROUTER_CONF_OUT)
    if not path.exists():
        return "Router config has not been generated yet."
    return path.read_text(encoding="utf-8", errors="replace")


def remote_client_config_text() -> str:
    path = Path(REMOTE_CLIENT_CONF_OUT)
    if not path.exists():
        return "Remote VPN client has not been created yet."
    return path.read_text(encoding="utf-8", errors="replace")


def render_login_page(message: str = "", username: str = "") -> str:
    status_html = (
        f'<div class="login-status">{esc(message)}</div>'
        if message
        else ""
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>WireGuard VPN Login</title>
  <style>
    :root {{
      --bg: #05090f;
      --panel: rgba(12, 18, 27, 0.94);
      --line: rgba(150, 176, 194, 0.14);
      --brand: #c8282e;
      --ink: #f5fbff;
      --muted: #90a9ba;
      --shadow: 0 22px 48px rgba(0, 0, 0, 0.34);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 24px;
      font-family: "Aptos", "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at 12% 10%, rgba(200,40,46,0.16), transparent 22%),
        radial-gradient(circle at 88% 8%, rgba(200,40,46,0.12), transparent 18%),
        linear-gradient(180deg, #04070c 0%, #08111a 48%, #060b12 100%);
    }}
    .login-shell {{
      width: min(1100px, 100%);
      display: grid;
      grid-template-columns: minmax(0, 1.15fr) minmax(320px, 420px);
      gap: 20px;
      align-items: center;
    }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 28px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(14px);
    }}
    .brand-panel {{
      padding: clamp(26px, 4vw, 42px);
      text-align: center;
    }}
    .brand-panel img {{
      display: block;
      width: min(760px, 100%);
      height: auto;
      margin: 0 auto 18px;
      filter: drop-shadow(0 18px 40px rgba(0, 0, 0, 0.38));
    }}
    .brand-panel h1 {{
      margin: 0;
      font-size: clamp(30px, 4vw, 44px);
      line-height: 1.05;
    }}
    .brand-panel p {{
      margin: 10px auto 0;
      max-width: 34ch;
      color: var(--muted);
      line-height: 1.5;
    }}
    .login-panel {{
      padding: 28px;
    }}
    .login-panel h2 {{
      margin: 0;
      font-size: 24px;
    }}
    .login-panel p {{
      margin: 8px 0 0 0;
      color: var(--muted);
      line-height: 1.45;
    }}
    .login-status {{
      margin: 18px 0 0 0;
      padding: 12px 14px;
      border-radius: 14px;
      background: rgba(200, 40, 46, 0.12);
      color: #ffc2c4;
      font-size: 14px;
    }}
    form {{
      display: grid;
      gap: 14px;
      margin-top: 18px;
    }}
    label {{
      display: grid;
      gap: 7px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      text-transform: uppercase;
      color: var(--muted);
    }}
    input {{
      width: 100%;
      border: 1px solid rgba(146, 172, 190, 0.18);
      border-radius: 14px;
      padding: 13px 14px;
      background: #0b121a;
      color: var(--ink);
      outline: none;
    }}
    input:focus {{
      border-color: var(--brand);
      box-shadow: 0 0 0 4px rgba(200, 40, 46, 0.18);
    }}
    button {{
      margin-top: 4px;
      border: 0;
      border-radius: 999px;
      padding: 12px 18px;
      font: inherit;
      font-weight: 700;
      cursor: pointer;
      color: white;
      background: linear-gradient(135deg, #c8282e, #88171a);
      box-shadow: 0 12px 26px rgba(136, 23, 26, 0.28);
    }}
    .login-note {{
      margin-top: 14px;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.45;
    }}
    @media (max-width: 980px) {{
      .login-shell {{
        grid-template-columns: 1fr;
      }}
    }}
  </style>
</head>
<body>
  <div class="login-shell">
    <section class="panel brand-panel">
      <img src="{esc(LOGO_URL)}" alt="WireGuard VPN logo">
      <h1>WireGuard Control Panel</h1>
      <p>Sign in to manage WireGuard, DNAT and router export.</p>
    </section>
    <section class="panel login-panel">
      <h2>Login</h2>
      <p>Authentication is required every time you reopen the page.</p>
      {status_html}
      <form method="post" action="/login" autocomplete="off">
        <label>
          Username
          <input type="text" name="username" value="{esc(username)}" autocomplete="username" required>
        </label>
        <label>
          Password
          <input type="password" name="password" value="" autocomplete="current-password" required>
        </label>
        <button type="submit">Login</button>
      </form>
      <div class="login-note">Close the tab or use Logout to require a fresh login on the next access.</div>
    </section>
  </div>
  <script>
    try {{
      window.sessionStorage.removeItem("{SESSION_STORAGE_KEY}");
    }} catch (err) {{}}
  </script>
</body>
</html>
"""


def render_login_bootstrap() -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Signing In</title>
</head>
<body style="background:#060b12;color:#f5fbff;font-family:Aptos,Segoe UI,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;">
  <p>Signing in...</p>
  <script>
    try {{
      window.sessionStorage.setItem("{SESSION_STORAGE_KEY}", "1");
    }} catch (err) {{}}
    window.location.replace("/change-password");
  </script>
</body>
</html>
"""


def render_change_password_page(message: str = "", level: str = "info") -> str:
    status_html = f'<div class="login-status">{esc(message)}</div>' if message else ""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Set WireGuard VPN Password</title>
  <style>
    * {{ box-sizing: border-box; }}
    body {{ margin:0; min-height:100vh; display:grid; place-items:center; padding:24px; font-family:Aptos,"Segoe UI",sans-serif; color:#f5fbff; background:linear-gradient(180deg,#04070c,#08111a 55%,#060b12); }}
    .panel {{ width:min(440px,100%); padding:28px; background:rgba(12,18,27,.96); border:1px solid rgba(150,176,194,.14); border-radius:24px; box-shadow:0 22px 48px rgba(0,0,0,.34); }}
    h1 {{ margin:0; font-size:25px; }} p {{ color:#90a9ba; line-height:1.5; }}
    form,label {{ display:grid; gap:10px; }} form {{ margin-top:20px; gap:15px; }} label {{ color:#90a9ba; font-size:12px; font-weight:700; text-transform:uppercase; }}
    input {{ width:100%; padding:13px 14px; border:1px solid rgba(146,172,190,.18); border-radius:14px; background:#0b121a; color:#f5fbff; outline:none; }}
    input:focus {{ border-color:#c8282e; box-shadow:0 0 0 4px rgba(200,40,46,.18); }}
    button {{ border:0; border-radius:999px; padding:12px 18px; font:inherit; font-weight:700; cursor:pointer; color:white; background:linear-gradient(135deg,#c8282e,#88171a); }}
    .login-status {{ margin-top:16px; padding:12px 14px; border-radius:14px; background:rgba(200,40,46,.12); color:#ffc2c4; font-size:14px; }}
  </style>
</head>
<body><section class="panel">
  <h1>Choose a new password</h1>
  <p>The initial password must be replaced before the control panel can be used. Use at least 10 characters.</p>
  {status_html}
  <form method="post" action="/change-password" autocomplete="off">
    <label>New password<input type="password" name="password" autocomplete="new-password" minlength="10" required></label>
    <label>Confirm password<input type="password" name="confirm" autocomplete="new-password" minlength="10" required></label>
    <button type="submit">Save New Password</button>
  </form>
</section></body></html>"""


def wizard_network_values(router_ip: str, prefix: int, current: Dict[str, str]) -> Dict[str, str]:
    router = ipaddress.IPv4Address(router_ip)
    if router.is_multicast or router.is_loopback or router.is_unspecified:
        raise ValueError("Enter a usable IPv4 address for the router LAN.")
    if prefix not in range(16, 25):
        raise ValueError("Choose a LAN prefix from /16 to /24. Smaller networks cannot hold the default StreamHub address.")
    network = ipaddress.IPv4Network(f"{router}/{prefix}", strict=False)
    if router in (network.network_address, network.broadcast_address):
        raise ValueError("The router must have a usable host address in the chosen subnet.")
    # Preserve the router's /24 block for the default StreamHub address.
    block = int(router) & 0xFFFFFF00
    values = dict(current)
    values["LAN_CIDR"] = str(network)
    values["ROUTER_LAN_IP"] = str(router)
    values["STREAMHUB_IP"] = str(ipaddress.IPv4Address(block + 101))
    if router_ip == values["STREAMHUB_IP"]:
        raise ValueError("The router IP conflicts with the default StreamHub address. Choose another router address or configure the StreamHub IP manually after setup.")
    return values


def wizard_router_online() -> Tuple[bool, str]:
    state = applied_state()
    if state is None:
        return False, "Apply the LAN configuration first."
    try:
        result = subprocess.run(["wg", "show", "wg0", "dump"], capture_output=True,
                                text=True, timeout=2, check=False)
        if result.returncode != 0:
            return False, "WireGuard is not running on the VPS."
        peer_ip = state["WG_GL_IP"]
        rows = [row.split("\t") for row in result.stdout.splitlines()[1:]]
        peer = next((row for row in rows if len(row) >= 8 and peer_ip + "/32" in row[3].split(",")), None)
        if peer is None:
            return False, "The WireGuard router peer is not configured on the VPS."
        reachable, _ = _ping_target(peer_ip)
        if not reachable:
            return False, "The router tunnel IP is not responding. Check its WireGuard profile and retry."
        handshake = int(peer[4])
        if handshake <= 0 or time.time() - handshake > 180:
            return False, "The router responded, but there is no recent WireGuard handshake. Retry shortly."
        return True, "Router tunnel is connected and responding."
    except (OSError, ValueError, subprocess.SubprocessError):
        return False, "The tunnel check failed. Retry or inspect the WireGuard service."


def render_wizard(step: str = "network", message: str = "", level: str = "error") -> str:
    state = merged_state()
    current = applied_state()
    profile_ready = current is not None and Path(ROUTER_CONF_OUT).is_file() and Path(REMOTE_CLIENT_CONF_OUT).is_file()
    if step not in ("network", "profile", "verify") or (step != "network" and not profile_ready):
        step = "network"
    step_number = {"network": 1, "profile": 2, "verify": 3}[step]
    status = f'<div class="notice {esc(level)}" role="alert">{esc(message)}</div>' if message else ""
    prefix = state.get("LAN_CIDR", DEFAULTS["LAN_CIDR"]).split("/")[-1]
    choices = "".join(f'<option value="{i}" {"selected" if prefix == str(i) else ""}>/{i}</option>' for i in range(16, 25))
    if step == "network":
        body = f"""<h1>Router LAN</h1><p>Enter the router LAN address and its subnet. The StreamHub defaults to address .101 in the router's /24 block.</p>
        <form method="post" action="/wizard/network" id="wizard-form">
          <label>Router LAN IP<input name="router_ip" inputmode="decimal" value="{esc(state['ROUTER_LAN_IP'])}" required></label>
          <label>Subnet prefix<select name="prefix">{choices}</select></label>
          <p class="hint">The tunnel uses a separate network. /25–/32 are unavailable here because the default StreamHub address must fit in the LAN.</p>
        </form>"""
        footer = '<div class="actions"><button type="submit" form="wizard-form">Apply and generate profile <span aria-hidden="true">→</span></button></div><p id="applying" class="hint" hidden>Applying network rules and saving them. This may take a moment…</p>'
    elif step == "profile":
        body = f"""<h1>WireGuard profiles</h1><p>First connect the WireGuard router. The support client is available in the next tab if you need access from another device.</p>
        <div class="profile-switch" role="tablist" aria-label="VPN profiles"><button type="button" class="selected" data-profile-tab="router">WireGuard Router</button><button type="button" data-profile-tab="client">Remote VPN Client</button></div>
        <section data-profile-panel="router"><p>Import this profile into your router and enable the tunnel. Its private key stays the same when you refresh.</p>
          <div class="profile-actions"><button type="button" data-copy-profile="router-profile">Copy profile</button><a href="/download-router-config">Download .conf</a></div>
          <details><summary>Show router configuration</summary><pre id="router-profile">{esc(router_config_text())}</pre></details>
          <details class="qr"><summary>Show router QR code</summary><img src="/wizard/router-qr" loading="lazy" alt="QR code for the WireGuard router profile"><p class="hint">The QR contains the private key. Show it only to someone who manages this router.</p></details>
        </section>
        <section data-profile-panel="client" hidden><p>Optional access for an Android or iOS phone, or a computer. Import this profile in the WireGuard app to reach the site LAN for remote support. It does not route all of the device's Internet traffic through the VPS.</p>
          <div class="profile-actions"><button type="button" data-copy-profile="client-profile">Copy profile</button><a href="/download-remote-client">Download .conf</a></div>
          <details><summary>Show client configuration</summary><pre id="client-profile">{esc(remote_client_config_text())}</pre></details>
          <details class="qr"><summary>Show client QR code</summary><img src="/wizard/client-qr" loading="lazy" alt="QR code for the remote VPN client profile"><p class="hint">The QR contains the private key. Keep it private.</p></details>
        </section>"""
        footer = '<div class="actions"><a class="back" href="/wizard?step=network">Back</a><a class="next" href="/wizard?step=verify">Next <span aria-hidden="true">→</span></a></div>'
    else:
        body = """<h1>Check the connection</h1><p>Make sure the router profile is enabled, then check that the VPS can reach its WireGuard tunnel address.</p>
        <div class="connection-status" id="connection-status" role="status"><span class="connection-icon" aria-hidden="true"></span><span id="connection-message">Waiting to check the router…</span></div>"""
        footer = '<div class="actions"><a class="back" href="/wizard?step=profile">Back</a><button type="button" id="retry-check">Check again</button><form method="post" action="/wizard/finish"><button id="finish-button" type="submit" disabled>Finish and open Overview</button></form></div>'
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>WireGuard VPN Initial Setup</title><style>
    * {{box-sizing:border-box}} body {{height:100vh;height:100dvh;margin:0;padding:24px;display:flex;align-items:center;justify-content:center;overflow:hidden;background:radial-gradient(circle at 15% 5%,#3a1214,#05090f 48%,#08111a);color:#f5fbff;font-family:Aptos,"Segoe UI",sans-serif}}
    .card {{width:min(610px,100%);height:740px;max-height:100%;min-height:0;display:flex;flex-direction:column;background:#0c121beF;border:1px solid #2b3c49;border-radius:22px;padding:clamp(22px,5vw,38px);box-shadow:0 22px 48px #0007}}
    .wizard-content {{flex:1;min-height:0;overflow-y:auto;overscroll-behavior:contain;padding-right:6px;scrollbar-color:#395063 transparent}}
    .wizard-footer {{flex:none;padding-top:14px}} .wizard-footer .actions {{margin-top:0}}
    .brand {{display:flex;flex:none;align-items:center;justify-content:space-between;gap:16px}} .brand img {{width:175px;max-width:55%;height:auto}} .brand span,.hint,p {{color:#9db3c1}}
    h1 {{font-size:27px;margin:28px 0 8px}} p {{line-height:1.5}} .progress {{display:flex;flex:none;gap:7px;margin-top:26px}} .progress i {{height:5px;flex:1;background:#1d3241;border-radius:8px}} .progress i.on {{background:#c8282e}}
    label {{display:grid;gap:7px;margin:18px 0;color:#a8c2d0;font-size:14px;font-weight:700}} input,select {{width:100%;padding:12px;border:1px solid #395063;border-radius:10px;background:#0b1823;color:white;font:inherit}}
    button,.next,.profile-actions a {{border:0;border-radius:10px;background:#a61e23;color:#fff;text-decoration:none;padding:12px 17px;font:inherit;font-weight:700;cursor:pointer}} button:disabled {{opacity:.45;cursor:default}} .back {{color:#b0dcea;text-decoration:none;padding:12px}} .actions,.profile-actions {{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-top:24px}} .actions form {{margin:0}}
    .profile-actions button {{background:#263d50}} details {{margin-top:18px}} summary {{cursor:pointer;color:#ffbfc1}} pre {{white-space:pre-wrap;overflow-wrap:anywhere;background:#07111a;border:1px solid #2b3c49;padding:14px;border-radius:12px;max-height:240px;overflow:auto}}
    .qr img {{max-width:220px;display:block;margin:16px auto;background:#fff;padding:10px;border-radius:12px}} .qr p {{font-size:12px}} .notice {{padding:12px;border-radius:10px;background:#3a2630;color:#ffd4dc;margin-top:20px;white-space:pre-wrap}} .notice.ok {{background:#173e34;color:#b3f6dd}}
    .connection-status {{padding:22px;border:1px solid #385366;border-radius:12px;margin-top:24px}} .checking::before {{content:"";display:inline-block;width:13px;height:13px;border:2px solid #c8282e;border-top-color:transparent;border-radius:50%;animation:spin .7s linear infinite;margin-right:10px}} @keyframes spin {{to {{transform:rotate(360deg)}}}}
    .profile-switch {{display:flex;gap:8px;margin-top:22px}} .profile-switch button {{flex:1;background:#183044}} .profile-switch button.selected {{background:#a61e23}} [data-profile-panel][hidden] {{display:none}}
    .connection-status {{display:flex;align-items:center;gap:18px;min-height:110px}} .connection-icon {{display:grid;place-items:center;flex:none;width:52px;height:52px;border-radius:50%;border:3px solid #57738a;color:#fff;font-size:29px;font-weight:800}}
    .connection-status.checking::before {{content:none}} .checking .connection-icon {{border-color:#c8282e;background:#c8282e22;animation:pulse 1.2s ease-in-out infinite}} .connected .connection-icon {{border-color:#39d98a;background:#1a8e58}} .connected .connection-icon::after {{content:"✓"}} .disconnected .connection-icon {{border-color:#df9363}}
    @keyframes pulse {{50% {{box-shadow:0 0 0 12px #c8282e25;opacity:.5}}}}
    @media (max-width:600px), (max-height:650px) {{body {{padding:12px}} .card {{padding:20px}} .brand img {{width:135px}} h1 {{margin-top:18px}} .progress {{margin-top:18px}}}}
    </style></head><body><main class="card"><div class="brand"><img src="{esc(LOGO_URL)}" alt="WireGuard VPN"><span>Initial setup · {step_number} of 3</span></div>
    <div class="progress" aria-hidden="true">{''.join('<i class="on"></i>' if n <= step_number else '<i></i>' for n in (1,2,3))}</div><div class="wizard-content">{status}{body}</div><div class="wizard-footer">{footer}</div></main>
    <script>
    const form=document.getElementById('wizard-form');if(form)form.addEventListener('submit',()=>{{document.querySelector('[form="wizard-form"]').disabled=true;document.getElementById('applying').hidden=false;}});
    document.querySelectorAll('[data-profile-tab]').forEach(button=>button.addEventListener('click',()=>{{document.querySelectorAll('[data-profile-tab]').forEach(tab=>tab.classList.toggle('selected',tab===button));document.querySelectorAll('[data-profile-panel]').forEach(panel=>panel.hidden=panel.dataset.profilePanel!==button.dataset.profileTab);}}));
    document.querySelectorAll('[data-copy-profile]').forEach(button=>button.addEventListener('click',async()=>{{try{{await navigator.clipboard.writeText(document.getElementById(button.dataset.copyProfile).textContent);button.textContent='Copied';}}catch(e){{button.textContent='Copy failed';}}}}));
    const retry=document.getElementById('retry-check');if(retry){{const box=document.getElementById('connection-status'),label=document.getElementById('connection-message'),finish=document.getElementById('finish-button');async function check(){{finish.disabled=true;retry.disabled=true;box.classList.remove('connected','disconnected');box.classList.add('checking');label.textContent='Checking WireGuard and router reachability…';const start=Date.now();let result;try{{const response=await fetch('/api/wizard-connection',{{cache:'no-store',credentials:'same-origin'}});result=await response.json();if(!response.ok)throw Error(result.message||'Check failed');}}catch(e){{result={{connected:false,message:'Cannot reach the VPS check. Retry.'}}}}await new Promise(resolve=>setTimeout(resolve,Math.max(0,5000-(Date.now()-start))));box.classList.remove('checking');box.classList.add(result.connected?'connected':'disconnected');label.textContent=result.message;finish.disabled=!result.connected;retry.disabled=false;}}retry.addEventListener('click',check);check();}}
    </script></body></html>"""


def render_logout_bootstrap() -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Signing Out</title>
</head>
<body style="background:#060b12;color:#f5fbff;font-family:Aptos,Segoe UI,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;">
  <p>Signing out...</p>
  <script>
    try {{
      window.sessionStorage.removeItem("{SESSION_STORAGE_KEY}");
    }} catch (err) {{}}
    window.location.replace("/login?logged_out=1");
  </script>
</body>
</html>
"""


def render_remove_pending() -> str:
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Removing WireGuard VPN</title>
<style>body{{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;box-sizing:border-box;background:radial-gradient(circle at 0 0,#3a1214,#060b12 55%);color:#f5fbff;font:18px Aptos,Segoe UI,sans-serif}}main{{width:min(580px,100%);padding:36px;border:1px solid #30465d;border-radius:22px;background:#0e1320;box-sizing:border-box}}img{{width:180px;max-width:100%}}h1{{font-size:27px;margin:28px 0 16px}}p{{line-height:1.5;color:#a9c6dc}}strong{{color:#fff}}</style></head>
<body><main><img src="{esc(LOGO_URL)}" alt="WireGuard VPN"><h1>Removing WireGuard VPN</h1>
<p>The VPS will remove the tunnel, forwarding rules, saved profiles and this Web UI in <strong id="seconds">10</strong> seconds. This page will then be unavailable.</p>
<p>Check the result from your VPS console or SSH session.</p></main>
<script>try{{window.sessionStorage.removeItem("{SESSION_STORAGE_KEY}");}}catch(e){{}}
let remaining=10;const counter=document.getElementById('seconds');const timer=setInterval(()=>{{remaining--;counter.textContent=String(Math.max(0,remaining));if(remaining<=0)clearInterval(timer);}},1000);</script>
</body></html>"""


def _script_sha256() -> str:
    try:
        digest = hashlib.sha256()
        with open(SCRIPT_PATH, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return "unavailable"


def _format_uptime(seconds: float) -> str:
    total_minutes = max(0, int(seconds // 60))
    days, remainder = divmod(total_minutes, 24 * 60)
    hours, minutes = divmod(remainder, 60)
    if days:
        return f"{days}d {hours}h {minutes}m"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def build_information() -> Dict[str, str]:
    os_name = platform.platform()
    try:
        os_release = load_shell_kv("/etc/os-release")
        os_name = os_release.get("PRETTY_NAME", os_name)
    except OSError:
        pass
    try:
        uptime = _format_uptime(float(Path("/proc/uptime").read_text(encoding="ascii").split()[0]))
    except (OSError, ValueError, IndexError):
        uptime = "unavailable"
    try:
        applied_at = time.strftime(
            "%Y-%m-%d %H:%M:%S UTC",
            time.gmtime(Path(APPLIED_STATE_FILE).stat().st_mtime),
        )
    except OSError:
        applied_at = "never"
    try:
        started = subprocess.run(
            ["systemctl", "show", WEBUI_SERVICE_NAME, "--property=ActiveEnterTimestamp", "--value"],
            capture_output=True, text=True, timeout=2, check=False,
        ).stdout.strip() or "unavailable"
    except (OSError, subprocess.SubprocessError):
        started = "unavailable"
    return {
        "version": SCRIPT_VERSION,
        "channel": RELEASE_CHANNEL,
        "sha256": _script_sha256(),
        "os": os_name,
        "kernel": platform.release(),
        "uptime": uptime,
        "last_apply": applied_at,
        "webui_started": started,
    }


def _command_output(command: List[str], timeout: float = 8.0) -> str:
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, check=False,
        )
        output = result.stdout
        if result.stderr:
            output += ("\n" if output else "") + result.stderr
        return f"$ {' '.join(command)}\nexit={result.returncode}\n{output}".rstrip() + "\n"
    except subprocess.TimeoutExpired:
        return f"$ {' '.join(command)}\nERROR: command timed out\n"
    except OSError as exc:
        return f"$ {' '.join(command)}\nERROR: {exc}\n"


def build_support_bundle() -> bytes:
    state = merged_state()
    info = build_information()
    safe_state = {key: state.get(key, "") for key in STATE_KEYS}
    files: Dict[str, str] = {
        "00-build-information.json": json.dumps(info, indent=2, sort_keys=True) + "\n",
        "01-sanitized-state.json": json.dumps(safe_state, indent=2, sort_keys=True) + "\n",
        "02-system-health.txt": _command_output([SCRIPT_PATH, "--health"], timeout=30),
        "03-wireguard-status.txt": _command_output(["wg", "show", "wg0"]),
        "04-ip-addresses.txt": _command_output(["ip", "-brief", "address"]),
        "05-ip-routes.txt": _command_output(["ip", "-4", "route", "show"]),
        "06-wgvpn-nat-chain.txt": _command_output(["iptables", "-t", "nat", "-S", "WGVPN_NAT"]),
        "07-wgvpn-forward-chain.txt": _command_output(["iptables", "-S", "WGVPN_FWD"]),
        "08-wireguard-service.txt": _command_output(["systemctl", "status", "wg-quick@wg0", "--no-pager", "--full"]),
        "09-webui-service.txt": _command_output(["systemctl", "status", WEBUI_SERVICE_NAME, "--no-pager", "--full"]),
        "10-rules-service.txt": _command_output(["systemctl", "status", "wgvpn-wg-rules.service", "--no-pager", "--full"]),
        "11-webui-journal.txt": _command_output(["journalctl", "-u", WEBUI_SERVICE_NAME, "-n", "200", "--no-pager", "--output=short-iso"]),
        "12-kernel-network.txt": "\n".join([
            _command_output(["sysctl", "net.ipv4.ip_forward"]),
            _command_output(["sysctl", "net.ipv4.conf.all.rp_filter"]),
            _command_output(["sysctl", "net.ipv4.conf.default.rp_filter"]),
        ]),
        "13-dashboard-status.json": json.dumps(dashboard_status(applied_state()), indent=2, sort_keys=True) + "\n",
        "README.txt": (
            "WireGuard VPN sanitized support bundle\n"
            "Generated by v" + SCRIPT_VERSION + " (" + RELEASE_CHANNEL + ").\n"
            "Private WireGuard keys, Web UI credentials, authentication hashes, cookies,\n"
            "TLS private keys and downloadable client configurations are intentionally excluded.\n"
        ),
    }
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name, content in files.items():
            payload = content.encode("utf-8", errors="replace")
            entry = tarfile.TarInfo(name=name)
            entry.size = len(payload)
            entry.mode = 0o600
            entry.mtime = int(time.time())
            archive.addfile(entry, io.BytesIO(payload))
    return output.getvalue()


def render_page(state: Dict[str, str], message: str = "", output: str = "", level: str = "info") -> str:
    status_class = {
        "info": "status info",
        "ok": "status ok",
        "error": "status error",
    }.get(level, "status info")
    host = state.get("PUB_IP") or "SERVER_IP"
    web_port = state.get("WEBUI_PORT", DEFAULTS["WEBUI_PORT"])
    management_summary = management_rows(state)
    services_links = public_service_links(state)
    redirects_html = redirect_details(state)
    extra_rules_html = extra_rule_form_rows(state)
    extra_rules_summary = extra_rules_summary_rows(state)
    dmz_exclusions = dmz_exclusion_rows(state)
    build = build_information()
    status_html = f'<div class="{status_class} header-status">{esc(message)}</div>' if message else ""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>WireGuard VPN Control Panel</title>
  <style>
    :root {{
      --bg: #060b12;
      --panel: rgba(12, 18, 27, 0.92);
      --panel-strong: #0b121a;
      --panel-soft: #0f1721;
      --ink: #f5fbff;
      --muted: #90a9ba;
      --line: rgba(150, 176, 194, 0.14);
      --brand: #c8282e;
      --brand-strong: #88171a;
      --brand-soft: rgba(200, 40, 46, 0.16);
      --ok-soft: rgba(44, 158, 98, 0.16);
      --error-soft: rgba(194, 61, 76, 0.15);
      --shadow: 0 22px 48px rgba(0, 0, 0, 0.34);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: "Aptos", "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at -5% 12%, rgba(200,40,46,0.18), transparent 28%),
        radial-gradient(circle at 88% 8%, rgba(200,40,46,0.12), transparent 18%),
        linear-gradient(180deg, #04070c 0%, #08111a 48%, #060b12 100%);
      animation: page-in 260ms ease-out;
    }}
    @keyframes page-in {{
      from {{ opacity: 0; transform: translateY(8px); }}
      to {{ opacity: 1; transform: translateY(0); }}
    }}
    .page-shell {{ width: min(1560px, calc(100vw - 40px)); margin: 24px auto 36px; }}
    .panel {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(14px);
    }}
    .hero {{
      padding: clamp(24px, 3.2vw, 34px) clamp(20px, 2.6vw, 28px) clamp(22px, 2.4vw, 26px);
      margin-bottom: 20px;
      background:
        linear-gradient(180deg, rgba(17, 24, 35, 0.96), rgba(11, 17, 25, 0.94)),
        linear-gradient(135deg, rgba(200,40,46,0.08), transparent);
    }}
    .hero-logo {{
      display: flex;
      justify-content: center;
      margin-bottom: 20px;
    }}
    .hero-logo img {{
      display: block;
      width: min(980px, calc(100vw - 120px));
      height: auto;
      filter: drop-shadow(0 18px 40px rgba(0, 0, 0, 0.38));
    }}
    .hero-copy {{
      text-align: center;
      margin-bottom: 20px;
    }}
    h1 {{
      margin: 0;
      font-size: 36px;
      line-height: 1.04;
      color: #ffffff;
    }}
    .hero-meta {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px;
      max-width: 980px;
      margin: 0 auto;
    }}
    .hero-actions {{
      display: flex;
      justify-content: center;
      margin-top: 14px;
    }}
    .logout-form {{
      margin: 0;
    }}
    .meta-pill {{
      padding: 14px 16px;
      border-radius: 16px;
      background: linear-gradient(180deg, rgba(200,40,46,0.10), rgba(15,23,33,0.96));
      border: 1px solid rgba(200, 40, 46, 0.16);
    }}
    .meta-pill span {{
      display: block;
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.16em;
      color: var(--muted);
      margin-bottom: 6px;
    }}
    .meta-pill strong {{
      display: block;
      font-size: 15px;
      color: #ffffff;
      word-break: break-word;
    }}
    .layout {{ display: grid; grid-template-columns: minmax(0, 1.38fr) minmax(320px, 0.92fr); gap: 20px; align-items: start; }}
    .aside {{ display: grid; gap: 20px; position: sticky; top: 22px; }}
    .panel-body {{ padding: clamp(20px, 2vw, 24px); }}
    .panel-head {{
      display: flex;
      justify-content: flex-start;
      gap: 16px;
      align-items: flex-start;
      margin-bottom: 16px;
    }}
    .panel-title {{
      margin: 0;
      font-size: 22px;
      line-height: 1.1;
      color: #ffffff;
    }}
    .panel-subtitle {{
      margin: 4px 0 0 0;
      color: var(--muted);
      line-height: 1.45;
    }}
    .config-block + .config-block {{
      margin-top: 18px;
    }}
    .config-block {{
      padding: 18px;
      border-radius: 18px;
      background: linear-gradient(180deg, rgba(16, 24, 35, 0.96), rgba(11, 18, 27, 0.96));
      border: 1px solid var(--line);
    }}
    .tab-bar {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-bottom: 16px;
    }}
    .tab-button {{
      border-radius: 999px;
      background: rgba(255,255,255,0.04);
      color: #dfeef7;
      border: 1px solid var(--line);
      box-shadow: none;
    }}
    .tab-button.active {{
      background: rgba(200,40,46,0.16);
      border-color: rgba(200, 40, 46, 0.42);
      color: #ffffff;
    }}
    .primary-navigation {{
      padding: 6px;
      border: 1px solid var(--line);
      border-radius: 18px;
      background: rgba(5, 12, 18, 0.58);
    }}
    .primary-navigation .tab-button {{ flex: 1 1 150px; }}
    .subtab-bar {{
      display: inline-flex;
      flex-wrap: wrap;
      gap: 6px;
      padding: 5px;
      margin-bottom: 16px;
      border-radius: 14px;
      border: 1px solid var(--line);
      background: rgba(255,255,255,0.025);
    }}
    .subtab-button {{
      min-height: 38px;
      padding: 8px 14px;
      border-radius: 10px;
      border: 0;
      box-shadow: none;
      background: transparent;
      color: var(--muted);
    }}
    .subtab-button.active {{ background: rgba(200,40,46,0.16); color: #fff; }}
    [data-config-page][hidden] {{ display: none; }}
    .tab-page[hidden] {{
      display: none;
    }}
    .block-head {{
      margin-bottom: 12px;
    }}
    .block-head h3 {{
      margin: 0;
      font-size: 15px;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: #dff6ff;
    }}
    .block-head p {{
      margin: 4px 0 0 0;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.4;
    }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }}
    .field {{ display: grid; gap: 7px; }}
    .field span {{
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
      color: var(--muted);
      text-transform: uppercase;
    }}
    .field input,
    .field select {{
      width: 100%;
      min-width: 0;
      border: 1px solid rgba(146, 172, 190, 0.18);
      border-radius: 14px;
      padding: 13px 14px;
      background: var(--panel-strong);
      color: var(--ink);
      outline: none;
      transition: border-color 140ms ease, box-shadow 140ms ease, transform 140ms ease;
    }}
    .field input:focus,
    .field select:focus {{
      border-color: var(--brand);
      box-shadow: 0 0 0 4px rgba(200, 40, 46, 0.18);
      transform: translateY(-1px);
    }}
    .field input::placeholder {{ color: #70889a; }}
    .extra-rule-list {{
      display: grid;
      gap: 14px;
    }}
    .extra-rule-row {{
      padding: 16px;
      border-radius: 18px;
      background: rgba(5, 9, 15, 0.42);
      border: 1px solid var(--line);
    }}
    .extra-rule-head {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 12px;
    }}
    .extra-rule-head strong {{
      color: #ffffff;
      font-size: 14px;
    }}
    .extra-rule-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(min(100%, 180px), 1fr));
      gap: 12px;
      align-items: end;
    }}
    .extra-rule-grid .field {{
      min-width: 0;
    }}
    .extra-help {{
      margin: 0 0 14px 0;
      color: var(--muted);
      line-height: 1.5;
      font-size: 13px;
    }}
    .switch-card {{
      margin-top: 14px;
      display: flex;
      gap: 12px;
      align-items: flex-start;
      padding: 14px 16px;
      border-radius: 16px;
      background: rgba(200, 40, 46, 0.10);
      border: 1px solid rgba(200, 40, 46, 0.16);
      color: var(--ink);
      font-weight: 600;
    }}
    .switch-card small {{
      display: block;
      margin-top: 4px;
      color: var(--muted);
      font-weight: 400;
      line-height: 1.45;
    }}
    .actions {{ display: flex; flex-wrap: wrap; gap: 12px; margin-top: 22px; }}
    button, .ghost-link {{
      border: 0;
      border-radius: 999px;
      padding: 12px 18px;
      font: inherit;
      font-weight: 700;
      cursor: pointer;
      text-decoration: none;
      transition: transform 140ms ease, box-shadow 140ms ease, border-color 140ms ease;
    }}
    button:hover, .ghost-link:hover {{ transform: translateY(-1px); }}
    .primary {{
      background: linear-gradient(135deg, var(--brand), var(--brand-strong));
      color: white;
      box-shadow: 0 12px 26px rgba(136, 23, 26, 0.28);
    }}
    .secondary {{
      background: linear-gradient(135deg, #1b2d40, #101c29);
      color: white;
      box-shadow: 0 12px 26px rgba(0, 0, 0, 0.22);
    }}
    .ghost-link {{
      background: rgba(255,255,255,0.04);
      color: #dfeef7;
      border: 1px solid var(--line);
    }}
    .logout-button {{
      background: rgba(255,255,255,0.04);
      color: #e6f6ff;
      border: 1px solid var(--line);
      box-shadow: none;
    }}
    .logout-button:hover {{
      border-color: rgba(200, 40, 46, 0.32);
      background: rgba(200,40,46,0.10);
    }}
    .danger {{
      background: rgba(194, 61, 76, 0.14);
      color: #ffd7dc;
      border: 1px solid rgba(194, 61, 76, 0.28);
      box-shadow: none;
    }}
    .small-button {{
      padding: 8px 12px;
      font-size: 13px;
    }}
    .status {{ margin: 0 0 18px 0; padding: 13px 16px; border-radius: 16px; font-size: 14px; white-space: pre-line; line-height: 1.5; }}
    .status.info {{ background: rgba(200, 40, 46, 0.12); color: #ffc2c4; }}
    .status.ok {{ background: var(--ok-soft); color: #a4f0c9; }}
    .status.error {{ background: var(--error-soft); color: #ffb3bc; }}
    .summary-list {{ display: grid; gap: 0; }}
    .summary-row {{
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(150px, 220px);
      gap: 14px;
      align-items: start;
      padding: 12px 0;
      border-top: 1px solid var(--line);
    }}
    .summary-row:first-child {{
      padding-top: 0;
      border-top: 0;
    }}
    .summary-copy strong {{
      display: block;
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.12em;
      margin-bottom: 4px;
      color: #e8f7ff;
    }}
    .summary-copy small {{
      display: block;
      color: var(--muted);
      line-height: 1.45;
      font-size: 13px;
    }}
    .summary-value {{
      display: inline-flex;
      align-items: center;
      justify-content: flex-start;
      width: 100%;
      min-height: 40px;
      padding: 10px 12px;
      border-radius: 14px;
      border: 1px solid var(--line);
      background: var(--panel-soft);
      color: #f5fbff;
      text-decoration: none;
      word-break: break-word;
      font: 600 13px/1.45 "Consolas", "SFMono-Regular", monospace;
    }}
    a.summary-value:hover {{
      border-color: rgba(200, 40, 46, 0.32);
      background: rgba(200, 40, 46, 0.10);
    }}
    .summary-value.disabled {{
      color: var(--muted);
      background: rgba(92, 114, 134, 0.10);
    }}
    .panel-note {{
      margin-top: 16px;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.5;
    }}
    pre {{
      margin: 0;
      padding: 18px;
      max-height: 420px;
      overflow: auto;
      border-radius: 18px;
      background: linear-gradient(180deg, #05090f, #0a1118);
      color: #e8f5ff;
      line-height: 1.45;
      font-size: 13px;
      border: 1px solid rgba(120, 152, 176, 0.12);
    }}
    .footer-note {{ margin-top: 12px; font-size: 13px; color: var(--muted); line-height: 1.5; }}
    .config-actions-row {{
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      margin: 12px 0;
    }}
    .copy-button {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 40px;
      padding: 9px 13px;
      border-radius: 12px;
      border: 1px solid var(--line);
      background: var(--panel-soft);
      color: #e8f7ff;
      cursor: pointer;
      font-weight: 700;
    }}
    .copy-button:hover {{
      border-color: rgba(200, 40, 46, 0.45);
      background: rgba(200, 40, 46, 0.12);
    }}
    .copy-icon {{
      position: relative;
      width: 16px;
      height: 16px;
      flex: 0 0 16px;
    }}
    .copy-icon::before, .copy-icon::after {{
      content: "";
      position: absolute;
      width: 9px;
      height: 9px;
      border: 1.7px solid currentColor;
      border-radius: 2px;
    }}
    .copy-icon::before {{ left: 1px; top: 5px; }}
    .copy-icon::after {{ left: 5px; top: 1px; background: var(--panel-soft); }}
    .dashboard-grid {{
      display: grid;
      grid-template-columns: minmax(0, 1fr);
      gap: 16px;
    }}
    .dashboard-card {{
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: 18px;
      background: linear-gradient(180deg, rgba(15, 25, 36, 0.98), rgba(9, 16, 24, 0.98));
    }}
    .dashboard-card-head {{
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 14px;
    }}
    .dashboard-card-head h4 {{ margin: 0; color: #fff; font-size: 15px; }}
    .dashboard-card-head small {{ display: block; margin-top: 4px; color: var(--muted); line-height: 1.4; }}
    .dashboard-list {{ display: grid; gap: 9px; }}
    .dashboard-row {{
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      align-items: center;
      gap: 12px;
      padding: 12px 13px;
      border-radius: 14px;
      background: rgba(255,255,255,0.025);
      border: 1px solid rgba(150,176,194,0.09);
    }}
    .dashboard-device {{ display: flex; align-items: center; gap: 11px; min-width: 0; }}
    .status-dot {{
      width: 11px; height: 11px; border-radius: 50%; flex: 0 0 11px;
      background: #607282; box-shadow: 0 0 0 4px rgba(96,114,130,0.10);
    }}
    .status-dot.online {{ background: #38d996; box-shadow: 0 0 0 4px rgba(56,217,150,0.12), 0 0 16px rgba(56,217,150,0.24); }}
    .status-dot.reachable {{ background: #f2b94b; box-shadow: 0 0 0 4px rgba(242,185,75,0.12), 0 0 14px rgba(242,185,75,0.18); }}
    .status-dot.offline {{ background: #ff5d6c; box-shadow: 0 0 0 4px rgba(255,93,108,0.11), 0 0 14px rgba(255,93,108,0.16); }}
    .status-dot.unknown {{ background: #8093a3; }}
    .device-copy {{ min-width: 0; }}
    .device-copy strong {{ display: block; color: #eef9ff; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
    .device-copy small {{ display: block; margin-top: 3px; color: var(--muted); font: 12px/1.3 "Consolas", "SFMono-Regular", monospace; }}
    .device-state {{ text-align: right; }}
    .device-state strong {{ display: block; font-size: 12px; text-transform: uppercase; color: #dcecf5; }}
    .device-state small {{ display: block; margin-top: 3px; color: var(--muted); font-size: 11px; }}
    .dashboard-summary {{
      display: flex; align-items: center; gap: 9px; color: var(--muted); font-size: 12px;
      padding: 7px 10px; border-radius: 999px; background: rgba(255,255,255,0.035); border: 1px solid var(--line);
    }}
    .dashboard-summary b {{ color: #eef9ff; }}
    .dashboard-note {{ margin: 14px 0 0; color: var(--muted); font-size: 12px; line-height: 1.45; }}
    .network-stat-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 12px;
      margin-bottom: 18px;
    }}
    .network-stat-card {{
      padding: 15px 16px;
      border: 1px solid var(--line);
      border-radius: 16px;
      background: var(--panel-soft);
    }}
    .network-stat-card span {{
      display: block;
      color: var(--muted);
      font-size: 11px;
      font-weight: 800;
      text-transform: uppercase;
      margin-bottom: 7px;
    }}
    .network-stat-card strong {{
      display: block;
      color: #f5fbff;
      font-size: 23px;
      line-height: 1.1;
      font-variant-numeric: tabular-nums;
    }}
    .network-chart-wrap {{
      position: relative;
      height: 320px;
      min-height: 240px;
      border: 1px solid var(--line);
      border-radius: 18px;
      background: linear-gradient(180deg, rgba(8, 18, 27, 0.95), rgba(5, 12, 18, 0.98));
      overflow: hidden;
    }}
    #network-chart {{ width: 100%; height: 100%; display: block; }}
    .network-chart-empty {{
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
      text-align: center;
      color: var(--muted);
      pointer-events: none;
      background: rgba(5, 12, 18, 0.42);
      backdrop-filter: blur(2px);
    }}
    .network-chart-empty[hidden] {{ display: none !important; }}
    .network-legend {{
      display: flex;
      gap: 18px;
      flex-wrap: wrap;
      margin-top: 12px;
      color: var(--muted);
      font-size: 13px;
    }}
    .legend-item {{ display: inline-flex; align-items: center; gap: 7px; }}
    .legend-dot {{ width: 9px; height: 9px; border-radius: 50%; }}
    .legend-dot.rx {{ background: #e0464c; }}
    .legend-dot.tx {{ background: #5ee6a8; }}
    .traffic-table {{ margin-top:16px; border:1px solid var(--line); border-radius:16px; overflow:hidden; }}
    .traffic-row {{ display:grid; grid-template-columns:minmax(150px,1fr) 130px 130px; align-items:center; gap:16px; padding:11px 16px; border-top:1px solid rgba(128,157,178,.11); }}
    .traffic-row:first-child {{ border-top:0; }}
    .traffic-row.header {{ color:var(--muted); background:rgba(128,157,178,.055); font-size:11px; font-weight:800; text-transform:uppercase; letter-spacing:.06em; }}
    .traffic-device {{ display:flex; align-items:center; gap:9px; color:#eef9ff; font-weight:750; }}
    .traffic-device-dot {{ width:8px; height:8px; border-radius:50%; background:#536676; }}
    .traffic-row.active .traffic-device-dot {{ background:#e0464c; box-shadow:0 0 12px rgba(224,70,76,.5); }}
    .traffic-value {{ text-align:right; color:#c8d9e5; font-variant-numeric:tabular-nums; }}
    .traffic-value.rx {{ color:#ff7a7f; }}
    .traffic-value.tx {{ color:#7aefb9; }}
    .profiles-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 310px), 1fr)); gap: 16px; }}
    .profile-qr {{display:block;width:175px;max-width:100%;height:auto;margin:16px auto 4px;padding:8px;background:white;border-radius:12px}}
    .profile-card {{
      padding: 20px;
      border: 1px solid var(--line);
      border-radius: 18px;
      background: linear-gradient(180deg, rgba(15,25,36,.98), rgba(8,15,23,.98));
    }}
    .profile-card-head {{ display:flex; justify-content:space-between; align-items:flex-start; gap:14px; }}
    .profile-card-head h3 {{ margin:0; color:#fff; font-size:17px; }}
    .profile-card-head p {{ margin:5px 0 0; color:var(--muted); font-size:13px; line-height:1.4; }}
    .profile-badge {{ padding:5px 9px; border-radius:999px; border:1px solid rgba(200,40,46,.3); background:rgba(200,40,46,.1); color:#ffcfd1; font-size:11px; font-weight:800; text-transform:uppercase; }}
    .profile-actions {{ display:flex; flex-wrap:wrap; gap:8px; margin-top:18px; }}
    .icon-action {{
      display:inline-flex; align-items:center; justify-content:center; gap:8px; min-height:40px;
      padding:9px 12px; border-radius:12px; border:1px solid var(--line); background:var(--panel-soft);
      color:#e8f7ff; text-decoration:none; font-weight:750; cursor:pointer; box-shadow:none;
    }}
    .icon-action:hover {{ border-color:rgba(200,40,46,.45); background:rgba(200,40,46,.12); }}
    .icon-action.primary-action {{ background:rgba(200,40,46,.2); border-color:rgba(200,40,46,.45); }}
    .download-icon {{ position:relative; width:16px; height:16px; flex:0 0 16px; border-bottom:1.8px solid currentColor; }}
    .download-icon::before {{ content:""; position:absolute; left:7px; top:1px; height:9px; border-left:1.8px solid currentColor; }}
    .download-icon::after {{ content:""; position:absolute; left:4px; top:6px; width:6px; height:6px; border-right:1.8px solid currentColor; border-bottom:1.8px solid currentColor; transform:rotate(45deg); }}
    .refresh-icon {{ font-size:19px; line-height:14px; }}
    .profile-details {{ margin-top:16px; border-top:1px solid var(--line); padding-top:14px; }}
    .profile-details summary {{ color:var(--muted); cursor:pointer; font-weight:700; font-size:13px; }}
    .profile-details[open] summary {{ color:#dff6ff; margin-bottom:12px; }}
    .profile-details pre {{ max-height:300px; font-size:12px; }}
    .compact-header {{
      display: grid;
      grid-template-columns: auto minmax(220px, 1fr) auto auto;
      align-items: center;
      gap: 22px;
      min-height: 96px;
      padding: 12px 18px 12px 24px;
      margin-bottom: 16px;
      border-radius: 16px;
    }}
    .compact-brand {{ display:flex; align-items:center; min-width:360px; grid-column:1; grid-row:1; }}
    .compact-brand img {{ display:block; width:360px; max-height:68px; object-fit:contain; object-position:left center; }}
    .compact-header .primary-navigation {{ grid-column:3; grid-row:1; margin:0; min-width:min(540px, 44vw); }}
    .compact-header .logout-form {{ grid-column:4; grid-row:1; margin:0; }}
    .compact-header .logout-button {{ min-height:42px; padding:9px 15px; border-radius:9px; box-shadow:none; background:var(--panel-soft); border:1px solid var(--line); }}
    .header-status {{ grid-column:2; grid-row:1; margin:0; padding:8px 11px; font-size:12px; opacity:1; transition:opacity 220ms ease, transform 220ms ease; }}
    .header-status.dismissed {{ opacity:0; transform:translateY(-3px); pointer-events:none; }}
    .primary-navigation {{ border-radius:12px; }}
    .primary-navigation .tab-button {{ border-radius:8px; min-height:42px; }}
    .layout.focus-mode {{ grid-template-columns: minmax(0, 1fr); }}
    .layout.focus-mode .aside {{ display:none; }}
    .control-panel {{ border-radius:16px; box-shadow:0 14px 34px rgba(0,0,0,.24); }}
    .control-panel > .panel-body {{ padding:16px; }}
    .control-heading {{ display:none; }}
    .status {{ margin-bottom:14px; padding:10px 13px; border-radius:9px; }}
    .overview-summary {{ display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:9px; margin-bottom:12px; }}
    .overview-metric {{ min-height:66px; padding:11px 13px; border-radius:10px; border:1px solid var(--line); background:var(--panel-soft); }}
    .overview-metric span {{ display:block; margin-bottom:5px; color:var(--muted); font-size:10px; font-weight:800; text-transform:uppercase; }}
    .overview-metric strong {{ display:block; color:#fff; font-size:14px; overflow-wrap:anywhere; }}
    .overview-services {{ display:flex; align-items:center; gap:7px; flex-wrap:wrap; margin-bottom:12px; }}
    .overview-services-label {{ margin-right:3px; color:var(--muted); font-size:11px; font-weight:800; text-transform:uppercase; }}
    .service-link {{ display:inline-flex; align-items:center; gap:7px; min-height:34px; padding:7px 10px; border:1px solid var(--line); border-radius:8px; background:var(--panel-soft); color:#e8f7ff; text-decoration:none; font-size:12px; font-weight:700; }}
    .service-link:hover {{ border-color:rgba(200,40,46,.45); background:rgba(200,40,46,.10); }}
    .external-icon {{ color:var(--brand); font-size:14px; }}
    .redirect-details {{ position:relative; }}
    .redirect-details summary {{ display:inline-flex; align-items:center; min-height:34px; padding:7px 10px; border:1px solid var(--line); border-radius:8px; background:var(--panel-soft); color:#cde8f5; cursor:pointer; font-size:12px; font-weight:700; list-style:none; }}
    .redirect-details summary::-webkit-details-marker {{ display:none; }}
    .redirect-details summary::after {{ content:"⌄"; margin-left:8px; color:var(--brand); }}
    .redirect-details[open] summary::after {{ content:"⌃"; }}
    .redirect-list {{ position:absolute; left:0; z-index:8; width:min(560px,86vw); margin-top:7px; padding:8px 12px; border:1px solid var(--line); border-radius:10px; background:#0b141e; box-shadow:var(--shadow); }}
    .redirect-row {{ display:grid; grid-template-columns:minmax(140px,1fr) 90px minmax(150px,1fr); gap:12px; align-items:center; padding:8px 4px; border-top:1px solid var(--line); font-size:12px; }}
    .redirect-row:first-child {{ border-top:0; }}
    .redirect-row span {{ color:var(--muted); }}
    .redirect-row code {{ color:#ffd0d2; text-align:right; }}
    .overview-workspace {{ display:grid; grid-template-columns:minmax(330px,.78fr) minmax(520px,1.42fr); gap:12px; align-items:start; }}
    .overview-workspace .config-block {{ padding:14px; margin:0; border-radius:12px; }}
    .overview-workspace .dashboard-card {{ padding:12px; border-radius:10px; }}
    .overview-workspace .dashboard-card-head {{ margin-bottom:9px; }}
    .overview-workspace .dashboard-row {{ padding:8px 10px; border-radius:8px; }}
    .overview-workspace .dashboard-list {{ gap:6px; }}
    .overview-workspace .network-chart-wrap {{ height:255px; min-height:220px; border-radius:10px; }}
    .overview-workspace .network-stat-grid {{ margin-bottom:10px; }}
    .overview-workspace .network-stat-card {{ padding:10px 12px; border-radius:9px; }}
    .overview-workspace .network-stat-card strong {{ font-size:20px; }}
    .overview-workspace .traffic-table {{ margin-top:10px; border-radius:10px; }}
    .overview-workspace .traffic-row {{ grid-template-columns:minmax(130px,1fr) 100px 100px; padding:7px 11px; }}
    .overview-workspace .dashboard-note {{ display:none; }}
    .overview-footer {{ display:flex; justify-content:space-between; align-items:center; gap:12px; margin-top:12px; color:var(--muted); font-size:11px; }}
    .system-details {{ position:relative; }}
    .system-details summary {{ cursor:pointer; color:#cde8f5; font-weight:700; }}
    .system-details-content {{ position:absolute; right:0; z-index:5; width:min(460px,80vw); margin-top:8px; padding:14px; border:1px solid var(--line); border-radius:12px; background:#0b141e; box-shadow:var(--shadow); }}
    .system-details-content .summary-row {{ grid-template-columns:1fr; }}
    @media (max-width: 1180px) {{
      .hero {{
        padding: 26px 20px 22px;
      }}
      .hero-meta {{
        grid-template-columns: 1fr;
        width: 100%;
      }}
      .layout {{
        grid-template-columns: 1fr;
      }}
      .aside {{
        position: static;
      }}
      .summary-row {{
        grid-template-columns: 1fr;
      }}
      .extra-rule-grid {{
        grid-template-columns: repeat(auto-fit, minmax(min(100%, 180px), 1fr));
      }}
      .dashboard-grid {{ grid-template-columns: 1fr; }}
      .network-stat-grid {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
      .compact-header {{ grid-template-columns:1fr auto; }}
      .compact-brand {{ grid-column:1; grid-row:1; }}
      .compact-header .logout-form {{ grid-column:2; grid-row:1; }}
      .compact-header .primary-navigation {{ grid-column:1 / -1; grid-row:2; width:100%; min-width:0; }}
      .header-status {{ grid-column:1 / -1; grid-row:3; }}
      .overview-summary {{ grid-template-columns:repeat(3,minmax(0,1fr)); }}
      .overview-workspace {{ grid-template-columns:1fr; }}
    }}
    * {{ min-width: 0; letter-spacing: 0 !important; }}
    .grid {{ grid-template-columns: repeat(auto-fit, minmax(min(100%, 240px), 1fr)); }}
    .extra-rule-head {{ flex-wrap: wrap; }}
    .extra-rule-head strong, .status, .panel-note, .footer-note {{ overflow-wrap: anywhere; }}
    button, .ghost-link {{ max-width: 100%; white-space: normal; overflow-wrap: anywhere; }}
    .summary-row {{ grid-template-columns: repeat(auto-fit, minmax(min(100%, 170px), 1fr)); }}
    img {{ max-width: 100%; }}
    @media (max-width: 600px) {{
      .page-shell {{ width: calc(100% - 20px); margin: 10px auto 20px; }}
      .panel-body, .config-block, .extra-rule-row {{ padding: 12px; }}
      .tab-bar {{ display: grid; grid-template-columns: 1fr; }}
      .actions > * {{ flex: 1 1 160px; text-align: center; }}
      h1 {{ font-size: 28px; }}
      .network-stat-grid {{ grid-template-columns: 1fr; }}
      .network-chart-wrap {{ height: 260px; }}
      .compact-brand {{ min-width:0; width:calc(100% - 90px); }}
      .compact-brand img {{ width:100%; }}
      .compact-header .primary-navigation {{ display:grid; grid-template-columns:1fr; }}
      .overview-summary {{ grid-template-columns:1fr 1fr; }}
      .overview-workspace .traffic-row {{ grid-template-columns:minmax(110px,1fr) 78px 78px; gap:7px; }}
      .overview-footer {{ align-items:flex-start; flex-direction:column; }}
      .system-details-content {{ left:0; right:auto; width:min(440px,calc(100vw - 52px)); }}
    }}
    @media (prefers-reduced-motion: reduce) {{
      *, *::before, *::after {{ animation: none !important; transition: none !important; }}
    }}
    .apply-progress {{ position:fixed;right:24px;bottom:24px;z-index:50;display:flex;align-items:center;gap:13px;padding:15px 20px;border:1px solid rgba(200,40,46,.45);border-radius:14px;background:#0b1722;color:#f5fbff;box-shadow:0 14px 40px #0009;font-size:14px; }}
    .apply-progress[hidden] {{ display:none; }}
    .apply-spinner {{ width:22px;height:22px;flex:none;border:3px solid #4b2427;border-top-color:#c8282e;border-radius:50%;animation:apply-spin .8s linear infinite; }}
    @keyframes apply-spin {{ to {{ transform:rotate(360deg); }} }}
    .remove-details {{ margin-top:28px;padding:16px 18px;border:1px solid #4b3540;border-radius:12px;background:#211820; }}
    .remove-details summary {{ cursor:pointer;color:#ffb6be;font-weight:700; }}
    .remove-details p {{ color:#cfb5bc;line-height:1.5; }}
    .remove-details input {{ max-width:240px; }}
    .remove-button {{ background:#a63248; }}
    .remove-button:disabled {{ opacity:.45;cursor:not-allowed; }}
  </style>
</head>
<body>
  <div class="page-shell">
    <header class="panel compact-header">
      <div class="compact-brand"><img src="{esc(LOGO_URL)}" alt="WireGuard VPN"></div>
      <div class="tab-bar primary-navigation" role="tablist" aria-label="Control panel sections">
        <button class="tab-button active" type="button" data-tab-target="overview">Overview</button>
        <button class="tab-button" type="button" data-tab-target="configuration">Configuration</button>
        <button class="tab-button" type="button" data-tab-target="profiles">VPN Profiles</button>
      </div>
      <form class="logout-form" method="post" action="/logout">
        <button class="logout-button" type="submit">Logout</button>
      </form>
      {status_html}
    </header>

    <div class="layout focus-mode" id="main-layout">
      <section class="panel control-panel">
        <div class="panel-body">
          <div class="panel-head control-heading">
            <div>
              <h2 class="panel-title">WireGuard VPN Control Center</h2>
              <p class="panel-subtitle">Live status, traffic, configuration and VPN profiles.</p>
            </div>
          </div>
          <form id="control-form" method="post" action="/apply">
            <div class="tab-page" data-tab-page="overview">
              <div class="overview-summary">
                <div class="overview-metric"><span>Public IP</span><strong>{esc(host)}</strong></div>
                <div class="overview-metric"><span>WireGuard Port</span><strong>UDP {esc(state.get("WG_PORT", ""))}</strong></div>
                <div class="overview-metric"><span>Build</span><strong>v{esc(build["version"])} · {esc(build["channel"])}</strong></div>
                <div class="overview-metric"><span>VPS Uptime</span><strong>{esc(build["uptime"])}</strong></div>
              </div>
              <div class="overview-services"><span class="overview-services-label">Public Services</span>{services_links}<details class="redirect-details"><summary>Port Redirects</summary><div class="redirect-list">{redirects_html}</div></details></div>
              <div class="overview-workspace">
              <section class="config-block">
                <div class="block-head">
                  <h3>WireGuard VPN Live Status</h3>
                  <p>Live WireGuard peers and reachability of the configured site LAN devices.</p>
                </div>
                <div class="dashboard-grid">
                  <div class="dashboard-card">
                    <div class="dashboard-card-head">
                      <div><h4>Connected Peers</h4><small>WireGuard peer activity on wg0.</small></div>
                      <div class="dashboard-summary"><b id="peer-online-count">0</b> online</div>
                    </div>
                    <div class="dashboard-list" id="peer-status-list">
                      <div class="dashboard-row"><div class="dashboard-device"><span class="status-dot unknown"></span><div class="device-copy"><strong>Loading peers…</strong><small>wg0</small></div></div><div class="device-state"><strong>Checking</strong></div></div>
                    </div>
                  </div>
                  <div class="dashboard-card">
                    <div class="dashboard-card-head">
                      <div><h4>LAN Devices</h4><small>ICMP and application-service reachability through the WireGuard VPN.</small></div>
                      <div class="dashboard-summary"><b id="lan-online-count">0</b>/<span id="lan-total-count">0</span> online</div>
                    </div>
                    <div class="dashboard-list" id="lan-status-list">
                      <div class="dashboard-row"><div class="dashboard-device"><span class="status-dot unknown"></span><div class="device-copy"><strong>Loading devices…</strong><small>LAN</small></div></div><div class="device-state"><strong>Checking</strong></div></div>
                    </div>
                  </div>
                </div>
                <p class="dashboard-note">Device status is sampled only while Overview is open and the page is visible. A device can be reported as Service Online when ICMP is blocked but a configured TCP service is reachable.</p>
              </section>
              <section class="config-block">
                <div class="block-head">
                  <h3>Network Statistics</h3>
                  <p>Live WireGuard RX and TX from the site LAN point of view, with per-device traffic.</p>
                </div>
                <div class="network-stat-grid">
                  <div class="network-stat-card"><span>RX Now</span><strong id="network-rx-now">0.00 Mbps</strong></div>
                  <div class="network-stat-card"><span>TX Now</span><strong id="network-tx-now">0.00 Mbps</strong></div>
                </div>
                <div class="network-chart-wrap">
                  <canvas id="network-chart" aria-label="Live WireGuard RX and TX traffic chart"></canvas>
                  <div class="network-chart-empty" id="network-chart-empty" hidden></div>
                </div>
                <div class="network-legend">
                  <span class="legend-item"><span class="legend-dot rx"></span>Total RX</span>
                  <span class="legend-item"><span class="legend-dot tx"></span>Total TX</span>
                  <span>Last 4 minutes · Mbps</span>
                </div>
                <div class="traffic-table" id="network-consumers">
                  <div class="traffic-row header"><span>Device</span><span class="traffic-value">RX</span><span class="traffic-value">TX</span></div>
                </div>
              </section>
              </div>
              <div class="overview-footer">
                <span>Traffic history covers the last four minutes while signed in.</span>
                <details class="system-details">
                  <summary>System information</summary>
                  <div class="system-details-content">
                    <div class="summary-list">
                      {summary_row("Script SHA-256", build["sha256"], "Installed source identity")}
                      {summary_row("Operating System", build["os"], "Kernel " + build["kernel"])}
                      {summary_row("Last Apply", build["last_apply"], "Applied-state timestamp")}
                      {summary_row("Web UI Started", build["webui_started"], "Current service activation")}
                    </div>
                    <div class="config-actions-row"><a class="ghost-link" href="/download-support-bundle">Download Support Bundle</a></div>
                  </div>
                </details>
              </div>
            </div>

            <div class="tab-page" data-tab-page="configuration" hidden>
              <div class="subtab-bar" role="tablist" aria-label="Configuration sections">
                <button class="subtab-button active" type="button" data-config-target="core">Core</button>
                <button class="subtab-button" type="button" data-config-target="extra">Extra Port Forwarding</button>
                <button class="subtab-button" type="button" data-config-target="dmz">DMZ</button>
                <button class="subtab-button" type="button" data-config-target="domain">Domain</button>
              </div>
              <div data-config-page="core">
              <section class="config-block">
              <div class="block-head">
                <h3>Network</h3>
                <p>Remote LAN and public VPS settings.</p>
              </div>
              <div class="grid">
                {input_row("LAN CIDR", "LAN_CIDR", state.get("LAN_CIDR", ""))}
                {input_row("Router LAN IP", "ROUTER_LAN_IP", state.get("ROUTER_LAN_IP", ""))}
                {input_row("Public iface", "PUB_IFACE", state.get("PUB_IFACE", ""))}
                {input_row("Public IPv4", "PUB_IP", state.get("PUB_IP", ""))}
              </div>
            </section>

            <section class="config-block">
              <div class="block-head">
                <h3>StreamHub</h3>
                <p>Destination IP for the published StreamHub ports.</p>
              </div>
              <div class="grid">
                {input_row("StreamHub IP", "STREAMHUB_IP", state.get("STREAMHUB_IP", ""))}
              </div>
            </section>

            <section class="config-block">
              <div class="block-head">
                <h3>WireGuard</h3>
                <p>Port and peer addresses.</p>
              </div>
              <div class="grid">
                {input_row("WireGuard UDP port", "WG_PORT", state.get("WG_PORT", ""))}
                {input_row("WG tunnel CIDR", "WG_TUN_CIDR", state.get("WG_TUN_CIDR", ""))}
                {input_row("VPS WG IP", "WG_VPS_IP", state.get("WG_VPS_IP", ""))}
                {input_row("Router WG IP", "WG_GL_IP", state.get("WG_GL_IP", ""))}
                {input_row("Remote VPN Client WG IP", "REMOTE_CLIENT_IP", state.get("REMOTE_CLIENT_IP", ""))}
              </div>
            </section>

            <section class="config-block">
              <div class="block-head">
                <h3>Web Access</h3>
                <p>Username, password and port.</p>
              </div>
              <div class="grid">
                {input_row("Web UI username", "WEBUI_USER", state.get("WEBUI_USER", ""))}
                {input_row("Web UI TCP port", "WEBUI_PORT", state.get("WEBUI_PORT", ""))}
                {input_row("Current Web UI password", "WEBUI_CURRENT_PASSWORD", "", "password")}
                {input_row("New Web UI password", "WEBUI_PASSWORD", "", "password")}
                {input_row("Confirm new password", "WEBUI_PASSWORD_CONFIRM", "", "password")}
              </div>
            </section>
              </div>

              <div data-config-page="extra" hidden>
              <section class="config-block">
                <div class="block-head">
                  <h3>Extra Port Forwarding Rules</h3>
                </div>
                <div class="extra-rule-list" id="extra-rule-list">
                  {extra_rules_html}
                </div>
                <div class="actions">
                  <button class="secondary" type="button" id="add-extra-rule">Add Extra Rule</button>
                </div>
                <template id="extra-rule-template">
                  {extra_rule_row(empty_extra_rule())}
                </template>
              </section>
              </div>
              <div data-config-page="dmz" hidden>
                <section class="config-block">
                  <div class="block-head"><h3>DMZ</h3><p>Forward unassigned public TCP and UDP ports to one LAN device. StreamHub, Extra rules and VPS services keep their ports.</p></div>
                  <div class="grid">{input_row("DMZ destination IP (blank to disable)", "DMZ_IP", state.get("DMZ_IP", ""))}</div>
                  <details class="profile-details"><summary>Ports excluded from DMZ</summary><div class="summary-list">{dmz_exclusions}</div></details>
                </section>
              </div>
              <div data-config-page="domain" hidden>
                <section class="config-block">
                  <div class="block-head"><h3>Domain</h3><p>Set a domain for the Public Services links in Overview. Configure DNS or dynamic DNS separately; this only changes where those links point.</p></div>
                  <div class="grid"><label class="field"><span>Domain for Public Services</span><input form="public-domain-form" name="domain" type="text" maxlength="253" value="{esc(state.get('PUBLIC_DOMAIN', ''))}" placeholder="streamhub.example.com" autocomplete="off"{' readonly' if state.get('PUBLIC_DOMAIN') else ''}></label></div>
                  <div class="actions">{'<button class="secondary" type="submit" form="public-domain-form" name="operation" value="remove">Remove</button>' if state.get('PUBLIC_DOMAIN') else '<button class="primary" type="submit" form="public-domain-form" name="operation" value="add">Add</button>'}</div>
                  <p class="hint">{ 'Remove the domain to use the VPS public IP in those links again.' if state.get('PUBLIC_DOMAIN') else 'Enter your domain, then select Add to use it in the Public Services links.' }</p>
                </section>
              </div>
            <div id="config-runtime-actions">
            <div class="actions">
              <button class="primary" type="submit" id="apply-button">Apply + Make Persistent</button>
              <button class="secondary" type="submit" formaction="/test" formmethod="post">Run Test</button>
              <button class="secondary" type="submit" formaction="/health" formmethod="post">System Health</button>
            </div>
            <div class="footer-note">To change username or password, enter the current password. Leave all password fields empty to keep it unchanged.</div>
            </div>
            <details class="remove-details"><summary>Remove All</summary>
              <p>Delete WireGuard VPN from this VPS, including its tunnel, keys, forwarding rules and Web UI. The connection will close. Type <strong>REMOVE</strong> to confirm.</p>
              <label class="field"><span>Confirmation</span><input id="remove-confirmation" form="remove-form" name="confirmation" type="text" pattern="REMOVE" required autocomplete="off" spellcheck="false" placeholder="REMOVE"></label>
              <div class="actions"><button class="remove-button" id="remove-button" form="remove-form" type="submit" disabled>Remove WireGuard VPN</button></div>
            </details>
            </div>

            <div class="tab-page" data-tab-page="profiles" hidden>
              <div class="profiles-grid">
                <section class="profile-card">
                  <div class="profile-card-head">
                    <div><h3>WireGuard Router</h3><p>Current router WireGuard peer profile.</p></div>
                    <span class="profile-badge">Router</span>
                  </div>
                  <div class="profile-actions">
                    <button class="icon-action" type="button" data-copy-target="router-config" title="Copy router configuration"><span class="copy-icon" aria-hidden="true"></span><span>Copy</span></button>
                    <a class="icon-action" href="/download-router-config" title="Download router configuration"><span class="download-icon" aria-hidden="true"></span><span>Download</span></a>
                  </div>
                  <details class="profile-details"><summary>View configuration</summary><pre id="router-config">{esc(router_config_text())}</pre></details>
                  {f'<img class="profile-qr" src="/profile-qr/router" alt="Router WireGuard QR code">' if Path(ROUTER_CONF_OUT).is_file() else ''}
                </section>
                <section class="profile-card">
                  <div class="profile-card-head">
                    <div><h3>Remote VPN Client</h3><p>Optional laptop or mobile peer.</p></div>
                    <span class="profile-badge">Client</span>
                  </div>
                  <div class="profile-actions">
                    <button class="icon-action primary-action" type="submit" formaction="/create-remote-client" formmethod="post"><span class="refresh-icon" aria-hidden="true">↻</span><span>Create / Refresh</span></button>
                    <button class="icon-action" type="button" data-copy-target="remote-client-config" title="Copy remote client configuration"><span class="copy-icon" aria-hidden="true"></span><span>Copy</span></button>
                    <a class="icon-action" href="/download-remote-client" title="Download remote client configuration"><span class="download-icon" aria-hidden="true"></span><span>Download</span></a>
                  </div>
                  <details class="profile-details"><summary>View configuration</summary><pre id="remote-client-config">{esc(remote_client_config_text())}</pre></details>
                  {f'<img class="profile-qr" src="/profile-qr/client" alt="Remote client WireGuard QR code">' if Path(REMOTE_CLIENT_CONF_OUT).is_file() else ''}
                </section>
              </div>
            </div>
          </form>
          <form id="public-domain-form" method="post" action="/public-domain"></form>
          <form id="remove-form" method="post" action="/remove-all"></form>
        </div>
      </section>

      <aside class="aside">
        <section class="panel summary-panel">
          <div class="panel-body">
            <div class="panel-head">
              <div>
                <h2 class="panel-title">Build Information</h2>
                <p class="panel-subtitle">Exact software and VPS identity.</p>
              </div>
            </div>
            <div class="summary-list">
              {summary_row("Version", "v" + build["version"], build["channel"])}
              {summary_row("Script SHA-256", build["sha256"], "Installed source identity")}
              {summary_row("Operating System", build["os"], "Kernel " + build["kernel"])}
              {summary_row("Last Apply", build["last_apply"], "Applied-state timestamp")}
              {summary_row("Web UI Started", build["webui_started"], "Current service activation")}
            </div>
            <div class="config-actions-row">
              <a class="ghost-link" href="/download-support-bundle">Download Support Bundle</a>
            </div>
          </div>
        </section>

        <section class="panel summary-panel">
          <div class="panel-body">
            <div class="panel-head">
              <div>
                <h2 class="panel-title">Extra Rules</h2>
                <p class="panel-subtitle">Custom user forwarding.</p>
              </div>
            </div>
            <div class="summary-list">{extra_rules_summary}</div>
          </div>
        </section>

        <section class="panel">
          <div class="panel-body">
            <div class="panel-head">
              <div>
                <h2 class="panel-title">Last Output</h2>
                <p class="panel-subtitle">Latest script output.</p>
              </div>
            </div>
            <pre>{esc(output or "No action executed yet.")}</pre>
          </div>
        </section>
      </aside>
    </div>

  </div>
  <div class="apply-progress" id="apply-progress" hidden role="status" aria-live="polite"><span class="apply-spinner" aria-hidden="true"></span><span id="apply-progress-text">Applying configuration…</span></div>
  <script>
    (function() {{
      const controlForm = document.getElementById("control-form");
      const removeConfirmation = document.getElementById("remove-confirmation");
      const removeButton = document.getElementById("remove-button");
      if (removeConfirmation && removeButton) removeConfirmation.addEventListener("input", function() {{ removeButton.disabled = removeConfirmation.value !== "REMOVE"; }});
      if (controlForm) controlForm.addEventListener("submit", function(event) {{
        if (!event.submitter || event.submitter.id !== "apply-button") return;
        const progress = document.getElementById("apply-progress");
        const progressText = document.getElementById("apply-progress-text");
        const button = event.submitter;
        progress.hidden = false;
        button.textContent = "Applying…";
        const started = Date.now();
        window.setInterval(function() {{ progressText.textContent = "Applying and saving · " + Math.floor((Date.now() - started) / 1000) + "s"; }}, 1000);
      }});
      const activeTabKey = "wgvpn_active_config_tab";
      const activeConfigKey = "wgvpn_active_config_section";
      const tabButtons = document.querySelectorAll("[data-tab-target]");
      const tabPages = document.querySelectorAll("[data-tab-page]");
      const configButtons = document.querySelectorAll("[data-config-target]");
      const configPages = document.querySelectorAll("[data-config-page]");
      const headerStatus = document.querySelector(".header-status");
      if (headerStatus) {{
        window.setTimeout(function() {{
          headerStatus.classList.add("dismissed");
          window.setTimeout(function() {{ headerStatus.remove(); }}, 250);
        }}, 10000);
      }}

      function activateTab(tabName) {{
        tabButtons.forEach(function(button) {{
          const active = button.dataset.tabTarget === tabName;
          button.classList.toggle("active", active);
          button.setAttribute("aria-selected", active ? "true" : "false");
        }});
        tabPages.forEach(function(page) {{
          page.hidden = page.dataset.tabPage !== tabName;
        }});
        const mainLayout = document.getElementById("main-layout");
        if (mainLayout) mainLayout.classList.toggle("focus-mode", tabName !== "configuration");
        try {{
          window.sessionStorage.setItem(activeTabKey, tabName);
        }} catch (err) {{}}
        updateNetworkPolling();
        updateDashboardPolling();
      }}

      function activateConfigTab(tabName) {{
        configButtons.forEach(function(button) {{
          const active = button.dataset.configTarget === tabName;
          button.classList.toggle("active", active);
          button.setAttribute("aria-selected", active ? "true" : "false");
        }});
        configPages.forEach(function(page) {{
          page.hidden = page.dataset.configPage !== tabName;
        }});
        const runtimeActions = document.getElementById("config-runtime-actions");
        if (runtimeActions) runtimeActions.hidden = tabName === "domain";
        try {{ window.sessionStorage.setItem(activeConfigKey, tabName); }} catch (err) {{}}
      }}

      const peerStatusList = document.getElementById("peer-status-list");
      const lanStatusList = document.getElementById("lan-status-list");
      const peerOnlineCount = document.getElementById("peer-online-count");
      const lanOnlineCount = document.getElementById("lan-online-count");
      const lanTotalCount = document.getElementById("lan-total-count");
      let dashboardTimer = null;
      let dashboardRequestActive = false;

      function dashboardTabIsActive() {{
        const page = document.querySelector('[data-tab-page="overview"]');
        return !!page && !page.hidden && document.visibilityState === "visible";
      }}

      function formatBytes(value) {{
        const n = Number(value) || 0;
        if (n >= 1000000000) return (n / 1000000000).toFixed(2) + " GB";
        if (n >= 1000000) return (n / 1000000).toFixed(1) + " MB";
        if (n >= 1000) return (n / 1000).toFixed(1) + " KB";
        return n.toFixed(0) + " B";
      }}

      function handshakeText(age) {{
        if (age === null || age === undefined) return "No handshake";
        const seconds = Math.max(0, Number(age) || 0);
        if (seconds < 60) return Math.round(seconds) + "s ago";
        if (seconds < 3600) return Math.floor(seconds / 60) + "m ago";
        return Math.floor(seconds / 3600) + "h ago";
      }}

      function renderDashboard(payload) {{
        const peers = Array.isArray(payload.peers) ? payload.peers : [];
        const devices = Array.isArray(payload.devices) ? payload.devices : [];
        if (peerOnlineCount) peerOnlineCount.textContent = String(peers.filter(function(p) {{ return p.online; }}).length);
        if (lanOnlineCount) lanOnlineCount.textContent = String(devices.filter(function(d) {{ return d.online; }}).length);
        if (lanTotalCount) lanTotalCount.textContent = String(devices.length);
        if (peerStatusList) {{
          peerStatusList.innerHTML = peers.map(function(peer) {{
            const stateClass = peer.online ? "online" : "offline";
            const stateText = peer.online ? "Online" : (peer.configured ? "Offline" : "Not configured");
            const detail = peer.configured ? "Handshake " + handshakeText(peer.handshake_age) : "Peer not present on wg0";
            return '<div class="dashboard-row"><div class="dashboard-device"><span class="status-dot ' + stateClass + '"></span><div class="device-copy"><strong>' + escapeHtml(peer.name) + '</strong>' + (peer.ip ? '<small>' + escapeHtml(peer.ip) + '</small>' : '') + '</div></div><div class="device-state"><strong>' + stateText + '</strong><small>' + escapeHtml(detail) + '</small></div></div>';
          }}).join("");
        }}
        if (lanStatusList) {{
          lanStatusList.innerHTML = devices.map(function(device) {{
            const configured = device.configured !== false;
            const status = configured ? (device.status || (device.online ? "online" : "offline")) : "not_configured";
            const stateClass = status === "reachable" ? "reachable" : ((status === "online" || status === "service_online") ? "online" : "offline");
            const stateLabels = {{online:"Online", service_online:"Service Online", reachable:"Reachable", offline:"Offline", not_configured:"Not configured"}};
            const detail = configured ? (device.ping_online && device.latency_ms !== null ? "RTT " + Number(device.latency_ms).toFixed(1) + " ms" : "No ICMP reply") : "";
            return '<div class="dashboard-row"><div class="dashboard-device"><span class="status-dot ' + stateClass + '"></span><div class="device-copy"><strong>' + escapeHtml(device.name) + '</strong>' + (device.ip ? '<small>' + escapeHtml(device.ip) + '</small>' : '') + '</div></div><div class="device-state"><strong>' + escapeHtml(stateLabels[status] || "Unknown") + '</strong><small>' + escapeHtml(detail) + '</small></div></div>';
          }}).join("");
        }}
      }}

      function escapeHtml(value) {{
        return String(value == null ? "" : value).replace(/[&<>"']/g, function(ch) {{
          return {{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}}[ch];
        }});
      }}

      async function pollDashboard() {{
        if (!dashboardTabIsActive() || dashboardRequestActive) return;
        dashboardRequestActive = true;
        try {{
          const response = await fetch("/api/dashboard-status", {{ cache: "no-store", credentials: "same-origin" }});
          if (!response.ok) throw new Error("dashboard unavailable");
          renderDashboard(await response.json());
        }} catch (err) {{
          if (peerStatusList) peerStatusList.innerHTML = '<div class="dashboard-row"><div class="dashboard-device"><span class="status-dot offline"></span><div class="device-copy"><strong>Status unavailable</strong><small>Dashboard endpoint</small></div></div><div class="device-state"><strong>Offline</strong></div></div>';
        }} finally {{
          dashboardRequestActive = false;
        }}
      }}

      function updateDashboardPolling() {{
        if (dashboardTimer !== null) {{ window.clearInterval(dashboardTimer); dashboardTimer = null; }}
        if (dashboardTabIsActive()) {{
          pollDashboard();
          dashboardTimer = window.setInterval(pollDashboard, 5000);
        }}
      }}

      const networkCanvas = document.getElementById("network-chart");
      const networkEmpty = document.getElementById("network-chart-empty");
      const rxNow = document.getElementById("network-rx-now");
      const txNow = document.getElementById("network-tx-now");
      const consumerList = document.getElementById("network-consumers");
      const deviceMeta = {{
        router: "Router", streamhub: "StreamHub",
        other: "Other / VPN"
      }};
      const networkWindowMs = 4 * 60 * 1000;
      let networkTimer = null;
      let networkRequestActive = false;
      let networkServerOffsetMs = 0;
      let networkSamples = [];
      let displayedYMax = 10;
      let scaleHoldUntil = 0;
      let lastScaleUpdate = performance.now();

      function formatMbps(value) {{
        if (!Number.isFinite(value) || value < 0) return "0.00 Mbps";
        if (value >= 100) return value.toFixed(1) + " Mbps";
        return value.toFixed(2) + " Mbps";
      }}

      function renderConsumers(rates) {{
        const entries = Object.keys(deviceMeta).map(function(key) {{
          const rate = rates[key] || {{}};
          return {{ key:key, label:deviceMeta[key], rx:Number(rate.rx || 0), tx:Number(rate.tx || 0) }};
        }});
        if (consumerList) consumerList.innerHTML = '<div class="traffic-row header"><span>Device</span><span class="traffic-value">RX</span><span class="traffic-value">TX</span></div>' + entries.map(function(item) {{
          const active = item.rx >= 0.01 || item.tx >= 0.01;
          return '<div class="traffic-row' + (active ? ' active' : '') + '"><span class="traffic-device"><i class="traffic-device-dot"></i>' + escapeHtml(item.label) + '</span><span class="traffic-value rx">' + formatMbps(item.rx) + '</span><span class="traffic-value tx">' + formatMbps(item.tx) + '</span></div>';
        }}).join("");
      }}

      function networkTabIsActive() {{
        const page = document.querySelector('[data-tab-page="overview"]');
        return !!page && !page.hidden && document.visibilityState === "visible";
      }}

      function pruneNetworkSamples(now) {{
        while (networkSamples.length && networkSamples[0].time < now - networkWindowMs) networkSamples.shift();
      }}

      function updateNetworkPolling() {{
        if (!networkCanvas) return;
        if (networkTabIsActive()) {{
          if (networkTimer === null) {{
            fetchNetworkSample();
            networkTimer = window.setInterval(fetchNetworkSample, 1000);
          }}
          drawNetworkChart();
        }} else if (networkTimer !== null) {{
          window.clearInterval(networkTimer);
          networkTimer = null;
        }}
      }}

      async function fetchNetworkSample() {{
        if (networkRequestActive) return;
        networkRequestActive = true;
        try {{
          const response = await fetch("/api/network-history", {{ cache: "no-store", credentials: "same-origin" }});
          if (!response.ok) throw new Error("stats unavailable");
          const payload = await response.json();
          networkServerOffsetMs = payload.timestamp - Date.now();
          if (!payload.available) {{
            networkSamples = [];
            if (networkEmpty) networkEmpty.textContent = "wg0 is not available. Apply the configuration to start monitoring.";
            if (networkEmpty) networkEmpty.hidden = false;
            if (rxNow) rxNow.textContent = "—";
            if (txNow) txNow.textContent = "—";
            drawNetworkChart();
            return;
          }}
          if (networkEmpty) networkEmpty.hidden = true;
          // Use the complete server window on every visit. Browser timers can
          // pause in a background tab, but the VPS continues sampling.
          networkSamples = Array.isArray(payload.samples) ? payload.samples : [];
          pruneNetworkSamples(payload.timestamp);
          if (payload.latest) {{
            if (rxNow) rxNow.textContent = formatMbps(payload.latest.rx);
            if (txNow) txNow.textContent = formatMbps(payload.latest.tx);
            renderConsumers(payload.latest.devices || {{}});
          }} else {{
            if (rxNow) rxNow.textContent = "—";
            if (txNow) txNow.textContent = "—";
          }}
          if (networkTabIsActive()) drawNetworkChart();
        }} catch (err) {{
          if (networkEmpty) {{
            networkEmpty.textContent = "Live network statistics are temporarily unavailable.";
            networkEmpty.hidden = false;
          }}
        }} finally {{
          networkRequestActive = false;
        }}
      }}

      function drawNetworkChart() {{
        if (!networkCanvas) return;
        const chartNow = Date.now() + networkServerOffsetMs;
        pruneNetworkSamples(chartNow);
        const rect = networkCanvas.getBoundingClientRect();
        if (rect.width < 10 || rect.height < 10) return;
        const dpr = Math.max(1, window.devicePixelRatio || 1);
        const width = Math.round(rect.width * dpr);
        const height = Math.round(rect.height * dpr);
        if (networkCanvas.width !== width || networkCanvas.height !== height) {{
          networkCanvas.width = width;
          networkCanvas.height = height;
        }}
        const ctx = networkCanvas.getContext("2d");
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, rect.width, rect.height);

        const pad = {{ left: 58, right: 20, top: 22, bottom: 34 }};
        const plotW = Math.max(1, rect.width - pad.left - pad.right);
        const plotH = Math.max(1, rect.height - pad.top - pad.bottom);
        const maxData = networkSamples.reduce(function(maximum, point) {{ return Math.max(maximum, point.rx, point.tx); }}, 0);

        function scaleTarget(value) {{
          if (!Number.isFinite(value) || value <= 0) return 10;
          const wanted = Math.max(10, value * 1.22);
          if (wanted <= 12) return 12;
          if (wanted <= 15) return 15;
          if (wanted <= 20) return 20;
          if (wanted <= 30) return 30;
          if (wanted <= 40) return 40;
          if (wanted <= 50) return 50;
          if (wanted <= 60) return 60;
          if (wanted <= 75) return 75;
          if (wanted <= 100) return 100;
          const magnitude = Math.pow(10, Math.floor(Math.log10(wanted)));
          const normalized = wanted / magnitude;
          let step = 1;
          if (normalized <= 1.25) step = 1.25;
          else if (normalized <= 1.5) step = 1.5;
          else if (normalized <= 2) step = 2;
          else if (normalized <= 2.5) step = 2.5;
          else if (normalized <= 5) step = 5;
          else step = 10;
          return step * magnitude;
        }}

        const nowMs = performance.now();
        const targetYMax = scaleTarget(maxData);
        const elapsedScaleSeconds = Math.max(0, (nowMs - lastScaleUpdate) / 1000);
        lastScaleUpdate = nowMs;

        // Fast attack, slow release: bursts expand the scale immediately, while
        // the graph returns gradually to its normal range after the burst leaves
        // the four-minute rolling window. This avoids abrupt visual compression.
        if (maxData > displayedYMax * 0.92 || targetYMax > displayedYMax) {{
          displayedYMax = Math.max(displayedYMax, targetYMax);
          scaleHoldUntil = nowMs + 8000;
        }} else if (nowMs > scaleHoldUntil && targetYMax < displayedYMax) {{
          const decay = Math.pow(0.94, elapsedScaleSeconds);
          displayedYMax = Math.max(targetYMax, displayedYMax * decay);
          if (displayedYMax - targetYMax < 0.25) displayedYMax = targetYMax;
        }}

        const yMax = Math.max(10, displayedYMax);
        ctx.font = '12px system-ui, -apple-system, sans-serif';
        ctx.lineWidth = 1;
        ctx.fillStyle = 'rgba(164, 190, 208, 0.72)';
        ctx.textAlign = 'right';
        ctx.textBaseline = 'middle';
        for (let i = 0; i <= 4; i++) {{
          const y = pad.top + plotH * i / 4;
          ctx.strokeStyle = i === 4 ? 'rgba(128, 157, 178, 0.24)' : 'rgba(128, 157, 178, 0.13)';
          ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(pad.left + plotW, y); ctx.stroke();
          const value = yMax * (1 - i / 4);
          const label = value >= 100 ? value.toFixed(0) : (value >= 10 ? value.toFixed(1) : value.toFixed(2));
          ctx.fillText(label, pad.left - 10, y);
        }}
        ctx.save();
        ctx.translate(15, pad.top + plotH / 2);
        ctx.rotate(-Math.PI / 2);
        ctx.textAlign = 'center';
        ctx.fillStyle = 'rgba(164, 190, 208, 0.58)';
        ctx.fillText('Mbps', 0, 0);
        ctx.restore();
        ctx.textAlign = 'left';
        ctx.textBaseline = 'top';
        ctx.fillStyle = 'rgba(164, 190, 208, 0.72)';
        ctx.fillText('-4m', pad.left, pad.top + plotH + 10);
        ctx.textAlign = 'center';
        ctx.fillText('-2m', pad.left + plotW / 2, pad.top + plotH + 10);
        ctx.textAlign = 'right';
        ctx.fillText('Now', pad.left + plotW, pad.top + plotH + 10);

        function pointFor(point, key) {{
          const x = pad.left + plotW * Math.max(0, Math.min(1, (point.time - (chartNow - networkWindowMs)) / networkWindowMs));
          const y = pad.top + plotH * (1 - Math.min(yMax, point[key]) / yMax);
          return {{ x: x, y: y }};
        }}

        function traceSeries(key, stroke, fillTop, fillBottom) {{
          if (!networkSamples.length) return;
          // Never join measurements across a pause in browser sampling.
          const groups = [];
          networkSamples.forEach(function(point, index) {{
            if (!index || point.time - networkSamples[index - 1].time > 2500) groups.push([]);
            groups[groups.length - 1].push(pointFor(point, key));
          }});
          const gradient = ctx.createLinearGradient(0, pad.top, 0, pad.top + plotH);
          gradient.addColorStop(0, fillTop);
          gradient.addColorStop(1, fillBottom);
          groups.forEach(function(points) {{
            ctx.beginPath();
            ctx.moveTo(points[0].x, pad.top + plotH);
            ctx.lineTo(points[0].x, points[0].y);
            for (let i = 1; i < points.length; i++) {{
              const previous = points[i - 1];
              const current = points[i];
              const midX = (previous.x + current.x) / 2;
              ctx.bezierCurveTo(midX, previous.y, midX, current.y, current.x, current.y);
            }}
            ctx.lineTo(points[points.length - 1].x, pad.top + plotH);
            ctx.closePath();
            ctx.fillStyle = gradient;
            ctx.fill();

            ctx.beginPath();
            ctx.moveTo(points[0].x, points[0].y);
            for (let i = 1; i < points.length; i++) {{
              const previous = points[i - 1];
              const current = points[i];
              const midX = (previous.x + current.x) / 2;
              ctx.bezierCurveTo(midX, previous.y, midX, current.y, current.x, current.y);
            }}
            ctx.strokeStyle = stroke;
            ctx.lineWidth = 2.35;
            ctx.lineJoin = 'round';
            ctx.lineCap = 'round';
            ctx.stroke();
          }});

          const lastGroup = groups[groups.length - 1];
          const last = lastGroup[lastGroup.length - 1];
          ctx.beginPath();
          ctx.arc(last.x, last.y, 3.2, 0, Math.PI * 2);
          ctx.fillStyle = stroke;
          ctx.fill();
        }}

        traceSeries('rx', '#e0464c', 'rgba(224, 70, 76, 0.18)', 'rgba(224, 70, 76, 0.015)');
        traceSeries('tx', '#5ee6a8', 'rgba(94, 230, 168, 0.16)', 'rgba(94, 230, 168, 0.012)');
      }}

      document.addEventListener("visibilitychange", function() {{ updateNetworkPolling(); updateDashboardPolling(); }});
      window.addEventListener("resize", function() {{ if (networkTabIsActive()) drawNetworkChart(); }});

      document.querySelectorAll("[data-copy-target]").forEach(function(button) {{
        button.addEventListener("click", async function() {{
          const target = document.getElementById(button.dataset.copyTarget || "");
          if (!target) return;
          const text = target.textContent || "";
          const label = button.querySelector("span:last-child");
          try {{
            await navigator.clipboard.writeText(text);
            if (label) label.textContent = "Copied";
          }} catch (err) {{
            const area = document.createElement("textarea");
            area.value = text;
            area.style.position = "fixed";
            area.style.opacity = "0";
            document.body.appendChild(area);
            area.focus();
            area.select();
            document.execCommand("copy");
            area.remove();
            if (label) label.textContent = "Copied";
          }}
          window.setTimeout(function() {{ if (label) label.textContent = "Copy to Clipboard"; }}, 1400);
        }});
      }});

      tabButtons.forEach(function(button) {{
        button.addEventListener("click", function() {{
          activateTab(button.dataset.tabTarget || "overview");
        }});
      }});

      configButtons.forEach(function(button) {{
        button.addEventListener("click", function() {{ activateConfigTab(button.dataset.configTarget || "core"); }});
      }});

      let initialTab = "overview";
      try {{
        initialTab = window.sessionStorage.getItem(activeTabKey) || "overview";
      }} catch (err) {{}}
      if (!["overview", "configuration", "profiles"].includes(initialTab)) initialTab = "overview";
      activateTab(initialTab);
      let initialConfigTab = "core";
      try {{ initialConfigTab = window.sessionStorage.getItem(activeConfigKey) || "core"; }} catch (err) {{}}
      if (!["core", "extra", "dmz", "domain"].includes(initialConfigTab)) initialConfigTab = "core";
      activateConfigTab(initialConfigTab);

      const extraRuleList = document.getElementById("extra-rule-list");
      const extraRuleTemplate = document.getElementById("extra-rule-template");
      const addExtraRuleButton = document.getElementById("add-extra-rule");

      function refreshExtraRuleTitles() {{
        if (!extraRuleList) {{
          return;
        }}
        extraRuleList.querySelectorAll("[data-extra-rule]").forEach(function(row, index) {{
          const labelInput = row.querySelector('input[name="EXTRA_RULE_LABEL"]');
          const title = row.querySelector(".extra-rule-head strong");
          const label = labelInput ? labelInput.value.trim() : "";
          if (title) {{
            title.textContent = label || "Extra rule " + (index + 1);
          }}
        }});
      }}

      if (addExtraRuleButton && extraRuleList && extraRuleTemplate) {{
        addExtraRuleButton.addEventListener("click", function() {{
          extraRuleList.insertAdjacentHTML("beforeend", extraRuleTemplate.innerHTML.trim());
          refreshExtraRuleTitles();
        }});
      }}

      if (extraRuleList) {{
        extraRuleList.addEventListener("input", refreshExtraRuleTitles);
        extraRuleList.addEventListener("click", function(event) {{
          const clicked = event.target;
          if (!clicked || !clicked.closest) {{
            return;
          }}
          const button = clicked.closest("[data-remove-extra-rule]");
          if (!button) {{
            return;
          }}
          const rows = extraRuleList.querySelectorAll("[data-extra-rule]");
          const row = button.closest("[data-extra-rule]");
          if (!row) {{
            return;
          }}
          if (rows.length <= 1) {{
            row.querySelectorAll("input").forEach(function(input) {{
              input.value = "";
            }});
            const proto = row.querySelector('select[name="EXTRA_RULE_PROTO"]');
            if (proto) {{
              proto.value = "udp";
            }}
          }} else {{
            row.remove();
          }}
          refreshExtraRuleTitles();
        }});
        refreshExtraRuleTitles();
      }}

    }})();
  </script>
</body>
</html>
"""

def run_script(flag: str) -> Tuple[int, str]:
    try:
        proc = subprocess.Popen(
            [SCRIPT_PATH, flag], stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
        try:
            output, _ = proc.communicate(timeout=600)
            return proc.returncode, output
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                output, _ = proc.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                output, _ = proc.communicate()
            return 124, output + "\nOperation timed out. Inspect service status before applying again."
    except OSError as exc:
        return 127, str(exc)


def schedule_restart() -> None:
    subprocess.Popen(
        ["/bin/sh", "-c", "sleep 2; systemctl restart %s >/dev/null 2>&1" % WEBUI_SERVICE_NAME],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def schedule_remove_all() -> None:
    result = subprocess.run(
        ["systemd-run", "--unit=wgvpn-remove-all", "--on-active=10s", "--timer-property=AccuracySec=1s", "--collect", SCRIPT_PATH, "--web-remove"],
        capture_output=True, text=True, timeout=8, check=False,
    )
    if result.returncode != 0:
        raise OSError(result.stderr.strip() or "Could not schedule Remove All.")


def safe_int(value: str) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_port(value: str, label: str, errors: List[str]) -> Optional[int]:
    if not value:
        errors.append(f"{label} is required.")
        return None
    port = safe_int(value)
    if port is None:
        errors.append(f"{label} must be numeric.")
        return None
    if port < 1 or port > 65535:
        errors.append(f"{label} must be between 1 and 65535.")
        return None
    return port


def parse_port_spec(value: str, rule_name: str, errors: List[str]) -> Tuple[Optional[int], Optional[int]]:
    raw = value.strip()
    if not raw:
        errors.append(f"{rule_name}: port is required.")
        return None, None

    normalized = raw.replace(" ", "")
    if "-" in normalized and ":" in normalized:
        errors.append(f"{rule_name}: use either '-' or ':' for a range, not both.")
        return None, None

    separator = "-" if "-" in normalized else ":" if ":" in normalized else ""
    if separator:
        parts = normalized.split(separator)
        if len(parts) != 2 or not parts[0] or not parts[1]:
            errors.append(f"{rule_name}: use a range like 12000-12010.")
            return None, None
        first_text, last_text = parts
    else:
        first_text = normalized
        last_text = normalized

    first = parse_port(first_text, f"{rule_name} port", errors)
    last = parse_port(last_text, f"{rule_name} port", errors)
    if first is not None and last is not None and first > last:
        errors.append(f"{rule_name}: port range start must be less than or equal to the end.")
    return first, last


def add_reservation(
    reservations: Dict[str, List[Tuple[int, int, str]]],
    proto: str,
    first: Optional[int],
    last: Optional[int],
    label: str,
) -> None:
    if first is None or last is None:
        return
    reservations[proto].append((min(first, last), max(first, last), label))


def standard_port_reservations(values: Dict[str, str]) -> Dict[str, List[Tuple[int, int, str]]]:
    reservations: Dict[str, List[Tuple[int, int, str]]] = {"tcp": [], "udp": []}
    add_reservation(reservations, "tcp", 22, 22, "VPS SSH")
    # Include custom SSH ports from the effective sshd configuration.
    try:
        result = subprocess.run(["/usr/sbin/sshd", "-T"], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                if line.startswith("port "):
                    port = safe_int(line.split()[1])
                    if port != 22:
                        add_reservation(reservations, "tcp", port, port, "VPS SSH")
    except (OSError, subprocess.TimeoutExpired):
        pass

    add_reservation(reservations, "udp", safe_int(values.get("WG_PORT", "")), safe_int(values.get("WG_PORT", "")), "WireGuard")
    add_reservation(reservations, "tcp", safe_int(values.get("WEBUI_PORT", "")), safe_int(values.get("WEBUI_PORT", "")), "Web UI")

    for first, last, label in STREAMHUB_TCP_PORTS:
        add_reservation(reservations, "tcp", first, last, label)
    for first, last, label in STREAMHUB_UDP_PORTS:
        add_reservation(reservations, "udp", first, last, label)

    return reservations


def ranges_overlap(first: int, last: int, other_first: int, other_last: int) -> bool:
    return max(first, other_first) <= min(last, other_last)


def collect_extra_rules(
    form: Dict[str, List[str]],
    values: Dict[str, str],
) -> Tuple[List[Dict[str, str]], List[str]]:
    field_names = [
        "EXTRA_RULE_PROTO",
        "EXTRA_RULE_TARGET_IP",
        "EXTRA_RULE_PORT",
        "EXTRA_RULE_TARGET_PORT",
        "EXTRA_RULE_LABEL",
        "EXTRA_RULE_PUBLIC_FROM",
        "EXTRA_RULE_PUBLIC_TO",
    ]
    lists = {name: form.get(name, []) for name in field_names}
    row_count = max((len(items) for items in lists.values()), default=0)
    if row_count > 128:
        return [], ["At most 128 extra forwarding rules are supported."]
    errors: List[str] = []
    rules: List[Dict[str, str]] = []

    lan_network = None
    lan_error = ""
    if row_count:
        try:
            lan_network = ipaddress.ip_network(values.get("LAN_CIDR", ""), strict=False)
            if lan_network.version != 4:
                lan_error = "LAN_CIDR must be an IPv4 CIDR before using extra rules."
        except ValueError:
            lan_error = "LAN_CIDR must be a valid IPv4 CIDR before using extra rules."

    def at(name: str, index: int) -> str:
        items = lists[name]
        return items[index].strip() if index < len(items) else ""

    for index in range(row_count):
        proto = at("EXTRA_RULE_PROTO", index).lower() or "udp"
        target_ip_text = at("EXTRA_RULE_TARGET_IP", index)
        port_spec_text = at("EXTRA_RULE_PORT", index)
        label = " ".join(at("EXTRA_RULE_LABEL", index).split())

        if not port_spec_text:
            old_public_from = at("EXTRA_RULE_PUBLIC_FROM", index)
            old_public_to = at("EXTRA_RULE_PUBLIC_TO", index)
            if old_public_from and old_public_to and old_public_from != old_public_to:
                port_spec_text = f"{old_public_from}-{old_public_to}"
            else:
                port_spec_text = old_public_from or old_public_to

        if not any([port_spec_text, target_ip_text, label, at("EXTRA_RULE_TARGET_PORT", index)]):
            continue

        rule_name = label or f"Extra rule {index + 1}"
        row_errors: List[str] = []

        if proto not in ("tcp", "udp"):
            row_errors.append(f"{rule_name}: protocol must be TCP or UDP.")

        public_from, public_to = parse_port_spec(port_spec_text, rule_name, row_errors)
        target_spec = at("EXTRA_RULE_TARGET_PORT", index) or port_spec_text
        target_from, target_to = parse_port_spec(target_spec, rule_name + " local", row_errors)
        if all(port is not None for port in (public_from, public_to, target_from, target_to)):
            if public_to - public_from != target_to - target_from:
                row_errors.append(f"{rule_name}: public and local ranges must contain the same number of ports.")

        target_ip = None
        if not target_ip_text:
            row_errors.append(f"{rule_name}: IP address is required.")
        else:
            try:
                target_ip = ipaddress.ip_address(target_ip_text)
                if target_ip.version != 4:
                    row_errors.append(f"{rule_name}: IP address must be IPv4.")
                elif lan_error:
                    row_errors.append(lan_error)
                elif lan_network is not None and (target_ip not in lan_network or target_ip in (lan_network.network_address, lan_network.broadcast_address)):
                    row_errors.append(f"{rule_name}: IP address must be inside LAN CIDR {values.get('LAN_CIDR', '')}.")
            except ValueError:
                row_errors.append(f"{rule_name}: IP address must be a valid IPv4 address.")

        if len(label) > 64:
            row_errors.append(f"{rule_name} label must be 64 characters or less.")
        if any(char in label for char in "|;\r\n"):
            row_errors.append(f"{rule_name}: label cannot contain semicolons or pipes.")

        if row_errors:
            errors.extend(row_errors)
            continue

        rules.append({
            "proto": proto,
            "public_from": str(public_from),
            "public_to": str(public_to),
            "target_ip": str(target_ip),
            "target_from": str(target_from),
            "target_to": str(target_to),
            "label": label,
        })

    reservations = standard_port_reservations(values)
    for index, rule in enumerate(rules):
        proto = rule["proto"]
        public_from = int(rule["public_from"])
        public_to = int(rule["public_to"])
        rule_name = rule.get("label") or f"Extra rule {index + 1}"
        for reserved_from, reserved_to, reserved_label in reservations[proto]:
            if ranges_overlap(public_from, public_to, reserved_from, reserved_to):
                errors.append(
                    f'{rule_name} overlaps {reserved_label}: {proto.upper()} '
                    f'{range_text(str(public_from), str(public_to))} conflicts with '
                    f'{range_text(str(reserved_from), str(reserved_to))}.'
                )
        for other_index, other in enumerate(rules[:index]):
            if proto != other["proto"]:
                continue
            other_from = int(other["public_from"])
            other_to = int(other["public_to"])
            if ranges_overlap(public_from, public_to, other_from, other_to):
                other_name = other.get("label") or f"Extra rule {other_index + 1}"
                errors.append(
                    f'{rule_name} overlaps {other_name}: {proto.upper()} '
                    f'{range_text(str(public_from), str(public_to))} conflicts with '
                    f'{range_text(str(other_from), str(other_to))}.'
                )

    return rules, errors


def apply_form_values(form: Dict[str, List[str]], current: Dict[str, str]) -> Tuple[Dict[str, str], List[str], str]:
    values = {
        "LAN_CIDR": form.get("LAN_CIDR", [current["LAN_CIDR"]])[0].strip(),
        "ROUTER_LAN_IP": form.get("ROUTER_LAN_IP", [current["ROUTER_LAN_IP"]])[0].strip(),
        "STREAMHUB_IP": form.get("STREAMHUB_IP", [current["STREAMHUB_IP"]])[0].strip(),
        "WG_PORT": form.get("WG_PORT", [current["WG_PORT"]])[0].strip(),
        "WG_TUN_CIDR": form.get("WG_TUN_CIDR", [current["WG_TUN_CIDR"]])[0].strip(),
        "WG_VPS_IP": form.get("WG_VPS_IP", [current["WG_VPS_IP"]])[0].strip(),
        "WG_GL_IP": form.get("WG_GL_IP", [current["WG_GL_IP"]])[0].strip(),
        "REMOTE_CLIENT_IP": form.get("REMOTE_CLIENT_IP", [current["REMOTE_CLIENT_IP"]])[0].strip(),
        "PUB_IFACE": form.get("PUB_IFACE", [current["PUB_IFACE"]])[0].strip(),
        "PUB_IP": form.get("PUB_IP", [current["PUB_IP"]])[0].strip(),
        "WEBUI_PORT": form.get("WEBUI_PORT", [current["WEBUI_PORT"]])[0].strip(),
        "WEBUI_USER": form.get("WEBUI_USER", [current["WEBUI_USER"]])[0].strip(),
        "WEBUI_ENABLED": "Y",
        "WEBUI_BIND": current.get("WEBUI_BIND", "0.0.0.0"),
        "EXTRA_PF_RULES": current.get("EXTRA_PF_RULES", ""),
        "DMZ_IP": form.get("DMZ_IP", [current.get("DMZ_IP", "")])[0].strip(),
        "PUBLIC_DOMAIN": current.get("PUBLIC_DOMAIN", ""),
        "UFW_WAS_ACTIVE": current.get("UFW_WAS_ACTIVE", "N"),
    }
    password = form.get("WEBUI_PASSWORD", [""])[0]
    confirm = form.get("WEBUI_PASSWORD_CONFIRM", [""])[0]
    current_password = form.get("WEBUI_CURRENT_PASSWORD", [""])[0]
    errors: List[str] = []
    if values["PUBLIC_DOMAIN"]:
        try:
            values["PUBLIC_DOMAIN"] = validate_public_domain(values["PUBLIC_DOMAIN"])
        except ValueError as exc:
            errors.append(str(exc))
    networks = {}
    for key in ("LAN_CIDR", "WG_TUN_CIDR"):
        try:
            networks[key] = ipaddress.IPv4Network(values[key], strict=True)
        except ValueError:
            errors.append(f"{key} must be a canonical IPv4 network, for example 192.168.10.0/24.")
    if len(networks) == 2 and networks["LAN_CIDR"].overlaps(networks["WG_TUN_CIDR"]):
        errors.append("LAN and WireGuard networks must not overlap.")
    if values["DMZ_IP"]:
        try:
            dmz_address = ipaddress.IPv4Address(values["DMZ_IP"])
            lan = networks.get("LAN_CIDR")
            if lan is None or dmz_address not in lan or dmz_address in (lan.network_address, lan.broadcast_address):
                errors.append("DMZ IP must be a usable host inside the site LAN.")
            elif values["DMZ_IP"] == values["ROUTER_LAN_IP"]:
                errors.append("DMZ IP cannot be the router LAN address.")
        except ValueError:
            errors.append("DMZ IP must be an IPv4 address, or left empty to disable DMZ.")
    for key in ("ROUTER_LAN_IP", "STREAMHUB_IP", "WG_VPS_IP", "WG_GL_IP", "REMOTE_CLIENT_IP", "PUB_IP"):
        try:
            address = ipaddress.IPv4Address(values[key])
            network = networks.get("WG_TUN_CIDR" if key in {"WG_VPS_IP", "WG_GL_IP", "REMOTE_CLIENT_IP"} else "LAN_CIDR")
            if key != "PUB_IP" and network is not None:
                if address not in network or address in (network.network_address, network.broadcast_address):
                    errors.append(f"{key} must be a usable host inside {network}.")
            if address.is_multicast or address.is_unspecified or address.is_loopback:
                errors.append(f"{key} is not a usable endpoint.")
        except ValueError:
            errors.append(f"{key} must be an IPv4 address.")
    wg_hosts = [values["WG_VPS_IP"], values["WG_GL_IP"], values["REMOTE_CLIENT_IP"]]
    if len(set(wg_hosts)) != len(wg_hosts):
        errors.append("VPS, WireGuard Router and Remote VPN Client WireGuard addresses must all be different.")
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", values["PUB_IFACE"]):
        errors.append("Public interface name is invalid.")
    parse_port(values["WG_PORT"], "WireGuard UDP port", errors)
    for key, value in values.items():
        if any(char in value for char in "\r\n\x00"):
            errors.append(f"{key} contains invalid control characters.")
    reservations = standard_port_reservations(values)
    adjustable = {"WireGuard", "Web UI"}
    for proto, entries in reservations.items():
        for index, (first, last, label) in enumerate(entries):
            for other_first, other_last, other_label in entries[:index]:
                if (label in adjustable or other_label in adjustable) and ranges_overlap(first, last, other_first, other_last):
                    errors.append(f"{proto.upper()} port conflict: {label} and {other_label}.")

    for key in [
        "LAN_CIDR",
        "ROUTER_LAN_IP",
            "STREAMHUB_IP",
                    "WG_PORT",
        "WG_TUN_CIDR",
        "WG_VPS_IP",
        "WG_GL_IP",
        "REMOTE_CLIENT_IP",
                        "PUB_IFACE",
        "PUB_IP",
        "WEBUI_USER",
        "WEBUI_PORT",
    ]:
        if not values[key]:
            errors.append(f"{key} cannot be empty.")

    if values["WEBUI_USER"] and not USERNAME_RE.fullmatch(values["WEBUI_USER"]):
        errors.append("Web UI username can only contain letters, numbers, dot, underscore or dash.")

    if values["WEBUI_PORT"]:
        try:
            port = int(values["WEBUI_PORT"])
            if port < 1024 or port > 65535:
                errors.append("Web UI port must be between 1024 and 65535.")
        except ValueError:
            errors.append("Web UI port must be numeric.")

    if password or confirm:
        if password != confirm:
            errors.append("Web UI passwords do not match.")
        elif len(password) < 10:
            errors.append("New Web UI passwords must be at least 10 characters.")

    if password or values["WEBUI_USER"] != current.get("WEBUI_USER", ""):
        if not verify_credentials(current.get("WEBUI_USER", ""), current_password):
            errors.append("The current Web UI password is required to change login credentials.")

    extra_rules, extra_errors = collect_extra_rules(form, values)
    errors.extend(extra_errors)
    values["EXTRA_PF_RULES"] = encode_extra_rules(extra_rules)

    return values, errors, password


def _ping_target(ip: str) -> Tuple[bool, Optional[float]]:
    start = time.monotonic()
    try:
        result = subprocess.run(
            ["ping", "-n", "-c", "1", "-W", "1", ip],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1.5,
            check=False,
        )
        if result.returncode == 0:
            return True, round((time.monotonic() - start) * 1000, 1)
    except (OSError, subprocess.SubprocessError):
        pass
    return False, None


def _tcp_target(ip: str, port: int) -> bool:
    try:
        with socket.create_connection((ip, port), timeout=0.8):
            return True
    except (OSError, TimeoutError):
        return False


def _probe_device(name: str, ip: str, ports: List[Tuple[int, str]]) -> Dict[str, object]:
    ping_online, latency = _ping_target(ip)
    services = [
        {"port": port, "label": label, "online": _tcp_target(ip, port)}
        for port, label in ports
    ]
    service_online = any(bool(service["online"]) for service in services)
    if ping_online:
        status = "online"
    elif service_online:
        status = "service_online"
    elif ping_online:
        status = "reachable"
    else:
        status = "offline"
    return {
        "name": name,
        "ip": ip,
        "configured": True,
        "online": ping_online or service_online,
        "ping_online": ping_online,
        "service_online": service_online,
        "status": status,
        "latency_ms": latency,
        "services": services,
    }


def dashboard_status(state: Optional[Dict[str, str]]) -> Dict[str, object]:
    if state is None:
        return {
            "timestamp": int(time.time() * 1000), "applied": False,
            "peers": [
                {"name":"WireGuard Router","kind":"router","ip":"","configured":False,"online":False,"handshake_age":None,"endpoint":"","rx_bytes":0,"tx_bytes":0},
                {"name":"Remote VPN Client","kind":"remote","ip":"","configured":False,"online":False,"handshake_age":None,"endpoint":"","rx_bytes":0,"tx_bytes":0},
            ],
            "devices": [
                {"name":name,"ip":"","configured":False,"online":False,"ping_online":False,"service_online":False,"status":"not_configured","latency_ms":None,"services":[]}
                for name in ("StreamHub",)
            ],
        }
    now = int(time.time())
    peers: List[Dict[str, object]] = []
    peer_specs = [
        ("WireGuard Router", state.get("WG_GL_IP", DEFAULTS["WG_GL_IP"]), "router"),
        ("Remote VPN Client", state.get("REMOTE_CLIENT_IP", DEFAULTS["REMOTE_CLIENT_IP"]), "remote"),
    ]
    wg_rows: List[List[str]] = []
    try:
        dump = subprocess.run(
            ["wg", "show", "wg0", "dump"],
            capture_output=True,
            text=True,
            timeout=1.5,
            check=False,
        )
        if dump.returncode == 0:
            wg_rows = [line.split("\t") for line in dump.stdout.splitlines()[1:] if line.strip()]
    except (OSError, subprocess.SubprocessError):
        wg_rows = []

    for label, peer_ip, kind in peer_specs:
        cidr = peer_ip + "/32"
        match = None
        for row in wg_rows:
            if len(row) >= 8 and cidr in [item.strip() for item in row[3].split(",")]:
                match = row
                break
        configured = match is not None
        handshake = 0
        rx_bytes = 0
        tx_bytes = 0
        endpoint = ""
        if match is not None:
            endpoint = "" if match[2] == "(none)" else match[2]
            try: handshake = int(match[4])
            except ValueError: handshake = 0
            try: rx_bytes = int(match[5])
            except ValueError: rx_bytes = 0
            try: tx_bytes = int(match[6])
            except ValueError: tx_bytes = 0
        age = (now - handshake) if handshake > 0 else None
        if configured:
            online, _ = _ping_target(peer_ip)
        else:
            online = False
        peers.append({
            "name": label,
            "kind": kind,
            "ip": peer_ip,
            "configured": configured,
            "online": online,
            "handshake_age": age,
            "endpoint": endpoint,
            "rx_bytes": rx_bytes,
            "tx_bytes": tx_bytes,
        })

    device_specs: List[Tuple[str, str, List[Tuple[int, str]]]] = [
        ("StreamHub", state.get("STREAMHUB_IP", ""), [(443, "HTTPS"), (8444, "Alt HTTPS")]),
    ]
    devices: List[Dict[str, object]] = []
    valid_specs = [(name, ip, ports) for name, ip, ports in device_specs if ip]
    if valid_specs:
        with ThreadPoolExecutor(max_workers=min(6, len(valid_specs))) as pool:
            futures = [pool.submit(_probe_device, name, ip, ports) for name, ip, ports in valid_specs]
            for index, future in enumerate(futures):
                name, ip, ports = valid_specs[index]
                try:
                    devices.append(future.result(timeout=5.0))
                except Exception:
                    devices.append({
                        "name": name, "ip": ip, "configured": True, "online": False,
                        "ping_online": False, "service_online": False, "status": "offline",
                        "latency_ms": None,
                        "services": [{"port": port, "label": label, "online": False} for port, label in ports],
                    })

    return {"timestamp": int(time.time() * 1000), "applied": True, "peers": peers, "devices": devices}


def device_traffic_counters() -> Dict[str, Dict[str, int]]:
    counters: Dict[str, Dict[str, int]] = {}
    try:
        result = subprocess.run(
            ["iptables-save", "-c", "-t", "filter"],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
        if result.returncode != 0:
            return counters
        pattern = re.compile(
            r'^\[(\d+):(\d+)\] -A WGVPN_STATS .*--comment "?(rx|tx):([a-z0-9_-]+)"?'
        )
        for line in result.stdout.splitlines():
            match = pattern.search(line)
            if not match:
                continue
            direction, device = match.group(3), match.group(4)
            counters.setdefault(device, {"rx_bytes": 0, "tx_bytes": 0})
            counters[device][direction + "_bytes"] += int(match.group(2))
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}
    return counters


def sample_network_history() -> None:
    """Keep only four minutes of traffic rates while a Web UI session exists."""
    stats_dir = Path("/sys/class/net/wg0/statistics")
    previous = None
    while True:
        started = time.monotonic()
        prune_sessions()
        if not SESSIONS:
            previous = None
            with NETWORK_HISTORY_LOCK:
                NETWORK_HISTORY.clear()
        else:
            try:
                rx_bytes = int((stats_dir / "rx_bytes").read_text(encoding="ascii").strip())
                tx_bytes = int((stats_dir / "tx_bytes").read_text(encoding="ascii").strip())
                devices = device_traffic_counters()
                now = int(time.time() * 1000)
                current = (time.monotonic(), rx_bytes, tx_bytes, devices)
                if previous:
                    elapsed = current[0] - previous[0]
                    if 0 < elapsed <= 3 and rx_bytes >= previous[1] and tx_bytes >= previous[2]:
                        # The Web UI displays traffic from the site LAN side of wg0.
                        rx = (tx_bytes - previous[2]) * 8 / elapsed / 1000000
                        tx = (rx_bytes - previous[1]) * 8 / elapsed / 1000000
                        rates = {}
                        for name in ("router", "streamhub"):
                            current_device = devices.get(name, {})
                            previous_device = previous[3].get(name, {})
                            rates[name] = {
                                "rx": max(0, current_device.get("tx_bytes", 0) - previous_device.get("tx_bytes", 0)) * 8 / elapsed / 1000000,
                                "tx": max(0, current_device.get("rx_bytes", 0) - previous_device.get("rx_bytes", 0)) * 8 / elapsed / 1000000,
                            }
                        rates["other"] = {
                            "rx": max(0, rx - sum(item["rx"] for item in rates.values())),
                            "tx": max(0, tx - sum(item["tx"] for item in rates.values())),
                        }
                        if SESSIONS:
                            with NETWORK_HISTORY_LOCK:
                                NETWORK_HISTORY.append({"time": now, "rx": rx, "tx": tx, "devices": rates})
                                while NETWORK_HISTORY and NETWORK_HISTORY[0]["time"] < now - NETWORK_WINDOW_MS:
                                    NETWORK_HISTORY.popleft()
                previous = current
            except (OSError, ValueError):
                previous = None
                with NETWORK_HISTORY_LOCK:
                    NETWORK_HISTORY.clear()
        time.sleep(max(0.1, 1 - (time.monotonic() - started)))


def network_history_for_session(session_id: str, now: int) -> Dict[str, object]:
    session = SESSIONS.get(session_id)
    if session is None:
        return {"timestamp": now, "samples": [], "latest": None}
    cutoff = max(now - NETWORK_WINDOW_MS, int(session["started_ms"]))
    with NETWORK_HISTORY_LOCK:
        samples = [
            {"time": item["time"], "rx": item["rx"], "tx": item["tx"]}
            for item in NETWORK_HISTORY if item["time"] >= cutoff
        ]
        latest = NETWORK_HISTORY[-1] if NETWORK_HISTORY else None
    return {
        "timestamp": now,
        "samples": samples,
        "latest": latest if latest and latest["time"] >= max(cutoff, now - 3000) else None,
    }


REQUEST_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "WireGuardVPN-WebUI/1.0"

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def send_html(
        self,
        content: str,
        status: int = 200,
        extra_headers: Optional[List[Tuple[str, str]]] = None,
    ) -> None:
        encoded = content.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        if extra_headers:
            for header, value in extra_headers:
                self.send_header(header, value)
        self.end_headers()
        self.wfile.write(encoded)

    def send_json(self, payload: Dict[str, object], status: int = 200) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(encoded)

    def send_png(self, data: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def send_profile_qr(self, kind: str) -> None:
        profile = ROUTER_CONF_OUT if kind == "router" else REMOTE_CLIENT_CONF_OUT
        if applied_state() is None or not Path(profile).is_file():
            self.send_error(404, "WireGuard profile has not been generated.")
            return
        try:
            qr = subprocess.run(["qrencode", "-t", "PNG", "-o", "-"],
                                input=Path(profile).read_bytes(), capture_output=True,
                                timeout=3, check=False)
            if qr.returncode == 0:
                self.send_png(qr.stdout)
            else:
                self.send_error(503, "QR generator unavailable; download the .conf profile.")
        except (OSError, subprocess.SubprocessError):
            self.send_error(503, "QR generator unavailable; download the .conf profile.")

    def send_download(self, data: bytes, filename: str, content_type: str = "application/octet-stream") -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def send_redirect(
        self,
        location: str,
        extra_headers: Optional[List[Tuple[str, str]]] = None,
    ) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        if extra_headers:
            for header, value in extra_headers:
                self.send_header(header, value)
        self.end_headers()

    def session_cookie(self, session_id: str) -> str:
        return f"{SESSION_COOKIE_NAME}={session_id}; Path=/; HttpOnly; Secure; SameSite=Strict"

    def clear_session_cookie(self) -> str:
        return f"{SESSION_COOKIE_NAME}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0"

    def current_session_id(self) -> Optional[str]:
        return get_active_session_id(self.headers.get("Cookie"))

    def split_path(self) -> Tuple[str, Dict[str, List[str]]]:
        if "?" not in self.path:
            return self.path, {}
        path, query_string = self.path.split("?", 1)
        return path, parse_qs(query_string, keep_blank_values=True)

    def do_GET(self) -> None:
        path, query = self.split_path()
        session_id = self.current_session_id()

        if path == "/login":
            if "logged_out" in query:
                message = "Logged out."
            elif "reauth" in query:
                message = "Session closed. Login required."
            elif "password_changed" in query:
                message = "Password changed. Sign in with the new password."
            elif "credentials_changed" in query:
                message = "Login credentials updated. Sign in again."
            else:
                message = ""
            self.send_html(render_login_page(message))
            return
        if path == "/change-password":
            if not session_id:
                self.send_redirect("/login")
            elif password_change_required():
                self.send_html(render_change_password_page())
            else:
                self.send_redirect("/")
            return
        if path == "/":
            if not session_id:
                self.send_redirect("/login")
                return
            if password_change_required():
                self.send_redirect("/change-password")
                return
            if wizard_pending():
                self.send_redirect("/wizard")
                return
            flash = pop_session_flash(session_id)
            flash_state = flash.get("state")
            page_state = flash_state if isinstance(flash_state, dict) else merged_state()
            self.send_html(render_page(
                page_state,
                str(flash.get("message", "")),
                str(flash.get("output", "")),
                str(flash.get("level", "info")),
            ))
            return
        if not session_id:
            self.send_redirect("/login")
            return
        if password_change_required():
            self.send_redirect("/change-password")
            return
        if wizard_pending():
            if path == "/wizard":
                step = query.get("step", ["network"])[0]
                flash = pop_session_flash(session_id)
                self.send_html(render_wizard(step, str(flash.get("message", "")), str(flash.get("level", "error"))))
                return
            if path == "/api/wizard-connection":
                online, message = wizard_router_online()
                self.send_json({"connected": online, "message": message})
                return
            if path in ("/wizard/router-qr", "/wizard/client-qr"):
                self.send_profile_qr("router" if path.endswith("router-qr") else "client")
                return
            if path in ("/download-router-config", "/download-remote-client") and applied_state() is not None:
                profile = ROUTER_CONF_OUT if path.endswith("router-config") else REMOTE_CLIENT_CONF_OUT
                if not Path(profile).is_file():
                    self.send_error(404, "WireGuard profile has not been generated.")
                    return
                name = "wgvpn_router_wg.conf" if path.endswith("router-config") else "wgvpn_remote_client_wg.conf"
                self.send_download(Path(profile).read_bytes(), name)
                return
            self.send_redirect("/wizard")
            return
        if path == "/api/dashboard-status":
            self.send_json(dashboard_status(applied_state()))
            return
        if path == "/api/network-history":
            now = int(time.time() * 1000)
            self.send_json({
                "available": Path("/sys/class/net/wg0/statistics/rx_bytes").exists(),
                **network_history_for_session(session_id, now),
            })
            return
        if path == "/api/network-stats":
            stats_dir = Path("/sys/class/net/wg0/statistics")
            try:
                rx_bytes = int((stats_dir / "rx_bytes").read_text(encoding="ascii").strip())
                tx_bytes = int((stats_dir / "tx_bytes").read_text(encoding="ascii").strip())
                self.send_json({
                    "available": True,
                    "timestamp": int(time.time() * 1000),
                    "rx_bytes": rx_bytes,
                    "tx_bytes": tx_bytes,
                    "devices": device_traffic_counters(),
                })
            except (OSError, ValueError):
                self.send_json({"available": False, "timestamp": int(time.time() * 1000), "rx_bytes": 0, "tx_bytes": 0, "devices": {}})
            return
        if path in ("/profile-qr/router", "/profile-qr/client"):
            self.send_profile_qr(path.rsplit("/", 1)[-1])
            return
        if path == "/download-support-bundle":
            bundle = build_support_bundle()
            stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
            self.send_download(
                bundle,
                f"wgvpn-support-v{SCRIPT_VERSION}-{stamp}.tar.gz",
                "application/gzip",
            )
            return
        if path == "/download-router-config":
            conf_path = Path(ROUTER_CONF_OUT)
            if not conf_path.exists():
                self.send_html(render_page(merged_state(), "Router config has not been generated yet.", "", "error"), 404)
                return
            data = conf_path.read_bytes()
            self.send_download(data, "wireguard_vpn_router.conf")
            return
        if path == "/download-remote-client":
            conf_path = Path(REMOTE_CLIENT_CONF_OUT)
            if not conf_path.exists():
                self.send_html(render_page(merged_state(), "Remote VPN client has not been created yet.", "", "error"), 404)
                return
            data = conf_path.read_bytes()
            self.send_download(data, "wgvpn_remote_client_wg.conf")
            return
        if path != "/":
            self.send_html(render_page(merged_state(), "Page not found.", "", "error"), 404)
            return

    def do_POST(self) -> None:
        if not REQUEST_LOCK.acquire(blocking=False):
            self.send_error(503, "Another operation is running. Retry shortly.")
            return
        try:
            self.handle_post()
        except (OSError, ValueError, subprocess.SubprocessError):
            self.send_error(500, "Operation failed. Check the service journal.")
        finally:
            REQUEST_LOCK.release()

    def handle_post(self) -> None:
        path, _ = self.split_path()
        origin = self.headers.get("Origin")
        if self.headers.get("Sec-Fetch-Site") == "cross-site" or (origin and origin != "https://" + self.headers.get("Host", "")):
            self.send_error(403, "Cross-origin request rejected.")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if self.headers.get("Transfer-Encoding") or not 0 <= length <= 65536:
                self.send_error(413, "Invalid or oversized request.")
                return
            payload = self.rfile.read(length).decode("utf-8")
            form = parse_qs(payload, keep_blank_values=True, max_num_fields=2048)
        except (ValueError, UnicodeError):
            self.send_error(400, "Invalid form data.")
            return

        if path == "/login":
            username = form.get("username", [""])[0].strip()
            password = form.get("password", [""])[0]
            if verify_credentials(username, password):
                session_id = create_session(username)
                self.send_html(
                    render_login_bootstrap(),
                    extra_headers=[("Set-Cookie", self.session_cookie(session_id))],
                )
                return
            self.send_html(render_login_page("Invalid username or password.", username), 401)
            return

        if path == "/logout":
            destroy_session(get_session_id_from_cookie(self.headers.get("Cookie")))
            self.send_html(
                render_logout_bootstrap(),
                extra_headers=[("Set-Cookie", self.clear_session_cookie())],
            )
            return

        session_id = self.current_session_id()
        if not session_id:
            self.send_redirect(
                "/login?reauth=1",
                extra_headers=[("Set-Cookie", self.clear_session_cookie())],
            )
            return

        if path == "/change-password":
            if not password_change_required():
                self.send_redirect("/")
                return
            password = form.get("password", [""])[0]
            confirm = form.get("confirm", [""])[0]
            if password != confirm:
                self.send_html(render_change_password_page("Passwords do not match.", "error"), 400)
                return
            if len(password) < 10:
                self.send_html(render_change_password_page("Password must contain at least 10 characters.", "error"), 400)
                return
            user = merged_state().get("WEBUI_USER", "admin")
            write_auth(user, password, False)
            SESSIONS.clear()
            new_session = create_session(user)
            self.send_redirect(
                "/wizard" if wizard_pending() else "/",
                extra_headers=[("Set-Cookie", self.session_cookie(new_session))],
            )
            return

        if password_change_required():
            self.send_redirect("/change-password")
            return

        if wizard_pending():
            if path == "/wizard/network":
                current = merged_state()
                try:
                    router_ip = form.get("router_ip", [""])[0].strip()
                    prefix = int(form.get("prefix", [""])[0])
                    values = wizard_network_values(router_ip, prefix, current)
                    validated, errors, _ = apply_form_values(
                        {key: [value] for key, value in values.items() if key in STATE_KEYS}, current)
                    if errors:
                        raise ValueError("\n".join(errors))
                    previously = applied_state()
                    if (previously is None or any(previously.get(key) != validated.get(key)
                                                  for key in ("LAN_CIDR", "ROUTER_LAN_IP", "STREAMHUB_IP"))
                            or not Path(ROUTER_CONF_OUT).is_file()):
                        write_state(validated)
                        rc, output = run_script("--web-apply")
                        if rc != 0:
                            write_state(current)
                            detail = next((line.strip() for line in reversed(output.splitlines()) if line.strip()), "Check the VPS service journal.")
                            raise ValueError("Apply and persistence failed. Previous settings restored. " + detail)
                    if not Path(REMOTE_CLIENT_CONF_OUT).is_file():
                        rc, output = run_script("--create-remote-client")
                        if rc != 0:
                            detail = next((line.strip() for line in reversed(output.splitlines()) if line.strip()), "Check the VPS service journal.")
                            raise ValueError("Router profile is ready, but the Remote VPN Client could not be created: " + detail)
                    self.send_redirect("/wizard?step=profile")
                except ValueError as exc:
                    set_session_flash(session_id, str(exc), "", "error")
                    self.send_redirect("/wizard")
                return
            if path == "/wizard/finish":
                if not Path(ROUTER_CONF_OUT).is_file() or not Path(REMOTE_CLIENT_CONF_OUT).is_file():
                    set_session_flash(session_id, "Generate both VPN profiles before completing setup.", "", "error")
                    self.send_redirect("/wizard")
                    return
                online, message = wizard_router_online()
                if not online:
                    set_session_flash(session_id, message, "", "error")
                    self.send_redirect("/wizard?step=verify")
                    return
                Path(WIZARD_PENDING_FILE).unlink()
                self.send_redirect("/")
                return
            self.send_redirect("/wizard")
            return

        if path == "/remove-all":
            if form.get("confirmation", [""])[0] != "REMOVE":
                set_session_flash(session_id, "Type REMOVE to confirm deletion.", "", "error")
                self.send_redirect("/")
                return
            try:
                schedule_remove_all()
            except (OSError, subprocess.SubprocessError) as exc:
                set_session_flash(session_id, "Remove All could not be scheduled: " + str(exc), "", "error")
                self.send_redirect("/")
                return
            SESSIONS.clear()
            self.send_html(render_remove_pending(), extra_headers=[("Set-Cookie", self.clear_session_cookie())])
            return

        if path == "/public-domain":
            operation = form.get("operation", [""])[0]
            try:
                if operation == "add":
                    domain = validate_public_domain(form.get("domain", [""])[0])
                elif operation == "remove":
                    domain = ""
                else:
                    raise ValueError("Choose Add or Remove.")
                write_state({"PUBLIC_DOMAIN": domain})
                set_session_flash(session_id, "Public Services links now use " + (domain or "the VPS public IP") + ".", "", "ok")
            except (ValueError, OSError) as exc:
                set_session_flash(session_id, str(exc), "", "error")
            self.send_redirect("/")
            return

        if path == "/apply":
            current = merged_state()
            values, errors, password = apply_form_values(form, current)
            if errors:
                message = "Configuration not applied. Fix the following fields:\n" + "\n".join(
                    "%d. %s" % (index, error) for index, error in enumerate(errors, 1)
                )
                set_session_flash(session_id, message, "", "error", values)
                self.send_redirect("/")
                return

            try:
                write_state(values)
            except Exception as exc:
                set_session_flash(session_id, "Failed to write configuration: %s" % exc, "", "error", values)
                self.send_redirect("/")
                return

            rc, output = run_script("--web-apply")
            credentials_changed = bool(password or values["WEBUI_USER"] != current.get("WEBUI_USER", ""))
            if rc == 0 and credentials_changed:
                write_auth(values["WEBUI_USER"], password or None)
                SESSIONS.clear()
            if rc != 0:
                write_state(current)
            message = "Apply + Make Persistent completed."
            level = "ok" if rc == 0 else "error"

            if rc == 0 and values["WEBUI_PORT"] != current.get("WEBUI_PORT", DEFAULTS["WEBUI_PORT"]):
                schedule_restart()
                message += " Web UI restart scheduled on https://%s:%s." % (
                    values["PUB_IP"] or "SERVER_IP",
                    values["WEBUI_PORT"],
                )

            if rc != 0:
                detail = next((line.strip() for line in reversed(output.splitlines()) if line.strip()), "No diagnostic detail was returned.")
                message = "Apply failed and the previous configuration was restored.\nReason: " + detail
            if rc == 0 and credentials_changed:
                self.send_redirect(
                    "/login?credentials_changed=1",
                    extra_headers=[("Set-Cookie", self.clear_session_cookie())],
                )
                return
            set_session_flash(session_id, message, output, level)
            self.send_redirect("/")
            return

        if path == "/test":
            rc, output = run_script("--web-test")
            message = "Test completed." if rc == 0 else "Test returned errors."
            level = "ok" if rc == 0 else "error"
            set_session_flash(session_id, message, output, level)
            self.send_redirect("/")
            return

        if path == "/health":
            rc, output = run_script("--health")
            if rc == 0:
                message = "System Health: HEALTHY."
                level = "ok"
            elif rc == 1:
                message = "System Health: WARNING."
                level = "info"
            else:
                message = "System Health: ERROR."
                level = "error"
            set_session_flash(session_id, message, output, level)
            self.send_redirect("/")
            return

        if path == "/create-remote-client":
            rc, output = run_script("--create-remote-client")
            message = "Remote VPN client created. Download the .conf and import it in WireGuard." if rc == 0 else "Remote VPN client creation failed."
            level = "ok" if rc == 0 else "error"
            set_session_flash(session_id, message, output, level)
            self.send_redirect("/")
            return

        set_session_flash(session_id, "Unsupported action.", "", "error")
        self.send_redirect("/")


class ThreadingTLSServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def __init__(self, server_address: Tuple[str, int], handler_class, context: ssl.SSLContext) -> None:
        self.ssl_context = context
        super().__init__(server_address, handler_class)

    def get_request(self):
        raw_socket, address = self.socket.accept()
        raw_socket.settimeout(15)
        tls_socket = self.ssl_context.wrap_socket(
            raw_socket,
            server_side=True,
            do_handshake_on_connect=False,
        )
        tls_socket.settimeout(30)
        return tls_socket, address

    def handle_error(self, request, client_address) -> None:
        exc_type, _, _ = sys.exc_info()
        if exc_type in (BrokenPipeError, ConnectionResetError, TimeoutError, ssl.SSLError):
            return
        super().handle_error(request, client_address)


def main() -> None:
    state = merged_state()
    host = state.get("WEBUI_BIND", "0.0.0.0")
    port = int(state.get("WEBUI_PORT", "65000"))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
    server = ThreadingTLSServer((host, port), Handler, context)
    threading.Thread(target=sample_network_history, name="wgvpn-network-sampler", daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
  chmod 700 "${WEBUI_APP}"
  ok "Wrote ${WEBUI_APP}"
}

write_webui_service() {
  local python_bin
  python_bin="$(command -v python3)"
  cat > "${WEBUI_SERVICE_FILE}" <<EOF
[Unit]
Description=WireGuard VPN Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${SCRIPT_INSTALL_PATH} --ensure-webui-input
ExecStart=${python_bin} ${WEBUI_APP}
WorkingDirectory=${WEBUI_DIR}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  ok "Wrote ${WEBUI_SERVICE_FILE}"
}

start_webui_service() {
  systemctl daemon-reload
  systemctl enable "${WEBUI_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${WEBUI_SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${WEBUI_SERVICE_NAME}"
  ok "Web UI service is running: ${WEBUI_SERVICE_NAME}"
}

install_webui_stack() {
  install_self_copy
  if [[ -n "${WEBUI_PASSWORD:-}" ]]; then
    write_webui_auth
  fi
  write_webui_cert
  write_webui_app
  write_webui_service
  start_webui_service
}

gen_keys() {
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"

  if [[ ! -f "${WG_DIR}/vps_private.key" ]]; then
    umask 077
    wg genkey | tee "${WG_DIR}/vps_private.key" | wg pubkey > "${WG_DIR}/vps_public.key"
  fi

  if [[ ! -f "${WG_DIR}/gl_private.key" ]]; then
    umask 077
    wg genkey | tee "${WG_DIR}/gl_private.key" | wg pubkey > "${WG_DIR}/gl_public.key"
  fi

  VPS_PRIV="$(cat "${WG_DIR}/vps_private.key")"
  VPS_PUB="$(cat "${WG_DIR}/vps_public.key")"
  GL_PRIV="$(cat "${WG_DIR}/gl_private.key")"
  GL_PUB="$(cat "${WG_DIR}/gl_public.key")"
  if [[ -f "${WG_DIR}/remote_client_private.key" && -f "${WG_DIR}/remote_client_public.key" ]]; then
    REMOTE_CLIENT_PRIV="$(cat "${WG_DIR}/remote_client_private.key")"
    REMOTE_CLIENT_PUB="$(cat "${WG_DIR}/remote_client_public.key")"
  fi
}

write_wg_configs() {
  gen_keys
  local prefix
  prefix="$(cidr_prefix "${WG_TUN_CIDR}")"
  [[ -n "${prefix}" ]] || { err "Invalid WG tunnel CIDR: ${WG_TUN_CIDR}"; exit 1; }

  cat > "${WG_CONF}" <<EOF
[Interface]
Address = ${WG_VPS_IP}/${prefix}
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIV}

[Peer]
PublicKey = ${GL_PUB}
AllowedIPs = ${WG_GL_IP}/32, ${LAN_CIDR}
EOF
  if [[ -n "${REMOTE_CLIENT_PUB:-}" ]]; then
    cat >> "${WG_CONF}" <<EOF

[Peer]
PublicKey = ${REMOTE_CLIENT_PUB}
AllowedIPs = ${REMOTE_CLIENT_IP}/32
EOF
  fi
  chmod 600 "${WG_CONF}"
  ok "Wrote ${WG_CONF}"

  cat > "${ROUTER_CONF_OUT}" <<EOF
[Interface]
PrivateKey = ${GL_PRIV}
Address = ${WG_GL_IP}/${prefix}
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = ${VPS_PUB}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 600 "${ROUTER_CONF_OUT}"
  ok "Wrote ${ROUTER_CONF_OUT}"

  if [[ -n "${REMOTE_CLIENT_PRIV:-}" ]]; then
    cat > "${REMOTE_CLIENT_CONF_OUT}" <<EOF
[Interface]
PrivateKey = ${REMOTE_CLIENT_PRIV}
Address = ${REMOTE_CLIENT_IP}/${prefix}
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = ${VPS_PUB}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = ${LAN_CIDR}, ${WG_VPS_IP}/32
PersistentKeepalive = 25
EOF
    chmod 600 "${REMOTE_CLIENT_CONF_OUT}"
    ok "Wrote ${REMOTE_CLIENT_CONF_OUT}"
  fi
}

create_remote_client() {
  load_state
  init_defaults
  mkdir -p "${WG_DIR}"
  chmod 700 "${WG_DIR}"
  if [[ -f "${WG_DIR}/remote_client_private.key" && -f "${WG_DIR}/remote_client_public.key" && -s "${REMOTE_CLIENT_CONF_OUT}" ]] &&
     { ! systemctl is-active --quiet "wg-quick@${WG_NAME}" || wg show "${WG_NAME}" peers 2>/dev/null | grep -Fxq "$(cat "${WG_DIR}/remote_client_public.key")"; }; then
    ok "Remote VPN client already available; existing keys and router tunnel unchanged."
    return 0
  fi
  if [[ ! -f "${WG_DIR}/remote_client_private.key" ]]; then
    umask 077
    wg genkey | tee "${WG_DIR}/remote_client_private.key" | wg pubkey > "${WG_DIR}/remote_client_public.key"
  fi
  write_wg_configs
  if systemctl is-active --quiet "wg-quick@${WG_NAME}"; then
    wg set "${WG_NAME}" peer "${REMOTE_CLIENT_PUB}" allowed-ips "${REMOTE_CLIENT_IP}/32"
  fi
  ok "Remote VPN client ready: ${REMOTE_CLIENT_IP}"
  ok "Config: ${REMOTE_CLIENT_CONF_OUT}"
}

apply_sysctl() {
  cat > "${SYSCTL_FILE}" <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
  sysctl -p "${SYSCTL_FILE}" >/dev/null
  ok "Applied sysctl settings."
}

wg_up() {
  systemctl stop "wg-quick@${WG_NAME}" >/dev/null 2>&1 || true
  systemctl start "wg-quick@${WG_NAME}"
  ok "WireGuard is up: wg-quick@${WG_NAME}"
}

wireguard_runtime_matches() {
  systemctl is-active --quiet "wg-quick@${WG_NAME}" || return 1
  [[ "$(wg show "${WG_NAME}" listen-port 2>/dev/null)" == "${WG_PORT}" ]] || return 1
  local peers allowed prefix route
  peers="$(wg show "${WG_NAME}" peers 2>/dev/null)" || return 1
  grep -Fxq "${GL_PUB}" <<< "${peers}" || return 1
  allowed="$(wg show "${WG_NAME}" allowed-ips 2>/dev/null)" || return 1
  grep -F "${GL_PUB}" <<< "${allowed}" | grep -Fq "${WG_GL_IP}/32" || return 1
  grep -F "${GL_PUB}" <<< "${allowed}" | grep -Fq "${LAN_CIDR}" || return 1
  if [[ -n "${REMOTE_CLIENT_PUB:-}" ]]; then
    grep -Fxq "${REMOTE_CLIENT_PUB}" <<< "${peers}" || return 1
    grep -F "${REMOTE_CLIENT_PUB}" <<< "${allowed}" | grep -Fq "${REMOTE_CLIENT_IP}/32" || return 1
  fi
  prefix="$(cidr_prefix "${WG_TUN_CIDR}")"
  ip -4 addr show dev "${WG_NAME}" 2>/dev/null | grep -Fq "${WG_VPS_IP}/${prefix}" || return 1
  route="$(ip -4 route show "${LAN_CIDR}" 2>/dev/null)"
  [[ "${route}" == *"dev ${WG_NAME}"* ]] || return 1
}

wireguard_input_rule_exists() {
  iptables -C INPUT -p udp --dport "${WG_PORT}" -j ACCEPT >/dev/null 2>&1
}

ensure_wireguard_input_rule() {
  if ! wireguard_input_rule_exists; then
    iptables -I INPUT 1 -p udp --dport "${WG_PORT}" -j ACCEPT
  fi
  ok "Allowed WireGuard on INPUT: UDP ${WG_PORT}"
}

remove_wireguard_input_rule() {
  while wireguard_input_rule_exists; do
    iptables -D INPUT -p udp --dport "${WG_PORT}" -j ACCEPT >/dev/null 2>&1 || true
  done
}

remove_webui_input_rules() {
  local rule
  while IFS= read -r rule; do
    [[ -n "${rule}" ]] || continue
    eval "iptables ${rule/-A /-D }" >/dev/null 2>&1 || true
  done < <(iptables -S INPUT 2>/dev/null | grep -F -- "${WEBUI_RULE_COMMENT}" || true)
}

ensure_webui_input_rule() {
  remove_webui_input_rules
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    iptables -I INPUT 1 -p tcp --dport "${WEBUI_PORT}" -m comment --comment "${WEBUI_RULE_COMMENT}" -j ACCEPT
    ok "Allowed Web UI on INPUT: TCP ${WEBUI_PORT}"
  fi
}

prepare_host_firewall() {
  if have_cmd ufw; then
    local ufw_status
    ufw_status="$(ufw status 2>/dev/null | head -n 1 || true)"
    if [[ "${ufw_status}" == "Status: active" ]]; then
      warn "UFW is active. Disabling it to avoid blocking WireGuard and custom iptables rules."
      ufw --force disable >/dev/null
      UFW_WAS_ACTIVE="Y"
      ok "UFW disabled."
    fi
  fi

  ensure_wireguard_input_rule
  ensure_webui_input_rule
  save_state
}

iptables_cleanup_chains() {
  iptables -t nat -D PREROUTING -j "${TAG_CHAIN_NAT}" >/dev/null 2>&1 || true
  iptables -t nat -F "${TAG_CHAIN_NAT}" >/dev/null 2>&1 || true
  iptables -t nat -X "${TAG_CHAIN_NAT}" >/dev/null 2>&1 || true

  iptables -D FORWARD -j "${TAG_CHAIN_FWD}" >/dev/null 2>&1 || true
  iptables -F "${TAG_CHAIN_FWD}" >/dev/null 2>&1 || true
  iptables -X "${TAG_CHAIN_FWD}" >/dev/null 2>&1 || true

  iptables -D FORWARD -j "${TAG_CHAIN_STATS}" >/dev/null 2>&1 || true
  iptables -F "${TAG_CHAIN_STATS}" >/dev/null 2>&1 || true
  iptables -X "${TAG_CHAIN_STATS}" >/dev/null 2>&1 || true
}

# helper: add DNAT rule for BOTH public iface and wg0 (hairpin)
dnat_both() {
  local proto="$1"
  local dport="$2"
  local to="$3"
  # From Internet
  iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${PUB_IFACE}" -p "${proto}" --dport "${dport}" -j DNAT --to-destination "${to}"
  # From inside tunnel, only when dst is VPS public IP
  iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${WG_NAME}" -d "${PUB_IP}" -p "${proto}" --dport "${dport}" -j DNAT --to-destination "${to}"
}

dnat_range_both() {
  local proto="$1"
  local dport_range="$2"
  local to="$3"
  iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${PUB_IFACE}" -p "${proto}" --dport "${dport_range}" -j DNAT --to-destination "${to}"
  iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${WG_NAME}" -d "${PUB_IP}" -p "${proto}" --dport "${dport_range}" -j DNAT --to-destination "${to}"
}

apply_extra_pf_rules() {
  [[ -n "${EXTRA_PF_RULES:-}" ]] || return 0

  local row proto public_from public_to target_ip target_from target_to label dport target
  local -a rows
  IFS=';' read -ra rows <<< "${EXTRA_PF_RULES}"
  for row in "${rows[@]}"; do
    [[ -n "${row}" ]] || continue
    IFS='|' read -r proto public_from public_to target_ip target_from target_to label <<< "${row}"
    [[ -n "${proto}" && -n "${public_from}" && -n "${public_to}" && -n "${target_ip}" && -n "${target_from}" && -n "${target_to}" ]] || continue

    if [[ "${public_from}" == "${public_to}" ]]; then
      target="${target_ip}:${target_from}"
      dnat_both "${proto}" "${public_from}" "${target}"
    else
      dport="${public_from}:${public_to}"
      if [[ "${public_from}" == "${target_from}" && "${public_to}" == "${target_to}" ]]; then
        target="${target_ip}"
      else
        target="${target_ip}:${target_from}-${target_to}/${public_from}"
      fi
      dnat_range_both "${proto}" "${dport}" "${target}"
    fi
  done
}

dmz_reserved_list() {
  # Protect VPS listeners as well as the known management ports. StreamHub
  # and Extra rules are placed ahead of the DMZ fallback in the same chain.
  python3 - "${WG_PORT}" "${WEBUI_PORT}" <<'PYDMZ'
import re, subprocess, sys
ports = {('tcp', 22), ('tcp', int(sys.argv[2])), ('udp', int(sys.argv[1]))}
result = subprocess.run(['ss', '-H', '-lntu'], capture_output=True, text=True, timeout=5, check=True)
for line in result.stdout.splitlines():
    fields = line.split()
    if len(fields) < 5 or fields[0] not in ('tcp', 'udp'):
        continue
    address = fields[4]
    if address.startswith(('127.', '[::1]:', '::1:')):
        continue
    match = re.search(r':([0-9]+)$', address)
    if match:
        ports.add((fields[0], int(match.group(1))))
try:
    sshd = subprocess.run(['/usr/sbin/sshd', '-T'], capture_output=True, text=True, timeout=5)
    if sshd.returncode == 0:
        for line in sshd.stdout.splitlines():
            if line.startswith('port '):
                ports.add(('tcp', int(line.split()[1])))
except (OSError, subprocess.SubprocessError):
    pass
for proto, port in sorted(ports):
    if 1 <= port <= 65535:
        print(proto, port)
PYDMZ
}

apply_dmz_rules() {
  [[ -n "${DMZ_IP:-}" ]] || return 0
  local reserved proto port
  reserved="$(dmz_reserved_list)" || { err "Cannot inspect VPS service ports; DMZ was not enabled."; return 1; }
  while read -r proto port; do
    [[ -n "${proto}" && -n "${port}" ]] || continue
    iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${PUB_IFACE}" -d "${PUB_IP}" -p "${proto}" --dport "${port}" -j RETURN
    iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${WG_NAME}" -d "${PUB_IP}" -p "${proto}" --dport "${port}" -j RETURN
  done <<< "${reserved}"
  for proto in tcp udp; do
    iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${PUB_IFACE}" -d "${PUB_IP}" -p "${proto}" -j DNAT --to-destination "${DMZ_IP}"
    iptables -t nat -A "${TAG_CHAIN_NAT}" -i "${WG_NAME}" -d "${PUB_IP}" -p "${proto}" -j DNAT --to-destination "${DMZ_IP}"
  done
}

iptables_apply_rules() {
  [[ -n "${PUB_IFACE}" ]] || { err "Public iface is empty."; exit 1; }
  [[ -n "${PUB_IP}" ]] || { err "Public IPv4 is empty."; exit 1; }

  iptables_cleanup_chains

  iptables -t nat -N "${TAG_CHAIN_NAT}"
  iptables -t nat -A PREROUTING -j "${TAG_CHAIN_NAT}"

  iptables -N "${TAG_CHAIN_FWD}"
  iptables -A FORWARD -j "${TAG_CHAIN_FWD}"

  # Dedicated non-terminating counters provide per-device traffic telemetry.
  # They do not alter packet handling and are read by the Web UI.
  iptables -N "${TAG_CHAIN_STATS}"
  iptables -I FORWARD 1 -j "${TAG_CHAIN_STATS}"
  local stats_name stats_ip
  while IFS='|' read -r stats_name stats_ip; do
    [[ -n "${stats_name}" && -n "${stats_ip}" ]] || continue
    iptables -A "${TAG_CHAIN_STATS}" -i "${WG_NAME}" -s "${stats_ip}" -m comment --comment "rx:${stats_name}"
    iptables -A "${TAG_CHAIN_STATS}" -o "${WG_NAME}" -d "${stats_ip}" -m comment --comment "tx:${stats_name}"
  done <<EOF
router|${ROUTER_LAN_IP}
streamhub|${STREAMHUB_IP}
EOF
  iptables -A "${TAG_CHAIN_STATS}" -j RETURN

  # Internet egress NAT (support both GL masquerade modes)
  iptables -t nat -C POSTROUTING -s "${LAN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -s "${LAN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE
  iptables -t nat -C POSTROUTING -s "${WG_TUN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -s "${WG_TUN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE

  # DNAT-to-LAN replies source rewritten to VPS WG IP (stable return path)
  iptables -t nat -C POSTROUTING -d "${LAN_CIDR}" -o "${WG_NAME}" -j SNAT --to-source "${WG_VPS_IP}" >/dev/null 2>&1 || \
    iptables -t nat -A POSTROUTING -d "${LAN_CIDR}" -o "${WG_NAME}" -j SNAT --to-source "${WG_VPS_IP}"

  # Forwarding allow rules
  iptables -A "${TAG_CHAIN_FWD}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A "${TAG_CHAIN_FWD}" -i "${WG_NAME}" -o "${PUB_IFACE}" -j ACCEPT
  iptables -A "${TAG_CHAIN_FWD}" -i "${PUB_IFACE}" -o "${WG_NAME}" -j ACCEPT
  iptables -A "${TAG_CHAIN_FWD}" -i "${WG_NAME}" -o "${WG_NAME}" -j ACCEPT

  # StreamHub (PDF + fixed TCP/UDP 7900-7940)
  dnat_both tcp 7900 "${STREAMHUB_IP}:7900"
  dnat_range_both tcp "7901:7940" "${STREAMHUB_IP}"
  dnat_range_both udp "${STREAMHUB_UDP_7900_FROM}:${STREAMHUB_UDP_7900_TO}" "${STREAMHUB_IP}"

  # StreamHub TCP per PDF
  dnat_both tcp 443  "${STREAMHUB_IP}:443"
  dnat_both tcp 8888 "${STREAMHUB_IP}:8888"
  dnat_both tcp 8891 "${STREAMHUB_IP}:8891"
  dnat_both tcp 8893 "${STREAMHUB_IP}:8893"
  dnat_both tcp 8896 "${STREAMHUB_IP}:8896"
  dnat_both tcp 8444 "${STREAMHUB_IP}:8444"
  dnat_both tcp 8884 "${STREAMHUB_IP}:8884"
  dnat_both tcp 8885 "${STREAMHUB_IP}:8885"
  dnat_both tcp 5322 "${STREAMHUB_IP}:5322"
  dnat_both tcp 1935 "${STREAMHUB_IP}:1935"

  # StreamHub FTP per PDF
  dnat_both tcp 20 "${STREAMHUB_IP}:20"
  dnat_both tcp 21 "${STREAMHUB_IP}:21"
  dnat_range_both tcp "12000:12009" "${STREAMHUB_IP}"

  # StreamHub UDP per PDF
  dnat_range_both udp "5010:5026" "${STREAMHUB_IP}"
  dnat_both udp 5353 "${STREAMHUB_IP}"
  dnat_range_both udp "5959:5960" "${STREAMHUB_IP}"
  dnat_range_both udp "5961:5999" "${STREAMHUB_IP}"
  dnat_range_both udp "6960:6999" "${STREAMHUB_IP}"
  dnat_range_both udp "7960:7999" "${STREAMHUB_IP}"
  dnat_range_both udp "20000:20100" "${STREAMHUB_IP}"
  dnat_range_both udp "20400:20499" "${STREAMHUB_IP}"
  dnat_range_both udp "7901:7940" "${STREAMHUB_IP}"

  # User-defined extra rules from the Web UI.
  apply_extra_pf_rules
  # Catch only ports still unclaimed by StreamHub, Extra and VPS services.
  apply_dmz_rules

  ok "iptables rules applied."
}

make_persistent() {
  log "Creating persistence..."
  prepare_host_firewall
  local temporary
  temporary="$(mktemp "${RULES_FILE}.XXXXXX")"
  iptables-save > "${temporary}"
  chmod 600 "${temporary}"
  iptables-restore --test < "${temporary}"
  mv -f "${temporary}" "${RULES_FILE}"

  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=WireGuard VPN iptables rules
After=network-online.target wg-quick@${WG_NAME}.service
Wants=network-online.target wg-quick@${WG_NAME}.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/iptables-restore < ${RULES_FILE}'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${UNIT_NAME}" >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "${UNIT_NAME}"; then
    systemctl start "${UNIT_NAME}"
  fi
  if [[ -f "${WG_CONF}" ]]; then
    systemctl enable "wg-quick@${WG_NAME}" >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet "wg-quick@${WG_NAME}"; then
      systemctl start "wg-quick@${WG_NAME}"
    fi
  else
    warn "WireGuard config not found yet. Skipping wg-quick enable/restart."
  fi
  ok "Persistence enabled: ${UNIT_NAME}"
}

do_test() {
  echo
  log "WireGuard status:"
  systemctl --no-pager --full status "wg-quick@${WG_NAME}" || true
  echo
  if have_cmd wg; then
    wg show "${WG_NAME}" || true
  fi

  echo
  log "iptables quick checks:"
  echo "  WG INPUT rule present:            $(iptables -S INPUT 2>/dev/null | grep -c -- "-p udp -m udp --dport ${WG_PORT} -j ACCEPT" || true)"
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    echo "  Web UI INPUT rule present:        $(iptables -S INPUT 2>/dev/null | grep -c -- "${WEBUI_RULE_COMMENT}" || true)"
  fi
  echo "  DNAT rules for public iface exist: $(iptables -t nat -S "${TAG_CHAIN_NAT}" 2>/dev/null | grep -c -- "-i ${PUB_IFACE}" || true)"
  echo "  DNAT hairpin rules on wg0 exist:   $(iptables -t nat -S "${TAG_CHAIN_NAT}" 2>/dev/null | grep -c -- "-i ${WG_NAME} -d ${PUB_IP}" || true)"
  echo
  if systemctl list-unit-files "${WEBUI_SERVICE_NAME}" >/dev/null 2>&1; then
    log "Web UI status:"
    systemctl --no-pager --full status "${WEBUI_SERVICE_NAME}" || true
    echo
  fi
  echo "Client-side tests:"
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    echo "  Web UI:        https://${PUB_IP}:${WEBUI_PORT}"
  fi
  echo "  StreamHub:     https://${PUB_IP} and https://${PUB_IP}:8444"
  echo
}

system_health() {
  local health_warn=0 health_error=0
  local latest_handshake now age route_line

  health_ok() { printf '[OK]      %s\n' "$*"; }
  health_warn_msg() { printf '[WARNING] %s\n' "$*"; health_warn=$((health_warn + 1)); }
  health_err_msg() { printf '[ERROR]   %s\n' "$*"; health_error=$((health_error + 1)); }

  echo
  echo "============================================================"
  echo " WireGuard VPN v1.0 - System Health"
  echo "============================================================"
  echo

  # WireGuard interface and service
  if ip link show "${WG_NAME}" >/dev/null 2>&1; then
    health_ok "WireGuard interface ${WG_NAME} exists."
  else
    health_err_msg "WireGuard interface ${WG_NAME} is missing."
  fi

  if systemctl is-active --quiet "wg-quick@${WG_NAME}"; then
    health_ok "WireGuard service wg-quick@${WG_NAME} is active."
  else
    health_err_msg "WireGuard service wg-quick@${WG_NAME} is not active."
  fi

  if ip -4 addr show dev "${WG_NAME}" 2>/dev/null | grep -Fq "${WG_VPS_IP}/"; then
    health_ok "VPS WireGuard address ${WG_VPS_IP} is configured on ${WG_NAME}."
  else
    health_err_msg "VPS WireGuard address ${WG_VPS_IP} is not configured on ${WG_NAME}."
  fi

  # WireGuard router peer and handshake
  if have_cmd wg && wg show "${WG_NAME}" allowed-ips 2>/dev/null | awk '{print $2}' | tr ',' '\n' | grep -Fxq "${WG_GL_IP}/32"; then
    health_ok "WireGuard router peer ${WG_GL_IP} is configured."
  else
    health_err_msg "WireGuard router peer ${WG_GL_IP} is not present in ${WG_NAME}."
  fi

  # Active router reachability check. The latest WireGuard handshake is diagnostic
  # history only; it must not be used by itself to declare the router online.
  local router_pubkey
  router_pubkey="$(wg show "${WG_NAME}" allowed-ips 2>/dev/null | awk -v ip="${WG_GL_IP}/32" '$2 ~ ip {print $1; exit}')"
  if [[ -n "${router_pubkey}" ]]; then
    latest_handshake="$(wg show "${WG_NAME}" latest-handshakes 2>/dev/null | awk -v key="${router_pubkey}" '$1 == key {print $2; exit}')"
  else
    latest_handshake="0"
  fi

  if have_cmd ping && ping -n -c 1 -W 1 "${WG_GL_IP}" >/dev/null 2>&1; then
    if [[ "${latest_handshake:-0}" =~ ^[0-9]+$ ]] && (( latest_handshake > 0 )); then
      now="$(date +%s)"
      age=$((now - latest_handshake))
      health_ok "WireGuard router is online (active check passed; last handshake ${age}s ago)."
    else
      health_ok "WireGuard router is online (active check passed)."
    fi
  else
    if [[ "${latest_handshake:-0}" =~ ^[0-9]+$ ]] && (( latest_handshake > 0 )); then
      now="$(date +%s)"
      age=$((now - latest_handshake))
      health_err_msg "WireGuard router is offline (active check failed; last handshake ${age}s ago)."
    else
      health_err_msg "WireGuard router is offline (active check failed; no WireGuard handshake detected)."
    fi
  fi

  # Kernel forwarding
  if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
    health_ok "IPv4 forwarding is enabled."
  else
    health_err_msg "IPv4 forwarding is disabled."
  fi

  # Route to site LAN
  route_line="$(ip -4 route show "${LAN_CIDR}" 2>/dev/null | head -n1 || true)"
  if [[ -n "${route_line}" && " ${route_line} " == *" dev ${WG_NAME} "* ]]; then
    health_ok "Route to site LAN ${LAN_CIDR} uses ${WG_NAME}."
  else
    health_err_msg "Route to site LAN ${LAN_CIDR} through ${WG_NAME} is missing."
  fi

  # Firewall/NAT runtime chains and jumps
  if iptables -t nat -S "${TAG_CHAIN_NAT}" >/dev/null 2>&1; then
    health_ok "NAT chain ${TAG_CHAIN_NAT} exists."
  else
    health_err_msg "NAT chain ${TAG_CHAIN_NAT} is missing."
  fi
  if iptables -S "${TAG_CHAIN_FWD}" >/dev/null 2>&1; then
    health_ok "Forwarding chain ${TAG_CHAIN_FWD} exists."
  else
    health_err_msg "Forwarding chain ${TAG_CHAIN_FWD} is missing."
  fi
  if iptables -t nat -C PREROUTING -j "${TAG_CHAIN_NAT}" >/dev/null 2>&1; then
    health_ok "PREROUTING is connected to ${TAG_CHAIN_NAT}."
  else
    health_err_msg "PREROUTING jump to ${TAG_CHAIN_NAT} is missing."
  fi
  if iptables -C FORWARD -j "${TAG_CHAIN_FWD}" >/dev/null 2>&1; then
    health_ok "FORWARD is connected to ${TAG_CHAIN_FWD}."
  else
    health_err_msg "FORWARD jump to ${TAG_CHAIN_FWD} is missing."
  fi
  if iptables -t nat -S POSTROUTING 2>/dev/null | grep -Fq -- "-s ${LAN_CIDR}"; then
    health_ok "Site LAN has a POSTROUTING NAT rule."
  else
    health_err_msg "POSTROUTING NAT rule for site LAN ${LAN_CIDR} is missing."
  fi

  # Persistent configuration
  if [[ -s "${WG_CONF}" ]]; then
    health_ok "WireGuard configuration ${WG_CONF} exists."
  else
    health_err_msg "WireGuard configuration ${WG_CONF} is missing or empty."
  fi
  if [[ -s "${RULES_FILE}" ]]; then
    health_ok "Persistent firewall rules ${RULES_FILE} exist."
  else
    health_err_msg "Persistent firewall rules ${RULES_FILE} are missing or empty."
  fi
  if systemctl is-enabled --quiet "${UNIT_NAME}" 2>/dev/null; then
    health_ok "Persistence service ${UNIT_NAME} is enabled."
  else
    health_err_msg "Persistence service ${UNIT_NAME} is not enabled."
  fi
  if systemctl is-active --quiet "${UNIT_NAME}"; then
    health_ok "Persistence service ${UNIT_NAME} is active."
  else
    health_warn_msg "Persistence service ${UNIT_NAME} is not active."
  fi

  # Web UI
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    if systemctl is-active --quiet "${WEBUI_SERVICE_NAME}"; then
      health_ok "Web UI service ${WEBUI_SERVICE_NAME} is active."
    else
      health_err_msg "Web UI is enabled but ${WEBUI_SERVICE_NAME} is not active."
    fi
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${WEBUI_PORT}$"; then
      health_ok "Web UI TCP port ${WEBUI_PORT} is listening."
    else
      health_err_msg "Web UI TCP port ${WEBUI_PORT} is not listening."
    fi
  else
    health_warn_msg "Web UI is disabled in the current configuration."
  fi

  echo
  echo "------------------------------------------------------------"
  if (( health_error > 0 )); then
    echo "SYSTEM HEALTH: ERROR (${health_error} error(s), ${health_warn} warning(s))"
    echo "------------------------------------------------------------"
    echo
    return 2
  elif (( health_warn > 0 )); then
    echo "SYSTEM HEALTH: WARNING (${health_warn} warning(s))"
    echo "------------------------------------------------------------"
    echo
    return 1
  else
    echo "SYSTEM HEALTH: HEALTHY"
    echo "------------------------------------------------------------"
    echo
    return 0
  fi
}

remove_all() {
  warn "REMOVE ALL will delete WireGuard configs, keys, systemd units, sysctl, rules, and generated files."
  if [[ "${1:-}" != "web-confirmed" ]]; then
    read -r -p "Type YES to continue: " a
    [[ "${a}" == "YES" ]] || { warn "Cancelled."; return; }
  fi

  load_state
  load_webui_auth
  init_defaults

  log "Stopping services..."
  systemctl disable --now "${WEBUI_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "${UNIT_NAME}" >/dev/null 2>&1 || true
  systemctl disable --now "wg-quick@${WG_NAME}" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  log "Removing iptables rules..."
  remove_wireguard_input_rule
  remove_webui_input_rules
  iptables_cleanup_chains
  iptables -t nat -D POSTROUTING -s "${LAN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE >/dev/null 2>&1 || true
  iptables -t nat -D POSTROUTING -s "${WG_TUN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE >/dev/null 2>&1 || true
  iptables -t nat -D POSTROUTING -d "${LAN_CIDR}" -o "${WG_NAME}" -j SNAT --to-source "${WG_VPS_IP}" >/dev/null 2>&1 || true

  if [[ "${UFW_WAS_ACTIVE}" == "Y" ]] && have_cmd ufw; then
    log "Re-enabling UFW because it was active before APPLY..."
    ufw --force enable >/dev/null 2>&1 || true
  fi

  log "Deleting files..."
  rm -f "${UNIT_FILE}" "${RULES_FILE}" "${SYSCTL_FILE}" "${STATE_FILE}" "${APPLIED_STATE_FILE}" "${WEBUI_SERVICE_FILE}" "${WEBUI_AUTH_FILE}" /root/wgvpn_wizard_pending
  rm -f "${ROUTER_CONF_OUT}" "${REMOTE_CLIENT_CONF_OUT}" "${WG_CONF}" "${SCRIPT_INSTALL_PATH}"
  rm -f "${WG_DIR}/vps_private.key" "${WG_DIR}/vps_public.key" "${WG_DIR}/gl_private.key" "${WG_DIR}/gl_public.key" "${WG_DIR}/remote_client_private.key" "${WG_DIR}/remote_client_public.key"
  rm -f "${EULA_FLAG}" >/dev/null 2>&1 || true
  rm -rf "${WEBUI_DIR}"
  systemctl daemon-reload >/dev/null 2>&1 || true

  log "Reload sysctl defaults..."
  sysctl --system >/dev/null 2>&1 || true

  log "Purging packages (wireguard)..."
  apt-get purge -y wireguard wireguard-tools >/dev/null 2>&1 || true
  if [[ "${PYTHON3_INSTALLED_BY_SCRIPT}" == "Y" ]]; then
    log "Purging python3 because it was installed by this script..."
    apt-get purge -y python3 >/dev/null 2>&1 || true
  fi
  apt-get autoremove -y >/dev/null 2>&1 || true

  ok "REMOVE ALL completed."
}

print_apply_summary() {
  echo
  echo "Router WireGuard config saved to: ${ROUTER_CONF_OUT}"
  echo "StreamHub exposed on: https://${PUB_IP}"
  echo
  echo "Router VPN options recommendation:"
  echo "  Kill Switch: ON"
  echo "  Router's own services use VPN: OFF"
  echo "  Allow Remote Access the LAN Subnet: ON"
  echo "  IP Masquerading: ON recommended (OFF also works)"
  if [[ "${WEBUI_ENABLED}" == "Y" ]]; then
    echo
    echo "Web UI:"
    echo "  https://${PUB_IP}:${WEBUI_PORT}"
    echo "  Username: ${WEBUI_USER}"
  fi
  echo
}

validate_config() {
  python3 - "$(script_real_path)" <<'PYVALIDATE'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text(encoding="utf-8")
app = source.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
namespace = {"__name__": "wgvpn_validation"}
exec(compile(app, "wgvpn_webui.py", "exec"), namespace)
state = namespace["merged_state"]()
form = {key: [value] for key, value in state.items()}
for rule in namespace["parse_extra_rules"](state.get("EXTRA_PF_RULES", "")):
    for field, value in {
        "PROTO": rule["proto"], "TARGET_IP": rule["target_ip"], "LABEL": rule["label"],
        "PORT": rule["public_from"] + "-" + rule["public_to"],
        "TARGET_PORT": rule["target_from"] + "-" + rule["target_to"],
    }.items():
        form.setdefault("EXTRA_RULE_" + field, []).append(value)
_, errors, _ = namespace["apply_form_values"](form, state)
if errors:
    print("Configuration rejected:\n" + "\n".join(errors), file=sys.stderr)
    sys.exit(1)
if not Path("/sys/class/net", state["PUB_IFACE"]).exists():
    sys.exit("Public network interface does not exist.")
PYVALIDATE
}

cleanup_previous_network_rules() (
  [[ -f "${APPLIED_STATE_FILE}" ]] || exit 0
  source "${APPLIED_STATE_FILE}"
  remove_wireguard_input_rule
  iptables -t nat -D POSTROUTING -s "${LAN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "${WG_TUN_CIDR}" -o "${PUB_IFACE}" -j MASQUERADE 2>/dev/null || true
  iptables -t nat -D POSTROUTING -d "${LAN_CIDR}" -o "${WG_NAME}" -j SNAT --to-source "${WG_VPS_IP}" 2>/dev/null || true
)

apply_runtime() (
  exec 9>/run/wgvpn-apply.lock
  flock -n 9 || { err "Another WireGuard VPN operation is running."; exit 1; }
  local apply_started=${SECONDS}
  validate_config
  log "Apply timing: validation $((SECONDS - apply_started))s"
  local backup item ufw_active=N wg_active=N wg_enabled=N rules_enabled=N
  backup="$(mktemp -d /root/wgvpn-rollback.XXXXXX)"
  iptables-save > "${backup}/iptables.v4"
  systemctl is-active --quiet "wg-quick@${WG_NAME}" && wg_active=Y
  systemctl is-enabled --quiet "wg-quick@${WG_NAME}" && wg_enabled=Y
  systemctl is-enabled --quiet "${UNIT_NAME}" && rules_enabled=Y
  if have_cmd ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw_active=Y; fi
  for item in "${WG_CONF}" "${SYSCTL_FILE}" "${RULES_FILE}" "${UNIT_FILE}"; do
    [[ ! -f "${item}" ]] || cp -p "${item}" "${backup}/$(basename "${item}")"
  done
  sysctl -n net.ipv4.ip_forward > "${backup}/ip_forward"
  sysctl -n net.ipv4.conf.all.rp_filter > "${backup}/rp_all"
  sysctl -n net.ipv4.conf.default.rp_filter > "${backup}/rp_default"
  rollback_runtime() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )); then
      set +e
      err "Apply failed; restoring previous firewall and WireGuard configuration. Backup: ${backup}"
      for item in "${WG_CONF}" "${SYSCTL_FILE}" "${RULES_FILE}" "${UNIT_FILE}"; do
        if [[ -f "${backup}/$(basename "${item}")" ]]; then
          cp -p "${backup}/$(basename "${item}")" "${item}"
        else
          rm -f "${item}"
        fi
      done
      systemctl daemon-reload
      [[ "${wg_enabled}" == Y ]] || systemctl disable "wg-quick@${WG_NAME}"
      [[ "${rules_enabled}" == Y ]] || systemctl disable "${UNIT_NAME}"
      if [[ "${wg_active}" == Y ]]; then systemctl restart "wg-quick@${WG_NAME}"; else systemctl stop "wg-quick@${WG_NAME}"; fi
      [[ "${ufw_active}" != Y ]] || ufw --force enable
      iptables-restore < "${backup}/iptables.v4"
      sysctl -w "net.ipv4.ip_forward=$(cat "${backup}/ip_forward")" "net.ipv4.conf.all.rp_filter=$(cat "${backup}/rp_all")" "net.ipv4.conf.default.rp_filter=$(cat "${backup}/rp_default")" >/dev/null
    else
      rm -rf -- "${backup}"
    fi
    exit "${rc}"
  }
  trap rollback_runtime EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  cleanup_previous_network_rules
  write_wg_configs
  apply_sysctl
  if [[ -f "${backup}/$(basename "${WG_CONF}")" ]] &&
     cmp -s "${backup}/$(basename "${WG_CONF}")" "${WG_CONF}" &&
     wireguard_runtime_matches; then
    ok "WireGuard configuration unchanged; keeping the active router tunnel."
  else
    wg_up
  fi
  log "Apply timing: WireGuard ready at $((SECONDS - apply_started))s"
  prepare_host_firewall
  iptables_apply_rules
  log "Apply timing: firewall ready at $((SECONDS - apply_started))s"
  if [[ "${1:-N}" == Y ]]; then make_persistent; fi
  cp -p "${STATE_FILE}" "${APPLIED_STATE_FILE}"
  log "Apply timing: complete in $((SECONDS - apply_started))s"
)

apply_all() {
  prompt_config
  apply_runtime
  ok "APPLY completed."
  print_apply_summary
}

web_apply_all() {
  apply_runtime Y
  ok "APPLY + MAKE PERSISTENT completed."
  print_apply_summary
}

install_workflow() {
  load_state
  load_webui_auth
  init_defaults
  show_eula_if_needed
  automatic_webui_setup
  install_deps
  save_state
  if [[ ! -f "${APPLIED_STATE_FILE}" ]]; then
    install -m 600 /dev/null /root/wgvpn_wizard_pending
  fi
  prepare_host_firewall
  install_webui_stack
  print_webui_access
  echo "Use the Web UI to fill the configuration and press Apply."
  echo
}

reset_webui_credentials() {
  load_state
  load_webui_auth
  init_defaults
  WEBUI_USER="admin"
  WEBUI_PASSWORD="password"
  WEBUI_FORCE_PASSWORD_CHANGE="Y"
  WEBUI_PORT="${WEBUI_PORT:-65000}"
  WEBUI_BIND="0.0.0.0"
  WEBUI_ENABLED="Y"
  write_webui_auth
  save_state
  systemctl restart "${WEBUI_SERVICE_NAME}" >/dev/null 2>&1 || true
  ok "Web UI credentials reset to admin / password."
  warn "A new password will be required at the next login."
}

run_noninteractive_command() {
  case "${1:-}" in
    --web-apply)
      load_state
      load_webui_auth
      init_defaults
      web_apply_all
      ;;
    --web-test)
      load_state
      load_webui_auth
      init_defaults
      do_test
      ;;
    --health)
      load_state
      load_webui_auth
      init_defaults
      system_health
      ;;
    --create-remote-client)
      create_remote_client
      ;;
    --ensure-webui-input)
      load_state
      load_webui_auth
      init_defaults
      ensure_webui_input_rule
      ensure_wireguard_input_rule
      ;;
    --print-webui-access)
      load_state
      load_webui_auth
      init_defaults
      print_webui_access
      ;;
    --reset-webui-credentials)
      reset_webui_credentials
      ;;
    --web-remove)
      remove_all web-confirmed
      ;;
    *)
      return 1
      ;;
  esac
}

menu() {
  while true; do
    load_state
    load_webui_auth
    init_defaults

    echo
    echo "WireGuard VPN v1.0 (GOLDEN)"
    echo "1) INSTALL + WEB UI"
    echo "2) APPLY (terminal fallback)"
    echo "3) TEST"
    echo "4) SYSTEM HEALTH"
    echo "5) MAKE PERSISTENT"
    echo "6) REMOVE ALL"
    echo "7) Show current config"
    echo "8) Show Web UI access"
    echo "9) Reset Web UI credentials"
    echo "0) Exit"
    echo
    read -r -p "Select: " c
    case "${c}" in
      1) install_workflow; pause ;;
      2) apply_all; pause ;;
      3) do_test; pause ;;
      4) system_health || true; pause ;;
      5) make_persistent; pause ;;
      6) remove_all; pause ;;
      7) print_config; pause ;;
      8) print_webui_access; pause ;;
      9) reset_webui_credentials; pause ;;
      0) exit 0 ;;
      *) warn "Invalid choice."; pause ;;
    esac
  done
}

need_root
if [[ $# -gt 0 ]]; then
  case "$1" in
    --web-apply|--web-test|--health|--ensure-webui-input|--print-webui-access|--create-remote-client|--reset-webui-credentials|--web-remove) ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  run_noninteractive_command "$1"
  exit 0
fi
menu
