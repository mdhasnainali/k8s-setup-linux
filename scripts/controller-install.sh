#!/bin/bash
set -e   # abort on first error, half-configured node worse than none

# Usage: k8s-setup controller install ENDPOINT [VERSION] [options]
#   ENDPOINT: hostname or IP to bake into certs/kubeconfig as the cluster's
#             control-plane endpoint. Required - no safe default since it's
#             baked into certs. Use a DNS name (or a load balancer's address)
#             if you plan to grow into an HA control-plane later - see README.
#   VERSION:  "latest" (default) or explicit e.g. "1.33.0", "v1.33.0", "1.33"
#
# The CRI/CNI/CSI choices are prompted for interactively; the matching flags
# below skip the prompt, and -y takes every default without asking.

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/cri.sh
. "$SCRIPT_DIR/lib/cri.sh"
# shellcheck source=lib/cni.sh
. "$SCRIPT_DIR/lib/cni.sh"
# shellcheck source=lib/csi.sh
. "$SCRIPT_DIR/lib/csi.sh"

usage() {
    cat <<EOF
Usage: k8s-setup controller install ENDPOINT [VERSION] [options]

  ENDPOINT   Control-plane endpoint (hostname or IP). Required.
             Pass a DNS name or load balancer address to leave room for HA later.
  VERSION    Kubernetes version to install.
             'latest' (default) fetches the latest stable release.
             Or give an explicit version, e.g. 1.33.0, v1.33.0, 1.33

Options (each skips its interactive prompt):
  --cri=NAME        Container runtime: containerd | crio | docker
  --cni=NAME        Pod network:       flannel | calico | cilium | none
  --csi=NAME        Storage:           none | local-path | nfs | longhorn
  --pod-cidr=CIDR   Override the pod network CIDR the CNI choice implies
  --nfs-server=HOST NFS server, required with --csi=nfs
  --nfs-path=PATH   NFS export path, required with --csi=nfs
  -y, --yes         Non-interactive: take the default for every prompt
  -h, --help        Show this help

Examples:
  k8s-setup controller install k8s.example.com
  k8s-setup controller install 10.0.0.5 1.33.0 --cri=crio --cni=calico
  k8s-setup controller install k8s.example.com --cni=cilium --csi=local-path -y
EOF
    exit 1
}

parse_common_flags "$@"

# Endpoint is required (no safe default - it's baked into certs/kubeconfig,
# see the HA note in README for why that choice matters).
if [[ ${#POSITIONAL[@]} -lt 1 || -z "${POSITIONAL[0]}" ]]; then
    echo "Error: ENDPOINT (hostname or IP) is required." >&2
    usage
fi
CONTROL_PLANE_ENDPOINT="${POSITIONAL[0]}"

# Version arg lets you pin a cluster to a known-good release instead of
# always drifting to whatever is newest (kubeadm join / upgrade paths care
# about exact minor versions matching across nodes).
resolve_k8s_version "${POSITIONAL[1]:-latest}"

SCRIPT_START=$(date +%s)

# Collect every choice up front so the run doesn't stop for input halfway
# through a long install.
cri_prompt
cni_prompt
csi_prompt

echo
log "Kubernetes:     $K8S_VERSION (apt channel v$K8S_MINOR)"
log "Endpoint:       $CONTROL_PLANE_ENDPOINT"
log "Runtime (CRI):  $CRI  ($CRI_SOCKET)"
log "Network (CNI):  $CNI  (pod CIDR $POD_CIDR)"
log "Storage (CSI):  $CSI${NFS_SERVER:+  (${NFS_SERVER}:${NFS_PATH})}"
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

# Enable kubelet so it starts on boot (kubeadm init below starts it too, but
# this ensures it survives a reboot).
sudo systemctl enable kubelet

log "Step 5: Pull Kubernetes images and init cluster"

# Pre-pull images first so `kubeadm init` doesn't stall/timeout on slow
# network pulls during the actual cluster bring-up.
sudo kubeadm config images pull --cri-socket "$CRI_SOCKET" --kubernetes-version "v${K8S_VERSION}"

# Initialize cluster
# --pod-network-cidr: matches what the chosen CNI plugin expects (step 7)
# --upload-certs: uploads control-plane certs to a Secret so additional
#   control-plane nodes can join later without manually copying certs
# --control-plane-endpoint: use hostname rather than a bare IP so the option
#   to grow into an HA control-plane behind a stable name stays open
# --ignore-preflight-errors=all: skip kubeadm's preflight checks (useful for
#   VMs/lab environments with non-standard resources); revisit before prod
sudo kubeadm init \
  --pod-network-cidr="$POD_CIDR" \
  --upload-certs \
  --kubernetes-version="v${K8S_VERSION}" \
  --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" \
  --ignore-preflight-errors=all \
  --cri-socket "$CRI_SOCKET"

log "Step 6: Set up kubeconfig"
# Copy the admin credentials kubeadm generated into the invoking user's home
# so `kubectl` works without sudo afterwards.
mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

log "Step 7: Apply the pod network ($CNI)"
cni_apply

log "Step 8: Deploy the storage provisioner ($CSI)"
csi_apply

# Record what this node was built with so uninstall can undo exactly that.
state_save controller

# By default kubeadm taints the control-plane node so regular pods can't be
# scheduled on it. Removing it is right for single-node clusters where the
# control-plane must also run workloads; leave it in place if you'll be
# joining worker nodes and want the control-plane workload-free.
if confirm "Allow workload pods to schedule on this control-plane node? (single-node cluster: yes / joining workers later: no)" N; then
    kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule-
fi

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
echo "Kubernetes cluster setup is complete! Runtime: $((ELAPSED / 60))m $((ELAPSED % 60))s"
