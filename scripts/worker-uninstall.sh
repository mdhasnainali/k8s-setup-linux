#!/bin/bash
set -e   # abort on first error, half-cleaned node worse than none

# Usage: k8s-setup worker uninstall
# Reverses worker-install.sh: resets kubeadm, purges kubelet/kubeadm/kubectl/
# containerd, removes repos/keys/config, restores swap, and drops the
# sysctl/kernel-module changes made for pod networking.
usage() {
    echo "Usage: k8s-setup worker uninstall"
    echo "  Tears down a worker node set up by 'k8s-setup worker install'."
    echo "  Run as the regular (non-root) user - script uses sudo internally."
    exit 1
}

case "$1" in
    -h|--help) usage ;;
esac

read -p "This will reset kubeadm and remove Kubernetes from this node. Continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

read -p "Also purge containerd (container runtime) and its repo/keys? [y/N]: " REMOVE_RUNTIME
if [[ "$REMOVE_RUNTIME" =~ ^[Yy]$ ]]; then
    PURGE_RUNTIME=true
else
    PURGE_RUNTIME=false
    echo "Skipping containerd removal - runtime stays installed."
fi

SCRIPT_START=$(date +%s)

echo "Step 1: kubeadm reset"
# Tears down kubelet state and removes /etc/kubernetes, undoing a prior
# `kubeadm join` (if one was run). --cri-socket must match what join used,
# else reset can't find/stop the right containerd sandbox.
if command -v kubeadm &> /dev/null; then
    sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
else
    echo "kubeadm not found, skipping kubeadm reset."
fi

echo "Step 2: Remove CNI leftovers"
# CNI plugin state gets written to this worker once it joins a cluster -
# not removed by kubeadm reset.
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni
sudo ip link delete cni0 2>/dev/null || true
sudo ip link delete flannel.1 2>/dev/null || true

echo "Step 3: Remove iptables/ipvs rules left by kube-proxy"
# kubeadm reset doesn't flush these - stale rules can interfere with a
# future join on the same node.
if command -v iptables &> /dev/null; then
    sudo iptables -F
    sudo iptables -t nat -F
    sudo iptables -t mangle -F
    sudo iptables -X
fi

echo "Step 4: Purge kubelet, kubeadm, kubectl"
if dpkg -l | grep -qE '^[hi]i\s+(kubelet|kubeadm|kubectl)\s'; then
    # Packages are held (apt-mark hold in setup) - unhold before purge so
    # apt will actually remove them instead of refusing.
    sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    sudo apt-get purge -y kubelet kubeadm kubectl
else
    echo "kubelet/kubeadm/kubectl not installed, skipping."
fi

echo "Step 5: Purge containerd and its config"
if [ "$PURGE_RUNTIME" = true ]; then
    if dpkg -l | grep -q '^ii\s\+containerd.io'; then
        sudo systemctl stop containerd 2>/dev/null || true
        sudo apt-get purge -y containerd.io
    else
        echo "containerd.io not installed, skipping."
    fi
    sudo rm -rf /etc/containerd
    sudo rm -rf /var/lib/containerd
else
    echo "Skipped (user opted to keep container runtime)."
fi

echo "Step 6: Remove Kubernetes apt repo/keys"
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
if [ "$PURGE_RUNTIME" = true ]; then
    sudo rm -f /etc/apt/sources.list.d/docker*.list
    sudo rm -f /etc/apt/sources.list.d/docker*.sources
    sudo rm -f /etc/apt/keyrings/docker-archive-keyring.gpg
fi
sudo apt-get update -y

echo "Step 7: Restore swap and kernel/sysctl changes"
# Uncomment swap lines that setup commented out in /etc/fstab.
sudo sed -i -E '/^#.* swap /s/^#//' /etc/fstab
sudo swapon -a || echo "No swap device to re-enable (or already enabled)."

sudo rm -f /etc/modules-load.d/containerd.conf
sudo rm -f /etc/sysctl.d/kubernetes.conf
sudo sysctl --system > /dev/null

echo "Step 8: Autoremove unused dependencies"
sudo apt-get autoremove -y

SCRIPT_END=$(date +%s)
ELAPSED=$((SCRIPT_END - SCRIPT_START))
echo "Cleanup complete! Runtime: $((ELAPSED / 60))m $((ELAPSED % 60))s"
