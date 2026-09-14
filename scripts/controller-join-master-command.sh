#!/bin/bash
set -e   # abort on first error, half-printed command worse than none

# Usage: k8s-setup controller join-master-command
# Run on an existing, healthy control-plane node. Prints kubeadm join
# command for a NEW control-plane (master) node, including the
# certificate key needed to join as control-plane rather than worker.
# Token/cert-hash expire (default 24h), certificate key expires (default 2h)
# - re-run this command to get fresh output if old one stops working.

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

echo "Uploading cluster certificates to generate certificate key..."
echo ""

CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n1)

MASTER_JOIN_COMMAND="$JOIN_COMMAND --control-plane --certificate-key $CERT_KEY"

echo "=================================================================="
echo " Master (control-plane) join command:"
echo " (token/cert-hash valid ~24h, certificate key valid ~2h from now)"
echo "=================================================================="
echo ""
echo "  $MASTER_JOIN_COMMAND"
echo ""
echo "=================================================================="
echo " Run above command with sudo on new control-plane node to join"
echo " cluster as master."
echo "=================================================================="
