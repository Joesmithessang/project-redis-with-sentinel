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
kubectl -n redis-jeessang exec redis-client -- redis-cli -h "$NEWM" \
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
