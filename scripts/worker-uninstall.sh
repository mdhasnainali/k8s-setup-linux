#!/bin/bash
set -e   # abort on first error, half-cleaned node worse than none

# Usage: k8s-setup worker uninstall
# Reverses worker-install.sh: resets kubeadm, purges kubelet/kubeadm/kubectl
# and (optionally) the container runtime, removes repos/keys/config, restores
# swap, and drops the sysctl/kernel-module changes made for pod networking.
#
# Which runtime to undo is read from the state file that install wrote; if
# that's missing you get asked.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/cri.sh
. "$SCRIPT_DIR/lib/cri.sh"
# shellcheck source=lib/cni.sh
. "$SCRIPT_DIR/lib/cni.sh"

usage() {
    cat <<EOF
Usage: k8s-setup worker uninstall [options]

  Tears down a worker node set up by 'k8s-setup worker install'.
  Run as the regular (non-root) user - the script uses sudo internally.

Options:
  --cri=NAME   Runtime to tear down: containerd | crio | docker
               Only needed when $K8S_SETUP_STATE_FILE is missing.
  -y, --yes    Non-interactive. Confirms the reset but keeps the runtime
               installed; pass --purge-runtime to remove it too.
  --purge-runtime
               Also purge the container runtime and its repo/keys.
  -h, --help   Show this help
EOF
    exit 1
}

PURGE_RUNTIME=""
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --purge-runtime) PURGE_RUNTIME=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
parse_common_flags "${ARGS[@]+"${ARGS[@]}"}"

# Prefer what install recorded; fall back to a flag, then to a prompt.
if state_load; then
    CRI="${CRI:-$K8S_SETUP_CRI}"
    log "Read node configuration from $K8S_SETUP_STATE_FILE (CRI: ${CRI:-unknown})"
else
    warn "No $K8S_SETUP_STATE_FILE found - this node may predate it."
    [[ -n "$CRI" ]] || CRI=$(prompt_choice "Which container runtime is installed?" "$CRI_DEFAULT" "${CRI_CHOICES[@]}")
fi
[[ -n "$CRI" ]] || CRI="$CRI_DEFAULT"
validate_choice "--cri" "$CRI" "${CRI_CHOICES[@]}"
# Recompute rather than trust a stale value if the state file was hand-edited.
CRI_SOCKET=$(cri_socket "$CRI")

# Interactively this defaults to "no" - it's destructive. -y is an explicit
# opt-in to the teardown, so it doesn't get to fall through to that default.
if [[ "$ASSUME_YES" == true ]]; then
    log "Non-interactive mode: proceeding with teardown."
elif ! confirm "This will reset kubeadm and remove Kubernetes from this node. Continue?" N; then
    echo "Aborted."
    exit 0
fi

if [[ -z "$PURGE_RUNTIME" ]]; then
    if confirm "Also purge the container runtime ($CRI) and its repo/keys?" N; then
        PURGE_RUNTIME=true
    else
        PURGE_RUNTIME=false
        echo "Skipping runtime removal - $CRI stays installed."
    fi
fi

SCRIPT_START=$(date +%s)

log "Step 1: kubeadm reset"
# Tears down kubelet state and removes /etc/kubernetes, undoing a prior
# `kubeadm join` (if one was run). --cri-socket must match what join used,
# else reset can't find/stop the right sandbox.
if command -v kubeadm &> /dev/null; then
    sudo kubeadm reset -f --cri-socket "$CRI_SOCKET"
else
    echo "kubeadm not found, skipping kubeadm reset."
fi

log "Step 2: Remove CNI leftovers"
# CNI plugin state gets written to this worker once it joins a cluster -
# not removed by kubeadm reset.
cni_cleanup

log "Step 3: Remove iptables/ipvs rules left by kube-proxy"
# kubeadm reset doesn't flush these - stale rules can interfere with a
# future join on the same node.
if command -v iptables &> /dev/null; then
    sudo iptables -F
    sudo iptables -t nat -F
    sudo iptables -t mangle -F
    sudo iptables -X
fi

log "Step 4: Purge kubelet, kubeadm, kubectl"
if dpkg -l | grep -qE '^[hi]i\s+(kubelet|kubeadm|kubectl)\s'; then
    # Packages are held (apt-mark hold in setup) - unhold before purge so
    # apt will actually remove them instead of refusing.
    sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    sudo apt-get purge -y kubelet kubeadm kubectl
else
    echo "kubelet/kubeadm/kubectl not installed, skipping."
fi

log "Step 5: Purge the container runtime ($CRI) and its config"
if [ "$PURGE_RUNTIME" = true ]; then
    cri_purge "$CRI"
else
    echo "Skipped (keeping the container runtime installed)."
fi

log "Step 6: Remove Kubernetes apt repo/keys"
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
if [ "$PURGE_RUNTIME" = true ]; then
    sudo rm -f /etc/apt/sources.list.d/docker*.list
    sudo rm -f /etc/apt/sources.list.d/docker*.sources
    sudo rm -f /etc/apt/keyrings/docker-archive-keyring.gpg
fi
sudo apt-get update -y

log "Step 7: Restore swap and kernel/sysctl changes"
# Uncomment swap lines that setup commented out in /etc/fstab.
sudo sed -i -E '/^#.* swap /s/^#//' /etc/fstab
sudo swapon -a || echo "No swap device to re-enable (or already enabled)."

# containerd.conf is the name older versions of this script used.
sudo rm -f /etc/modules-load.d/kubernetes.conf /etc/modules-load.d/containerd.conf
sudo rm -f /etc/sysctl.d/kubernetes.conf
sudo sysctl --system > /dev/null

log "Step 8: Remove the k8s-setup state file"
sudo rm -rf "$K8S_SETUP_STATE_DIR"

log "Step 9: Autoremove unused dependencies"
sudo apt-get autoremove -y

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
echo "Cleanup complete! Runtime: $((ELAPSED / 60))m $((ELAPSED % 60))s"
