#!/bin/bash
# Project 4 - Redis with Sentinel, live-demo command walkthrough.
#
# Run these ON YOUR HOST, section by section, alongside runbook.md.
# Do NOT run the whole file at once.
#
# ./bootstrap.sh jeessang has already built the cluster before you start here
# bootstrap builds it, commands.sh operates it.
#
# alias k=kubectl   # optional

export STUDENT_ID=jeessang
export NS=redis-${STUDENT_ID}
export MASTER_NAME=mymaster-${STUDENT_ID}

########################################################
# 0) Verify the cluster (mirrors "Cluster is ready" in the Week 10 deck)
########################################################
kubectl get nodes -o wide                        # control-plane + 2 workers, all Ready
kubectl get pods -n "$NS" -o wide                 # 3 redis + 3 sentinel + redis-client, Running
ls manifests/rendered                             # the manifests bootstrap.sh actually applied

########################################################
# PART 1 - Identify the current master
########################################################
kubectl -n "$NS" exec sentinel-${STUDENT_ID}-0 -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name "$MASTER_NAME"
# cross-check from Redis itself:
kubectl -n "$NS" exec redis-${STUDENT_ID}-0 -- redis-cli info replication
# expect role:master, connected_slaves:2, slaveN lines showing *hostnames* not raw IPs
# (that's replica-announce-ip doing its job — see runbook.md §0)

########################################################
# PART 2 - Prove the data is yours (owner key + seed keys)
########################################################
kubectl -n "$NS" exec redis-client -- redis-cli -h redis-${STUDENT_ID}-2.redis-hl get owner
# -> jeessang
kubectl -n "$NS" exec redis-client -- redis-cli -h redis-${STUDENT_ID}-1.redis-hl \
  --scan --pattern "${STUDENT_ID}:seed:*" | wc -l
# -> 50

########################################################
# PART 3 - Prove replicas reject writes (Task 7)
########################################################
kubectl -n "$NS" exec redis-client -- redis-cli -h redis-${STUDENT_ID}-1.redis-hl set canary 1
# -> (error) READONLY You can't write against a read only replica.

########################################################
# PART 4 - Start the write loop and watch a failover live
# (two terminals; run each block below in its own SSH session)
########################################################
# terminal A:
./writer.sh "$STUDENT_ID"

# terminal B:
kubectl -n "$NS" logs -f sentinel-${STUDENT_ID}-0
#   point at, in order: +sdown -> +odown -> +vote-for-leader -> +switch-master

########################################################
# PART 5 - Trigger the failover (method 1)
########################################################
M=$(kubectl -n "$NS" exec sentinel-${STUDENT_ID}-0 -- redis-cli -p 26379 --raw \
    sentinel get-master-addr-by-name "$MASTER_NAME" | head -n1)
POD=${M%%.*}
echo "killing $POD"
kubectl -n "$NS" delete pod "$POD" --grace-period=0 --force
# writer.sh should print a handful of LOST lines, then REDISCOVERED, then OK again

# method 2 - freeze without killing the pod:
kubectl -n "$NS" exec "$POD" -- redis-cli -h 127.0.0.1 debug sleep 60

# method 3 - drain the node the master is on:
NODE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
kubectl uncordon "$NODE"                          # run once you're done rehearsing

########################################################
# PART 6 - Verify data after failover and count losses
########################################################
NEWM=$(kubectl -n "$NS" exec sentinel-${STUDENT_ID}-0 -- redis-cli -p 26379 --raw \
       sentinel get-master-addr-by-name "$MASTER_NAME" | head -n1)
kubectl -n "$NS" exec redis-client -- redis-cli -h "$NEWM" --scan --pattern "${STUDENT_ID}:live:*" | wc -l
# compare this count against writer.sh's last printed counter -> that's your lost-write number

kubectl -n "$NS" exec redis-${STUDENT_ID}-0 -- redis-cli info replication | head -5
# expect role:slave, master_host=<the new master> -> old master rejoined correctly

########################################################
# PART 7 - Sentinel quorum health (twist part 2: a Sentinel gets deleted)
########################################################
kubectl -n "$NS" exec sentinel-${STUDENT_ID}-0 -- \
  redis-cli -p 26379 sentinel master "$MASTER_NAME" | grep -A1 -E 'num-other-sentinels|quorum|flags'
kubectl -n "$NS" exec sentinel-${STUDENT_ID}-0 -- redis-cli -p 26379 sentinel ckquorum "$MASTER_NAME"

########################################################
# CLEANUP - no EBS, no PVCs, nothing to orphan; the cluster IS the state
########################################################
pkill -f writer.sh || true
kubectl delete ns "$NS"
kind delete cluster --name redis-lab
