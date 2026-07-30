# Kubernetes Setup Scripts

Scripts to bootstrap (and tear down) a Kubernetes cluster on Ubuntu/Debian nodes.

## Scripts

| Script | Description | Docs |
|---|---|---|
| `base_controller_setup.sh` | Provisions a control-plane (master) node: installs kubeadm/kubelet/kubectl, configures containerd, runs `kubeadm init`, applies Flannel networking. | [docs/setup.md](docs/setup.md) |
| `base_controller_cleanup.sh` | Reverses `base_controller_setup.sh`: `kubeadm reset`, purges kubelet/kubeadm/kubectl/containerd, removes their repos/config, restores swap/sysctl/kernel-module changes. | [docs/cleanup.md](docs/cleanup.md) |
| `worker_setup.sh` | Preps a worker node: installs kubeadm/kubelet/kubectl, configures containerd, pre-pulls images. Stops short of `kubeadm join`. | [docs/worker-setup.md](docs/worker-setup.md) |
| `worker_cleanup.sh` | Reverses `worker_setup.sh` (and any `kubeadm join`): resets kubeadm, purges kubelet/kubeadm/kubectl/containerd, removes their repos/config, restores swap/sysctl/kernel-module changes. | [docs/worker-cleanup.md](docs/worker-cleanup.md) |

## Quick reference

```bash
# Provision a control-plane node (endpoint required, version optional -> latest)
./base_controller_setup.sh <endpoint> [version]

# Tear a control-plane node back down
./base_controller_cleanup.sh

# Prep a worker node (version optional -> latest)
./worker_setup.sh [version]
# ...then join it to the cluster with the `kubeadm join` command from
# base_controller_setup.sh's output

# Tear a worker node back down
./worker_cleanup.sh
```

See each script's doc page above for full usage, arguments, requirements, and a step-by-step breakdown of what it does and why.

## Planned

- Additional cluster scripts (TBD)
