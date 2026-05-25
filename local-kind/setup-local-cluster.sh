#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-patroni-prod-local}"
NAMESPACE="${NAMESPACE:-prod-pgcluster-uae-local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need docker
need kind
need kubectl

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running or this shell cannot reach the Docker socket." >&2
  echo "Start Docker Desktop, then rerun: $0" >&2
  exit 1
fi

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
else
  echo "kind cluster '$CLUSTER_NAME' already exists"
fi

kubectl config use-context "kind-$CLUSTER_NAME"
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "Installing Crunchy Postgres Operator..."
kubectl apply -k "github.com/CrunchyData/postgres-operator/config/namespace?ref=v6.0.1"
kubectl apply --server-side -k "github.com/CrunchyData/postgres-operator/config/default?ref=v6.0.1"
kubectl -n postgres-operator wait \
  --for=condition=Ready pod \
  --selector=postgres-operator.crunchydata.com/control-plane=postgres-operator \
  --timeout=300s

echo "Applying local PostgresCluster overlay..."
kubectl apply -f "$REPO_ROOT/local-kind/postgrescluster-local.yaml"

echo "Waiting for database pods to appear..."
for _ in {1..60}; do
  if kubectl -n "$NAMESPACE" get pod \
    -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae \
    --no-headers 2>/dev/null | grep -q .; then
    break
  fi
  sleep 5
done

echo "Waiting for core database, PgBouncer, and repo-host pods to become ready..."
for _ in {1..120}; do
  NOT_READY="$(
    kubectl -n "$NAMESPACE" get pod \
      -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae \
      --no-headers 2>/dev/null |
    grep -v -- "-backup-" |
    awk '{
      split($2, ready, "/")
      if (ready[1] != ready[2] || $3 != "Running") print
    }'
  )"
  if [[ -z "$NOT_READY" ]]; then
    break
  fi
  sleep 5
done

if [[ -n "${NOT_READY:-}" ]]; then
  echo "Timed out waiting for core pods to become ready:" >&2
  echo "$NOT_READY" >&2
  exit 1
fi

cat <<EOF

Local Patroni/PostgreSQL lab is deployed.

Check cluster:
  kubectl -n $NAMESPACE get postgrescluster,pods,svc,pvc

Check Patroni:
  PRIMARY=\$(kubectl -n $NAMESPACE get pod \\
    -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae,postgres-operator.crunchydata.com/role=master \\
    -o jsonpath='{.items[0].metadata.name}')
  kubectl -n $NAMESPACE exec "\$PRIMARY" -c database -- patronictl list

Get generated tps-app password:
  kubectl -n $NAMESPACE get secret prod-pgcluster-uae-pguser-tps-app \\
    -o jsonpath='{.data.password}' | base64 --decode; echo

Connect through PgBouncer from the Mac:
  psql 'host=127.0.0.1 port=5555 dbname=tps user=tps-app sslmode=require'

EOF
