#!/bin/bash
# Run on each worker node (NestedVM-02 / NestedVM-03) with sudo after the
# management node has a working K3s server.
#
# Requires environment variables (same contract as https://get.k3s.io):
#   K3S_URL   - e.g. https://192.168.100.100:6443 (reachable from this host)
#   K3S_TOKEN - from the server: sudo cat /var/lib/rancher/k3s/server/node-token
#
# Both can instead be placed in ENV_FILE (default /tmp/k3s-lab/k3s.env), which
# is sourced when present; Deploy-K3sCluster.ps1 uses this so the token never
# appears on a command line.
#
# Optional:
#   INSTALL_K3S_VERSION - pin to the same build as the server (recommended)
#   NODE_IP             - IP the agent advertises (default: first 192.168.100.x address)
#   NODE_NAME           - override node name (default: hostname)
#   READY_TIMEOUT       - seconds to wait for k3s-agent to become active (default 180)
#
# Example:
#   export K3S_URL="https://192.168.100.100:6443"
#   export K3S_TOKEN="K10....::server:...."
#   sudo -E ./k3s-join-agent.sh
#
set -euo pipefail

# The K3s installer uses /opt/bin when /usr/local/bin is read-only; sudo may not have either on PATH.
export PATH="$PATH:/usr/local/bin:/opt/bin"

ENV_FILE="${ENV_FILE:-/tmp/k3s-lab/k3s.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
READY_TIMEOUT="${READY_TIMEOUT:-180}"

log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    err "Run as root (e.g. sudo -E $0) so K3S_TOKEN from the environment is preserved."
  fi
}

detect_node_ip() {
  if [[ -n "${NODE_IP:-}" ]]; then
    return
  fi
  NODE_IP="$(ip -4 addr show 2>/dev/null | grep -oE 'inet 192\.168\.100\.[0-9]+' | awk '{print $2}' | head -n1 || true)"
}

join_k3s_agent() {
  [[ -n "${K3S_URL:-}" ]]  || err "Set K3S_URL (e.g. https://<management-ip>:6443)."
  [[ -n "${K3S_TOKEN:-}" ]] || err "Set K3S_TOKEN from the management node."

  if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    warn "k3s-agent is already active. Nothing to do."
    return 0
  fi

  if systemctl is-active --quiet k3s 2>/dev/null; then
    err "This host is running the k3s server service (k3s). Join agents only on worker nodes."
  fi

  detect_node_ip
  local exec_args="agent"
  [[ -n "${NODE_IP:-}" ]]   && exec_args="$exec_args --node-ip ${NODE_IP}"
  [[ -n "${NODE_NAME:-}" ]] && exec_args="$exec_args --node-name ${NODE_NAME}"

  log "Installing K3s agent (INSTALL_K3S_SKIP_SELINUX_RPM=true, exec: $exec_args)..."
  export INSTALL_K3S_SKIP_SELINUX_RPM=true
  export INSTALL_K3S_EXEC="$exec_args"
  export K3S_URL K3S_TOKEN
  if [[ -n "${INSTALL_K3S_VERSION:-}" ]]; then
    export INSTALL_K3S_VERSION
  else
    unset INSTALL_K3S_VERSION 2>/dev/null || true
  fi
  curl -sfL https://get.k3s.io | sh -s -

  log "Waiting up to ${READY_TIMEOUT}s for k3s-agent..."
  local deadline=$((SECONDS + READY_TIMEOUT))
  until systemctl is-active --quiet k3s-agent; do
    (( SECONDS < deadline )) || err "k3s-agent failed to start. Check: journalctl -u k3s-agent -n 200"
    sleep 5
  done
  log "Joined cluster. On the management node run: kubectl get nodes"
}

main() {
  echo "============================================================"
  echo "  K3s agent join (get.k3s.io)"
  echo "============================================================"
  check_root
  join_k3s_agent
}

main "$@"
