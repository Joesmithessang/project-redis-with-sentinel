# CLO835 — Semester Project 4: Redis with Sentinel

Self-healing Redis on a local **kind** cluster: one master, two replicas, three Sentinels
watching the master and auto-promoting a replica when it dies. Individual project — no
Helm, no kustomize, no EKS/managed AWS. Everything is raw manifests plus `kubectl`, same
spirit as the Week 10 kubeadm lab but with **no cloud dependency at all**: `kind` runs the
whole cluster as Docker containers on your own host, so there is no Terraform, no EBS CSI
driver, and no `terraform destroy` step to remember.

## What `bootstrap.sh` sets up (≈5–8 minutes, unattended)

| Requirement in the project spec | How `bootstrap.sh` provides it |
|---|---|
| kind cluster, 1 control-plane + 2 workers (`kind-config.yaml`) | `kind create cluster --config manifests/kind-config.yaml` |
| Namespace `redis-jeessang` | `kubectl create ns redis-jeessang` (skipped if it already exists) |
| StatefulSet + headless Service, master/replica decided by pod ordinal via Sentinel lookup | `manifests/02-redis-statefulset.yaml`, driven by the ConfigMap in `01-redis-config.yaml` |
| Sentinel workload + `sentinel-svc:26379`, quorum 2 | `manifests/04-sentinel-statefulset.yaml`, config in `03-sentinel-config.yaml` |
| 50 seeded keys + `owner=jeessang` | `manifests/06-seed-job.yaml`, run once pods are Ready |
| Student ID not hand-typed in 12 places | `envsubst '${STUDENT_ID}'` renders every manifest from one exported variable |
| `redis-cli` never installed on the host | a parked `redis-client` pod (`05-client-pod.yaml`) owns the binary; every check runs via `kubectl exec` |

Nothing here talks to AWS. If you're used to the Week 10 lab: there is no `terraform apply`,
no `LabInstanceProfile`, no EBS — `kind` nodes are Docker containers on your own EC2/Cloud9
box, so `docker`, `kind`, and `kubectl` on the host are the only prerequisites.

## Prerequisites

- A Linux host (your own EC2/Cloud9 instance) with Docker installed and your user in the
  `docker` group
- `kind`, `kubectl`, `envsubst` on PATH — see `bootstrap.sh` step 0 for install commands
- This repo cloned locally — no AWS credentials needed for anything in this project

## 1. Configure

```bash
export STUDENT_ID=xxxxxx
```

`bootstrap.sh` also accepts the ID as its first argument, so `export` is optional:

```bash
./bootstrap.sh jeessang
```

## 2. Apply and verify

```bash
./bootstrap.sh jeessang
kubectl get nodes -o wide                       # 1 control-plane + 2 workers, all Ready
kubectl get pods -n redis-jeessang -o wide       # 3 redis + 3 sentinel + redis-client, Running
kubectl get pods -n redis-jeessang -w            # watch it converge, Ctrl-C when steady
```

Then follow **`commands.sh`** section by section
`commands.sh`: run it alongside `runbook.md`, not all at once.

## 3. Cleanup — order matters

```bash
# on your host: run the CLEANUP section of commands.sh
#   (kills the writer loop, deletes the namespace, deletes the kind cluster)
kind delete cluster --name redis-lab
```

> **Why this order is simpler than Week 10's:** there is no EBS volume to orphan — every
> volume in this project is an `emptyDir`, which dies with the pod on purpose (see
> `runbook.md` §0 for why persistence is deliberately off). Deleting the kind cluster is
> the entire teardown; there is no `terraform destroy` meter to worry about.

## Files

| File | Purpose |
|---|---|
| `bootstrap.sh` | Full unattended build: kind cluster, namespace, manifests, wait-for-ready, seed.
| `commands.sh` | Section-by-section walkthrough for the live demo and rehearsal — run manually, not as a script. |
| `writer.sh` | Continuous writer that discovers the master via `SENTINEL get-master-addr-by-name`, never hardcodes a pod name. |
| `runbook.md` | The seven required operating procedures with exact, tested commands. |
| `manifests/` | `kind-config.yaml` + all rendered-at-bootstrap YAML (namespace, redis StatefulSet + config, sentinel StatefulSet + config, client pod, seed Job). |
| `evidence/` | `bootstrap-timing.log` and one full failover capture, per submission requirements. |
