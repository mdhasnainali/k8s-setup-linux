#!/bin/bash
# Pod network (CNI) selection and installation. Sourced by controller-install.sh
# after lib/common.sh.
#
# A fresh cluster has no CNI plugin, so pods sit in Pending/ContainerCreating
# until one is applied. The choice also decides the pod CIDR handed to
# `kubeadm init`, which is why cni_prompt has to run before init, and cni_apply
# after it.

CNI_CHOICES=(
    "flannel|Flannel - simple VXLAN overlay, no NetworkPolicy"
    "calico|Calico - NetworkPolicy support, BGP or overlay"
    "cilium|Cilium - eBPF dataplane, NetworkPolicy and observability"
    "none|Skip - install a CNI yourself after init"
)
CNI_DEFAULT="calico"

cni_prompt() {
    if [[ -n "$CNI" ]]; then
        validate_choice "--cni" "$CNI" "${CNI_CHOICES[@]}"
    else
        CNI=$(prompt_choice "Select a pod network add-on (CNI):" "$CNI_DEFAULT" "${CNI_CHOICES[@]}")
    fi
    # --pod-cidr wins if given; otherwise take whatever the plugin expects.
    [[ -n "$POD_CIDR" ]] || POD_CIDR=$(_cni_default_pod_cidr "$CNI")
}

_cni_default_pod_cidr() {
    case "$1" in
        # Flannel's manifest hardcodes this; Cilium is told to use it below.
        flannel|cilium|none) echo "10.244.0.0/16" ;;
        # Calico's documented default pool.
        calico)              echo "192.168.0.0/16" ;;
        *) die "unknown CNI: $1" ;;
    esac
}

cni_apply() {
    case "$CNI" in
        flannel) _cni_apply_flannel ;;
        calico)  _cni_apply_calico ;;
        cilium)  _cni_apply_cilium ;;
        none)
            warn "No CNI installed. Pods stay Pending until you apply one."
            warn "The cluster was initialised with --pod-network-cidr=${POD_CIDR}."
            ;;
        *) die "unknown CNI: $CNI" ;;
    esac
}

_cni_apply_flannel() {
    log "Applying Flannel (pod CIDR ${POD_CIDR})"
    # The manifest hardcodes 10.244.0.0/16 in its net-conf.json, so rewrite it
    # when the user asked for a different CIDR.
    curl -fsSL "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml" \
        | sed "s#10\.244\.0\.0/16#${POD_CIDR}#g" \
        | kubectl apply -f -
}

_cni_apply_calico() {
    local version base i
    version=$(curl -fsSL "https://api.github.com/repos/projectcalico/calico/releases/latest" \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ -n "$version" ]] || die "could not determine the latest Calico release"
    base="https://raw.githubusercontent.com/projectcalico/calico/${version}/manifests"

    log "Installing Calico ${version} via the Tigera operator (pod CIDR ${POD_CIDR})"
    # `create`, not `apply`: the CRD bundle exceeds apply's annotation size limit.
    kubectl create -f "${base}/operator-crds.yaml"
    kubectl create -f "${base}/tigera-operator.yaml"

    # Pool pinned to the CIDR kubeadm init used; VXLANCrossSubnet works on any L2/L3 network.
    kubectl create -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

    log "Waiting for Calico to become ready..."
    # tigerastatus objects appear only after the operator reconciles them.
    for i in $(seq 60); do
        kubectl get tigerastatus calico &> /dev/null && break
        sleep 5
    done
    kubectl wait --for=condition=Available tigerastatus --all --timeout=600s \
        || warn "Calico not Available yet; check: kubectl get tigerastatus"
}

_cni_apply_cilium() {
    local version arch tmp
    if ! command -v cilium &> /dev/null; then
        arch="$(host_arch)"
        version=$(curl -fsSL "https://api.github.com/repos/cilium/cilium-cli/releases/latest" \
            | grep -m1 '"tag_name"' | cut -d'"' -f4)
        [[ -n "$version" ]] || die "could not determine the latest cilium-cli release"

        log "Installing cilium CLI ${version}..."
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/cilium.tar.gz" \
            "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-linux-${arch}.tar.gz"
        tar -xzf "$tmp/cilium.tar.gz" -C "$tmp"
        sudo install -m 0755 "$tmp/cilium" /usr/local/bin/cilium
        rm -rf "$tmp"
    fi

    log "Installing Cilium (pod CIDR ${POD_CIDR})"
    # Cilium's cluster-pool IPAM defaults to 10.0.0.0/8, which wouldn't match
    # what kubeadm init was told - pin it to the same CIDR.
    cilium install \
        --set ipam.mode=cluster-pool \
        --set "ipam.operator.clusterPoolIPv4PodCIDRList={${POD_CIDR}}"
    cilium status --wait
}

# Interfaces and on-disk state the plugins leave behind; kubeadm reset doesn't
# clear these, and stale ones break the next cluster built on the same node.
cni_cleanup() {
    sudo rm -rf /etc/cni/net.d /var/lib/cni
    local link
    for link in cni0 flannel.1 vxlan.calico tunl0 cilium_host cilium_net cilium_vxlan; do
        sudo ip link delete "$link" 2>/dev/null || true
    done
}
