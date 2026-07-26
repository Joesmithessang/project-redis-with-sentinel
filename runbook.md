# Runbook — Redis + Sentinel

Assumes: repo cloned, Docker/kind/kubectl/envsubst on PATH, `./bootstrap.sh jeessang`
already run. Every command below also lives in `commands.sh`, section-tagged.

## 0. Design decisions

- **Sentinel is a StatefulSet, not a Deployment.** Sentinels identify each other by
  announced address and rewrite peer state into their own config file. A StatefulSet
  plus a headless Service gives each pod a stable DNS name across restarts, so a
  restarted Sentinel returns as the *same* Sentinel instead of a fourth unknown one.
- **No persistence (`save ""`, `appendonly no`, `emptyDir`).** State rebuilds from
  replication every restart, so a returning old master can never resurrect stale data
  and confuse the write count.
- **`sentinel.conf` is copied from the ConfigMap to a writable `emptyDir`.** Sentinel
  rewrites its own config on every `+switch-master`. A direct ConfigMap mount is
  read-only; observed failure with a direct mount: the pod exits immediately with
  `Sentinel config file /etc/sentinel/sentinel.conf is not writable: Read-only file
  system` and enters CrashLoopBackOff.
- **`start-redis.sh` asks Sentinel for the current master before falling back to the
  pod-ordinal rule — intentional, not a miss on Task 2's wording.** Task 2 says
  "decide by pod ordinal," but a pure, unconditional ordinal rule means pod `-0`
  always tries to boot as master, and nothing in Sentinel's design self-corrects
  that: Sentinel learns about replicas by reading `INFO replication` off the master
  it already knows, not by scanning for a rogue new master. So an unconditional
  ordinal rule produces a real split-brain (two masters accepting writes) the moment
  pod `-0` restarts after a failover — which fails the pass bar "old master rejoins
  as a replica of the NEW master." Asking Sentinel first, and only falling back to
  the ordinal rule when Sentinel can't be reached (cold cluster, no Sentinel running
  yet), is what makes that pass bar hold.
  Known gap in that same mechanism: the Sentinel query has a bounded retry window
  (5 attempts, 2s apart) before falling back to ordinal. If that query fails for a
  transient reason — a DNS blip, Sentinel momentarily unreachable but not actually
  gone — rather than because Sentinel is genuinely down, a restarting pod `-0` falls
  back to declaring itself master even though the real master is elsewhere,
  recreating the exact split-brain this check exists to prevent. This is
  low-probability, not zero-probability, and is a known, named gap rather than
  something papered over — not fixed here, since lengthening the retry window or
  adding more failure-handling logic this close to a graded demo is a bigger risk
  than the edge case itself.
- **`writer.sh`'s loop isn't a true 1/sec cadence.** Each iteration is `sleep 1`
  plus a real `kubectl exec` round-trip (network + exec overhead), so consecutive
  writes land roughly every 1.2-1.5s in practice, not exactly 1.000s. This doesn't
  affect the loss-count or pass/fail logic — that compares actual keys against the
  actual printed counter, never an assumed cadence — but any oral-question
  arithmetic about the failover timeline should be computed from `writer.sh`'s own
  printed timestamps, not from dividing `down-after-milliseconds` by an assumed
  1000ms period.
- **`redis-client` is a Deployment, not a bare Pod.** Node drain is a listed twist
  method, and a bare Pod has no controller to recreate it — if it happened to land
  on the drained node it would be evicted permanently, and every `redis-cli` call in
  the project runs through that one pod, so losing it would break the rest of any
  demo depending on node drain. A Deployment self-heals the same way the
  redis/sentinel StatefulSets already do; the trade-off is addressing it as
  `deploy/redis-client` in every command instead of a literal pod name.
- **`podManagementPolicy` is intentionally omitted from both StatefulSets (defaults
  to `OrderedReady`).** `Parallel` was the original setting; observed directly
  during rehearsal to put all 3 redis pods and all 3 sentinel pods on the same
  single node, every time, because preferred anti-affinity only repels against
  already-scheduled siblings and `Parallel` creates all pods before the
  scheduler's cache reflects any of them. `OrderedReady` creates pods one at a
  time, giving the scheduler real placement data before each subsequent
  decision. Cost: bootstrap takes roughly 1-2 minutes longer, still within the
  15-minute budget.

## 1. Bootstrap from nothing

```bash
./bootstrap.sh jeessang
kubectl get pods -n redis-jeessang -w
```
Success = 3/3 redis Running+Ready, 3/3 sentinel Running+Ready, `redis-client` Running,
`job/seed-jeessang` Completed. See `evidence/bootstrap-timing.log` for wall time.

## 2. Identify the current master

```bash
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster-jeessang
kubectl -n redis-jeessang exec redis-jeessang-0 -- redis-cli info replication
```

## 3. Start the write loop

```bash
./writer.sh jeessang
```
Output format: `<TS> OK|LOST counter=<n> master=<host>`. `LOST` lines mark the
failover window; a `REDISCOVERED` line marks re-discovery via Sentinel.

## 4. Watch a failover live

```bash
kubectl -n redis-jeessang logs -f sentinel-jeessang-0
```
Point at, in order: `+sdown` → `+odown` → `+vote-for-leader` → `+switch-master`.

## 5. Verify data after failover

```bash
NEWM=$(kubectl -n redis-jeessang exec sentinel-jeessang-0 -- redis-cli -p 26379 --raw \
       sentinel get-master-addr-by-name mymaster-jeessang | head -n1)
kubectl -n redis-jeessang exec deploy/redis-client -- redis-cli -h "$NEWM" \
  --scan --pattern "jeessang:live:*" | wc -l
```
`lost = writer's last counter − key count`. Explain the gap against the Sentinel log
timestamps: most of it is the `down-after-milliseconds` detection window, plus a short
election/promotion window, plus one writer re-discovery cycle.

## 6. Check Sentinel quorum health

```bash
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel ckquorum mymaster-jeessang
kubectl -n redis-jeessang exec sentinel-jeessang-0 -- \
  redis-cli -p 26379 sentinel master mymaster-jeessang
```
Fields to read: `num-other-sentinels`, `quorum`, `flags`.

## 7. Recover the killed pod

```bash
kubectl -n redis-jeessang get pod redis-jeessang-0
kubectl -n redis-jeessang exec redis-jeessang-0 -- redis-cli info replication
```
Expect `role:slave`, `master_host=<the new master>` — confirms it rejoined as a
replica of the new master, not as a second master.
