# Kubernetes Setup Scripts

Scripts to bootstrap a Kubernetes cluster on Ubuntu/Debian nodes.

## `base_controller_setup.sh`

Sets up a Kubernetes **control-plane (master) node**: installs kubeadm/kubelet/kubectl, configures containerd, initializes the cluster, and applies Flannel networking.

### Requirements

- Ubuntu/Debian host (uses `apt`)
- Root/sudo access
- Internet access to `pkgs.k8s.io`, `dl.k8s.io`, `download.docker.com`, GitHub
- Run as the regular (non-root) user — script uses `sudo` internally

### Usage

```bash
chmod +x base_controller_setup.sh

./base_controller_setup.sh              # latest stable Kubernetes release
./base_controller_setup.sh 1.33.0       # pin an exact version
./base_controller_setup.sh v1.33.0      # "v" prefix optional
./base_controller_setup.sh 1.33         # major.minor only -> latest patch in that channel
./base_controller_setup.sh -h           # show usage
```

Why a version option: the Kubernetes apt repo (`pkgs.k8s.io`) is split into separate channels per minor version (`v1.33`, `v1.32`, ...) with no "all versions" feed. Passing an explicit version lets you reproduce a known-good setup or match an existing cluster's version instead of always drifting to whatever is newest. Default (`latest`) resolves via `https://dl.k8s.io/release/stable.txt`, upstream's own pointer to the current stable GA release.

If the exact patch you request isn't in the repo (already superseded, typo, etc.), the script logs a fallback message and installs the newest available package in that same minor channel instead of failing.

Script uses `set -e` — stops on first error, so it won't continue provisioning on top of a failed step.

### What it does, and why

**Step 1 — Install kubelet, kubeadm, kubectl**
- Adds `/etc/apt/keyrings` (the current apt-recommended place for repo signing keys, replacing the deprecated `apt-key add`) and imports the Kubernetes repo's signing key so apt can verify packages.
- Registers the repo for the resolved `v<major.minor>` channel.
- The k8s apt repo appends its own build revision to versions (e.g. `1.33.0-1.1`), so the script looks up the exact matching package string via `apt-cache madison` rather than guessing it.
- `apt-mark hold` pins the installed versions so a routine `apt upgrade` can't silently bump them — version skew between kubelet/kubeadm/kubectl (or across nodes) breaks clusters.

**Step 2 — Disable swap, load kernel modules**
- kubelet refuses to start with swap on (memory limits become unenforceable), so swap is turned off and commented out of `/etc/fstab` so it stays off after reboot.
- `overlay`: filesystem driver containerd uses for container image layers.
- `br_netfilter`: makes bridged network traffic visible to iptables — without it, pod-to-pod traffic can bypass kube-proxy's rules.
- Both modules are persisted via `/etc/modules-load.d/` so they reload automatically on reboot.
- sysctl params (`bridge-nf-call-iptables`/`ip6tables`, `ip_forward`) are what actually make bridged-pod traffic filterable and let the node route packets between interfaces — required for pod/service networking to work at all.

**Step 3 — Install and configure containerd**
- Skips reinstalling containerd if it's already present, so re-running the script on a provisioned node is safe.
- containerd itself ships from Docker's apt repo, not the Kubernetes one, hence the separate repo/key setup.
- `SystemdCgroup = true` is set because kubelet manages cgroups via systemd; if containerd's cgroup driver doesn't match, kubelet fails to start.

**Step 4 — Pull images and initialize the cluster**
- Images are pre-pulled before `kubeadm init` so cluster bring-up doesn't stall/timeout on slow image pulls.
- `--pod-network-cidr=10.244.0.0/16` must match what the CNI plugin (Flannel, step 5) expects.
- `--upload-certs` uploads control-plane certs to a Secret so additional control-plane nodes could join later without manually copying certs.
- `--control-plane-endpoint=$(hostname)` uses the hostname rather than a bare IP, keeping the option open to later grow into an HA control-plane behind a stable name.
- `--ignore-preflight-errors=all` skips kubeadm's preflight checks — convenient for VMs/lab boxes with non-standard resources, but worth revisiting before production use.
- Admin kubeconfig is copied to `$HOME/.kube/config` and chowned to the invoking user so `kubectl` works without `sudo` afterward.

**Step 5 — Apply Flannel networking**
- A fresh cluster has no CNI plugin, so pods stay stuck in `Pending`/`ContainerCreating` without one; Flannel is applied here to match the pod CIDR from step 4.
- kubeadm taints the control-plane node by default so regular pods can't be scheduled on it. The taint is removed here for single-node clusters where the control-plane must also run workloads — leave it in place instead if you plan to join worker nodes and want the control-plane kept workload-free.

### Notes / Caveats

- `--ignore-preflight-errors=all` bypasses preflight checks — fine for lab/dev, review before prod use.
- Removing the control-plane taint is only appropriate for single-node clusters; skip/revert for multi-node setups.
- After running, join worker nodes using the `kubeadm join` command printed at the end of `kubeadm init` output.

### Planned

- Worker node setup script (TBD)
- Additional cluster scripts (TBD)
