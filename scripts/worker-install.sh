#!/bin/bash
set -e   # abort on first error, half-configured node worse than none

# Usage: k8s-setup worker install [VERSION] [options]
#   VERSION: "latest" (default) or explicit e.g. "1.33.0", "v1.33.0", "1.33"
#
# A worker gets the same runtime and node-level storage prerequisites as the
# control-plane, but no CNI or provisioner of its own - those are cluster-wide
# workloads the control-plane already deployed. Pick the same --cri and --csi
# here as you did there.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/cri.sh
. "$SCRIPT_DIR/lib/cri.sh"
# shellcheck source=lib/csi.sh
. "$SCRIPT_DIR/lib/csi.sh"

usage() {
    cat <<EOF
Usage: k8s-setup worker install [VERSION] [options]

  VERSION    Kubernetes version to install.
             'latest' (default) fetches the latest stable release.
             Or give an explicit version, e.g. 1.33.0, v1.33.0, 1.33
             Keep this in sync with the control-plane's version.

Options (each skips its interactive prompt):
  --cri=NAME   Container runtime: containerd | crio | docker
               Must match the runtime the control-plane was built with.
  --csi=NAME   Storage: none | local-path | nfs | longhorn
               Installs only this node's host-side prerequisites
               (nfs-common, open-iscsi); the provisioner itself is
               deployed once, from the control-plane.
  -y, --yes    Non-interactive: take the default for every prompt
  -h, --help   Show this help

Examples:
  k8s-setup worker install
  k8s-setup worker install 1.33.0 --cri=crio --csi=longhorn
EOF
    exit 1
}

parse_common_flags "$@"

# The pod network is a cluster-wide workload the control-plane deploys; a
# worker has nothing to do with it. Fail loudly rather than silently ignoring
# a flag someone reasonably expected to matter.
[[ -z "$CNI" ]] || die "--cni doesn't apply to a worker - the pod network is deployed once, from the control-plane."
[[ -z "$POD_CIDR" ]] || die "--pod-cidr doesn't apply to a worker - it's set by 'controller install'."

# Version arg lets you pin a node to a known-good release instead of always
# drifting to whatever is newest (kubeadm join / upgrade paths care about
# exact minor versions matching across nodes - keep this in sync with the
# control-plane's version).
resolve_k8s_version "${POSITIONAL[0]:-latest}"

SCRIPT_START=$(date +%s)

# Collect every choice up front so the run doesn't stop for input halfway
# through a long install.
cri_prompt
csi_prompt node-only

echo
log "Kubernetes:     $K8S_VERSION (apt channel v$K8S_MINOR)"
log "Runtime (CRI):  $CRI  ($CRI_SOCKET)"
log "Storage (CSI):  $CSI  (node prerequisites only)"
echo

if ! confirm "Proceed with this configuration?" Y; then
    echo "Aborted."
    exit 0
fi

log "Step 1: Install kubectl, kubeadm, and kubelet $K8S_VERSION"
install_k8s_packages

log "Step 2: Swap off and kernel module / sysctl setup"
prepare_node

log "Step 3: Install and configure the container runtime ($CRI)"
cri_install

log "Step 4: Install storage prerequisites ($CSI)"
csi_node_prereqs

# Enable kubelet so it starts on boot (kubeadm join later starts it too, but
# this ensures it survives a reboot).
sudo systemctl enable kubelet

log "Step 5: Pull Kubernetes images"

# Pre-pull images so a subsequent `kubeadm join` doesn't stall/timeout on
# slow network pulls when actually joining the cluster.
sudo kubeadm config images pull --cri-socket "$CRI_SOCKET" --kubernetes-version "v${K8S_VERSION}"

# Record what this node was built with so uninstall can undo exactly that.
state_save worker

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
echo "Worker node prep complete!"
echo "Join it with the command from 'k8s-setup controller join-command', adding: --cri-socket $CRI_SOCKET"
echo "Runtime: $((ELAPSED / 60))m $((ELAPSED % 60))s"
