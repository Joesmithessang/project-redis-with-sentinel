#!/bin/bash
# Project 4 Redis with sentinel — build: kind cluster -> namespace -> manifests ->
# wait-for-ready -> seed. Run by hand on your host: ./bootstrap.sh jeessang

set -euxo pipefail

STUDENT_ID="${1:-${STUDENT_ID:-jeessang}}"
export STUDENT_ID
NS="redis-${STUDENT_ID}"
CLUSTER="redis-lab"
START=$(date +%s)

# 0. Host prerequisites (run once per host; comment out after first run)
if ! command -v kind >/dev/null 2>&1; then
  echo "installing kind, kubectl, envsubst"
  sudo apt-get update
  sudo apt-get install -y docker.io gettext-base
  sudo usermod -aG docker "$USER"
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
  sudo install -o root -g root -m 0755 kind /usr/local/bin/kind
fi

# 1. Render manifests — single variable, no hand-typed IDs (Task 8)
echo "== [1/6] rendering manifests for ${STUDENT_ID} =="
rm -rf manifests/rendered && mkdir -p manifests/rendered evidence
for f in manifests/*.yaml; do
  base=$(basename "$f")
  [ "$base" = "kind-config.yaml" ] && continue
  envsubst '${STUDENT_ID}' < "$f" > "manifests/rendered/$base"
done

# 2. kind cluster — 1 control-plane + 2 workers, no EKS, no managed AWS
echo "== [2/6] creating kind cluster =="
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config manifests/kind-config.yaml
else
  echo "cluster $CLUSTER already exists, reusing"
fi
kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

# 3. Pre-load the image into all nodes
echo "== [3/6] pre-loading redis:7-alpine =="
docker pull redis:7-alpine
kind load docker-image redis:7-alpine --name "$CLUSTER"

# 4. Namespace + manifests
echo "== [4/6] applying manifests to namespace ${NS} =="
kubectl apply -f manifests/rendered/00-namespace.yaml
kubectl apply -n "$NS" -f manifests/rendered/01-redis-config.yaml
kubectl apply -n "$NS" -f manifests/rendered/02-redis-statefulset.yaml
kubectl apply -n "$NS" -f manifests/rendered/03-sentinel-config.yaml
kubectl apply -n "$NS" -f manifests/rendered/04-sentinel-statefulset.yaml
kubectl apply -n "$NS" -f manifests/rendered/05-client-pod.yaml

# 5. Wait for readiness (kubectl wait / rollout status, not sleep)
echo "== [5/6] waiting for readiness =="
kubectl -n "$NS" rollout status "statefulset/redis-${STUDENT_ID}"    --timeout=420s
kubectl -n "$NS" rollout status "statefulset/sentinel-${STUDENT_ID}" --timeout=420s
kubectl -n "$NS" wait --for=condition=Ready pod/redis-client --timeout=180s

# 6. Seed: 50 keys + owner=<ID> (Task 5)
echo "== [6/6] seeding =="
kubectl apply -n "$NS" -f manifests/rendered/06-seed-job.yaml
kubectl -n "$NS" wait --for=condition=complete "job/seed-${STUDENT_ID}" --timeout=300s

END=$(date +%s)
ELAPSED=$((END-START))
kubectl -n "$NS" get pods -o wide
echo "MASTER: $(kubectl -n "$NS" exec redis-client -- redis-cli -h sentinel-svc -p 26379 --raw \
  sentinel get-master-addr-by-name "mymaster-${STUDENT_ID}" | head -n1)"
printf 'bootstrap %s completed in %s seconds (%s)\n' "$STUDENT_ID" "$ELAPSED" "$(date -Is)" \
  | tee -a evidence/bootstrap-timing.log
echo "Prerequisites built, cluster seeded."
