#!/usr/bin/env bash
# Purpose:
#   Make Docker unable to access the network during tests by:
#     1) Enabling the discard service on localhost:9 (TCP/UDP) via inetd to accept and immediately discard traffic.
#     2) Pointing Docker's HTTP(S) proxy environment variables to http(s)://localhost:9 using a systemd drop-in.
#
# Why:
#   - Tests may only use pre-pulled/allowed Docker images. This prevents Docker from downloading anything else.
#   - Using the discard service avoids long TCP connection timeouts: the local port accepts connections and discards
#     data quickly, causing Docker's proxy connections to fail fast.
#
# Notes:
#   - This script is designed for GitHub Actions Ubuntu runners with sudo.
#   - It is idempotent: re-running it won't duplicate config lines or unnecessarily restart Docker.

set -Eeuo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Resolve paths relative to this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
DISCARD_CONF="$SCRIPT_DIR/discard-port.conf"
DOCKERD_DROPIN_TEMPLATE="$SCRIPT_DIR/dockerd.service"

# 1) Ensure inetd (openbsd-inetd) is installed
if ! dpkg -s openbsd-inetd >/dev/null 2>&1; then
  log "Installing openbsd-inetd"
  sudo apt-get update -y -qq || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openbsd-inetd
else
  log "openbsd-inetd already installed"
fi

# 2) Ensure discard service entries for tcp/9 and udp/9 exist in /etc/inetd.conf; track if changes were made
INETD_CHANGED=false
DISCARD_TCP_REGEX='^[[:space:]]*discard[[:space:]]+stream[[:space:]]+tcp'
DISCARD_UDP_REGEX='^[[:space:]]*discard[[:space:]]+dgram[[:space:]]+udp'

if ! grep -qE "$DISCARD_TCP_REGEX" /etc/inetd.conf 2>/dev/null; then
  log "Adding discard tcp/9 entry to /etc/inetd.conf"
  sudo grep -E "$DISCARD_TCP_REGEX" "$DISCARD_CONF" | sudo tee -a /etc/inetd.conf > /dev/null
  INETD_CHANGED=true
else
  log "discard tcp/9 already present in /etc/inetd.conf"
fi

if ! grep -qE "$DISCARD_UDP_REGEX" /etc/inetd.conf 2>/dev/null; then
  log "Adding discard udp/9 entry to /etc/inetd.conf"
  sudo grep -E "$DISCARD_UDP_REGEX" "$DISCARD_CONF" | sudo tee -a /etc/inetd.conf > /dev/null
  INETD_CHANGED=true
else
  log "discard udp/9 already present in /etc/inetd.conf"
fi

# 3) Start inetd (service name may be inetd or openbsd-inetd depending on image)
if systemctl list-unit-files | grep -q '^inetd\.service'; then
  if ! systemctl is-active --quiet inetd; then
    log "Starting inetd"
    sudo systemctl start inetd
  else
    log "inetd already running"
  fi
else
  if ! systemctl is-active --quiet openbsd-inetd; then
    log "Starting openbsd-inetd"
    sudo systemctl start openbsd-inetd
  else
    log "openbsd-inetd already running"
  fi
fi

# 3b) Reload/restart inetd if inetd.conf changed
if [ "$INETD_CHANGED" = true ]; then
  log "Reloading/restarting inetd due to inetd.conf changes"
  if systemctl list-unit-files | grep -q '^inetd\.service'; then
    sudo systemctl reload inetd || sudo systemctl restart inetd
  else
    sudo systemctl reload openbsd-inetd || sudo systemctl restart openbsd-inetd
  fi
else
  log "No change to /etc/inetd.conf; no inetd reload needed"
fi

# 4) Create a systemd drop-in for docker.service to set HTTP(S)_PROXY to localhost:9
# 4) Configure Docker proxy drop-in only if docker.service exists
if systemctl list-unit-files | grep -q '^docker\.service'; then
  DROPIN_DIR=/etc/systemd/system/docker.service.d
  DROPIN_FILE=$DROPIN_DIR/http-proxy.conf
  sudo install -d -m 0755 "$DROPIN_DIR"

  NEED_RESTART=false
  if ! sudo test -f "$DROPIN_FILE"; then
    log "Creating Docker proxy drop-in at $DROPIN_FILE"
    sudo tee "$DROPIN_FILE" > /dev/null < "$DOCKERD_DROPIN_TEMPLATE"
    NEED_RESTART=true
  else
    if ! sudo cmp -s "$DOCKERD_DROPIN_TEMPLATE" "$DROPIN_FILE"; then
      log "Updating Docker proxy drop-in at $DROPIN_FILE"
      sudo tee "$DROPIN_FILE" > /dev/null < "$DOCKERD_DROPIN_TEMPLATE"
      NEED_RESTART=true
    else
      log "Docker proxy drop-in already up to date"
    fi
  fi

  # 5) Reload systemd and restart Docker only if the drop-in changed
  if [ "$NEED_RESTART" = true ]; then
    log "Reloading systemd and restarting docker"
    sudo systemctl daemon-reload
    sudo systemctl restart docker
  else
    log "No docker restart needed"
  fi
else
  log "docker.service not present; skipping Docker proxy drop-in"
fi

log "Docker outbound network effectively disabled via proxy=http(s)://localhost:9 backed by inetd discard service."
