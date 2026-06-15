#!/bin/bash
# Run on the K3s management / server node (NestedVM-01) with sudo. Installs
# K3s agents on the other two nested VMs over SSH using the same SELinux RPM
# skip as setup-k3s-arc.sh / k3s-join-agent.sh.
#
# Prerequisites:
#   - K3s server already installed and running on this host (setup-k3s-arc.sh).
#   - SSH private key on this host that can authenticate as SSH_USER to each
#     worker (default after Arc provisioning: clouduser).
#   - This script and k3s-join-agent.sh in the same directory (or set JOIN_SCRIPT).
#
# Usage:
#   export K3S_WORKER_IPS="192.168.100.101 192.168.100.102"
#   sudo -E ./bootstrap-k3s-agents.sh
#
# Optional environment:
#   K3S_URL              - override API URL shown to agents (default: https://<this host's 192.168.100.x>:6443)
#   SSH_USER             - default edgeuser
#   SSH_IDENTITY         - default $SUDO_HOME/.ssh/id_rsa or /root/.ssh/id_rsa or $HOME/.ssh/id_rsa
#   SSH_OPTS             - extra ssh/scp args, e.g. '-o StrictHostKeyChecking=accept-new'
#   JOIN_SCRIPT          - path to k3s-join-agent.sh (default: beside this script)
#   INSTALL_K3S_VERSION  - passed to workers to match server (auto-set from `k3s --version` when empty)
#
# --- One-time: copy these scripts from the Hyper-V host (Windows) to the management VM ---
# On the Azure VM (RDP/Bastion), open PowerShell. Install OpenSSH Client if needed
# (Settings -> Apps -> Optional features). Replace <MGMT_IP> with the management nested
# VM address (often 192.168.100.x from DHCP). Use your real repo or script path:
#
#   mkdir $env:USERPROFILE\k3s-stage -Force
#   scp C:\Scripts\bootstrap-k3s-agents.sh clouduser@<MGMT_IP>:~/k3s/
#   scp C:\Scripts\k3s-join-agent.sh clouduser@<MGMT_IP>:~/k3s/
#
# On the management Linux VM:
#   mkdir -p ~/k3s && chmod +x ~/k3s/bootstrap-k3s-agents.sh ~/k3s/k3s-join-agent.sh
#
# --- One-time: SSH private key on the management VM (for NestedVM-02 and NestedVM-03) ---
# bootstrap-k3s-agents.sh connects as SSH_USER (default edgeuser) to each worker IP.
# That user needs key-based SSH. Typical lab approach: reuse the same key pair the
# Hyper-V host uses with Get-SffNodeVoucher.ps1 if workers already trust it.
# From the Hyper-V host PowerShell (example paths from README):
#
#   scp C:\Users\azureadmin\.ssh\id_rsa edgeuser@<MGMT_IP>:~/.ssh/id_rsa_from_host
#   ssh edgeuser@<MGMT_IP> "chmod 600 ~/.ssh/id_rsa_from_host"
#
# Then on the management VM either merge into ~/.ssh/id_rsa or run bootstrap with:
#   export SSH_IDENTITY=$HOME/.ssh/id_rsa_from_host
#
# Alternative: generate a new key on the management node and append the new public key
# to ~/.ssh/authorized_keys on vm2 and vm3 (one-time access from the host with your
# existing key).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOIN_SCRIPT="${JOIN_SCRIPT:-$SCRIPT_DIR/k3s-join-agent.sh}"

log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

: "${K3S_WORKER_IPS:=}"
[[ -n "$K3S_WORKER_IPS" ]] || err "Set K3S_WORKER_IPS to the two worker IPs (space-separated), e.g. export K3S_WORKER_IPS='192.168.100.101 192.168.100.102'"

SSH_USER="${SSH_USER:-clouduser}"
SSH_OPTS="${SSH_OPTS:-}"

# When invoked via sudo, prefer the user who invoked sudo for key location.
effective_home="${SUDO_HOME:-}"
if [[ -z "$effective_home" && -n "${SUDO_USER:-}" ]]; then
  effective_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)
fi
effective_home="${effective_home:-$HOME}"
SSH_IDENTITY="${SSH_IDENTITY:-}"
if [[ -z "$SSH_IDENTITY" ]]; then
  for cand in "$effective_home/.ssh/id_rsa" "$effective_home/.ssh/id_ed25519" /root/.ssh/id_rsa; do
    if [[ -f "$cand" ]]; then
      SSH_IDENTITY="$cand"
      break
    fi
  done
fi
[[ -f "$SSH_IDENTITY" ]] || err "No SSH private key found. Set SSH_IDENTITY to a key that can reach $SSH_USER@<workers>."

[[ -f "$JOIN_SCRIPT" ]] || err "Join helper not found: $JOIN_SCRIPT (copy k3s-join-agent.sh next to this script or set JOIN_SCRIPT)."

check_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    err "Run as root (sudo -E $0) to read /var/lib/rancher/k3s/server/node-token."
  fi
}

detect_k3s_url() {
  if [[ -n "${K3S_URL:-}" ]]; then
    log "Using K3S_URL from environment: $K3S_URL"
    return
  fi
  local ip
  ip="$(ip -4 addr show 2>/dev/null | grep -oE 'inet 192\.168\.100\.[0-9]+' | awk '{print $2}' | head -n1 || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [[ -n "$ip" ]] || err "Could not determine this host's IP. Set K3S_URL explicitly."
  K3S_URL="https://${ip}:6443"
  log "Using K3S_URL=$K3S_URL (set K3S_URL to override if workers cannot reach this address)."
}

read_join_token() {
  local token_file="/var/lib/rancher/k3s/server/node-token"
  [[ -f "$token_file" ]] || err "Missing $token_file - is K3s server installed on this node?"
  K3S_TOKEN="$(tr -d '\n\r' <"$token_file")"
  [[ -n "$K3S_TOKEN" ]] || err "Empty node token in $token_file"
}

detect_install_version() {
  if [[ -n "${INSTALL_K3S_VERSION:-}" ]]; then
    return
  fi
  # Example line: k3s version v1.30.2+k3s1 (...)
  local ver
  ver="$(k3s --version 2>/dev/null | head -n1 | awk '{print $3}' || true)"
  if [[ -n "$ver" ]]; then
    INSTALL_K3S_VERSION="$ver"
    log "Pinning workers to INSTALL_K3S_VERSION=$INSTALL_K3S_VERSION (unset INSTALL_K3S_VERSION to use channel default)."
  else
    warn "Could not read k3s --version; workers will use install script default channel."
  fi
}

remote_join() {
  local target="$1"
  local q_url q_tok ver_prefix=""
  q_url=$(printf '%q' "$K3S_URL")
  q_tok=$(printf '%q' "$K3S_TOKEN")
  if [[ -n "${INSTALL_K3S_VERSION:-}" ]]; then
    ver_prefix="INSTALL_K3S_VERSION=$(printf '%q' "$INSTALL_K3S_VERSION") "
  fi
  log "Joining $SSH_USER@$target ..."
  # shellcheck disable=SC2086
  scp $SSH_OPTS -i "$SSH_IDENTITY" "$JOIN_SCRIPT" "${SSH_USER}@${target}:/tmp/k3s-join-agent.sh"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS -i "$SSH_IDENTITY" "${SSH_USER}@${target}" \
    "sudo env INSTALL_K3S_SKIP_SELINUX_RPM=true ${ver_prefix}K3S_URL=${q_url} K3S_TOKEN=${q_tok} bash /tmp/k3s-join-agent.sh; rm -f /tmp/k3s-join-agent.sh"
  log "Finished $target"
}

main() {
  echo "============================================================"
  echo "  K3s - bootstrap agents from management node"
  echo "============================================================"

  check_root
  systemctl is-active --quiet k3s || err "k3s server service is not active. Complete setup on this node first."

  detect_k3s_url
  read_join_token
  detect_install_version

  for ip in $K3S_WORKER_IPS; do
    remote_join "$ip"
  done

  log "All workers processed. Verify: kubectl get nodes -o wide"
}

main "$@"
