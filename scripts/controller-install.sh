#!/bin/bash
set -e   # abort on first error, half-configured node worse than none

# Usage: k8s-setup controller install ENDPOINT [VERSION]
#   ENDPOINT: hostname or IP to bake into certs/kubeconfig as the cluster's
#             control-plane endpoint. Required - no safe default since it's
#             baked into certs. Use a DNS name (or a load balancer's address)
#             if you plan to grow into an HA control-plane later - see README.
#   VERSION:  "latest" (default) or explicit e.g. "1.33.0", "v1.33.0", "1.33"
usage() {
    echo "Usage: k8s-setup controller install ENDPOINT [VERSION]"
    echo "  ENDPOINT   Control-plane endpoint (hostname or IP). Required."
    echo "             Pass a DNS name or load balancer address to leave"
    echo "             room for HA later."
    echo "  VERSION    Kubernetes version to install."
    echo "             'latest' (default) fetches the latest stable release."
    echo "             Or give explicit version, e.g. 1.33.0, v1.33.0, 1.33"
    exit 1
}

case "$1" in
    -h|--help) usage ;;
esac

# Endpoint is required (no safe default - it's baked into certs/kubeconfig,
# see the HA note in README for why that choice matters).
if [[ -z "$1" ]]; then
    echo "Error: ENDPOINT (hostname or IP) is required." >&2
    usage
fi
CONTROL_PLANE_ENDPOINT="$1"

# Version arg lets you pin a cluster to a known-good release instead of
# always drifting to whatever is newest (kubeadm join / upgrade paths care
# about exact minor versions matching across nodes).
K8S_VERSION="${2:-latest}"

SCRIPT_START=$(date +%s)

if [[ "$K8S_VERSION" == "latest" ]]; then
    echo "Fetching latest stable Kubernetes version..."
    # dl.k8s.io/release/stable.txt is upstream's own pointer to the latest
    # stable GA release (e.g. v1.33.2) - avoids hardcoding a version here.
    K8S_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//')
else
    # strip an optional leading "v" so both "1.33.0" and "v1.33.0" work
    K8S_VERSION="${K8S_VERSION#v}"
fi

# The pkgs.k8s.io apt repo is split into per-minor channels (v1.33, v1.32, ...),
# there's no single "all versions" repo, so we need major.minor separately.
K8S_MINOR="$(echo "$K8S_VERSION" | cut -d. -f1,2)"
echo "Target Kubernetes version: $K8S_VERSION (channel v$K8S_MINOR)"
echo "Control-plane endpoint: $CONTROL_PLANE_ENDPOINT"

echo "Step 1: Install kubectl, kubeadm, and kubelet $K8S_VERSION"

# Prepare keyrings
# /etc/apt/keyrings is the apt-recommended location for repo signing keys
# (replaces the deprecated apt-key add flow).
sudo mkdir -p /etc/apt/keyrings
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Kubernetes repo (channel is major.minor only, e.g. v1.33)
# Import the repo's signing key so apt can verify package authenticity.
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
# Register the repo, pinned to the [signed-by=...] key above rather than
# trusting it globally.
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Refresh package index so apt knows about the repo just added
sudo apt-get update -y

# The k8s apt repo appends its own build revision to the version string
# (e.g. 1.33.0-1.1), so "kubeadm=1.33.0" alone won't match. Look up the
# exact package version string that starts with our requested version.
PKG_VERSION=$(apt-cache madison kubeadm | awk -v v="$K8S_VERSION" '$3 ~ "^"v"-" {print $3; exit}')
if [[ -z "$PKG_VERSION" ]]; then
    # Requested patch version isn't in this channel (e.g. already superseded
    # or typo'd) - fall back to whatever is newest in the same minor channel
    # instead of failing outright.
    echo "Exact package for $K8S_VERSION not found in v$K8S_MINOR channel, falling back to latest available in that channel."
    PKG_VERSION=$(apt-cache madison kubeadm | head -1 | awk '{print $3}')
fi
# Re-derive K8S_VERSION from the resolved package so kubeadm init/pull later
# (Step 4) always requests the version that's actually installed here.
K8S_VERSION=$(echo "$PKG_VERSION" | cut -d- -f1)
echo "Installing kubelet/kubeadm/kubectl $PKG_VERSION"

sudo apt-get install -y kubelet="$PKG_VERSION" kubeadm="$PKG_VERSION" kubectl="$PKG_VERSION" vim git curl wget
# Prevent unattended-upgrades / apt upgrade from silently bumping k8s
# components - version skew across a cluster breaks things.
sudo apt-mark hold kubelet kubeadm kubectl

echo "Step 2: Swap Off and Kernel Modules Setup"
# kubelet refuses to start with swap enabled (memory limits become
# unenforceable) - comment out swap entries in fstab so it stays off on reboot.
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo swapoff -a
# overlay: filesystem driver containerd uses for container image layers
# br_netfilter: lets iptables see bridged traffic, required for pod networking
sudo modprobe overlay
sudo modprobe br_netfilter

# Persist kernel modules so they're loaded again automatically after reboot
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# Kernel parameters for Kubernetes networking
# bridge-nf-call-iptables/ip6tables: let iptables filter/NAT bridged packets
#   between pods (without this, pod-to-pod traffic can bypass kube-proxy rules)
# ip_forward: lets the node route packets between interfaces, needed for
#   pod/service networking to work at all
cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params immediately (without this they'd only take effect on reboot)
sudo sysctl --system


echo "Step 3: Install and Configure Containerd"

# Check if containerd is already installed - skip reinstalling it so re-running
# this script on an already-provisioned node is safe/idempotent.
if ! command -v containerd &> /dev/null
then
    echo "Containerd not found, installing..."

    # Add Docker repo key and repository
    # containerd.io ships from Docker's apt repo, not the Kubernetes one.
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker-archive-keyring.gpg

    echo \
    "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y

    # --allow-downgrades / --allow-change-held-packages: avoids apt aborting
    # if a conflicting/held docker-related package already exists on the box.
    # Dpkg::Options::="--force-confold": keep any existing local config files
    # instead of prompting (script runs non-interactively).
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      -o Dpkg::Options::="--force-confold" \
      --allow-downgrades --allow-change-held-packages containerd.io
else
    echo "Containerd is already installed, skipping installation."
fi

# Always (re)configure containerd, even if it was already installed, so
# config stays consistent with what kubeadm expects below.
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# kubelet manages cgroups via systemd; containerd defaults to its own cgroup
# driver, and a mismatch between the two causes kubelet to fail on startup.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd


# Enable kubelet so it starts on boot (kubeadm init below starts it too, but
# this ensures it survives a reboot).
sudo systemctl enable kubelet

echo "Step 4: Pull Kubernetes images and init cluster"

# Pre-pull images first so `kubeadm init` doesn't stall/timeout on slow
# network pulls during the actual cluster bring-up.
sudo kubeadm config images pull --cri-socket unix:///run/containerd/containerd.sock --kubernetes-version "v${K8S_VERSION}"

# Initialize cluster
# --pod-network-cidr: must match what the CNI plugin (Flannel, step 5) expects
# --upload-certs: uploads control-plane certs to a Secret so additional
#   control-plane nodes can join later without manually copying certs
# --control-plane-endpoint: use hostname rather than a bare IP so the option
#   to grow into an HA control-plane behind a stable name stays open
# --ignore-preflight-errors=all: skip kubeadm's preflight checks (useful for
#   VMs/lab environments with non-standard resources); revisit before prod
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --kubernetes-version="v${K8S_VERSION}" \
  --control-plane-endpoint="$CONTROL_PLANE_ENDPOINT" \
  --ignore-preflight-errors=all \
  --cri-socket unix:///run/containerd/containerd.sock

# Setup kubeconfig for user - copy the admin credentials kubeadm generated
# into the invoking user's home so `kubectl` works without sudo afterwards.
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config

echo "Step 5: Apply Flannel Network"

# A fresh cluster has no CNI plugin - pods stay stuck in Pending/ContainerCreating
# without one. Flannel is applied here to match the pod-network-cidr above.
kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml

# By default kubeadm taints the control-plane node so regular pods can't be
# scheduled on it. Removed here for single-node clusters where the
# control-plane must also run workloads; leave the taint in place if you'll
# be joining worker nodes and want the control-plane workload-free.

read -p "Allow workload pods to schedule on this control-plane node? (single-node cluster: yes / joining workers later: no) [y/N]: " ALLOW_CP_WORKLOADS
if [[ "$ALLOW_CP_WORKLOADS" =~ ^[Yy]$ ]]; then
  kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-
fi

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
echo "Kubernetes cluster setup is complete! Runtime: $((ELAPSED / 60))m $((ELAPSED % 60))s"
