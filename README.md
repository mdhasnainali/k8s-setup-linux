# k8s-setup

A CLI for bootstrapping (and tearing down) a `kubeadm`-based Kubernetes cluster on Ubuntu/Debian nodes.

## Install

```bash
git clone https://github.com/mdhasnainali/k8s-setup-linux.git k8s-setup-linux
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
# Prompts for the container runtime, pod network, and storage provisioner.
k8s-setup controller install <endpoint> [version]

# Print a fresh kubeadm join command for worker nodes (run on control-plane)
k8s-setup controller join-command

# Print a fresh kubeadm join command for a new master/control-plane node (run on existing control-plane)
k8s-setup controller join-master-command

# Tear a control-plane node back down
k8s-setup controller uninstall

# Prep a worker node (version optional -> latest)
k8s-setup worker install [version]
# ...then join it to the cluster with the command from `controller join-command`

# Tear a worker node back down
k8s-setup worker uninstall
```

## Choosing your stack

`install` asks which container runtime, pod network, and storage provisioner to use before it touches the machine, prints the resulting plan, and waits for one confirmation. Each prompt has a flag that skips it, so the same install stays scriptable:

| Layer | Options | Default | Flag |
|---|---|---|---|
| **CRI** — container runtime | `containerd`, `crio`, `docker` (Docker Engine + cri-dockerd) | `containerd` | `--cri=` |
| **CNI** — pod network | `flannel`, `calico`, `cilium`, `none` | `flannel` | `--cni=` |
| **CSI** — storage | `none`, `local-path`, `nfs`, `longhorn` | `none` | `--csi=` |

```bash
# fully non-interactive
k8s-setup controller install k8s.example.com 1.33.0 --cri=crio --cni=calico --csi=local-path -y

# workers take --cri (must match the control-plane) and --csi (host prerequisites only)
k8s-setup worker install 1.33.0 --cri=crio --csi=local-path -y
```

Also available: `--pod-cidr=` to override the CIDR the CNI choice implies, and `--nfs-server=` / `--nfs-path=` for `--csi=nfs`. `-y` takes every default and never prompts, which is also what happens automatically when stdin isn't a terminal.

The pod CIDR follows the CNI choice (Flannel and Cilium `10.244.0.0/16`, Calico `192.168.0.0/16`) and is pushed into both `kubeadm init` and the plugin's own config so the two can't drift.

Choices are recorded in `/etc/k8s-setup/node.conf`. `join-command` uses it to append the right `--cri-socket`, and `uninstall` uses it to tear down the runtime you actually installed. See [docs/controller-install.md](docs/controller-install.md) for what each option installs and when to pick it.

## Commands

| Command | Description | Docs |
|---|---|---|
| `k8s-setup controller install` | Installs kubeadm/kubelet/kubectl, installs and configures the chosen CRI, runs `kubeadm init`, applies the chosen CNI, deploys the chosen CSI. | [docs/controller-install.md](docs/controller-install.md) |
| `k8s-setup controller join-command` | Prints a fresh `kubeadm join` command (~24h validity) for worker nodes. | [scripts/controller-join-command.sh](scripts/controller-join-command.sh) |
| `k8s-setup controller join-master-command` | Prints a fresh `kubeadm join --control-plane` command (token ~24h, cert key ~2h) for new master nodes. | [scripts/controller-join-master-command.sh](scripts/controller-join-master-command.sh) |
| `k8s-setup controller uninstall` | Reverses `controller install`: `kubeadm reset`, purges kubelet/kubeadm/kubectl and (opt-in) the recorded CRI, removes their repos/config, restores swap/sysctl/kernel-module changes. | [docs/controller-uninstall.md](docs/controller-uninstall.md) |
| `k8s-setup worker install` | Installs kubeadm/kubelet/kubectl, installs and configures the chosen CRI, installs CSI host prerequisites, pre-pulls images. Stops short of `kubeadm join`. | [docs/worker-install.md](docs/worker-install.md) |
| `k8s-setup worker uninstall` | Reverses `worker install` (and any `kubeadm join`): resets kubeadm, purges kubelet/kubeadm/kubectl and (opt-in) the recorded CRI, removes their repos/config, restores swap/sysctl/kernel-module changes. | [docs/worker-uninstall.md](docs/worker-uninstall.md) |

See each doc page above for full usage, arguments, requirements, and a step-by-step breakdown of what it does and why.

## Repo layout

```
bin/k8s-setup       CLI entrypoint (dispatches to scripts/)
scripts/            Implementation - each is also runnable standalone
scripts/lib/        Shared helpers: prompts/flags, CRI, CNI, CSI
docs/               Per-command reference docs
install.sh          Symlinks bin/k8s-setup onto PATH
```

## Planned

- Additional cluster commands (TBD)
