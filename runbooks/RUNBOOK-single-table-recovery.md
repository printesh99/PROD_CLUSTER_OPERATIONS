# RUNBOOK: Single Table Recovery — Habib Bank UAE PostgreSQL 18

**Cluster:** prod-pgcluster-uae | **Namespace:** prod-pgcluster-uae  
**pgBackRest Stanza:** db | **Repo:** repo1 | **Backend:** S3/ODF Nooba (pgbackrest-uae-prod-609d40f1)  
**PGO Version:** Crunchy Data PGO v5 | **Last Validated:** 2026-05-22

---

## Quick Reference — Critical Commands (Approach B)

```bash
# 1. Spin up temp restore pod
oc run pg-temp-restore -n prod-pgcluster-uae \
  --image=registry.crunchydata.com/crunchydata/crunchy-postgres:ubi8-18.x-0 \
  --restart=Never --command -- sleep 86400

# 2. Restore pgBackRest backup to temp pod's mounted PVC
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pgbackrest --stanza=db --repo=1 restore \
  --type=time --target="2026-05-24 09:00:00+04" \
  --delta --force --pg1-path=/pgdata-temp/pg18

# 3. Dump the specific table from temp instance
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pg_dump -U postgres -d <target_database> -t <schema>.<tablename> \
  -F c -f /tmp/table_recovery.dump

# 4. Copy dump to local machine
oc cp prod-pgcluster-uae/pg-temp-restore:/tmp/table_recovery.dump ./table_recovery.dump

# 5. Restore table to production (with triggers disabled)
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "ALTER TABLE <schema>.<tablename> DISABLE TRIGGER ALL;"
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pg_restore -U postgres -d <target_database> -t <tablename> --data-only /tmp/table_recovery.dump

# 6. Re-enable triggers
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "ALTER TABLE <schema>.<tablename> ENABLE TRIGGER ALL;"
```

---

## When to Use Single Table Recovery

| Scenario | Recommended Approach |
|----------|---------------------|
| Accidental DELETE/TRUNCATE of one table, production otherwise healthy | **Approach B** (pgBackRest temp restore) |
| pg_dump snapshot exists from before the incident | **Approach A** (logical restore from snapshot) |
| Table corruption detected, need point-in-time state | **Approach C** (PITR on clone cluster) |
| Multiple tables affected across many schemas | Use full PITR runbook instead |
| Foreign key dependencies are complex | **Approach C** (clone PITR) — safer |

**Key advantage of single table recovery:** Production cluster stays online. Only the affected table is taken out of service briefly. RTO is significantly better than full PITR.

---

## Approach A: Logical Restore from pg_dump Snapshot

Use when a pre-incident `pg_dump` or `pg_dumpall` snapshot is available (e.g., from a scheduled logical backup).

**Estimated time: 15–45 minutes**

### A-1: Locate the Snapshot

```bash
# Check if logical backups are stored in S3 or local storage
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  ls -la /pgdata/logical-backups/ 2>/dev/null || echo "Check S3 bucket for logical backups"
```

### A-2: Disable Triggers and Rename Existing Table

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    ALTER TABLE <schema>.<tablename> DISABLE TRIGGER ALL;
    ALTER TABLE <schema>.<tablename> RENAME TO <tablename>_broken_$(date +%Y%m%d%H%M%S);"
```

### A-3: Restore Table from Snapshot

```bash
# If snapshot is a custom-format dump:
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pg_restore -U postgres -d <target_database> \
  -t <tablename> /path/to/snapshot.dump

# If snapshot is plain SQL:
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -f /path/to/snapshot.sql
```

### A-4: Verify and Re-Enable Triggers

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    SELECT count(*) FROM <schema>.<tablename>;
    ALTER TABLE <schema>.<tablename> ENABLE TRIGGER ALL;"
```

---

## Approach B: pgBackRest Restore to Temp Instance (Recommended)

This is the safest approach for production. A temporary PostgreSQL instance is spun up with a pgBackRest restore of the backup. The specific table is then extracted via `pg_dump` and restored to production. Production stays online throughout.

**Estimated time: 1–3 hours**

### Phase B-1: Prepare Temporary PVC

**Estimated time: 5–10 minutes**

#### B-1.1: Create a PVC for the Temp Restore

```bash
cat <<EOF | oc apply -n prod-pgcluster-uae -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-temp-restore-pvc
  namespace: prod-pgcluster-uae
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Gi
  storageClassName: <your-storageclass>
EOF
```

Adjust `storage` to at least 1.5x the size of your PGDATA. Check current size:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  df -h /pgdata
```

#### B-1.2: Spin Up Temporary Restore Pod

```bash
cat <<EOF | oc apply -n prod-pgcluster-uae -f -
apiVersion: v1
kind: Pod
metadata:
  name: pg-temp-restore
  namespace: prod-pgcluster-uae
spec:
  containers:
  - name: pg-temp-restore
    image: registry.crunchydata.com/crunchydata/crunchy-postgres:ubi8-18.x-0
    command: ["sleep", "86400"]
    volumeMounts:
    - name: pgdata-temp
      mountPath: /pgdata-temp
    - name: pgbackrest-config
      mountPath: /etc/pgbackrest
      readOnly: true
    env:
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: prod-pgcluster-uae-pguser-postgres
          key: password
  volumes:
  - name: pgdata-temp
    persistentVolumeClaim:
      claimName: pg-temp-restore-pvc
  - name: pgbackrest-config
    secret:
      secretName: prod-pgcluster-uae-pgbackrest-secret
  restartPolicy: Never
EOF
```

Wait for pod to be Running:

```bash
oc wait -n prod-pgcluster-uae pod/pg-temp-restore --for=condition=Ready --timeout=120s
```

### Phase B-2: Restore pgBackRest Backup to Temp Instance

**Estimated time: 30–90 minutes** (download from S3)

#### B-2.1: Identify Target Backup

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pgbackrest --stanza=db --repo=1 info
```

#### B-2.2: Run pgBackRest Restore to Temp PGDATA

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pgbackrest --stanza=db --repo=1 restore \
  --type=time \
  --target="2026-05-24 09:00:00+04" \
  --target-action=promote \
  --delta \
  --force \
  --pg1-path=/pgdata-temp/pg18 \
  --log-level-console=info
```

**Note:** Adjust `--target` to the timestamp just before the incident. Use `--target-action=promote` to auto-promote after reaching the target time (no manual intervention needed).

#### B-2.3: Start PostgreSQL on Temp Instance

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pg_ctl start -D /pgdata-temp/pg18 \
  -o "-p 5433" \
  -l /tmp/pg-temp-restore.log
```

Monitor startup:

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  tail -f /tmp/pg-temp-restore.log
```

Wait for: `LOG: database system is ready to accept connections`

#### B-2.4: Verify Temp Instance is Healthy and at Correct Time

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  psql -p 5433 -U postgres -c "
    SELECT pg_is_in_recovery(),
           pg_last_xact_replay_timestamp(),
           now();"
```

Expected: `pg_is_in_recovery = f` (promoted) and timestamp is at or before the incident.

### Phase B-3: Dump the Specific Table from Temp Instance

**Estimated time: 2–30 minutes** (depends on table size)

#### B-3.1: Verify Table Data on Temp Instance

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  psql -p 5433 -U postgres -d <target_database> -c "
    SELECT count(*) FROM <schema>.<tablename>;
    SELECT max(updated_at) FROM <schema>.<tablename>;" 2>/dev/null || \
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  psql -p 5433 -U postgres -d <target_database> -c "
    SELECT count(*) FROM <schema>.<tablename>;"
```

Application team must confirm the row count and sample data is correct.

#### B-3.2: pg_dump the Specific Table

```bash
# Data only (recommended if table structure unchanged in production)
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pg_dump -p 5433 -U postgres -d <target_database> \
  -t '<schema>.<tablename>' \
  --data-only \
  -F c \
  -f /tmp/table_recovery.dump

# Schema + Data (use if table was dropped entirely)
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pg_dump -p 5433 -U postgres -d <target_database> \
  -t '<schema>.<tablename>' \
  -F c \
  -f /tmp/table_recovery.dump
```

#### B-3.3: Copy Dump to Local Machine (Optional Safety Copy)

```bash
oc cp prod-pgcluster-uae/pg-temp-restore:/tmp/table_recovery.dump \
  ./table_recovery_$(date +%Y%m%d_%H%M%S).dump

# Verify dump file is valid
pg_restore --list ./table_recovery_*.dump | head -30
```

#### B-3.4: Copy Dump into Production Primary Pod

```bash
oc cp ./table_recovery_*.dump \
  prod-pgcluster-uae/prod-pgcluster-uae-dc1-9c5j-0:/tmp/table_recovery.dump -c database
```

Or directly between pods if on same namespace:

```bash
# Get dump contents and pipe directly (for large tables, use oc cp above)
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  cat /tmp/table_recovery.dump | \
oc exec -i -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  tee /tmp/table_recovery.dump > /dev/null
```

### Phase B-4: Restore Table to Production

**Estimated time: 5–30 minutes**

#### B-4.1: Verify Current State of Production Table

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    SELECT count(*) AS current_row_count FROM <schema>.<tablename>;"
```

#### B-4.2: Create a Safety Backup of Current Production Table

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    CREATE TABLE <schema>.<tablename>_pre_recovery_$(date +%Y%m%d%H%M%S)
    AS SELECT * FROM <schema>.<tablename>;"
```

#### B-4.3: Disable Foreign Key Constraints and Triggers

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    -- Disable triggers (includes FK constraint triggers)
    ALTER TABLE <schema>.<tablename> DISABLE TRIGGER ALL;
    -- Check for FKs referencing this table from other tables
    SELECT conname, conrelid::regclass
    FROM pg_constraint
    WHERE confrelid = '<schema>.<tablename>'::regclass
      AND contype = 'f';"
```

If other tables have FKs referencing this table, temporarily disable them too:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    ALTER TABLE <schema>.<referencing_table> DISABLE TRIGGER ALL;"
```

#### B-4.4: Truncate Production Table

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    TRUNCATE TABLE <schema>.<tablename>;"
```

**Alternative (rename instead of truncate — safer for rollback):**

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    ALTER TABLE <schema>.<tablename> RENAME TO <tablename>_broken;
    CREATE TABLE <schema>.<tablename> (LIKE <schema>.<tablename>_broken INCLUDING ALL);"
```

#### B-4.5: Restore Table Data from Dump

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pg_restore -U postgres -d <target_database> \
  -t <tablename> \
  --data-only \
  --disable-triggers \
  -v \
  /tmp/table_recovery.dump
```

Monitor output for any errors. Each restored sequence and table data batch will be logged.

#### B-4.6: Re-Enable Triggers and Foreign Keys

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    ALTER TABLE <schema>.<tablename> ENABLE TRIGGER ALL;"

# Re-enable on referencing tables if disabled in B-4.3
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    ALTER TABLE <schema>.<referencing_table> ENABLE TRIGGER ALL;"
```

#### B-4.7: Reset Sequences (If Table Has Serial/Identity Columns)

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    SELECT setval(
      pg_get_serial_sequence('<schema>.<tablename>', '<id_column>'),
      (SELECT max(<id_column>) FROM <schema>.<tablename>)
    );"
```

### Phase B-5: Verify Recovered Table

**Estimated time: 10–20 minutes**

#### B-5.1: Row Count Verification

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    SELECT
      (SELECT count(*) FROM <schema>.<tablename>) AS recovered_rows,
      (SELECT count(*) FROM pg-temp-restore_expected_count) AS expected_rows;"
```

Compare with the count from the temp instance (Phase B-3.1).

#### B-5.2: Application Team Verification

Application team should run their validation queries to confirm data integrity.

#### B-5.3: Test FK Integrity

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    -- Validate FK integrity
    SET constraint_exclusion = on;
    SELECT count(*) FROM <schema>.<tablename> t
    WHERE NOT EXISTS (
      SELECT 1 FROM <schema>.<parent_table> p
      WHERE p.<pk_col> = t.<fk_col>
    );"
```

Expected: 0 orphaned rows.

#### B-5.4: VACUUM ANALYZE

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    VACUUM ANALYZE <schema>.<tablename>;"
```

### Phase B-6: Cleanup

#### B-6.1: Stop Temp PostgreSQL Instance

```bash
oc exec -n prod-pgcluster-uae pg-temp-restore -- \
  pg_ctl stop -D /pgdata-temp/pg18 -m fast
```

#### B-6.2: Delete Temp Pod and PVC

```bash
oc delete pod -n prod-pgcluster-uae pg-temp-restore
oc delete pvc -n prod-pgcluster-uae pg-temp-restore-pvc
```

#### B-6.3: Remove Dump File from Production Pod

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  rm -f /tmp/table_recovery.dump
```

#### B-6.4: Drop Safety Backup Table (After Confirmed Successful)

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    DROP TABLE IF EXISTS <schema>.<tablename>_pre_recovery_<timestamp>;"
```

---

## Approach C: Flashback Using PITR on a Clone Cluster

Use when FK dependencies are complex, multiple related tables are affected, or you need a full database-consistent view at the recovery point.

**Estimated time: 2–5 hours**

### C-1: Create Clone PostgresCluster CR

Create a separate PostgresCluster CR in the same namespace pointing to the same pgBackRest S3 repo, with `spec.standby.enabled: false` and a restore annotation:

```bash
cat <<EOF | oc apply -n prod-pgcluster-uae -f -
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: prod-pgcluster-uae-recovery-clone
  namespace: prod-pgcluster-uae
  annotations:
    postgres-operator.crunchydata.com/pgbackrest-restore: '{"repoName":"repo1","options":["--type=time","--target=2026-05-24 09:00:00+04"]}'
spec:
  postgresVersion: 18
  instances:
  - name: clone
    replicas: 1
    dataVolumeClaimSpec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 500Gi
  backups:
    pgbackrest:
      repos:
      - name: repo1
        s3:
          bucket: pgbackrest-uae-prod-609d40f1
          endpoint: <your-nooba-endpoint>
          region: us-east-1
EOF
```

### C-2: Wait for Clone to Come Up at Target Time

```bash
oc get pods -n prod-pgcluster-uae -w | grep clone
```

### C-3: Dump Target Tables from Clone

```bash
CLONE_POD=$(oc get pod -n prod-pgcluster-uae \
  -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae-recovery-clone \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n prod-pgcluster-uae ${CLONE_POD} -c database -- \
  pg_dump -U postgres -d <target_database> \
  -t '<schema>.<table1>' \
  -t '<schema>.<table2>' \
  --data-only -F c -f /tmp/multi_table_recovery.dump
```

### C-4: Restore to Production

Follow the same restore steps as Approach B (Phase B-4 onwards), adapting for multiple tables.

### C-5: Teardown Clone

```bash
oc delete postgrescluster -n prod-pgcluster-uae prod-pgcluster-uae-recovery-clone
```

---

## Rollback Procedure

If the recovery introduces unexpected issues:

### Rollback Option 1: Rename Back (If Rename Strategy Used)

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    -- Drop the (partially restored) table
    DROP TABLE IF EXISTS <schema>.<tablename>;
    -- Rename the original broken table back
    ALTER TABLE <schema>.<tablename>_broken RENAME TO <tablename>;
    -- Re-enable triggers
    ALTER TABLE <schema>.<tablename> ENABLE TRIGGER ALL;"
```

### Rollback Option 2: Restore from Safety Backup Table

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    BEGIN;
    TRUNCATE TABLE <schema>.<tablename>;
    INSERT INTO <schema>.<tablename>
      SELECT * FROM <schema>.<tablename>_pre_recovery_<timestamp>;
    COMMIT;"
```

### Rollback Option 3: Full PITR

If single table recovery is insufficient and data state is unacceptable, escalate to the full PITR runbook (`RUNBOOK-pitr.md`).

---

## Single Table Recovery Checklist

| # | Check | Status |
|---|-------|--------|
| 1 | Target time confirmed with application team | |
| 2 | pgBackRest backup covers target time | |
| 3 | Temp PVC and pod created successfully | |
| 4 | pgBackRest restore to temp instance complete | |
| 5 | Table data verified on temp instance | |
| 6 | Safety backup of current production table created | |
| 7 | Triggers disabled on production table | |
| 8 | pg_restore completed without errors | |
| 9 | Triggers re-enabled | |
| 10 | Sequences reset (if serial/identity columns) | |
| 11 | Row count matches expected | |
| 12 | FK integrity verified | |
| 13 | Application team sign-off | |
| 14 | VACUUM ANALYZE run | |
| 15 | Temp pod and PVC deleted | |
| 16 | Dump file removed from production pod | |
| 17 | Safety backup table dropped (after confirmation) | |
| 18 | Incident ticket updated and closed | |

---

## Timing Estimates Summary

| Approach | Estimated Duration | Production Impact |
|----------|--------------------|------------------|
| A: Logical snapshot | 15–45 min | Table offline ~5–15 min |
| B: pgBackRest temp restore | 1–3 hours | Table offline ~10–30 min |
| C: Clone cluster PITR | 2–5 hours | Table offline ~15–30 min |

