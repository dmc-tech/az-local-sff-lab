#!/bin/bash
# Prepares an Azure Local SFF nested VM (NestedVM-0x) for K3s. Run with sudo on
# every node before installing the K3s server or agent. Safe to re-run.
#
# Called automatically by Deploy-K3sCluster.ps1 on the Hyper-V host; can also
# be run by hand:
#   sudo NODE_CIDR=192.168.100.0/24 bash ./k3s-node-prep.sh
#
# What it does:
#   1. Loads the overlay / br_netfilter kernel modules (persisted when /etc is writable)
#   2. Enables IPv4 forwarding and bridge netfilter sysctls (persisted when writable)
#   3. Opens the host firewall for cluster traffic (firewalld, or iptables when the
#      INPUT chain defaults to DROP/REJECT as on Azure Linux based images)
#   4. Verifies outbound HTTPS to the K3s download endpoints
#
# Optional environment:
#   NODE_CIDR         - node subnet allowed in by the firewall (default 192.168.100.0/24)
#   CLUSTER_CIDR      - K3s pod CIDR (default 10.42.0.0/16)
#   SERVICE_CIDR      - K3s service CIDR (default 10.43.0.0/16)
#   SKIP_EGRESS_CHECK - true to skip the outbound HTTPS check
#
set -euo pipefail

NODE_CIDR="${NODE_CIDR:-192.168.100.0/24}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.43.0.0/16}"
SKIP_EGRESS_CHECK="${SKIP_EGRESS_CHECK:-false}"

log()  { echo -e "\n\033[1;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\n\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    err "Run as root (sudo bash $0)."
  fi
}

# Writes a file only when its directory is writable (parts of the SFF image are read-only).
write_if_possible() {
  local path="$1" content="$2"
  if mkdir -p "$(dirname "$path")" 2>/dev/null && printf '%s\n' "$content" >"$path" 2>/dev/null; then
    log "Persisted $path"
  else
    warn "Could not write $path (read-only filesystem?). Setting applies until next reboot only."
  fi
}

load_kernel_modules() {
  log "Step 1/4 - Loading kernel modules (overlay, br_netfilter)..."
  local m
  for m in overlay br_netfilter; do
    if modprobe "$m" 2>/dev/null; then
      log "Loaded $m"
    else
      warn "modprobe $m failed (may be built into the kernel)."
    fi
  done
  write_if_possible /etc/modules-load.d/k3s.conf "$(printf 'overlay\nbr_netfilter')"
}

configure_sysctl() {
  log "Step 2/4 - Configuring sysctl for Kubernetes networking..."
  local settings=(
    "net.ipv4.ip_forward=1"
    "net.bridge.bridge-nf-call-iptables=1"
    "net.bridge.bridge-nf-call-ip6tables=1"
  )
  local s
  for s in "${settings[@]}"; do
    sysctl -w "$s" >/dev/null 2>&1 || warn "sysctl -w $s failed"
  done
  write_if_possible /etc/sysctl.d/90-k3s.conf "$(printf '%s\n' "${settings[@]}")"
}

configure_firewall() {
  log "Step 3/4 - Opening host firewall for cluster traffic..."

  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    log "firewalld is active - adding trusted sources $NODE_CIDR $CLUSTER_CIDR $SERVICE_CIDR"
    local src
    for src in "$NODE_CIDR" "$CLUSTER_CIDR" "$SERVICE_CIDR"; do
      firewall-cmd --permanent --zone=trusted --add-source="$src" >/dev/null
    done
    firewall-cmd --permanent --add-port=6443/tcp >/dev/null
    firewall-cmd --reload >/dev/null
    return
  fi

  if ! command -v iptables &>/dev/null; then
    log "No firewalld or iptables found - nothing to open."
    return
  fi

  # Azure Linux based images ship an iptables service whose INPUT policy is DROP
  # with only SSH allowed. That silently blocks 6443 (API), 10250 (kubelet),
  # 8472/udp (flannel VXLAN) and 2379-2380 (etcd), so allow the cluster ranges.
  local policy
  policy="$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/ {print $3}')"
  if [[ "$policy" != "DROP" ]] && ! iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
    log "iptables INPUT policy is '${policy:-unknown}' with no REJECT rules - no changes needed."
    return
  fi

  log "iptables INPUT is restrictive (policy ${policy}) - inserting ACCEPT rules for cluster ranges."
  local src
  for src in "$NODE_CIDR" "$CLUSTER_CIDR" "$SERVICE_CIDR"; do
    iptables -C INPUT -s "$src" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -s "$src" -j ACCEPT
  done
  iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -C FORWARD -s "$CLUSTER_CIDR" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s "$CLUSTER_CIDR" -j ACCEPT
  iptables -C FORWARD -d "$CLUSTER_CIDR" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d "$CLUSTER_CIDR" -j ACCEPT

  # Persist before K3s adds its own chains so only the base rules are saved.
  local save_file=""
  for save_file in /etc/systemd/scripts/ip4save /etc/sysconfig/iptables; do
    if [[ -f "$save_file" ]]; then
      if iptables-save >"$save_file" 2>/dev/null; then
        log "Saved iptables rules to $save_file"
      else
        warn "Could not persist rules to $save_file; re-run this script after a reboot."
      fi
      return
    fi
  done
  warn "No known iptables save file found; rules apply until next reboot. Re-run this script after a reboot."
}

check_egress() {
  log "Step 4/4 - Checking outbound HTTPS to K3s download endpoints..."
  if [[ "$SKIP_EGRESS_CHECK" == "true" ]]; then
    warn "SKIP_EGRESS_CHECK=true - skipping."
    return
  fi
  command -v curl &>/dev/null || err "curl is required by the K3s installer but was not found."
  local url
  for url in https://get.k3s.io https://update.k3s.io/v1-release/channels https://github.com; do
    if curl -sS -o /dev/null --max-time 20 "$url"; then
      log "Reachable: $url"
    else
      err "Cannot reach $url. The node needs outbound HTTPS (via the host NAT) to install K3s."
    fi
  done
}

main() {
  echo "============================================================"
  echo "  K3s node preparation ($(hostname))"
  echo "============================================================"
  check_root
  load_kernel_modules
  configure_sysctl
  configure_firewall
  check_egress
  log "Node preparation complete."
}

main "$@"
