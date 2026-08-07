# k8s-setup

A CLI for bootstrapping (and tearing down) a `kubeadm`-based Kubernetes cluster on Ubuntu/Debian nodes.

## Install

```bash
git clone <this-repo-url> k8s-setup-linux
cd k8s-setup-linux
./install.sh                # symlinks bin/k8s-setup into /usr/local/bin
k8s-setup help
```

Pass a different target directory if you don't want `/usr/local/bin`:

```bash
./install.sh "$HOME/.local/bin"   # make sure it's on your PATH
```

No install step is required to just run it in place: `./bin/k8s-setup help` works directly from a clone.

## Usage

```bash
# Provision a control-plane node (endpoint required, version optional -> latest)
k8s-setup controller install <endpoint> [version]

# Print a fresh kubeadm join command for worker nodes (run on control-plane)
k8s-setup controller join-command

# Tear a control-plane node back down
k8s-setup controller uninstall

# Prep a worker node (version optional -> latest)
k8s-setup worker install [version]
# ...then join it to the cluster with the command from `controller join-command`

# Tear a worker node back down
k8s-setup worker uninstall
```

## Commands

| Command | Description | Docs |
|---|---|---|
| `k8s-setup controller install` | Installs kubeadm/kubelet/kubectl, configures containerd, runs `kubeadm init`, applies Flannel networking. | [docs/controller-install.md](docs/controller-install.md) |
| `k8s-setup controller join-command` | Prints a fresh `kubeadm join` command (~24h validity) for worker nodes. | [scripts/controller-join-command.sh](scripts/controller-join-command.sh) |
| `k8s-setup controller uninstall` | Reverses `controller install`: `kubeadm reset`, purges kubelet/kubeadm/kubectl/containerd, removes their repos/config, restores swap/sysctl/kernel-module changes. | [docs/controller-uninstall.md](docs/controller-uninstall.md) |
| `k8s-setup worker install` | Installs kubeadm/kubelet/kubectl, configures containerd, pre-pulls images. Stops short of `kubeadm join`. | [docs/worker-install.md](docs/worker-install.md) |
| `k8s-setup worker uninstall` | Reverses `worker install` (and any `kubeadm join`): resets kubeadm, purges kubelet/kubeadm/kubectl/containerd, removes their repos/config, restores swap/sysctl/kernel-module changes. | [docs/worker-uninstall.md](docs/worker-uninstall.md) |

See each doc page above for full usage, arguments, requirements, and a step-by-step breakdown of what it does and why.

## Repo layout

```
bin/k8s-setup       CLI entrypoint (dispatches to scripts/)
scripts/            Implementation - each is also runnable standalone
docs/               Per-command reference docs
install.sh          Symlinks bin/k8s-setup onto PATH
```

## Planned

- CNI choice prompt in `controller install` — pick Flannel, Calico, or Cilium at install time instead of hardcoding Flannel.
- Additional cluster commands (TBD)
