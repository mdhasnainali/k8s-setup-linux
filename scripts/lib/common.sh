#!/bin/bash
# Shared helpers for k8s-setup scripts. Meant to be sourced, not executed.
#
# Everything the controller and worker install paths have in common lives
# here: option parsing, prompting, the Kubernetes apt repo, kernel/sysctl
# prep, and the small state file that records which CRI/CNI/CSI a node was
# built with so `uninstall` can undo the right things.

# Where install records its choices. Uninstall reads this back so it knows
# which runtime socket to pass to `kubeadm reset` and which packages to purge.
K8S_SETUP_STATE_DIR="/etc/k8s-setup"
K8S_SETUP_STATE_FILE="$K8S_SETUP_STATE_DIR/node.conf"

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "Error: $*" >&2; exit 1; }

# Defaults for everything parse_common_flags can set. Empty CRI/CNI/CSI means
# "not specified on the command line" - the prompt helpers fill those in.
CRI=""
CNI=""
CSI=""
POD_CIDR=""
NFS_SERVER=""
NFS_PATH=""
ASSUME_YES=false
POSITIONAL=()

# Map uname -m onto the arch strings upstream release assets actually use.
host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

# Callers define their own usage(); this parser just recognises the shared
# flags and collects anything else positionally (endpoint, version).
parse_common_flags() {
    POSITIONAL=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cri=*)         CRI="${1#*=}" ;;
            --cri)           CRI="$2"; shift ;;
            --cni=*)         CNI="${1#*=}" ;;
            --cni)           CNI="$2"; shift ;;
            --csi=*)         CSI="${1#*=}" ;;
            --csi)           CSI="$2"; shift ;;
            --pod-cidr=*)    POD_CIDR="${1#*=}" ;;
            --pod-cidr)      POD_CIDR="$2"; shift ;;
            --nfs-server=*)  NFS_SERVER="${1#*=}" ;;
            --nfs-server)    NFS_SERVER="$2"; shift ;;
            --nfs-path=*)    NFS_PATH="${1#*=}" ;;
            --nfs-path)      NFS_PATH="$2"; shift ;;
            -y|--yes)        ASSUME_YES=true ;;
            -h|--help)       usage ;;
            --)              shift; POSITIONAL+=("$@"); break ;;
            -*)              die "unknown option: $1" ;;
            *)               POSITIONAL+=("$1") ;;
        esac
        shift
    done
}

# True when we can actually ask the user something. With -y, or when stdin
# isn't a terminal (piped installs, CI), every prompt silently takes its
# default instead of blocking forever on a read that never returns.
interactive() {
    [[ "$ASSUME_YES" == true ]] && return 1
    [[ -t 0 || -r /dev/tty ]]
}

# Menu prompt. Options are "key|description" strings; the chosen key goes to
# stdout, so all the menu chrome has to go to stderr.
#   choice=$(prompt_choice "Pick one:" default "a|first" "b|second")
prompt_choice() {
    local title="$1" default="$2"; shift 2
    local opts=("$@") line key desc choice suffix

    if ! interactive; then
        echo "$default"
        return 0
    fi

    printf '\n%s\n' "$title" >&2
    for line in "${opts[@]}"; do
        key="${line%%|*}"; desc="${line#*|}"
        suffix=""
        [[ "$key" == "$default" ]] && suffix="  [default]"
        printf '  %-12s %s%s\n' "$key" "$desc" "$suffix" >&2
    done

    while true; do
        printf 'Choice [%s]: ' "$default" >&2
        read -r choice < /dev/tty || choice=""
        choice="${choice:-$default}"
        for line in "${opts[@]}"; do
            if [[ "$choice" == "${line%%|*}" ]]; then
                echo "$choice"
                return 0
            fi
        done
        printf 'Not one of the listed options: %s\n' "$choice" >&2
    done
}

# Validate a value that came in via a flag against the same option list, so a
# typo'd --cni=flannnel fails loudly instead of silently skipping the CNI.
validate_choice() {
    local what="$1" value="$2"; shift 2
    local line keys=()
    for line in "$@"; do
        keys+=("${line%%|*}")
        [[ "$value" == "${line%%|*}" ]] && return 0
    done
    die "invalid $what '$value' (expected one of: ${keys[*]})"
}

# Yes/no prompt. Returns 0 for yes. Non-interactive runs take the default.
confirm() {
    local prompt="$1" default="${2:-N}" ans hint="y/N"
    [[ "$default" =~ ^[Yy]$ ]] && hint="Y/n"

    if ! interactive; then
        [[ "$default" =~ ^[Yy]$ ]]
        return $?
    fi

    printf '%s [%s]: ' "$prompt" "$hint" >&2
    read -r ans < /dev/tty || ans=""
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# Free-text prompt with a default; used for the NFS server/export.
prompt_value() {
    local title="$1" default="${2:-}" ans
    if ! interactive; then
        echo "$default"
        return 0
    fi
    printf '%s [%s]: ' "$title" "$default" >&2
    read -r ans < /dev/tty || ans=""
    echo "${ans:-$default}"
}

# --- state file ------------------------------------------------------------

state_save() {
    sudo mkdir -p "$K8S_SETUP_STATE_DIR"
    sudo tee "$K8S_SETUP_STATE_FILE" > /dev/null <<EOF
# Written by k8s-setup. Read back by 'k8s-setup <role> uninstall'.
K8S_SETUP_ROLE=${1:-}
K8S_SETUP_CRI=${CRI:-}
K8S_SETUP_CRI_SOCKET=${CRI_SOCKET:-}
K8S_SETUP_CNI=${CNI:-}
K8S_SETUP_CSI=${CSI:-}
K8S_SETUP_POD_CIDR=${POD_CIDR:-}
K8S_SETUP_VERSION=${K8S_VERSION:-}
EOF
    log "Recorded node configuration in $K8S_SETUP_STATE_FILE"
}

state_load() {
    [[ -r "$K8S_SETUP_STATE_FILE" ]] || return 1
    # shellcheck disable=SC1090
    . "$K8S_SETUP_STATE_FILE"
    return 0
}

# --- Kubernetes packages ---------------------------------------------------

# Turn "latest" / "1.33" / "v1.33.0" into a bare x.y.z in K8S_VERSION and the
# matching apt channel in K8S_MINOR.
resolve_k8s_version() {
    K8S_VERSION="${1:-latest}"
    if [[ "$K8S_VERSION" == "latest" ]]; then
        log "Fetching latest stable Kubernetes version..."
        # dl.k8s.io/release/stable.txt is upstream's own pointer to the latest
        # stable GA release (e.g. v1.33.2) - avoids hardcoding a version here.
        K8S_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//')
    else
        # strip an optional leading "v" so both "1.33.0" and "v1.33.0" work
        K8S_VERSION="${K8S_VERSION#v}"
    fi
    # The pkgs.k8s.io apt repo is split into per-minor channels (v1.33, v1.32,
    # ...), there's no single "all versions" repo, so we need major.minor too.
    K8S_MINOR="$(echo "$K8S_VERSION" | cut -d. -f1,2)"
}

# Adds the pkgs.k8s.io repo for the resolved channel and installs the three
# kube binaries pinned to one exact package version.
install_k8s_packages() {
    # /etc/apt/keyrings is the apt-recommended location for repo signing keys
    # (replaces the deprecated apt-key add flow).
    sudo mkdir -p /etc/apt/keyrings
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg

    # Import the repo's signing key so apt can verify package authenticity.
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    # Register the repo, pinned to the [signed-by=...] key above rather than
    # trusting it globally.
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list

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
        warn "Exact package for $K8S_VERSION not found in v$K8S_MINOR channel, falling back to latest available in that channel."
        PKG_VERSION=$(apt-cache madison kubeadm | head -1 | awk '{print $3}')
    fi
    # Re-derive K8S_VERSION from the resolved package so kubeadm init/pull
    # later always requests the version that's actually installed here.
    K8S_VERSION=$(echo "$PKG_VERSION" | cut -d- -f1)
    log "Installing kubelet/kubeadm/kubectl $PKG_VERSION"

    sudo apt-get install -y \
        kubelet="$PKG_VERSION" kubeadm="$PKG_VERSION" kubectl="$PKG_VERSION" \
        vim git curl wget
    # Prevent unattended-upgrades / apt upgrade from silently bumping k8s
    # components - version skew across a cluster breaks things.
    sudo apt-mark hold kubelet kubeadm kubectl
}

# --- node prep -------------------------------------------------------------

# Swap off, kernel modules, and the sysctl knobs every CRI/CNI combination
# needs. Identical for control-plane and worker nodes.
prepare_node() {
    # kubelet refuses to start with swap enabled (memory limits become
    # unenforceable) - comment out swap entries in fstab so it stays off on
    # reboot.
    sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
    sudo swapoff -a

    # overlay: filesystem driver the runtime uses for container image layers
    # br_netfilter: lets iptables see bridged traffic, required for pod networking
    sudo modprobe overlay
    sudo modprobe br_netfilter

    # Persist kernel modules so they're loaded again automatically after reboot
    cat <<EOF | sudo tee /etc/modules-load.d/kubernetes.conf
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
}
