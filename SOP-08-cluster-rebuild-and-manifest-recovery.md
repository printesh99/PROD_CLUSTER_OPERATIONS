# SOP-08: Cluster Rebuild and Manifest Recovery
## Habib Bank UAE Production PostgreSQL Cluster

**Cluster:** prod-pgcluster-uae
**OCP Context:** prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
**Namespace:** prod-pgcluster-uae
**PostgresCluster CR:** prod-pgcluster-uae
**Working Directory:** /home/mohsinali@habibbank.local/PROD_PATRONI
**S3 Bucket:** pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
**Last Reviewed:** 2026-05-22

---

## 1. Purpose and Scope

This SOP covers rebuilding the PROD PostgreSQL cluster from its captured manifest bundle and pgBackRest backup repository. It applies to disaster recovery and migration scenarios where the original OCP cluster or its PVCs are lost or unrecoverable.

**This SOP does NOT cover:**
- Normal DR failover/promotion (covered in SOP-04)
- Point-in-time recovery on a running cluster (covered in SOP-03)
- Configuration change management for a healthy cluster (covered in SOP-05)

**Trigger conditions for this SOP:**
- PROD OCP cluster is unrecoverable (entire cluster lost, corrupted etcd, catastrophic node failure)
- PVCs for all PROD database pods are lost or corrupt
- A migration to a new OCP cluster is required and PROD must be reconstructed
- DR cluster has been promoted and the old PROD infrastructure must be rebuilt as a new standby

**Authority:** This SOP may only be executed with DBA lead sign-off and CAB approval. No unilateral execution.

---

## 2. Manifest Bundle Overview

### What is the manifest bundle

The manifest export script (`./scripts/export-prod-cluster-manifests.sh`) produces a point-in-time capture of all Kubernetes/OCP resource definitions for the PROD PostgreSQL cluster. These manifests are sufficient to reconstruct the cluster skeleton — the data is recovered from the pgBackRest S3 repository.

### Bundle location

```
/home/mohsinali@habibbank.local/PROD_PATRONI/
  manifests/
    prod-pgcluster-uae/
      YYYYMMDD_HHMMSS/       # timestamped snapshot directory
        namespace.json
        postgrescluster-cr.json
        configmaps/
        services/
        routes/
        workloads/
        pvcs/
        rbac/
        monitoring/
        storageclasses/
    latest -> prod-pgcluster-uae/YYYYMMDD_HHMMSS/   # symlink to most recent export
```

### What each manifest category contains

| Directory/File | Contents | Notes |
|---|---|---|
| namespace.json | Namespace definition with labels and annotations | Update name/labels for rebuild target |
| postgrescluster-cr.json | Full PostgresCluster CR spec (cleaned) | Primary rebuild artifact — review all fields before apply |
| configmaps/ | All ConfigMaps (PGO-generated ones are for reference — PGO recreates them) | Use only non-PGO ConfigMaps for direct apply |
| services/ | Service definitions including LoadBalancer services | Verify IP ranges are valid in new environment |
| routes/ | OCP Route definitions | Update hostnames if different cluster |
| workloads/ | StatefulSet, Deployment, ReplicaSet definitions | PGO recreates these — for reference only |
| pvcs/ | PVC definitions | Use as template; new PVCs will be created by PGO |
| rbac/ | ServiceAccounts, Roles, RoleBindings | Apply before the CR |
| monitoring/ | PrometheusRule, ServiceMonitor definitions | Apply after cluster is healthy |
| storageclasses/ | StorageClass references | Must confirm StorageClass exists before CR apply |

### Secrets handling

Secrets are **not** stored in the manifest bundle. The export script captures Secret names and key names only, replacing all values with `[REDACTED]`. This is intentional — secret values must never be stored in documentation or version control.

**Export script:**
```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI
./scripts/export-prod-cluster-manifests.sh
```

---

## 3. Pre-Rebuild Checklist

Complete every item before issuing any `oc apply` or `oc create` commands against the target environment.

| Item | Check | Notes |
|---|---|---|
| Target OCP cluster API reachable | `oc cluster-info` | Must resolve and authenticate |
| Target namespace does not already exist with conflicting resources | `oc get ns <target-ns>` | If it exists, verify it is empty or a clean slate |
| Target StorageClass available | `oc get storageclass` | Must have ocs-storagecluster-ceph-rbd equivalent |
| StorageClass supports ReadWriteOnce and RWX (for shared volumes) | `oc describe storageclass <name>` | PGO uses RWO for pgdata and pgwal PVCs |
| S3 bucket accessible from the new OCP cluster | curl or aws s3 ls from a test pod | pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e |
| S3 credentials (for pgBackRest Secret recreation) available via secure channel | Verified with credential store team | Never from documentation |
| LoadBalancer IP range compatible (or plan to use different IPs) | Network team confirmation | PROD primary LB was 10.171.1.229:5555; PROD PgBouncer LB was 10.171.1.205:5555 |
| Network policies allow pod-to-pod communication within namespace | OCP network policy review | |
| Crunchy Data PGO operator installed on target cluster | `oc get csv -n openshift-operators | grep pgo` | Must be installed before applying PostgresCluster CR |
| PGO CRD present | `oc get crd postgresclusters.postgres-operator.crunchydata.com` | |
| Backup manifest bundle exported (if PROD was still reachable before disaster) | Check manifests/latest symlink | Run export script if possible |
| CAB approval obtained | Change ticket number: ___________ | |
| DBA lead sign-off obtained | Name + timestamp: ___________ | |

---

## 4. Fresh Manifest Export (If Cluster Still Reachable)

If the original PROD cluster is still reachable at the time of initiating this procedure (e.g., planned migration), export a fresh manifest bundle before touching anything.

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI

# Confirm PROD context
oc config current-context
# Expected: prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali

# Run export script
./scripts/export-prod-cluster-manifests.sh

# Verify output completeness
EXPORT_DIR=$(readlink -f manifests/latest)
echo "Latest export: $EXPORT_DIR"
ls -la $EXPORT_DIR
ls -la $EXPORT_DIR/configmaps/
ls -la $EXPORT_DIR/rbac/

# Verify the PostgresCluster CR is captured
cat $EXPORT_DIR/postgrescluster-cr.json | jq '.kind, .metadata.name, .spec.instances | length'
# Expected: "PostgresCluster", "prod-pgcluster-uae", 1 (or more instance groups)
```

---

## 5. Operator Installation Prerequisite

The Crunchy Data PGO operator must be installed on the target OCP cluster **before** the PostgresCluster CR is applied. The operator watches for PostgresCluster CRs and creates all child resources.

### Verify operator is installed

```bash
# Check for PGO operator
oc get csv -n openshift-operators | grep -i pgo
oc get csv -n openshift-operators | grep -i crunchy

# Check for the CRD
oc get crd postgresclusters.postgres-operator.crunchydata.com
```

### Verify operator is healthy

```bash
# Find the PGO operator pod
oc get pods -n openshift-operators | grep pgo

# Check operator logs for errors
oc logs -n openshift-operators <pgo-operator-pod> --tail=50
```

**If operator is not installed:** Install via OperatorHub on the target OCP cluster, or apply the operator manifests directly from the Crunchy Data distribution. The operator version must be compatible with the PostgresCluster CR API version used in the export bundle.

---

## 6. Secret Recreation Process

Secrets must be recreated in the target namespace **before** the PostgresCluster CR is applied. The operator references these Secrets by name during reconciliation.

### Critical rule

**Never** retrieve Secret values from documentation, SOP files, git history, or any written record. Documentation deliberately stores only Secret names and key names with `[REDACTED]` values. Retrieve actual values through the approved secure credential store.

### Secrets required before CR apply

| Secret Name | Keys Required | Source |
|---|---|---|
| prod-pgcluster-uae-pgbackrest-secret | AWS_ACCESS_KEY_ID or equivalent, AWS_SECRET_ACCESS_KEY or equivalent | OCP Vault / credential store |
| prod-pgcluster-uae-replication | username, password | OCP Vault / credential store |
| prod-pgcluster-uae-patroni | username, password | OCP Vault / credential store |
| prod-pgcluster-uae-pguser-* | username, password, dbname (one per pgUser defined in CR) | OCP Vault / credential store |

**Note:** PGO will auto-generate some Secrets (like TLS certs) if they do not exist. However, the pgBackRest S3 credentials and any pre-existing user credentials must match the original values if you are restoring from an existing S3 repository.

### Create the namespace and Secrets

```bash
# Switch to target OCP context first
oc config use-context <target-context>

# Create namespace
oc create namespace prod-pgcluster-uae

# Create pgBackRest S3 Secret (fill in actual values from credential store)
oc create secret generic prod-pgcluster-uae-pgbackrest-secret \
  -n prod-pgcluster-uae \
  --from-literal=<KEY_NAME>=<VALUE_FROM_CREDENTIAL_STORE> \
  ...

# Verify Secret exists (check names only — do not decode values)
oc get secrets -n prod-pgcluster-uae
```

---

## 7. PostgresCluster CR Rebuild Sequence

### 7a. Review and adapt the CR before applying

The exported CR must be reviewed and potentially modified for the new environment before application.

```bash
EXPORT_DIR=$(readlink -f /home/mohsinali@habibbank.local/PROD_PATRONI/manifests/latest)
cat $EXPORT_DIR/postgrescluster-cr.json | jq '.' | less
```

**Fields to review and potentially update:**

| Field | Original Value | Check |
|---|---|---|
| metadata.namespace | prod-pgcluster-uae | Update if rebuilding in a different namespace |
| spec.instances[].dataVolumeClaimSpec.storageClassName | ocs-storagecluster-ceph-rbd | Update if target cluster uses a different StorageClass name |
| spec.instances[].walVolumeClaimSpec.storageClassName | ocs-storagecluster-ceph-rbd | Update if target cluster uses a different StorageClass name |
| spec.backups.pgbackrest.repos[0].s3.endpoint | (S3 endpoint URL) | Confirm S3 endpoint is reachable from new cluster |
| spec.backups.pgbackrest.repos[0].s3.bucket | pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e | Must match existing bucket |
| spec.proxy.pgBouncer.service.type | LoadBalancer | Confirm LB provisioner available; may need to switch to NodePort temporarily |
| spec.service.type | LoadBalancer | Same as above |

### 7b. Apply resources in sequence

```bash
TARGET_NS=prod-pgcluster-uae
EXPORT_DIR=/home/mohsinali@habibbank.local/PROD_PATRONI/manifests/latest

# Step 1: RBAC (ServiceAccounts, Roles, RoleBindings)
oc apply -f $EXPORT_DIR/rbac/ -n $TARGET_NS

# Step 2: Non-PGO ConfigMaps (if any custom ones exist outside PGO generation)
# Note: PGO-generated ConfigMaps (prod-pgcluster-uae-config, prod-pgcluster-uae-pgbackrest-config,
# prod-pgcluster-uae-pgbouncer) will be regenerated by PGO — do not apply them manually

# Step 3: Verify Secrets are present
oc get secrets -n $TARGET_NS

# Step 4: Apply the PostgresCluster CR
oc apply -f $EXPORT_DIR/postgrescluster-cr.json -n $TARGET_NS

# Step 5: Watch operator reconciliation
oc get postgrescluster prod-pgcluster-uae -n $TARGET_NS -w
```

### 7c. Monitor operator reconciliation

```bash
# Watch CR status conditions
watch -n 10 "oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json \
  | jq '.status.conditions[] | {type: .type, status: .status, reason: .reason, message: .message}'"

# Watch pod creation
oc get pods -n prod-pgcluster-uae -w

# Watch PGO operator logs for this cluster
oc logs -n openshift-operators <pgo-operator-pod> -f | grep prod-pgcluster-uae
```

**Expected reconciliation sequence:**
1. PGO creates ServiceAccounts, ConfigMaps, Secrets (TLS certs if not present)
2. PGO creates the pgBackRest repo host StatefulSet
3. pgBackRest stanza is initialized or verified
4. PGO creates the database StatefulSets (one per instance group)
5. Primary pod starts, initializes or restores database
6. Standby pod starts, performs pg_basebackup from primary
7. PgBouncer Deployment is created
8. Services and endpoints become active

---

## 8. Restoring Data from S3 (If PVCs Lost)

If the PVCs are lost and the cluster must restore from pgBackRest S3 backups, the PostgresCluster CR must include a `dataSource` stanza pointing to the pgBackRest repository.

### Verify backup availability before applying restore CR

From any pod with pgBackRest access, or a temporary pod in the new namespace:
```bash
pgbackrest --stanza=db \
  --repo1-type=s3 \
  --repo1-s3-bucket=pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e \
  --repo1-s3-endpoint=<endpoint> \
  --repo1-s3-region=<region> \
  --repo1-path=/<path> \
  info
# Verify: status=ok, at least one full backup visible, recent WAL archive timestamps
```

### Add dataSource to the PostgresCluster CR for restore

In the CR spec, add:

```json
{
  "spec": {
    "dataSource": {
      "pgbackrest": {
        "stanza": "db",
        "configuration": [
          {
            "secret": {
              "name": "prod-pgcluster-uae-pgbackrest-secret"
            }
          }
        ],
        "global": {
          "repo1-path": "/pgbackrest/prod-pgcluster-uae",
          "repo1-s3-bucket": "pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e",
          "repo1-s3-endpoint": "<s3-endpoint>",
          "repo1-s3-region": "<region>",
          "repo1-type": "s3"
        },
        "repo": {
          "name": "repo1"
        }
      }
    }
  }
}
```

### Restore to a specific backup label or PITR time

To restore to a specific point in time (e.g., before a data corruption event):

```json
{
  "spec": {
    "dataSource": {
      "pgbackrest": {
        "options": ["--type=time", "--target=2026-05-22 14:30:00+04"],
        ...
      }
    }
  }
}
```

**After the restore completes, remove the `dataSource` block from the CR** to prevent PGO from attempting another restore on the next reconciliation.

```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae --type=json \
  -p '[{"op":"remove","path":"/spec/dataSource"}]'
```

---

## 9. Post-Rebuild Validation

Complete all validation steps before declaring the rebuild successful and routing application traffic.

### 9a. Pod readiness

```bash
oc get pods -n prod-pgcluster-uae -o wide
# Expected: all pods Running and Ready (2/2 or appropriate container count)
# No pods in CrashLoopBackOff, Init, or Pending state
```

### 9b. Patroni cluster health

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
```

Expected:
- One pod in Leader role, state=running
- One pod in Replica role with Sync Standby tag, state=running
- Lag=0 for all members
- No Pending restart flags
- Both members on the same timeline

### 9c. pgBackRest repository health

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
  pgbackrest --stanza=db info
# Expected: status: ok
# Verify backup count and timestamps match pre-disaster state
```

### 9d. WAL archiving health

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT archived_count, failed_count, last_archived_time,
           now() - last_archived_time AS time_since_last_archive
    FROM pg_stat_archiver;"
# Expected: failed_count=0, last_archived_time recent (< 5 minutes ago)
```

### 9e. Replication health

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag
    FROM pg_stat_replication;"
# Expected: sync_state=sync, all lag columns NULL or empty
```

### 9f. PgBouncer health

```bash
for POD in prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl; do
  echo "=== $POD ==="
  oc exec -it $POD -n prod-pgcluster-uae -c pgbouncer -- \
    psql -p 5432 pgbouncer -c "SHOW STATS;" 2>&1 | head -5
done
```

### 9g. Service endpoints and LoadBalancer

```bash
oc get service -n prod-pgcluster-uae
oc get endpoints -n prod-pgcluster-uae
# Verify LoadBalancer IPs are assigned (or NodePort ports if LB not available)
# Verify endpoints are populated (not empty)
```

### 9h. Application connectivity test

```bash
# Test connection via PgBouncer LB
psql -h 10.171.1.205 -p 5555 -U <appuser> -d <database> -c "SELECT 1;" 2>&1

# Test connection via primary LB (direct, bypassing PgBouncer)
psql -h 10.171.1.229 -p 5555 -U postgres -c "SELECT pg_is_in_recovery(), now();" 2>&1
```

### 9i. Apply monitoring resources

Only after the cluster is validated as healthy:
```bash
EXPORT_DIR=/home/mohsinali@habibbank.local/PROD_PATRONI/manifests/latest
oc apply -f $EXPORT_DIR/monitoring/ -n prod-pgcluster-uae
```

### Post-Rebuild Validation Checklist

| Validation Item | Result | Sign-off |
|---|---|---|
| All pods Running and Ready | | |
| Patroni: one Leader, one Sync Standby | | |
| Patroni: Lag=0, no Pending restart | | |
| pgBackRest: status=ok | | |
| pgBackRest: backup count matches pre-disaster | | |
| WAL archiving: failed_count=0 | | |
| WAL archiving: last_archived_time < 5 minutes | | |
| Replication: sync_state=sync | | |
| Replication: all lag=0 | | |
| PgBouncer pods: responding to SHOW STATS | | |
| Services: endpoints populated | | |
| LoadBalancer IPs: assigned | | |
| Application connectivity: confirmed | | |
| Monitoring: PrometheusRules applied | | |
| Change ticket: closed with evidence | | |

---

## 10. DR Rebuild as Standby (After DR Promotion)

After a DR promotion event (where the DR cluster accepted writes as the new primary), the old PROD cluster infrastructure must be rebuilt as a **standby** pointing to the promoted DR cluster as its upstream. The old PROD must never be started as an independent writable cluster.

### Why this matters

If the old PROD cluster is started without `spec.standby.enabled=true`, it will initialize as a new independent primary. This creates two writable primaries, which will cause data divergence. This condition is unrecoverable without data loss.

### Rebuild PROD as standby after DR promotion

Step 1 — Confirm DR cluster is the active primary and healthy:
```bash
oc config use-context dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali
oc exec -it <dr-leader-pod> -n dr-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
# Confirm DR cluster shows a Leader and is accepting writes
oc config use-context prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
```

Step 2 — Prepare the PostgresCluster CR with standby mode enabled, pointing to the DR primary:

In the CR spec, configure:
```json
{
  "spec": {
    "standby": {
      "enabled": true,
      "host": "<DR primary LB IP or hostname>",
      "port": 5555,
      "replicationTLSSecret": "<secret-name-for-tls-if-required>"
    }
  }
}
```

Step 3 — Apply the modified CR:
```bash
oc apply -f postgrescluster-cr-standby-mode.json -n prod-pgcluster-uae
```

Step 4 — Monitor the new standby cluster connecting to the DR primary:
```bash
oc get pods -n prod-pgcluster-uae -w
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn();"
# Expected: in_recovery=true, receive LSN is catching up to DR primary's LSN
```

Step 5 — Verify replication lag from DR primary perspective (on the DR cluster):
```bash
oc config use-context dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali
oc exec -it <dr-leader-pod> -n dr-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;"
# The rebuilt PROD cluster should appear as a connected replica
oc config use-context prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
```

**The old PROD cluster is now operating as a disaster recovery standby for the DR cluster.** Future roles can be swapped back when the original environment is deemed appropriate to take primary again, following the DR failback procedure (SOP-04).

