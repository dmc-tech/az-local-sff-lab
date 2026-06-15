#!/bin/bash
# Run on each worker node (NestedVM-02 / NestedVM-03) with sudo after the
# management node has a working K3s server.
#
# Requires environment variables (same contract as https://get.k3s.io):
#   K3S_URL   - e.g. https://192.168.100.100:6443 (reachable from this host)
#   K3S_TOKEN - from the server: sudo cat /var/lib/rancher/k3s/server/node-token
#
# Optional:
#   INSTALL_K3S_VERSION - pin to the same build as the server (recommended)
#
# Example:
#   export K3S_URL="https://192.168.100.100:6443"
#   export K3S_TOKEN="K10....::server:...."
#   sudo -E ./k3s-join-agent.sh
#
set -euo pipefail

log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    err "Run as root (e.g. sudo -E $0) so K3S_TOKEN from the environment is preserved."
  fi
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

  log "Installing K3s agent (INSTALL_K3S_SKIP_SELINUX_RPM=true)..."
  export INSTALL_K3S_SKIP_SELINUX_RPM=true
  export K3S_URL K3S_TOKEN
  if [[ -n "${INSTALL_K3S_VERSION:-}" ]]; then
    export INSTALL_K3S_VERSION
  else
    unset INSTALL_K3S_VERSION 2>/dev/null || true
  fi
  curl -sfL https://get.k3s.io | sh -s -

  log "Waiting for k3s-agent..."
  systemctl is-active --quiet k3s-agent || err "k3s-agent failed to start."
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
