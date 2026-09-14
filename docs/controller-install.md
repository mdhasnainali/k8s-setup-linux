# `k8s-setup controller install`

Sets up a Kubernetes **control-plane (master) node**: installs kubeadm/kubelet/kubectl, installs and configures the container runtime you pick, initializes the cluster, applies the pod network you pick, and optionally deploys a storage provisioner.

[← Back to README](../README.md)

## Requirements

- Ubuntu/Debian host (uses `apt`)
- Root/sudo access
- Internet access to `pkgs.k8s.io`, `dl.k8s.io`, `download.docker.com`, `storage.googleapis.com`, GitHub
- Run as the regular (non-root) user — script uses `sudo` internally

## Usage

```bash
k8s-setup controller install k8s-cluster.mycompany.local      # endpoint (DNS name), latest version
k8s-setup controller install 10.0.1.50                        # endpoint (bare IP), latest version
k8s-setup controller install k8s-cluster.mycompany.local 1.33.0   # pin an exact version
k8s-setup controller install 10.0.1.50 v1.33.0                # "v" prefix optional
k8s-setup controller install 10.0.1.50 1.33                   # major.minor only -> latest patch in that channel
k8s-setup controller install -h                                # show usage
```

Runs `scripts/controller-install.sh` under the hood — that script can also be called directly if you're not using the CLI.

Why a version option: the Kubernetes apt repo (`pkgs.k8s.io`) is split into separate channels per minor version (`v1.33`, `v1.32`, ...) with no "all versions" feed. Passing an explicit version lets you reproduce a known-good setup or match an existing cluster's version instead of always drifting to whatever is newest. Default (`latest`) resolves via `https://dl.k8s.io/release/stable.txt`, upstream's own pointer to the current stable GA release.

Why an endpoint option: the first arg controls what `--control-plane-endpoint` bakes into the cluster's certs/kubeconfig (see the HA note under Step 5 below). Required — no safe default, since it's baked into certs. Pass a DNS name or load balancer address instead of a bare IP if you might grow into an HA control-plane later — switching afterward means regenerating certs, so it's cheaper to decide up front.

If the exact patch you request isn't in the repo (already superseded, typo, etc.), the script logs a fallback message and installs the newest available package in that same minor channel instead of failing.

Script uses `set -e` — stops on first error, so it won't continue provisioning on top of a failed step.

## Choosing the CRI, CNI, and CSI

The script asks three questions before it changes anything on the box, prints the resulting plan, and waits for one confirmation. Everything is collected up front on purpose — a long install shouldn't stop halfway to ask you something.

| Prompt | Options | Default |
|---|---|---|
| Container runtime (CRI) | `containerd`, `crio`, `docker` | `containerd` |
| Pod network (CNI) | `flannel`, `calico`, `cilium`, `none` | `flannel` |
| Storage (CSI) | `none`, `local-path`, `nfs`, `longhorn` | `none` |

Each prompt has a matching flag that skips it, so the same install is reproducible and scriptable:

```bash
--cri=containerd|crio|docker            # container runtime
--cni=flannel|calico|cilium|none        # pod network add-on
--csi=none|local-path|nfs|longhorn      # storage provisioner
--pod-cidr=10.244.0.0/16                # override the CIDR the CNI choice implies
--nfs-server=HOST --nfs-path=/export    # required with --csi=nfs
-y, --yes                               # take the default for every remaining prompt
```

```bash
k8s-setup controller install 10.0.1.50 1.33.0 --cri=crio --cni=calico
k8s-setup controller install k8s.example.com --cni=cilium --csi=local-path -y
```

`-y` also covers the non-tty case: piped or CI runs never block on a prompt, they take defaults.

The choices are written to `/etc/k8s-setup/node.conf`, which `join-command`, `join-master-command`, and `uninstall` read back so they use the right CRI socket without you having to remember it.

### Container runtime (CRI)

| Option | What gets installed | kubeadm socket |
|---|---|---|
| `containerd` | `containerd.io` from Docker's apt repo | `unix:///run/containerd/containerd.sock` |
| `crio` | CRI-O from the `pkgs.k8s.io` CRI-O channel matching your Kubernetes minor; falls back to the upstream static bundle (`storage.googleapis.com/cri-o/artifacts`) when that channel doesn't exist yet | `unix:///var/run/crio/crio.sock` |
| `docker` | `docker-ce` plus the [cri-dockerd](https://github.com/Mirantis/cri-dockerd) shim, installed from its release tarball with the upstream systemd units | `unix:///var/run/cri-dockerd.sock` |

All three are configured for the **systemd** cgroup driver, because kubelet uses systemd and a mismatch makes kubelet fail on startup.

Kubernetes removed in-tree Docker support in 1.24 — the `docker` option is Docker Engine *plus* a CRI shim, not native support. Pick it only if you specifically need the Docker daemon on the node; it has the most moving parts of the three.

**Workers must use the same runtime.** Pass the same `--cri` to `k8s-setup worker install`, and use the `--cri-socket` that `k8s-setup controller join-command` appends to the join command.

### Pod network (CNI)

| Option | Default pod CIDR | Notes |
|---|---|---|
| `flannel` | `10.244.0.0/16` | Lightweight L3 VXLAN overlay, no NetworkPolicy engine. Common default for dev setups (e.g. K3s). |
| `calico` | `192.168.0.0/16` | Enterprise-grade NetworkPolicy, BGP or overlay. Heavily used in production. |
| `cilium` | `10.244.0.0/16` | eBPF dataplane, NetworkPolicy plus observability. Installed via the `cilium` CLI. Default CNI on GKE. |
| `none` | `10.244.0.0/16` | Nothing applied. Pods stay `Pending` until you apply a CNI yourself. |

The chosen CIDR is what `kubeadm init --pod-network-cidr` receives, and the same value is pushed into the plugin's own config, so the two can't drift:

- Flannel's manifest hardcodes `10.244.0.0/16` in its `net-conf.json` — the script rewrites it when you override the CIDR.
- Calico ships `CALICO_IPV4POOL_CIDR` commented out; the script uncomments it and pins it to the cluster's CIDR.
- Cilium's cluster-pool IPAM defaults to `10.0.0.0/8`; the script sets `ipam.operator.clusterPoolIPv4PodCIDRList` to the cluster's CIDR instead.

Manifests are fetched at the plugin's current release, not a version pinned in this repo.

Cloud-managed clusters use their own: **AWS VPC CNI** on EKS, **Azure CNI** on AKS. Neither applies to a self-managed kubeadm cluster.

Swapping CNIs later: remove the old plugin's manifest and its leftover interfaces (`cni0`, `flannel.1`, `vxlan.calico`, `cilium_*` — see `k8s-setup controller uninstall` Step 2), then apply the replacement, keeping its pod CIDR matched to `--pod-network-cidr`.

### Storage (CSI)

| Option | What it deploys | Node prerequisites |
|---|---|---|
| `none` | Nothing | — |
| `local-path` | [Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner), set as the default StorageClass. Volumes are node-local directories. | — |
| `nfs` | [nfs-subdir-external-provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner) pointed at an NFS server you already run, set as the default StorageClass. | `nfs-common` |
| `longhorn` | [Longhorn](https://longhorn.io) replicated block storage. | `open-iscsi`, `nfs-common`, `iscsid` enabled |

`local-path` is the practical choice for a single-node cluster — it has no external dependency, but its volumes are pinned to one node and are not replicated.

`nfs` needs `--nfs-server` and `--nfs-path` (prompted for if not passed). This script does **not** set up an NFS server; it wires a provisioner to one that already exists and is exported to your nodes.

`longhorn` wants three or more nodes to replicate across, and needs its host prerequisites on **every** node — run `k8s-setup worker install --csi=longhorn` on the workers so they get `open-iscsi` too.

## What it does, and why

**Step 1 — Install kubelet, kubeadm, kubectl**

- Adds `/etc/apt/keyrings` (the current apt-recommended place for repo signing keys, replacing the deprecated `apt-key add`) and imports the Kubernetes repo's signing key so apt can verify packages.
- Registers the repo for the resolved `v<major.minor>` channel.
- The k8s apt repo appends its own build revision to versions (e.g. `1.33.0-1.1`), so the script looks up the exact matching package string via `apt-cache madison` rather than guessing it.
- `apt-mark hold` pins the installed versions so a routine `apt upgrade` can't silently bump them — version skew between kubelet/kubeadm/kubectl (or across nodes) breaks clusters.

**Step 2 — Disable swap, load kernel modules**

- kubelet refuses to start with swap on (memory limits become unenforceable), so swap is turned off and commented out of `/etc/fstab` so it stays off after reboot.
- `overlay`: filesystem driver the container runtime uses for image layers.
- `br_netfilter`: makes bridged network traffic visible to iptables — without it, pod-to-pod traffic can bypass kube-proxy's rules.
- Both modules are persisted via `/etc/modules-load.d/kubernetes.conf` so they reload automatically on reboot.
- sysctl params (`bridge-nf-call-iptables`/`ip6tables`, `ip_forward`) are what actually make bridged-pod traffic filterable and let the node route packets between interfaces — required for pod/service networking to work at all.

**Step 3 — Install and configure the container runtime**

- Skips reinstalling if the chosen runtime is already present, so re-running the script on a provisioned node is safe.
- containerd and Docker Engine ship from Docker's apt repo, not the Kubernetes one, hence the separate repo/key setup. CRI-O comes from the `pkgs.k8s.io` CRI-O channel or the upstream static bundle.
- The cgroup driver is forced to systemd in all three cases (`SystemdCgroup = true` for containerd, a `crio.conf.d` drop-in for CRI-O, `native.cgroupdriver=systemd` in `daemon.json` for Docker) — kubelet manages cgroups via systemd and a mismatch stops it from starting.

**Step 4 — Storage prerequisites**

- Installs only the host packages the chosen provisioner needs (`nfs-common`, `open-iscsi`). The provisioner itself is deployed in Step 8, once there's a cluster to deploy it into.

**Step 5 — Pull images and initialize the cluster**

- Images are pre-pulled before `kubeadm init` so cluster bring-up doesn't stall/timeout on slow image pulls.
- `--pod-network-cidr` is whatever the CNI choice resolved to (see the CNI table above).
- `--cri-socket` is the socket for the chosen runtime — required, since a `docker` node also has containerd installed and kubeadm would otherwise refuse to guess.
- `--upload-certs` uploads control-plane certs to a Secret so additional control-plane nodes could join later without manually copying certs.
- `--control-plane-endpoint` uses the endpoint you passed, keeping the option open to later grow into an HA control-plane behind a stable name.
  - **HA (High Availability)** means running multiple control-plane nodes (typically 3, an odd number so etcd keeps quorum) instead of one, so the cluster survives a node dying. With a single control-plane node, that node crashing takes down the whole API — no `kubectl`, nothing new gets scheduled or healed, even though already-running pods keep going. With HA, losing one of three nodes still leaves two serving the API/etcd, so the cluster keeps working. A load balancer or DNS name in front of the nodes routes traffic to whichever are alive — which is exactly why the hostname (vs. bare IP) choice below matters.
  - Every cert and kubeconfig kubeadm generates bakes in whatever address you pass here — it becomes "the cluster's address" as far as clients are concerned.
  - **Bare IP** (e.g. `192.168.1.50`): fine for a single node. Add more control-plane nodes later for HA and that IP is just one of several — it's not a shared front door. Switching means regenerating certs and reconfiguring every client, with likely downtime.
  - **Hostname** (e.g. `k8s-cluster.mycompany.local`): certs/kubeconfigs only ever reference the name, not what's behind it. Today DNS points that name straight at the one node. Add more control-plane nodes later, drop a load balancer in front of them, and just repoint the DNS name at the load balancer — no cert regen, no client reconfig.
  - Analogy: bare IP is like handing out your friend's home address directly. A hostname is like handing out a PO box number — if your friend moves, you update the PO box's forwarding, and nobody holding "the address" needs to change anything.
  - Trade-off: the hostname has to actually resolve (DNS record, or `/etc/hosts` on every node/client) — a bare IP has no such dependency and just works.
- `--ignore-preflight-errors=all` skips kubeadm's preflight checks — convenient for VMs/lab boxes with non-standard resources, but worth revisiting before production use.

**Step 6 — Set up kubeconfig**

- Admin kubeconfig is copied to `$HOME/.kube/config` and chowned to the invoking user so `kubectl` works without `sudo` afterward.

**Step 7 — Apply the pod network**

- A fresh cluster has no CNI plugin, so pods stay stuck in `Pending`/`ContainerCreating` until one is applied. The chosen plugin is applied here with its CIDR matched to Step 5.
- With `--cni=none`, the script prints the CIDR the cluster was initialized with and leaves the rest to you.

**Step 8 — Deploy the storage provisioner**

- Applies the chosen provisioner's manifests and marks its StorageClass default, so PVCs without an explicit class bind.
- With `--csi=none` (the default) this step is a no-op.

**Finally**

- Writes `/etc/k8s-setup/node.conf` recording the CRI/CNI/CSI/pod-CIDR/version this node was built with, so the join and uninstall commands don't have to guess.
- kubeadm taints the control-plane node by default so regular pods can't be scheduled on it. The script prompts — "Allow workload pods to schedule on this control-plane node?" — and removes the taint only on `y`. Answer yes for single-node clusters where the control-plane must also run workloads; answer no (default) if you plan to join worker nodes and want the control-plane kept workload-free.
- Prints total script runtime (minutes/seconds) once setup completes.

## Notes / Caveats

- `--ignore-preflight-errors=all` bypasses preflight checks — fine for lab/dev, review before prod use.
- Removing the control-plane taint is only appropriate for single-node clusters; skip/revert for multi-node setups.
- Worker nodes must use the same CRI. `k8s-setup controller join-command` appends the right `--cri-socket` to the join command it prints.
- CNI and CSI manifests are fetched from upstream at their current release, so two installs run months apart can land on different plugin versions even at the same Kubernetes version.
