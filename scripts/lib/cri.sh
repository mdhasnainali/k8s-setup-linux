#!/bin/bash
# Container runtime (CRI) selection and installation. Sourced by the install
# scripts after lib/common.sh.
#
# All three options end the same way: a running CRI whose cgroup driver is
# systemd (kubelet's default - a mismatch makes kubelet fail on startup) and a
# socket path exported as CRI_SOCKET for kubeadm to use.

CRI_CHOICES=(
    "containerd|containerd from the Docker apt repo - fewest moving parts"
    "crio|CRI-O, matched to the Kubernetes minor version"
    "docker|Docker Engine plus the cri-dockerd shim"
)
CRI_DEFAULT="containerd"

cri_prompt() {
    if [[ -n "$CRI" ]]; then
        validate_choice "--cri" "$CRI" "${CRI_CHOICES[@]}"
    else
        CRI=$(prompt_choice "Select a container runtime (CRI):" "$CRI_DEFAULT" "${CRI_CHOICES[@]}")
    fi
    CRI_SOCKET=$(cri_socket "$CRI")
}

# kubeadm needs the socket explicitly whenever more than one runtime could be
# present on the box - which is exactly the case for the docker option, since
# docker-ce pulls in containerd.io alongside cri-dockerd.
cri_socket() {
    case "$1" in
        containerd) echo "unix:///run/containerd/containerd.sock" ;;
        crio)       echo "unix:///var/run/crio/crio.sock" ;;
        docker)     echo "unix:///var/run/cri-dockerd.sock" ;;
        *) die "unknown CRI: $1" ;;
    esac
}

# Docker's apt repo serves containerd.io (containerd option) and docker-ce
# (docker option), so both paths share this.
_add_docker_apt_repo() {
    local distro codename
    # shellcheck disable=SC1091
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) distro="$ID" ;;
        # Mint, Pop!_OS etc. report their own ID but track an upstream release.
        *) distro="${ID_LIKE%% *}"; [[ -n "$distro" ]] || die "unsupported distribution: $ID" ;;
    esac
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$codename" ]] || codename="$(lsb_release -cs)"

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker-archive-keyring.gpg

    echo "deb [arch=$(host_arch) signed-by=/etc/apt/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${distro} ${codename} stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
}

cri_install() {
    case "$CRI" in
        containerd) _cri_install_containerd ;;
        crio)       _cri_install_crio ;;
        docker)     _cri_install_docker ;;
        *) die "unknown CRI: $CRI" ;;
    esac
}

# --- containerd ------------------------------------------------------------

_cri_install_containerd() {
    # Skip reinstalling so re-running this script on an already-provisioned
    # node is safe/idempotent.
    if ! command -v containerd &> /dev/null; then
        log "containerd not found, installing..."
        _add_docker_apt_repo
        # --allow-downgrades / --allow-change-held-packages: avoids apt aborting
        # if a conflicting/held docker-related package already exists on the box.
        # Dpkg::Options::="--force-confold": keep any existing local config files
        # instead of prompting (script runs non-interactively).
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confold" \
            --allow-downgrades --allow-change-held-packages containerd.io
    else
        log "containerd is already installed, skipping installation."
    fi

    # Always (re)configure, even if it was already installed, so config stays
    # consistent with what kubeadm expects below.
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
    # kubelet manages cgroups via systemd; containerd defaults to its own cgroup
    # driver, and a mismatch between the two causes kubelet to fail on startup.
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    sudo systemctl restart containerd
    sudo systemctl enable containerd
}

# --- CRI-O -----------------------------------------------------------------

_cri_install_crio() {
    if command -v crio &> /dev/null; then
        log "CRI-O is already installed, skipping installation."
    elif curl -fsSL -o /dev/null "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${K8S_MINOR}/deb/Release.key" 2>/dev/null; then
        _cri_install_crio_apt
    else
        # pkgs.k8s.io only carries CRI-O channels for the minors CRI-O has
        # actually cut packages for, and that trails new Kubernetes releases.
        # The upstream static bundle covers every release, so fall back to it.
        warn "No CRI-O apt channel for v${K8S_MINOR}; using the upstream static bundle instead."
        _cri_install_crio_bundle
    fi

    # CRI-O's own default is already systemd, but pin it explicitly so an
    # upstream default change can't silently break kubelet.
    sudo mkdir -p /etc/crio/crio.conf.d
    cat <<EOF | sudo tee /etc/crio/crio.conf.d/10-k8s-setup.conf > /dev/null
[crio.runtime]
cgroup_manager = "systemd"
conmon_cgroup = "pod"
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable crio
    sudo systemctl restart crio
}

_cri_install_crio_apt() {
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${K8S_MINOR}/deb/Release.key" \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/v${K8S_MINOR}/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confold" cri-o
}

_cri_install_crio_bundle() {
    local arch crio_version url tmp
    arch="$(host_arch)"

    # Pick the newest CRI-O patch release on the same minor as Kubernetes;
    # CRI-O tracks Kubernetes minors one-for-one.
    crio_version=$(curl -fsSL "https://api.github.com/repos/cri-o/cri-o/releases?per_page=100" \
        | grep -o "\"tag_name\": \"v${K8S_MINOR}\.[0-9]\+\"" | head -1 | cut -d'"' -f4)
    if [[ -z "$crio_version" ]]; then
        crio_version=$(curl -fsSL "https://api.github.com/repos/cri-o/cri-o/releases/latest" \
            | grep -m1 '"tag_name"' | cut -d'"' -f4)
        warn "No CRI-O release on the v${K8S_MINOR} line; using ${crio_version} instead."
    fi
    [[ -n "$crio_version" ]] || die "could not determine a CRI-O version to install"

    # The bundle's Makefile install target needs make; CRI-O itself needs
    # conntrack for its network teardown path.
    sudo apt-get install -y make conntrack

    url="https://storage.googleapis.com/cri-o/artifacts/cri-o.${arch}.${crio_version}.tar.gz"
    tmp=$(mktemp -d)
    log "Downloading CRI-O ${crio_version} bundle..."
    curl -fsSL -o "$tmp/cri-o.tar.gz" "$url" || die "failed to download $url"
    tar -xzf "$tmp/cri-o.tar.gz" -C "$tmp"
    # `make install` drops the binaries, the crio.service unit, and the default
    # config into place.
    ( cd "$tmp/cri-o" && sudo make install )
    rm -rf "$tmp"
}

# --- Docker + cri-dockerd --------------------------------------------------

_cri_install_docker() {
    if ! command -v dockerd &> /dev/null; then
        log "Docker Engine not found, installing..."
        _add_docker_apt_repo
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            -o Dpkg::Options::="--force-confold" \
            --allow-downgrades --allow-change-held-packages \
            docker-ce docker-ce-cli containerd.io
    else
        log "Docker Engine is already installed, skipping installation."
    fi

    # Docker defaults to the cgroupfs driver; kubelet uses systemd. Without
    # this the kubelet and Docker disagree about who owns the cgroup tree.
    sudo mkdir -p /etc/docker
    cat <<EOF | sudo tee /etc/docker/daemon.json > /dev/null
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m" },
  "storage-driver": "overlay2"
}
EOF
    sudo systemctl restart docker
    sudo systemctl enable docker

    _cri_install_cri_dockerd
}

# Docker Engine doesn't speak CRI. cri-dockerd is the out-of-tree shim that
# kubelet talks to instead, forwarding to the Docker daemon.
_cri_install_cri_dockerd() {
    local arch version url tmp unit
    if command -v cri-dockerd &> /dev/null; then
        log "cri-dockerd is already installed, skipping installation."
    else
        arch="$(host_arch)"
        version=$(curl -fsSL "https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest" \
            | grep -m1 '"tag_name"' | cut -d'"' -f4)
        [[ -n "$version" ]] || die "could not determine the latest cri-dockerd release"

        # The published .deb packages only cover a handful of distro codenames,
        # so use the plain binary tarball, which works on any of them.
        url="https://github.com/Mirantis/cri-dockerd/releases/download/${version}/cri-dockerd-${version#v}.${arch}.tgz"
        tmp=$(mktemp -d)
        log "Downloading cri-dockerd ${version}..."
        curl -fsSL -o "$tmp/cri-dockerd.tgz" "$url" || die "failed to download $url"
        tar -xzf "$tmp/cri-dockerd.tgz" -C "$tmp"
        sudo install -m 0755 "$tmp/cri-dockerd/cri-dockerd" /usr/local/bin/cri-dockerd

        # The tarball ships no systemd units, so take them from the same tag.
        for unit in cri-docker.service cri-docker.socket; do
            curl -fsSL "https://raw.githubusercontent.com/Mirantis/cri-dockerd/${version}/packaging/systemd/${unit}" \
                | sudo tee "/etc/systemd/system/${unit}" > /dev/null
        done
        # Units assume the packaged /usr/bin path; we installed to /usr/local/bin.
        sudo sed -i 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,g' \
            /etc/systemd/system/cri-docker.service
        rm -rf "$tmp"
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable --now cri-docker.socket
    sudo systemctl restart cri-docker.service
}

# --- teardown --------------------------------------------------------------

# Used by the uninstall scripts. Only removes what the matching install added.
cri_purge() {
    case "${1:-containerd}" in
        containerd)
            if dpkg -l | grep -qE '^[hi]i\s+containerd\.io\s'; then
                sudo systemctl stop containerd 2>/dev/null || true
                sudo apt-get purge -y containerd.io
            else
                log "containerd.io not installed, skipping."
            fi
            sudo rm -rf /etc/containerd /var/lib/containerd
            ;;
        crio)
            sudo systemctl disable --now crio 2>/dev/null || true
            if dpkg -l | grep -qE '^[hi]i\s+cri-o\s'; then
                sudo apt-get purge -y cri-o
            else
                # Static-bundle install: no package to purge, remove by hand.
                sudo rm -f /usr/local/bin/crio /usr/local/bin/crio-status \
                    /usr/local/bin/pinns /usr/local/bin/conmon /usr/local/bin/conmonrs
                sudo rm -f /usr/local/lib/systemd/system/crio.service \
                    /etc/systemd/system/crio.service
            fi
            sudo rm -rf /etc/crio /var/lib/containers
            sudo rm -f /etc/apt/sources.list.d/cri-o.list /etc/apt/keyrings/cri-o-apt-keyring.gpg
            ;;
        docker)
            sudo systemctl disable --now cri-docker.service cri-docker.socket 2>/dev/null || true
            sudo rm -f /etc/systemd/system/cri-docker.service /etc/systemd/system/cri-docker.socket
            sudo rm -f /usr/local/bin/cri-dockerd
            if dpkg -l | grep -qE '^[hi]i\s+docker-ce\s'; then
                sudo systemctl stop docker 2>/dev/null || true
                sudo apt-get purge -y docker-ce docker-ce-cli containerd.io
            else
                log "docker-ce not installed, skipping."
            fi
            sudo rm -rf /etc/docker /var/lib/docker /etc/containerd /var/lib/containerd
            ;;
        *) warn "unknown CRI '$1' in state file, nothing purged." ;;
    esac
    sudo systemctl daemon-reload
}
