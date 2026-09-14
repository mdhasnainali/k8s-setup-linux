# `k8s-setup worker install`

Preps a Kubernetes **worker node**: installs kubeadm/kubelet/kubectl, disables swap, installs and configures the container runtime you pick, installs any host-side storage prerequisites, and pre-pulls Kubernetes images. Stops short of `kubeadm join` — run the join command from `k8s-setup controller join-command` afterward to actually add the node to the cluster.

[← Back to README](../README.md)

## Requirements

- Ubuntu/Debian host (uses `apt`)
- Root/sudo access
- Internet access to `pkgs.k8s.io`, `dl.k8s.io`, `download.docker.com`, `storage.googleapis.com`, GitHub
- Run as the regular (non-root) user — script uses `sudo` internally

## Usage

```bash
k8s-setup worker install              # latest version
k8s-setup worker install 1.33.0       # pin an exact version
k8s-setup worker install v1.33.0      # "v" prefix optional
k8s-setup worker install 1.33         # major.minor only -> latest patch in that channel
k8s-setup worker install -h           # show usage
```

No endpoint argument — this command never bakes a control-plane address into anything (that happens on the control-plane during `kubeadm init`, and on this node when you later run `kubeadm join` with the token/endpoint it gives you).

`VERSION` works the same way as in `k8s-setup controller install`: `latest` (default) resolves via `https://dl.k8s.io/release/stable.txt`; an explicit version (e.g. `1.33.0`, `v1.33.0`, `1.33`) pins to a known release. Keep this in sync with the control-plane's version — `kubeadm join` and cluster operation both assume matching minor versions across nodes.

Script uses `set -e` — stops on first error, so it won't continue provisioning on top of a failed step.

## Choosing the CRI and CSI

A worker gets asked two of the three questions the control-plane asks. There's no CNI prompt: the pod network is a cluster-wide workload the control-plane already deployed, and its DaemonSet lands on this node automatically once it joins.

| Prompt | Options | Default |
|---|---|---|
| Container runtime (CRI) | `containerd`, `crio`, `docker` | `containerd` |
| Storage (CSI) | `none`, `local-path`, `nfs`, `longhorn` | `none` |

```bash
--cri=containerd|crio|docker            # container runtime
--csi=none|local-path|nfs|longhorn      # storage prerequisites for this node
-y, --yes                               # take the default for every prompt
```

```bash
k8s-setup worker install 1.33.0 --cri=crio
k8s-setup worker install --cri=containerd --csi=longhorn -y
```

**`--cri` must match the control-plane's runtime.** See the [CRI table in the controller docs](controller-install.md#container-runtime-cri) for what each option installs and which socket it uses. When the node joins, kubeadm needs that socket — `k8s-setup controller join-command` reads it from the control-plane's `/etc/k8s-setup/node.conf` and appends `--cri-socket ...` to the command it prints, so copy that command verbatim.

**`--csi` here installs host packages only** — `nfs-common` for `nfs`, `open-iscsi` + `nfs-common` (and `iscsid` enabled) for `longhorn`. The provisioner itself is a cluster workload deployed once, from the control-plane. Longhorn in particular will not schedule volumes onto a node missing `open-iscsi`, which is why the option exists here at all.

This node's choices are recorded in `/etc/k8s-setup/node.conf` so `k8s-setup worker uninstall` tears down the right runtime.

## What it does, and why

**Step 1 — Install kubelet, kubeadm, kubectl**
- Same as `k8s-setup controller install`: adds `/etc/apt/keyrings`, imports the Kubernetes repo's signing key, registers the repo for the resolved `v<major.minor>` channel, and resolves the exact package version string via `apt-cache madison` (the repo appends a build revision, e.g. `1.33.0-1.1`).
- `apt-mark hold` pins the installed versions so a routine `apt upgrade` can't silently bump them — version skew across a cluster's nodes breaks things.

**Step 2 — Disable swap, load kernel modules**
- kubelet refuses to start with swap on, so swap is turned off and commented out of `/etc/fstab` so it stays off after reboot.
- `overlay`: filesystem driver the container runtime uses for image layers.
- `br_netfilter`: makes bridged network traffic visible to iptables — without it, pod-to-pod traffic can bypass kube-proxy's rules.
- Both modules persist via `/etc/modules-load.d/kubernetes.conf` so they reload on reboot; sysctl params (`bridge-nf-call-iptables`/`ip6tables`, `ip_forward`) are applied immediately so pod/service networking works without a reboot.

**Step 3 — Install and configure the container runtime**
- Skips reinstalling if the chosen runtime is already present, so re-running the script on a provisioned node is safe.
- containerd and Docker Engine ship from Docker's apt repo, not the Kubernetes one, hence the separate repo/key setup. CRI-O comes from the `pkgs.k8s.io` CRI-O channel, falling back to the upstream static bundle when that channel doesn't exist for your Kubernetes minor yet.
- The cgroup driver is forced to systemd in all three cases — kubelet manages cgroups via systemd, and a mismatch stops kubelet from starting.

**Step 4 — Storage prerequisites**
- Installs the host packages the cluster's provisioner needs on this node. No-op for `none` and `local-path`.

**Step 5 — Pull Kubernetes images**
- Pre-pulls images (via the chosen runtime's socket) so a subsequent `kubeadm join` doesn't stall/timeout on slow image pulls.
- Doesn't run `kubeadm join` — that command (with its token and discovery hash) comes from the control-plane and is specific to each join attempt, so it's left as a manual step after this script finishes.
- Prints the exact `--cri-socket` this node needs on its join command.

## Notes / Caveats

- This command only prepares the node — it does not join it to a cluster. Run the `kubeadm join ...` command from `k8s-setup controller join-command` on the control-plane after this completes.
- Keep `VERSION` matched to the control-plane's Kubernetes version to avoid skew.
- Keep `--cri` matched to the control-plane's runtime; a worker running a different CRI than the join command's `--cri-socket` expects will fail to join.
