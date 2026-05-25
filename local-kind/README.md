# Local macOS Kubernetes Lab

This folder creates a small local Kubernetes lab based on the production capture in this repo.

It is not a production restore. The production `PostgresCluster` uses OpenShift, OCS/Ceph storage, node labels, large CPU/RAM requests, S3 pgBackRest secrets, monitoring CRDs, and Habib Bank network endpoints. The local overlay keeps the useful shape for testing:

- Crunchy Postgres Operator / PGO
- PostgreSQL 18
- Two PostgreSQL instances managed by Patroni
- Synchronous replication settings copied from the production capture
- PgBouncer on port `5555`
- Local pgBackRest repository PVC instead of production S3
- Small CPU, memory, and disk requests for a Mac

## Minimum Local Requirements

- Docker Desktop running
- `kind`
- `kubectl`
- About 4 CPU cores and 6 GB free RAM available to Docker
- About 8 GB free disk space

## Create The Lab

From the repo root:

```bash
./local-kind/setup-local-cluster.sh
```

The script creates a kind cluster named `patroni-prod-local`, installs Crunchy Postgres for Kubernetes from the official Crunchy Data operator repository pinned to `v6.0.1`, and applies `local-kind/postgrescluster-local.yaml`.

## Check Status

```bash
kubectl -n prod-pgcluster-uae-local get postgrescluster,pods,svc,pvc
```

Find the current Patroni leader:

```bash
PRIMARY=$(kubectl -n prod-pgcluster-uae-local get pod \
  -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae,postgres-operator.crunchydata.com/role=master \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n prod-pgcluster-uae-local exec "$PRIMARY" -c database -- patronictl list
```

Get the generated `tps-app` password:

```bash
kubectl -n prod-pgcluster-uae-local get secret prod-pgcluster-uae-pguser-tps-app \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

Connect from macOS through PgBouncer:

```bash
psql 'host=127.0.0.1 port=5555 dbname=tps user=tps-app sslmode=require'
```

## Delete The Lab

```bash
./local-kind/delete-local-cluster.sh
```

## What Was Intentionally Changed From Production

- Namespace changed to `prod-pgcluster-uae-local`.
- Storage reduced from `2Ti` data and `500Gi` WAL to small local PVCs.
- CPU and memory requests reduced to fit a Mac.
- OpenShift node affinity and anti-affinity removed.
- S3 pgBackRest repo replaced with a local PVC repo.
- `pgaudit` removed from `shared_preload_libraries` for portability.
- PgBouncer reduced to one replica and exposed through kind port mapping `127.0.0.1:5555`.
