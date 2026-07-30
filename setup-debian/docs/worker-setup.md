# `worker_setup.sh`

Preps a Kubernetes **worker node**: installs kubeadm/kubelet/kubectl, disables swap, configures containerd, and pre-pulls Kubernetes images. Stops short of `kubeadm join` — run the join command from the control-plane's `kubeadm init` output afterward to actually add the node to the cluster.

[← Back to README](../README.md)

## Requirements

- Ubuntu/Debian host (uses `apt`)
- Root/sudo access
- Internet access to `pkgs.k8s.io`, `dl.k8s.io`, `download.docker.com`
- Run as the regular (non-root) user — script uses `sudo` internally

## Usage

```bash
chmod +x worker_setup.sh

./worker_setup.sh              # latest version
./worker_setup.sh 1.33.0       # pin an exact version
./worker_setup.sh v1.33.0      # "v" prefix optional
./worker_setup.sh 1.33         # major.minor only -> latest patch in that channel
./worker_setup.sh -h           # show usage
```

No endpoint argument — this script never bakes a control-plane address into anything (that happens on the control-plane during `kubeadm init`, and on this node when you later run `kubeadm join` with the token/endpoint it gives you).

`VERSION` works the same way as in `base_controller_setup.sh`: `latest` (default) resolves via `https://dl.k8s.io/release/stable.txt`; an explicit version (e.g. `1.33.0`, `v1.33.0`, `1.33`) pins to a known release. Keep this in sync with the control-plane's version — `kubeadm join` and cluster operation both assume matching minor versions across nodes.

Script uses `set -e` — stops on first error, so it won't continue provisioning on top of a failed step.

## What it does, and why

**Step 1 — Install kubelet, kubeadm, kubectl**
- Same as `base_controller_setup.sh`: adds `/etc/apt/keyrings`, imports the Kubernetes repo's signing key, registers the repo for the resolved `v<major.minor>` channel, and resolves the exact package version string via `apt-cache madison` (the repo appends a build revision, e.g. `1.33.0-1.1`).
- `apt-mark hold` pins the installed versions so a routine `apt upgrade` can't silently bump them — version skew across a cluster's nodes breaks things.

**Step 2 — Disable swap, load kernel modules**
- kubelet refuses to start with swap on, so swap is turned off and commented out of `/etc/fstab` so it stays off after reboot.
- `overlay`: filesystem driver containerd uses for container image layers.
- `br_netfilter`: makes bridged network traffic visible to iptables — without it, pod-to-pod traffic can bypass kube-proxy's rules.
- Both modules persist via `/etc/modules-load.d/` so they reload on reboot; sysctl params (`bridge-nf-call-iptables`/`ip6tables`, `ip_forward`) are applied immediately so pod/service networking works without a reboot.

**Step 3 — Install and configure containerd**
- Skips reinstalling containerd if already present, so re-running the script on a provisioned node is safe.
- containerd ships from Docker's apt repo, not the Kubernetes one, hence the separate repo/key setup.
- `SystemdCgroup = true` is set because kubelet manages cgroups via systemd; a mismatched cgroup driver between kubelet and containerd stops kubelet from starting.

**Step 4 — Pull Kubernetes images**
- Pre-pulls images so a subsequent `kubeadm join` doesn't stall/timeout on slow image pulls.
- Doesn't run `kubeadm join` — that command (with its token and discovery hash) comes from the control-plane's `kubeadm init` output and is specific to each join attempt, so it's left as a manual step after this script finishes.

## Notes / Caveats

- This script only prepares the node — it does not join it to a cluster. Run the `kubeadm join ...` command printed by `base_controller_setup.sh` (or `kubeadm token create --print-join-command` on the control-plane) after this script completes.
- Keep `VERSION` matched to the control-plane's Kubernetes version to avoid skew.
