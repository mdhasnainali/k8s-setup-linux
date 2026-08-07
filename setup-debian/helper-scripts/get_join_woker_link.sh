#!/bin/bash
set -e   # abort on first error, half-printed command worse than none

# Usage: ./get_join_woker_link.sh
# Run on control-plane node. Prints kubeadm join command worker nodes need
# to run to join cluster. Token/cert-hash expire (default 24h) - re-run
# this script to get fresh command if old one stops working.

if ! command -v kubeadm &> /dev/null
then
    echo "Error: kubeadm not found. Run this on control-plane node." >&2
    exit 1
fi

echo "Generating new bootstrap token and join command..."
echo ""

JOIN_COMMAND=$(sudo kubeadm token create --print-join-command)

echo "=================================================================="
echo " Worker join command (valid ~24h from now):"
echo "=================================================================="
echo ""
echo "  $JOIN_COMMAND"
echo ""
echo "=================================================================="
echo " Run above command with sudo on worker node to join cluster."
echo "=================================================================="
