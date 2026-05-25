# SOP-03: Point-In-Time Recovery (PITR) and Restore Procedure
## Habib Bank UAE Production PostgreSQL Cluster

**Document ID:** SOP-03  
**Version:** 1.0  
**Effective Date:** 2026-05-22  
**Author:** DBA Operations Team  
**Cluster:** prod-pgcluster-uae  
**Validated PITR run:** 2026-05-21 (clone pitr-clone-20260521, TL 9, PASS)  

---

## 1. Purpose

This SOP defines the procedure for performing Point-In-Time Recovery (PITR) of the Habib Bank UAE production PostgreSQL cluster using pgBackRest and Crunchy Data PGO. It covers validation PITR (non-destructive clone testing), emergency production PITR, and the critical lessons learned from the validated run on 2026-05-21.

**Safety Rule:** Never restore over the live production PostgresCluster CR. Always create an isolated temporary PostgresCluster for PITR validation. Production emergency recovery follows the same pattern but with the incident commander as mandatory approver.

---

## 2. PITR Theory: How pgBackRest PITR Works

Point-In-Time Recovery is the process of restoring a PostgreSQL cluster to a specific timestamp in the past by replaying WAL (Write-Ahead Log) records up to that target moment.

The recovery process has three phases. First, pgBackRest takes the base backup identified as the closest full or differential/incremental backup that predates the target time and restores it to the data directory. Second, PostgreSQL enters recovery mode and replays WAL segments from the pgBackRest archive (via `restore_command`) starting from the base backup's LSN (Log Sequence Number). Third, when the replayed WAL reaches the `recovery_target_time`, PostgreSQL stops replaying and either promotes (becomes a writable primary) or pauses, depending on the `recovery_target_action` setting.

PGO (Crunchy Data PostgreSQL Operator) manages this by injecting `restore_command` into the PostgreSQL recovery configuration via a recovery ConfigMap. The operator also handles the `--target-action` internally — the operator must never be bypassed by manually editing `postgresql.conf` or `recovery.conf` for PGO-managed clusters.

The clone cluster created during PITR will come up on the next timeline (Timeline 9 in the 2026-05-21 validated run, since the production cluster was on Timeline 8). This is the expected and correct behavior.

---

## 3. Pre-PITR Prerequisites Checklist

Before initiating any PITR procedure, verify all items in this checklist. Do not proceed if any item fails.

| Item | Verification Command | Required State |
|---|---|---|
| PROD Patroni healthy | `patronictl list` on leader pod | One Leader, one Sync Standby, lag=0 |
| pgBackRest status | `pgbackrest --stanza=db --repo=1 info` | `status: ok` |
| Latest backup label identified | Parse `pgbackrest info` output | Label noted and predates target time |
| WAL archive covering target time | `pg_stat_archiver` last_archived_time | last_archived_time > target recovery time |
| Approved change window | Change management system | Approved ticket number recorded |
| Incident commander designated | For emergency PITR | Name and contact on call |
| Isolated namespace or cluster available | `oc get ns` | Clone namespace available; NOT prod-pgcluster-uae |
| S3 bucket accessible | `pgbackrest --stanza=db --repo=1 check` | Exits 0 |

The target recovery time must be within the backup chain's coverage window. The earliest possible recovery point is the `timestamp start` of the oldest retained full backup. The latest possible point is the `last_archived_time` reported by `pg_stat_archiver` at the time of the PITR initiation.

---

## 4. PITR Validation Procedure (Non-Destructive Clone)

This procedure creates a temporary PostgresCluster in an isolated namespace that recovers from the same S3 repository as production, stopping at a specified target time. The production cluster is not touched.

**4.1 Determine Target Timestamp**

Identify the target recovery timestamp in UTC. For validation runs, choose a time within the last 24 hours that has confirmed WAL coverage. Record it exactly:

```
TARGET_TIME="2026-05-21 07:37:42+00"
CLONE_NAME="pitr-clone-20260521"
CLONE_DATE="20260521"
```

**4.2 Create Clone Manifest**

The clone manifest must include both the `dataSource.pgbackrest` section (which tells PGO where to restore from) and a separate `backups.pgbackrest` section (which tells the clone how to reach the repository for WAL replay during recovery). Omitting the `backups.pgbackrest` section causes the restore job to fail because the clone cannot execute `restore_command`.

The clone must use a unique repo path to avoid writing into the production stanza. Use `/pgbackrest/<clone-name>/repo1` as the repository path within S3.

```yaml
# Save as: /home/mohsinali@habibbank.local/PROD_PATRONI/pitr-clone-YYYYMMDD.yaml
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: pitr-clone-20260521
  namespace: prod-pgcluster-uae
spec:
  postgresVersion: 14
  instances:
    - name: instance1
      replicas: 1
      dataVolumeClaimSpec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 100Gi
  dataSource:
    pgbackrest:
      stanza: db
      configuration:
        - secret:
            name: prod-pgcluster-uae-pgbackrest-secret
      global:
        repo1-path: /pgbackrest/db/repo1
        repo1-s3-bucket: pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
        repo1-s3-endpoint: s3-openshift-storage.apps.ocp-prod.habibbank.local
        repo1-s3-region: prod
        repo1-cipher-type: aes-256-cbc
      options:
        - --type=time
        - --target="2026-05-21 07:37:42+00"
      repo:
        name: repo1
        s3:
          bucket: pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
          endpoint: s3-openshift-storage.apps.ocp-prod.habibbank.local
          region: prod
  backups:
    pgbackrest:
      configuration:
        - secret:
            name: prod-pgcluster-uae-pgbackrest-secret
      global:
        repo1-path: /pgbackrest/pitr-clone-20260521/repo1
        repo1-s3-bucket: pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
        repo1-s3-endpoint: s3-openshift-storage.apps.ocp-prod.habibbank.local
        repo1-s3-region: prod
        repo1-cipher-type: aes-256-cbc
      repos:
        - name: repo1
          s3:
            bucket: pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
            endpoint: s3-openshift-storage.apps.ocp-prod.habibbank.local
            region: prod
```

**4.3 Apply the Manifest**

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI

# Verify you are in the correct context before applying
oc config current-context
# Expected: prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali

oc apply -f pitr-clone-20260521.yaml -n prod-pgcluster-uae
```

**4.4 Monitor the Restore Job**

PGO will create a restore job that pulls the base backup from S3 and then replays WAL to the target time.

```bash
# Watch the restore job appear and progress
oc get jobs -n prod-pgcluster-uae -w | grep pitr-clone

# Get logs from the restore job pod
oc get pods -n prod-pgcluster-uae | grep pitr-clone
oc logs <restore-job-pod> -n prod-pgcluster-uae -f

# Watch pods become ready
oc get pods -n prod-pgcluster-uae -w | grep pitr-clone
```

The restore job typically takes 10–60 minutes depending on the size of the WAL replay window. The pod will show `Completed` when done, and then the PostgresCluster pod will start.

**4.5 Confirm Recovery Completed at Target Time**

Once the clone pod is Running, connect to it and verify recovery is complete and the database is writable (promoted), and verify the stop time matches the target.

```bash
# Get the clone pod name
CLONE_POD=$(oc get pods -n prod-pgcluster-uae | grep 'pitr-clone.*instance1' | awk '{print $1}')

# Check recovery status (should be false after promotion)
oc exec -it $CLONE_POD -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "SELECT pg_is_in_recovery();"
# Expected: f (false)

# Check current timeline (should be 9, one higher than production TL 8)
oc exec -it $CLONE_POD -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT timeline_id FROM pg_control_checkpoint();
"
# Expected: 9

# Verify recovery target time from pg_control_recovery
oc exec -it $CLONE_POD -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT now(), pg_postmaster_start_time();
"
```

**4.6 Validate Databases and Row Counts**

Run application-specific validation queries to confirm the data state matches expectations for the target time. At a minimum, check that all expected databases exist and that key tables have row counts consistent with the target timestamp.

```bash
# List databases
oc exec -it $CLONE_POD -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "\l"

# Record row counts for validation evidence
oc exec -it $CLONE_POD -n prod-pgcluster-uae \
  -c database -- psql -U postgres -d <application_db> -c "
SELECT schemaname, tablename, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 20;
"
```

Save all output to a timestamped file in `/home/mohsinali@habibbank.local/PROD_PATRONI/pitr-evidence/`.

**4.7 Save Evidence and Delete Clone**

After validation is complete and results are approved by the DBA Lead, delete the clone to free cluster resources.

```bash
# Save evidence first
oc exec -it $CLONE_POD -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT version(), now(), pg_is_in_recovery(),
       (SELECT timeline_id FROM pg_control_checkpoint()) AS timeline;
" > /home/mohsinali@habibbank.local/PROD_PATRONI/pitr-evidence/pitr-clone-20260521-evidence.txt

# Delete the clone (requires DBA Lead approval sign-off)
oc delete postgrescluster pitr-clone-20260521 -n prod-pgcluster-uae

# Verify deletion
oc get postgrescluster -n prod-pgcluster-uae
```

---

## 5. Production Emergency PITR

Production emergency PITR follows the same clone pattern as the validation procedure, but with the following critical differences:

The incident commander must approve the target time before the manifest is applied. The target time must be confirmed as a point before the data corruption or deletion event, with documented evidence (application logs, audit logs, or transaction logs showing the last known good state).

```bash
# Identify the correct target time from WAL archive
# Find WAL segments near the incident time
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT pg_walfile_name('<lsn-of-last-known-good-state>');
"

# Calculate LSN difference to estimate data loss
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT pg_wal_lsn_diff('<current-lsn>', '<target-lsn>') AS bytes_to_lose;
"
```

The emergency clone must be validated before any application traffic is cut over to it. If the data on the clone matches expectations and the incident commander approves cutover, the application team must update connection strings to point to the clone, and the original production cluster must be demoted and put into maintenance mode pending a full rebuild.

Never promote the emergency clone and simultaneously keep the original production cluster running as a writable primary. That is a split-brain scenario.

---

## 6. Critical Lessons from the 2026-05-21 Validated PITR Run

The following lessons were learned during the validated PITR test performed on 2026-05-21 and must be treated as mandatory requirements for all future PITR operations.

**Lesson 1: The `backups.pgbackrest` section is mandatory in the clone manifest.** Without it, the PGO restore job cannot execute `restore_command` during WAL replay because it has no access to the S3 repository. The restore job will stall or fail with a WAL archiver connectivity error after restoring the base backup.

**Lesson 2: Do NOT add `--target-action=promote` to the options list.** PGO manages the promotion of the cluster after the target time is reached. Adding `--target-action=promote` manually conflicts with the operator's recovery flow and can result in the cluster entering an unexpected state.

**Lesson 3: The target timestamp must be quoted in the YAML options list.** The YAML entry must be `- --target="2026-05-21 07:37:42+00"` with the timestamp enclosed in double quotes within the string value. Without quotes, the YAML parser may interpret the timestamp incorrectly.

**Lesson 4: The clone's `backups.pgbackrest` repo path must be different from the production stanza path.** Use `/pgbackrest/<clone-name>/repo1` rather than `/pgbackrest/db/repo1`. If the same path is used, the clone's stanza initialization may overwrite production backup metadata.

**Validated result:** Clone `pitr-clone-20260521` successfully recovered to `2026-05-21 07:37:42+00`, promoted to Timeline 9 (production was Timeline 8), `pg_is_in_recovery()` returned `f`, and data validation passed. Result: PASS.

---

## 7. Logical Restore from UAT

If a specific table or dataset must be recovered from a point in time and a full cluster PITR is not required, a logical restore from a clone is the preferred approach. Create the PITR clone as described above, then use `pg_dump` to extract the required tables, and `pg_restore` or `psql` to load them into the production database within a transaction.

This procedure requires application-level coordination to freeze writes to the affected tables during the restore window, and requires DBA Lead and application team approval before execution.

---

## 8. Cleanup Procedure

After any PITR clone has been validated and results approved, clean up all associated resources to free cluster compute and storage resources.

```bash
# Delete the PostgresCluster CR (this deletes pods and PVCs)
oc delete postgrescluster <clone-name> -n prod-pgcluster-uae

# Verify all clone pods are gone
oc get pods -n prod-pgcluster-uae | grep <clone-name>

# Verify PVCs are deleted (PGO default deletes PVCs with the cluster)
oc get pvc -n prod-pgcluster-uae | grep <clone-name>

# If any PVCs remain, delete manually
oc delete pvc <clone-pvc-name> -n prod-pgcluster-uae

# Archive the evidence file
ls -lh /home/mohsinali@habibbank.local/PROD_PATRONI/pitr-evidence/
```

Retain evidence files for a minimum of 90 days or as required by the bank's data retention policy.

