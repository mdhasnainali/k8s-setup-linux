# `base_controller_setup.sh`

Sets up a Kubernetes **control-plane (master) node**: installs kubeadm/kubelet/kubectl, configures containerd, initializes the cluster, and applies Flannel networking.

[← Back to README](../README.md)

## Requirements

- Ubuntu/Debian host (uses `apt`)
- Root/sudo access
- Internet access to `pkgs.k8s.io`, `dl.k8s.io`, `download.docker.com`, GitHub
- Run as the regular (non-root) user — script uses `sudo` internally

## Usage

```bash
chmod +x base_controller_setup.sh

./base_controller_setup.sh k8s-cluster.mycompany.local      # endpoint (DNS name), latest version
./base_controller_setup.sh 10.0.1.50                        # endpoint (bare IP), latest version
./base_controller_setup.sh k8s-cluster.mycompany.local 1.33.0   # pin an exact version
./base_controller_setup.sh 10.0.1.50 v1.33.0                # "v" prefix optional
./base_controller_setup.sh 10.0.1.50 1.33                   # major.minor only -> latest patch in that channel
./base_controller_setup.sh -h                                # show usage
```

Why a version option: the Kubernetes apt repo (`pkgs.k8s.io`) is split into separate channels per minor version (`v1.33`, `v1.32`, ...) with no "all versions" feed. Passing an explicit version lets you reproduce a known-good setup or match an existing cluster's version instead of always drifting to whatever is newest. Default (`latest`) resolves via `https://dl.k8s.io/release/stable.txt`, upstream's own pointer to the current stable GA release.

Why an endpoint option: the first arg controls what `--control-plane-endpoint` bakes into the cluster's certs/kubeconfig (see the HA note under Step 4 below). Required — no safe default, since it's baked into certs. Pass a DNS name or load balancer address instead of a bare IP if you might grow into an HA control-plane later — switching afterward means regenerating certs, so it's cheaper to decide up front.

If the exact patch you request isn't in the repo (already superseded, typo, etc.), the script logs a fallback message and installs the newest available package in that same minor channel instead of failing.

Script uses `set -e` — stops on first error, so it won't continue provisioning on top of a failed step.

## What it does, and why

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
  - **HA (High Availability)** means running multiple control-plane nodes (typically 3, an odd number so etcd keeps quorum) instead of one, so the cluster survives a node dying. With a single control-plane node, that node crashing takes down the whole API — no `kubectl`, nothing new gets scheduled or healed, even though already-running pods keep going. With HA, losing one of three nodes still leaves two serving the API/etcd, so the cluster keeps working. A load balancer or DNS name in front of the nodes routes traffic to whichever are alive — which is exactly why the hostname (vs. bare IP) choice below matters.
  - Every cert and kubeconfig kubeadm generates bakes in whatever address you pass here — it becomes "the cluster's address" as far as clients are concerned.
  - **Bare IP** (e.g. `--control-plane-endpoint=192.168.1.50`): fine for a single node. Add more control-plane nodes later for HA and that IP is just one of several — it's not a shared front door. Switching means regenerating certs and reconfiguring every client, with likely downtime.
  - **Hostname** (e.g. `--control-plane-endpoint=k8s-cluster.mycompany.local`): certs/kubeconfigs only ever reference the name, not what's behind it. Today DNS points that name straight at the one node. Add more control-plane nodes later, drop a load balancer in front of them, and just repoint the DNS name at the load balancer — no cert regen, no client reconfig.
  - Analogy: bare IP is like handing out your friend's home address directly. A hostname is like handing out a PO box number — if your friend moves, you update the PO box's forwarding, and nobody holding "the address" needs to change anything.
  - Trade-off: the hostname has to actually resolve (DNS record, or `/etc/hosts` on every node/client) — a bare IP has no such dependency and just works.
- `--ignore-preflight-errors=all` skips kubeadm's preflight checks — convenient for VMs/lab boxes with non-standard resources, but worth revisiting before production use.
- Admin kubeconfig is copied to `$HOME/.kube/config` and chowned to the invoking user so `kubectl` works without `sudo` afterward.

**Step 5 — Apply Flannel networking**
- A fresh cluster has no CNI plugin, so pods stay stuck in `Pending`/`ContainerCreating` without one; Flannel is applied here to match the pod CIDR from step 4.
- kubeadm taints the control-plane node by default so regular pods can't be scheduled on it. Script prompts — "Allow workload pods to schedule on this control-plane node?" — and removes the taint only on `y`. Answer yes for single-node clusters where the control-plane must also run workloads; answer no (default) if you plan to join worker nodes and want the control-plane kept workload-free.
- Prints total script runtime (minutes/seconds) once setup completes.

## Notes / Caveats

- `--ignore-preflight-errors=all` bypasses preflight checks — fine for lab/dev, review before prod use.
- Removing the control-plane taint is only appropriate for single-node clusters; skip/revert for multi-node setups.
- After running, join worker nodes using the `kubeadm join` command printed at the end of `kubeadm init` output.
