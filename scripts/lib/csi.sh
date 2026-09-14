#!/bin/bash
# Storage (CSI) selection and installation. Sourced by the install scripts
# after lib/common.sh.
#
# Split in two halves on purpose: csi_node_prereqs installs the host packages
# every node needs (workers included), while csi_apply deploys the provisioner
# and runs only on the control-plane.

CSI_CHOICES=(
    "none|Skip storage setup - add a provisioner later"
    "local-path|Rancher local-path-provisioner - node-local dirs, good for single-node"
    "nfs|NFS subdir external provisioner - needs an existing NFS server"
    "longhorn|Longhorn - replicated block storage, wants 3+ nodes"
)
CSI_DEFAULT="none"

# Pass "node-only" on workers: they install host prerequisites but never deploy
# the provisioner, so the NFS server/export details don't apply there.
csi_prompt() {
    local scope="${1:-full}"

    if [[ -n "$CSI" ]]; then
        validate_choice "--csi" "$CSI" "${CSI_CHOICES[@]}"
    else
        CSI=$(prompt_choice "Select a storage provisioner (CSI):" "$CSI_DEFAULT" "${CSI_CHOICES[@]}")
    fi

    if [[ "$CSI" == "nfs" && "$scope" == "full" ]]; then
        [[ -n "$NFS_SERVER" ]] || NFS_SERVER=$(prompt_value "NFS server (hostname or IP)" "")
        [[ -n "$NFS_PATH" ]]   || NFS_PATH=$(prompt_value "NFS export path" "/srv/nfs/kubernetes")
        [[ -n "$NFS_SERVER" ]] || die "--nfs-server is required when --csi=nfs"
        [[ -n "$NFS_PATH" ]]   || die "--nfs-path is required when --csi=nfs"
    fi
}

# Host-level packages the provisioner's pods depend on. These have to exist on
# every node that will mount the volumes, not just the control-plane.
csi_node_prereqs() {
    case "${CSI:-none}" in
        nfs)
            log "Installing NFS client packages"
            sudo apt-get install -y nfs-common
            ;;
        longhorn)
            # Longhorn attaches its volumes over iSCSI and uses NFS for RWX
            # volumes, both of which need host-side support.
            log "Installing Longhorn node prerequisites (open-iscsi, nfs-common)"
            sudo apt-get install -y open-iscsi nfs-common
            sudo systemctl enable --now iscsid
            ;;
        local-path|none) : ;;
        *) warn "unknown CSI '${CSI}', skipping node prerequisites." ;;
    esac
}

csi_apply() {
    case "${CSI:-none}" in
        local-path) _csi_apply_local_path ;;
        nfs)        _csi_apply_nfs ;;
        longhorn)   _csi_apply_longhorn ;;
        none)       log "No storage provisioner requested - skipping." ;;
        *) die "unknown CSI: $CSI" ;;
    esac
}

# Marks a StorageClass default so PVCs without an explicit class bind.
_csi_set_default_sc() {
    kubectl patch storageclass "$1" \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

_csi_apply_local_path() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/rancher/local-path-provisioner/releases/latest" \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ -n "$version" ]] || die "could not determine the latest local-path-provisioner release"

    log "Applying local-path-provisioner ${version}"
    kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${version}/deploy/local-path-storage.yaml"
    _csi_set_default_sc local-path
}

_csi_apply_nfs() {
    local version base
    version=$(curl -fsSL "https://api.github.com/repos/kubernetes-sigs/nfs-subdir-external-provisioner/releases/latest" \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ -n "$version" ]] || die "could not determine the latest nfs-subdir-external-provisioner release"
    base="https://raw.githubusercontent.com/kubernetes-sigs/nfs-subdir-external-provisioner/${version}/deploy"

    log "Applying nfs-subdir-external-provisioner ${version} (server ${NFS_SERVER}, export ${NFS_PATH})"
    kubectl apply -f "${base}/rbac.yaml"
    # The upstream deployment hardcodes the maintainers' own NFS server in both
    # the env vars and the volume definition - swap in the real one.
    curl -fsSL "${base}/deployment.yaml" \
        | sed -e "s#10\.3\.243\.101#${NFS_SERVER}#g" \
              -e "s#/ifs/kubernetes#${NFS_PATH}#g" \
        | kubectl apply -f -
    kubectl apply -f "${base}/class.yaml"
    _csi_set_default_sc nfs-client
}

_csi_apply_longhorn() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/longhorn/longhorn/releases/latest" \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ -n "$version" ]] || die "could not determine the latest Longhorn release"

    log "Applying Longhorn ${version}"
    kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${version}/deploy/longhorn.yaml"
    warn "Longhorn needs open-iscsi on every node - run 'k8s-setup worker install --csi=longhorn' on the workers too."
    warn "Longhorn's own storageclass becomes default once its manager pods are Ready; watch 'kubectl -n longhorn-system get pods'."
}
