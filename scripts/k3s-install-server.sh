#!/bin/bash
# Installs a K3s server on an Azure Local SFF nested VM. Run with sudo.
#
# Two modes (K3S_ROLE):
#   init - first server. Set CLUSTER_INIT=true to start embedded etcd so more
#          servers can join later (HA). Without it, a single server using SQLite.
#   join - additional server joining an HA cluster (needs K3S_URL + K3S_TOKEN).
#
# Called automatically by Deploy-K3sCluster.ps1 on the Hyper-V host; can also
# be run by hand:
#   sudo K3S_ROLE=init NODE_IP=192.168.100.100 TLS_SANS="192.168.100.100" bash ./k3s-install-server.sh
#
# Secrets (K3S_TOKEN) can be supplied in ENV_FILE instead of the environment so
# they never appear on a command line. The file is sourced when present.
#
# Optional environment:
#   ENV_FILE            - default /tmp/k3s-lab/k3s.env
#   K3S_ROLE            - init (default) | join
#   CLUSTER_INIT        - true to enable embedded etcd on the first server
#   K3S_URL             - https://<first-server>:6443 (join only)
#   K3S_TOKEN           - cluster token (required for join; optional for init)
#   NODE_IP             - IP to advertise (default: first 192.168.100.x address)
#   NODE_NAME           - override node name (default: hostname)
#   TLS_SANS            - space-separated extra API server certificate SANs
#   K3S_DISABLE         - space-separated packaged components to disable (default: traefik)
#   INSTALL_K3S_VERSION - pin version, e.g. v1.33.5+k3s1 (default: stable channel)
#   READY_TIMEOUT       - seconds to wait for the node to become Ready (default 300)
#
set -euo pipefail

# The K3s installer uses /opt/bin when /usr/local/bin is read-only; sudo may not have either on PATH.
export PATH="$PATH:/usr/local/bin:/opt/bin"

ENV_FILE="${ENV_FILE:-/tmp/k3s-lab/k3s.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

K3S_ROLE="${K3S_ROLE:-init}"
CLUSTER_INIT="${CLUSTER_INIT:-false}"
K3S_DISABLE="${K3S_DISABLE:-traefik}"
TLS_SANS="${TLS_SANS:-}"
NODE_NAME="${NODE_NAME:-}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
CONFIG_FILE="/etc/rancher/k3s/config.yaml"

log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    err "Run as root (sudo bash $0)."
  fi
}

detect_node_ip() {
  if [[ -n "${NODE_IP:-}" ]]; then
    return
  fi
  NODE_IP="$(ip -4 addr show 2>/dev/null | grep -oE 'inet 192\.168\.100\.[0-9]+' | awk '{print $2}' | head -n1 || true)"
  if [[ -z "$NODE_IP" ]]; then
    NODE_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -n "$NODE_IP" ]] || err "Could not determine this node's IP. Set NODE_IP."
}

write_config() {
  if [[ -f "$CONFIG_FILE" ]] && grep -q '^# Managed by k3s-install-server.sh' "$CONFIG_FILE"; then
    log "$CONFIG_FILE already written by this script - leaving it unchanged."
    return
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    warn "Existing $CONFIG_FILE backed up before rewrite."
  fi

  mkdir -p "$(dirname "$CONFIG_FILE")"
  {
    echo "# Managed by k3s-install-server.sh"
    echo "node-ip: \"${NODE_IP}\""
    echo "advertise-address: \"${NODE_IP}\""
    [[ -n "$NODE_NAME" ]] && echo "node-name: \"${NODE_NAME}\""
    echo "write-kubeconfig-mode: \"0600\""
    echo "tls-san:"
    echo "  - \"${NODE_IP}\""
    local san
    for san in $TLS_SANS; do
      [[ "$san" == "$NODE_IP" ]] || echo "  - \"${san}\""
    done
    if [[ -n "$K3S_DISABLE" ]]; then
      echo "disable:"
      local c
      for c in $K3S_DISABLE; do echo "  - \"${c}\""; done
    fi
    if [[ "$K3S_ROLE" == "init" && "$CLUSTER_INIT" == "true" ]]; then
      echo "cluster-init: true"
    fi
    if [[ "$K3S_ROLE" == "join" ]]; then
      echo "server: \"${K3S_URL}\""
    fi
  } >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  log "Wrote $CONFIG_FILE"
}

install_k3s() {
  if systemctl is-active --quiet k3s 2>/dev/null; then
    warn "K3s server is already running ($(k3s --version 2>/dev/null | head -n1)). Skipping install."
    return
  fi
  if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    err "This node already runs k3s-agent. Uninstall it (k3s-agent-uninstall.sh) before making it a server."
  fi

  log "Installing K3s server (role: $K3S_ROLE, INSTALL_K3S_SKIP_SELINUX_RPM=true)..."
  # The SELinux RPM step fails on Azure Local SFF nodes, so it is always skipped.
  export INSTALL_K3S_SKIP_SELINUX_RPM=true
  export INSTALL_K3S_EXEC="server"
  if [[ -n "${INSTALL_K3S_VERSION:-}" ]]; then
    export INSTALL_K3S_VERSION
  else
    unset INSTALL_K3S_VERSION 2>/dev/null || true
  fi
  if [[ -n "${K3S_TOKEN:-}" ]]; then
    export K3S_TOKEN
  fi
  # K3S_URL would make the installer create an agent; the server URL lives in config.yaml.
  unset K3S_URL 2>/dev/null || true
  curl -sfL https://get.k3s.io | sh -s -
  log "K3s server installed."
}

wait_ready() {
  local name="${NODE_NAME:-$(hostname | tr '[:upper:]' '[:lower:]')}"
  log "Waiting up to ${READY_TIMEOUT}s for node '$name' to become Ready..."
  local deadline=$((SECONDS + READY_TIMEOUT))
  while (( SECONDS < deadline )); do
    if k3s kubectl get node "$name" --no-headers 2>/dev/null | awk '{print $2}' | grep -qx 'Ready'; then
      log "Node '$name' is Ready."
      return
    fi
    sleep 5
  done
  err "Timed out waiting for node '$name' to become Ready. Check: journalctl -u k3s -n 200"
}

main() {
  echo "============================================================"
  echo "  K3s server install ($(hostname), role: $K3S_ROLE)"
  echo "============================================================"
  check_root
  case "$K3S_ROLE" in
    init) ;;
    join)
      [[ -n "${K3S_URL:-}" ]]   || err "K3S_ROLE=join needs K3S_URL (https://<first-server>:6443)."
      [[ -n "${K3S_TOKEN:-}" ]] || err "K3S_ROLE=join needs K3S_TOKEN (from /var/lib/rancher/k3s/server/token)."
      ;;
    *) err "K3S_ROLE must be 'init' or 'join' (got '$K3S_ROLE')." ;;
  esac
  detect_node_ip
  if systemctl is-active --quiet k3s 2>/dev/null; then
    # Leave config.yaml alone: it may hold Arc RBAC kube-apiserver-arg entries.
    warn "K3s server is already running ($(k3s --version 2>/dev/null | head -n1)). Skipping config and install."
  else
    write_config
    install_k3s
  fi
  wait_ready
  log "K3s server ready on $NODE_IP. Version: $(k3s --version | head -n1)"
}

main "$@"
