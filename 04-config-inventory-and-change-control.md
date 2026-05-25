# Config Inventory And Change Control

## Rules

- Persistent database config changes must be made through `oc patch postgrescluster`.
- Do not use `patronictl edit-config`; Crunchy PGO can overwrite it.
- Do not edit generated ConfigMaps directly.
- Do not decode or print Kubernetes Secret values unless there is an approved operational need.
- Always capture before and after evidence.

## PROD ConfigMaps

Captured names:

```text
configmap/config-service-cabundle
configmap/config-trusted-cabundle
configmap/istio-ca-root-cert
configmap/kube-root-ca.crt
configmap/openshift-service-ca.crt
configmap/pgbackrest-uae-prod
configmap/prod-pg-inspector-metrics-scripts
configmap/prod-pgcluster-uae
configmap/prod-pgcluster-uae-config
configmap/prod-pgcluster-uae-dc1-5c2q-config
configmap/prod-pgcluster-uae-dc1-9c5j-config
configmap/prod-pgcluster-uae-exporter-queries-config
configmap/prod-pgcluster-uae-pgbackrest-config
configmap/prod-pgcluster-uae-pgbouncer
configmap/prod-pgo18-prometheus-config
```

Important captured config files:

| Config | Local snapshot |
|---|---|
| pgBackRest | `configs/prod-pgbackrest-config.md` |
| PgBouncer | `configs/prod-pgbouncer.ini` |
| Patroni | `configs/prod-patroni.yaml` |
| PostgresCluster CR summary | `configs/prod-postgrescluster-summary.md` |

## PROD Secret Names

Secret values are not included. Names only:

```text
secret/pg-object-monitor-agent-db
secret/pg-object-monitor-agent-token
secret/pg-object-monitor-uat-image-pull
secret/pgadmin-modern-login
secret/pgbackrest-uae-prod
secret/pgo-root-cacert
secret/prod-pgcluster-uae
secret/prod-pgcluster-uae-cluster-cert
secret/prod-pgcluster-uae-dc1-5c2q-certs
secret/prod-pgcluster-uae-dc1-9c5j-certs
secret/prod-pgcluster-uae-monitoring
secret/prod-pgcluster-uae-pgbackrest
secret/prod-pgcluster-uae-pgbackrest-secret
secret/prod-pgcluster-uae-pgbouncer
secret/prod-pgcluster-uae-pguser-common-app
secret/prod-pgcluster-uae-pguser-postgres
secret/prod-pgcluster-uae-pguser-ro-user
secret/prod-pgcluster-uae-pguser-service-app
secret/prod-pgcluster-uae-pguser-tps-app
secret/prod-pgcluster-uae-pguser-tpsdw-app
secret/prod-pgcluster-uae-replication-cert
secret/prod-restore-from-uat-20260521-pgbackrest-secret
```

## Export Fresh Config Snapshot

Use this when you need updated local evidence. This exports config and Secret names, not Secret values.

```bash
SNAP_DIR="/home/mohsinali@habibbank.local/PROD_PATRONI/config_snapshot_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$SNAP_DIR"

oc config current-context > "$SNAP_DIR/context.txt"
oc project > "$SNAP_DIR/project.txt"

oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o yaml > "$SNAP_DIR/prod-postgrescluster.yaml"
oc get configmap prod-pgcluster-uae-config -n prod-pgcluster-uae -o yaml > "$SNAP_DIR/prod-patroni-configmap.yaml"
oc get configmap prod-pgcluster-uae-pgbackrest-config -n prod-pgcluster-uae -o yaml > "$SNAP_DIR/prod-pgbackrest-configmap.yaml"
oc get configmap prod-pgcluster-uae-pgbouncer -n prod-pgcluster-uae -o yaml > "$SNAP_DIR/prod-pgbouncer-configmap.yaml"
oc get configmap,secret -n prod-pgcluster-uae -o name > "$SNAP_DIR/configmap-secret-names.txt"
```

Do not export `oc get secret -o yaml` into a general docs folder unless the file is encrypted and access-controlled.

## Export Full Cluster Manifest Bundle

For a rebuild/reference bundle, use the manifest exporter from this folder:

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI/PROD_CLUSTER_OPERATIONS_README_20260522
./scripts/export-prod-cluster-manifests.sh
```

Default output:

```text
manifests/prod-pgcluster-uae/<YYYYMMDD_HHMMSS>/
manifests/latest -> prod-pgcluster-uae/<latest-capture>
```

The exporter captures cleaned JSON manifests for the namespace, `PostgresCluster`, ConfigMaps, services/routes, workloads, PVCs, RBAC, monitoring resources, StorageClasses, and operator evidence. It also captures Secret names, types, and key names only; Secret values are replaced by placeholders.

Use the bundle as rebuild source material, not as a blind restore. Install the correct operators/CRDs first, recreate Secrets through the approved secure process, review target namespace/storage/load balancer/S3 differences, then apply the reviewed `PostgresCluster` CR and supporting manifests.

## Safe Parameter Change Pattern

Example for a reloadable parameter:

```bash
oc config current-context
oc project

oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae \
  --type=json \
  -p '[{"op":"replace","path":"/spec/patroni/dynamicConfiguration/postgresql/parameters/log_min_duration_statement","value":"1000"}]'
```

For postmaster parameters such as `max_connections`, `shared_buffers`, or `wal_level`, a restart is required after patching. Do not run restart commands without approval.

Check pending restart:

```bash
oc exec -n prod-pgcluster-uae <database-pod> -c database -- patronictl list
```

## pgBackRest Config Change Pattern

Patch the `PostgresCluster` CR, not the generated ConfigMap.

Example shape:

```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae \
  --type=merge \
  -p '{"spec":{"backups":{"pgbackrest":{"global":{"repo1-retention-full":"4"}}}}}'
```

Then verify operator reconciliation:

```bash
oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json | \
  jq '.spec.backups.pgbackrest'

oc get configmap prod-pgcluster-uae-pgbackrest-config -n prod-pgcluster-uae -o yaml
```

## PgBouncer Config Change Pattern

Patch:

```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae \
  --type=merge \
  -p '{"spec":{"proxy":{"pgBouncer":{"config":{"global":{"default_pool_size":"50"}}}}}}'
```

Verify:

```bash
oc get configmap prod-pgcluster-uae-pgbouncer -n prod-pgcluster-uae -o yaml
oc get pods -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/role=pgbouncer -o wide
```

## Rollback Pattern

Before changing any CR value, capture the old value:

```bash
oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json | \
  jq '.spec.patroni.dynamicConfiguration.postgresql.parameters'
```

Rollback is another CR patch to the old value. Do not use `git checkout`, do not edit generated ConfigMaps, and do not restart blindly.
