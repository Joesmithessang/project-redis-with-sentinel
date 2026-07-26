# Runbook — Redis + Sentinel

Assumes: repo cloned, Docker/kind/kubectl/envsubst on PATH, `./bootstrap.sh jeessang`
already run.

## 0. Design decisions

- **Sentinel runs as a StatefulSet, not a Deployment.** Each Sentinel writes peer
  data to its own config file. A StatefulSet with a headless Service gives each pod
  a fixed DNS name. A restarted Sentinel keeps its identity. It does not start as a
  new, unknown Sentinel.
- **The Redis pods use no persistent storage.** Settings: `save ""`, `appendonly
  no`, `emptyDir`. Each pod rebuilds its data from replication after a restart. An
  old master cannot return with stale data.
- **Sentinel copies `sentinel.conf` to a writable `emptyDir` at startup.** Sentinel
  rewrites this file after each `+switch-master` event. A direct ConfigMap mount is
  read-only. A direct mount causes a CrashLoopBackOff error.
- **`start-redis.sh` asks Sentinel for the master address first. It uses the
  pod-ordinal rule only as a fallback.** This order is intentional. Sentinel cannot
  detect a wrong master on its own. A fixed ordinal rule would restart pod `-0` as
  master after every failover. Two masters would then accept writes at the same
  time. This is a split-brain condition. It would also stop the old master from
  rejoining as a replica of the new master.
  Known gap: the Sentinel query retries 5 times over 10 seconds, then falls back to
  the ordinal rule. A short network fault could trigger this fallback path. The
  fallback could cause the same split-brain condition. This risk is low. The risk
  is not zero. The team will not fix this gap now. A late change close to the demo
  is a bigger risk than the gap.
- **`writer.sh` writes about every 1.2 to 1.5 seconds, not exactly 1 second.** Each
  loop adds a `kubectl exec` delay to the 1-second sleep. This delay does not
  change the lost-write count. The count compares real keys to the real counter.
  Use the timestamps printed by `writer.sh` for failover-timing math. Do not assume
  a fixed 1000 ms write interval.
- **`redis-client` runs as a Deployment, not a single Pod.** A node drain can
  remove a single Pod with no way to restart it. All `redis-cli` commands in this
  project use this one pod. A Deployment restarts the pod automatically. Commands
  must target `deploy/redis-client`, not a fixed pod name.
- **Both StatefulSets omit `podManagementPolicy`.** The default value applies:
  `OrderedReady`. The prior setting, `Parallel`, put all 3 redis pods and all 3
  Sentinel pods on one node during tests. Anti-affinity rules only avoid pods
  already placed. `Parallel` creates all pods before the scheduler sees any of
  them. `OrderedReady` creates pods one at a time. The scheduler sees real
  placement data before each new pod. Cost: bootstrap takes about 1 to 2 minutes
  longer. Total bootstrap time stays under the 15-minute limit.

## 1. Bootstrap from nothing

```bash
./bootstrap.sh jeessang
kubectl get pods -n redis-jeessang -w
```
Success = 3/3 redis Running+Ready, 3/3 sentinel Running+Ready, `redis-client` Running,
`job/seed-jeessang` Completed. See `evidence/bootstrap-timing.log` for wall time.

Validate the cluster and the manifests bootstrap.sh actually applied:
```bash
kubectl get nodes -o wide                          # control-plane + 2 workers, all Ready
kubectl get pods -n redis-jeessang -o wide          # 3 redis + 3 sentinel + redis-client, Running
ls manifests/rendered                               # the manifests bootstrap.sh actually applied
```

## 2. Identify the current master

```bash
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster-jeessang
kubectl -n redis-jeessang exec redis-jeessang-0 -- redis-cli info replication
```
Expect `role:master`, `connected_slaves:2`, and `slaveN` lines showing *hostnames*,
not raw IPs — that's `replica-announce-ip` at work.

## 3. Verify the seeded data (owner key + seed keys)

```bash
kubectl -n redis-jeessang exec deploy/redis-client -- redis-cli -h redis-jeessang-2.redis-hl get owner
# -> jeessang
kubectl -n redis-jeessang exec deploy/redis-client -- redis-cli -h redis-jeessang-1.redis-hl \
  --scan --pattern "jeessang:seed:*" | wc -l
# -> 50
```

## 4. Prove replicas reject writes

```bash
kubectl -n redis-jeessang exec deploy/redis-client -- redis-cli -h redis-jeessang-1.redis-hl set canary 1
# -> (error) READONLY You can't write against a read only replica.
```

## 5. Start the write loop

# terminal A:
```bash
./writer.sh jeessang
```
Output format: `<TS> OK|LOST counter=<n> master=<host>`. `LOST` lines mark the
failover window; a `REDISCOVERED` line marks re-discovery via Sentinel.

## 6. Watch a failover live

Two terminals: start the write loop first (#5), then in a second terminal:
# terminal B: (consider terminal C: k"ubectl get pods -n redis-jeessang -o wide -w" to watch pod 
# creation/termination, and terminal D: to execute failover trigger)
```bash
kubectl -n redis-jeessang logs -f sentinel-jeessang-0
```
Narrate behavior observed, in order: `+sdown` → `+odown` → `+vote-for-leader` → `+switch-master`.

Trigger the failover with one of three methods:

```bash
# method 1a - kill the master pod outright:
M=$(kubectl -n redis-jeessang exec sentinel-jeessang-0 -- redis-cli -p 26379 --raw \
    sentinel get-master-addr-by-name mymaster-jeessang | head -n1)
POD=${M%%.*}
kubectl -n redis-jeessang delete pod "$POD" --grace-period=0 --force

# method 1b - kill the master pod outright - kill loop:
for i in 1 2 3; do
  M=$(kubectl -n redis-jeessang exec sentinel-jeessang-0 -- redis-cli -p 26379 --raw \
      sentinel get-master-addr-by-name mymaster-jeessang | head -n1)
  POD=${M%%.*}
  echo "run $i: killing $POD"
  kubectl -n redis-jeessang delete pod "$POD" --grace-period=0 --force
  sleep 25
  kubectl -n redis-jeessang logs sentinel-jeessang-0 | tail -15
done
```
```bash
# method 2 - freeze the master without killing the pod:
M=$(kubectl -n redis-jeessang exec sentinel-jeessang-0 -- redis-cli -p 26379 --raw \
    sentinel get-master-addr-by-name mymaster-jeessang | head -n1)
POD=${M%%.*}
echo "current master pod: $POD"
kubectl -n redis-jeessang exec "$POD" -- redis-cli -h 127.0.0.1 debug sleep 60
```
```bash
# method 3 - drain the node the master runs on:
M=$(kubectl -n redis-jeessang exec sentinel-jeessang-0 -- redis-cli -p 26379 --raw \
    sentinel get-master-addr-by-name mymaster-jeessang | head -n1)
POD=${M%%.*}
echo "current master pod: $POD"
kubectl -n redis-jeessang get pods -o wide | grep -E "$POD|sentinel"   # see what else shares its node
NODE=$(kubectl -n redis-jeessang get pod "$POD" -o jsonpath='{.spec.nodeName}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
kubectl uncordon "$NODE"
```
`writer.sh` should print a handful of `LOST` lines, then `REDISCOVERED`, then `OK`
again.

## 7. Verify data after failover

```bash
NEWM=$(kubectl -n redis-jeessang exec sentinel-jeessang-0 -- redis-cli -p 26379 --raw \
       sentinel get-master-addr-by-name mymaster-jeessang | head -n1)
kubectl -n redis-jeessang exec deploy/redis-client -- redis-cli -h "$NEWM" \
  --scan --pattern "jeessang:live:*" | wc -l
```
`lost = writer's last counter − key count`. Explain the gap against the Sentinel log
timestamps

## 8. Check Sentinel quorum health

```bash
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel master mymaster-jeessang | grep -A1 -E 'num-other-sentinels|quorum|flags'
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel ckquorum mymaster-jeessang
```
Fields to read: `num-other-sentinels`, `quorum`, `flags`.

# delete one Sentinel pod and re-run ckquorum
```bash
kubectl -n redis-jeessang get pod sentinel-jeessang-1 -w   # confirm it's back Running
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel master mymaster-jeessang | grep -A1 -E 'num-other-sentinels|flags'
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel ckquorum mymaster-jeessang
```

## 9. Recover the killed pod

```bash
kubectl -n redis-jeessang get pod redis-jeessang-0
kubectl -n redis-jeessang exec redis-jeessang-0 -- redis-cli info replication | head -5
```
Expect `role:slave`, `master_host=<the new master>` — confirms it rejoined as a
replica of the new master, not as a second master.

## 10. Cleanup

No EBS, no PVCs, nothing to orphan — the cluster is the state.
```bash
pkill -f writer.sh || true
kubectl delete ns redis-jeessang
kind delete cluster --name redis-lab
```
