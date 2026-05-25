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
kubectl apply -k "github.com/CrunchyData/postgres-operator-examples/kustomize/install/namespace?ref=main"
kubectl apply --server-side -k "github.com/CrunchyData/postgres-operator-examples/kustomize/install/default?ref=main"
kubectl -n postgres-operator wait \
  --for=condition=Available deployment/pgo \
  --timeout=300s

echo "Applying local PostgresCluster overlay..."
kubectl apply -f "$REPO_ROOT/local-kind/postgrescluster-local.yaml"

echo "Waiting for database pods to appear..."
kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready pod \
  -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae \
  --timeout=600s

cat <<EOF

Local Patroni/PostgreSQL lab is deployed.

Check cluster:
  kubectl -n $NAMESPACE get postgrescluster,pods,svc,pvc

Check Patroni:
  PRIMARY=\$(kubectl -n $NAMESPACE get pod \\
    -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae,postgres-operator.crunchydata.com/role=master \\
    -o jsonpath='{.items[0].metadata.name}')
  kubectl -n $NAMESPACE exec "\$PRIMARY" -c database -- patronictl list

Get generated password:
  kubectl -n $NAMESPACE get secret prod-pgcluster-uae-pguser-postgres \\
    -o jsonpath='{.data.password}' | base64 --decode; echo

Connect through PgBouncer from the Mac:
  psql 'host=127.0.0.1 port=5555 dbname=postgres user=postgres sslmode=require'

EOF
