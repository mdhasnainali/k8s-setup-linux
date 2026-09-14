# `k8s-setup controller uninstall`

Reverses [`k8s-setup controller install`](controller-install.md) on a control-plane node: resets kubeadm, purges kubelet/kubeadm/kubectl and optionally the container runtime, removes their apt repos/keys/config, and restores swap/sysctl/kernel-module changes made during setup — so the node returns to a pre-setup state.

[← Back to README](../README.md)

## Requirements

- Same host that ran `k8s-setup controller install` (or an equivalently-provisioned Ubuntu/Debian node)
- Root/sudo access
- Run as the regular (non-root) user — script uses `sudo` internally

## Usage

```bash
k8s-setup controller uninstall              # prompts for confirmation, then tears down the node
k8s-setup controller uninstall --purge-runtime   # also remove the container runtime
k8s-setup controller uninstall -y           # non-interactive: reset, but keep the runtime
k8s-setup controller uninstall -h           # show usage
```

Script prompts for confirmation before doing anything, since `kubeadm reset` and package purges aren't easily undone. Uses `set -e` like the setup script, so it stops on first error rather than continuing a partial teardown.

Which container runtime to tear down is read from `/etc/k8s-setup/node.conf`, written by install. If that file is missing (node predates it, or was set up by hand) the script asks, or you can pass `--cri=containerd|crio|docker`.

Removing the runtime is a **separate, opt-in** decision — the second prompt defaults to *no*, and `-y` keeps the runtime installed unless you also pass `--purge-runtime`. Other things on the box may be using it.

## What it does, and why

**Step 1 — `kubeadm reset`**
- Undoes most of what `kubeadm init` set up: stops kubelet, cleans up `/etc/kubernetes`, and tears down local etcd data. The `--cri-socket` comes from the recorded runtime, so it targets the right sandbox whether that's containerd, CRI-O, or cri-dockerd. Skipped if `kubeadm` isn't installed (already cleaned up, or setup never ran).

**Step 2 — Remove CNI and kube configs**
- `kubeadm reset` doesn't touch CNI plugin state, so the plugin's `/etc/cni/net.d` and `/var/lib/cni` are removed directly, along with the `cni0`, `flannel.1`, `vxlan.calico`, and `cilium_*` interfaces the plugin created.
- Removes `$HOME/.kube`, the admin kubeconfig setup copied in at its Step 6.

**Step 3 — Flush iptables/ipvs rules**
- kube-proxy's iptables rules (NAT/mangle tables, custom chains) survive `kubeadm reset` and can conflict with a future cluster on the same node, so they're flushed here.

**Step 4 — Purge kubelet, kubeadm, kubectl**
- Setup pins these with `apt-mark hold` so routine upgrades can't touch them; cleanup unholds first, or `apt-get purge` would refuse to remove them.
- Skipped if none of the three packages are installed.

**Step 5 — Purge the container runtime and its config**
- Only runs if you opted in. What gets removed depends on the recorded runtime:
  - `containerd` — the `containerd.io` package plus `/etc/containerd` and `/var/lib/containerd`.
  - `crio` — the `cri-o` package (or the static bundle's binaries and unit file), plus `/etc/crio` and `/var/lib/containers`, and the CRI-O apt repo/key.
  - `docker` — the cri-dockerd binary and its systemd units, the `docker-ce`/`docker-ce-cli`/`containerd.io` packages, plus `/etc/docker` and `/var/lib/docker`.
- Skipped entirely if you declined, leaving the runtime and its images in place for whatever else on the box needs them.

**Step 6 — Remove Kubernetes and Docker apt repos/keys**
- Deletes the `kubernetes.list`/`docker.list` sources and their signing keyrings added during setup, then refreshes the apt index — leaves apt in the state it was before setup ran.

**Step 7 — Restore swap and kernel/sysctl changes**
- Un-comments the swap line(s) setup commented out in `/etc/fstab` and re-enables swap.
- Removes `/etc/modules-load.d/kubernetes.conf` (and `containerd.conf`, the name older versions of this script used) and `/etc/sysctl.d/kubernetes.conf`, then reapplies sysctl so the bridge/forwarding settings setup added are dropped immediately (not just on next reboot).

**Step 8 — Remove the k8s-setup state file**
- Deletes `/etc/k8s-setup/`, the record of what this node was built with — there's nothing left for it to describe.

**Step 9 — Autoremove unused dependencies**
- Cleans up now-orphaned packages that were pulled in as dependencies during setup.

## Notes / Caveats

- Destructive and mostly irreversible — confirms interactively before touching anything.
- The container runtime is never removed without an explicit yes (or `--purge-runtime`).
- Doesn't remove `apt-transport-https`/`ca-certificates`/`curl`/`gpg`/`vim`/`git`/`wget`, since those are common general-purpose packages other things may depend on.
- Prints total script runtime (minutes/seconds) once cleanup completes.
