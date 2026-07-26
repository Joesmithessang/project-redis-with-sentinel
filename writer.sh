#!/usr/bin/env bash
# Project 4 — Task 6. Writes <ID>:live:<counter> once a second, always through
# Sentinel discovery. Runs on your host, driving the redis-client pod, same
# split as bootstrap.sh building infra and commands.sh operating it.
set -uo pipefail

STUDENT_ID="${1:-jeessang}"
NS="redis-${STUDENT_ID}"
MASTER_NAME="mymaster-${STUDENT_ID}"
POD="redis-client"

get_master() {
  kubectl -n "$NS" exec "$POD" -- redis-cli -h sentinel-svc -p 26379 --raw \
    sentinel get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | head -n1 | tr -d '\r'
}

MASTER="$(get_master)"
echo "writer: starting, master=$MASTER"

i=0
lost=0
while true; do
  i=$((i+1))
  TS="$(date '+%H:%M:%S.%3N')"
  OUT="$(kubectl -n "$NS" exec "$POD" -- redis-cli -h "$MASTER" -p 6379 \
        set "${STUDENT_ID}:live:${i}" "$TS" 2>&1)"
  if [ "$OUT" = "OK" ]; then
    echo "$TS  OK    counter=$i  master=$MASTER"
  else
    lost=$((lost+1))
    echo "$TS  LOST  counter=$i  master=$MASTER  err=${OUT%%$'\n'*}  lost_total=$lost"
    NEW="$(get_master)"
    if [ -n "$NEW" ] && [ "$NEW" != "$MASTER" ]; then
      echo "$TS  REDISCOVERED master: $MASTER -> $NEW"
      MASTER="$NEW"
    fi
  fi
  sleep 1
done
