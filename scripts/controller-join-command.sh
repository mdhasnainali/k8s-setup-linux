#!/bin/bash
set -e   # abort on first error, half-printed command worse than none

# Usage: k8s-setup controller join-command
# Run on control-plane node. Prints kubeadm join command worker nodes need
# to run to join cluster. Token/cert-hash expire (default 24h) - re-run
# this command to get fresh output if old one stops working.

if ! command -v kubeadm &> /dev/null
then
    echo "Error: kubeadm not found. Run this on control-plane node." >&2
    exit 1
fi

echo "Generating new bootstrap token and join command..."
echo ""

JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)

# kubeadm omits --cri-socket from the printed command, and it's only optional
# when exactly one runtime is detectable on the joining node. Append the socket
# this cluster was built with so CRI-O / cri-dockerd nodes join cleanly too.
STATE_FILE="/etc/k8s-setup/node.conf"
if [[ -r "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    if [[ -n "${K8S_SETUP_CRI_SOCKET:-}" && "$JOIN_COMMAND" != *--cri-socket* ]]; then
        JOIN_COMMAND="$JOIN_COMMAND --cri-socket $K8S_SETUP_CRI_SOCKET"
    fi
fi

echo "=================================================================="
echo " Worker join command (valid ~24h from now):"
echo "=================================================================="
echo ""
echo "  $JOIN_COMMAND"
echo ""
echo "=================================================================="
echo " Run above command with sudo on worker node to join cluster."
echo "=================================================================="
