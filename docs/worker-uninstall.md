# `k8s-setup worker uninstall`

Reverses [`k8s-setup worker install`](worker-install.md) (and any subsequent `kubeadm join`) on a worker node: resets kubeadm, purges kubelet/kubeadm/kubectl/containerd, removes their apt repos/keys/config, and restores swap/sysctl/kernel-module changes made during setup — so the node returns to a pre-setup state.

[← Back to README](../README.md)

## Requirements

- Same host that ran `k8s-setup worker install` (or an equivalently-provisioned Ubuntu/Debian node)
- Root/sudo access
- Run as the regular (non-root) user — script uses `sudo` internally

## Usage

```bash
k8s-setup worker uninstall   # prompts for confirmation, then tears down the node
k8s-setup worker uninstall -h   # show usage
```

Script prompts for confirmation before doing anything, since `kubeadm reset` and package purges aren't easily undone. Uses `set -e` like the setup script, so it stops on first error rather than continuing a partial teardown.

## What it does, and why

**Step 1 — `kubeadm reset`**
- Undoes a prior `kubeadm join`: stops kubelet and cleans up `/etc/kubernetes`. Same `--cri-socket` as setup so it targets the right containerd sandbox. Skipped if `kubeadm` isn't installed (already cleaned up, setup never ran, or the node never joined).

**Step 2 — Remove CNI leftovers**
- Joining a cluster writes CNI plugin state to the node; `kubeadm reset` doesn't touch it, so `/etc/cni/net.d` and `/var/lib/cni` are removed directly, along with the `cni0`/`flannel.1` network interfaces the CNI plugin created.

**Step 3 — Flush iptables/ipvs rules**
- kube-proxy's iptables rules (NAT/mangle tables, custom chains) survive `kubeadm reset` and can conflict with a future join on the same node, so they're flushed here.

**Step 4 — Purge kubelet, kubeadm, kubectl**
- Setup pins these with `apt-mark hold` so routine upgrades can't touch them; cleanup unholds first, or `apt-get purge` would refuse to remove them.
- Skipped if none of the three packages are installed.

**Step 5 — Purge containerd and its config**
- Removes the `containerd.io` package plus `/etc/containerd` and `/var/lib/containerd` (image layers, container state) — otherwise stale config/images linger for the next setup.

**Step 6 — Remove Kubernetes and Docker apt repos/keys**
- Deletes the `kubernetes.list`/`docker.list` sources and their signing keyrings added during setup, then refreshes the apt index — leaves apt in the state it was before setup ran.

**Step 7 — Restore swap and kernel/sysctl changes**
- Un-comments the swap line(s) setup commented out in `/etc/fstab` and re-enables swap.
- Removes `/etc/modules-load.d/containerd.conf` and `/etc/sysctl.d/kubernetes.conf`, then reapplies sysctl so the bridge/forwarding settings setup added are dropped immediately (not just on next reboot).

**Step 8 — Autoremove unused dependencies**
- Cleans up now-orphaned packages that were pulled in as dependencies during setup.

## Notes / Caveats

- Destructive and mostly irreversible — confirms interactively before touching anything.
- Doesn't remove `apt-transport-https`/`ca-certificates`/`curl`/`gpg`/`vim`/`git`/`wget`, since those are common general-purpose packages other things may depend on.
- Prints total script runtime (minutes/seconds) once cleanup completes.
