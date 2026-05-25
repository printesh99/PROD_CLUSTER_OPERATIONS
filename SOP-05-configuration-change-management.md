# SOP-05: Configuration Change Management
## Habib Bank UAE Production PostgreSQL Cluster

**Cluster:** prod-pgcluster-uae
**OCP Context:** prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
**Namespace:** prod-pgcluster-uae
**PostgresCluster CR:** prod-pgcluster-uae
**Working Directory:** /home/mohsinali@habibbank.local/PROD_PATRONI
**Last Reviewed:** 2026-05-22

---

## 1. Governing Principle

The **PostgresCluster CR is the single source of truth** for all cluster configuration. Crunchy Data PGO (PostgreSQL Operator) reconciles all child resources — including ConfigMaps, Deployments, StatefulSets, and Services — from this CR. Any configuration drift applied directly to child resources will be overwritten silently during the next reconciliation cycle.

**Hard rules:**

- **Never** directly edit any generated ConfigMap (prod-pgcluster-uae-config, prod-pgcluster-uae-pgbackrest-config, prod-pgcluster-uae-pgbouncer).
- **Never** use `patronictl edit-config` to change PostgreSQL or Patroni parameters. PGO overwrites Patroni's DCS configuration on every reconcile, and any edits made via `patronictl edit-config` will be lost without warning.
- **Never** exec into a pod and edit postgresql.conf, pg_hba.conf, or pgbackrest.conf directly.
- **All** configuration changes must be made via `oc patch postgrescluster` targeting the CR spec, or by applying an updated CR YAML through a controlled change ticket.
- **All** changes require a pre-change evidence capture and a rollback value documented before the patch is issued.

### Why This Matters

PGO renders the Patroni configuration in `prod-pgcluster-uae-config` and the pgBackRest configuration in `prod-pgcluster-uae-pgbackrest-config` directly from the CR spec. If you edit these ConfigMaps directly, PGO will overwrite your changes within minutes. The only persistent path is the CR.

---

## 2. Change Classification Table

| Change Type | Requires DB Restart | Requires Rolling Pod Restart | Requires CAB Approval | Examples |
|---|---|---|---|---|
| Reloadable PostgreSQL parameter | No | No | No (standard change) | log_min_duration_statement, autovacuum_vacuum_scale_factor, work_mem, maintenance_work_mem, checkpoint_completion_target, idle_in_transaction_session_timeout, statement_timeout |
| Postmaster PostgreSQL parameter | Yes (brief failover) | Yes (rolling) | Yes (change freeze window) | max_connections, shared_buffers, wal_level, shared_preload_libraries, max_replication_slots, max_wal_senders, huge_pages |
| pgBackRest configuration | No | No | No (standard change) | repo1-retention-full, repo1-retention-diff, compress-level, backup schedules |
| PgBouncer configuration | No (graceful reload) | No | No (standard change) | pool_mode, max_client_conn, default_pool_size, max_db_connections, query_wait_timeout |
| pg_hba.conf / host-based auth | No (reload) | No | Yes | Adding/removing access rules |
| Patroni topology parameters | Potentially | Potentially | Yes | synchronous_mode, synchronous_node_count, ttl, loop_wait |
| Storage resize (PVC) | No (online) | No | Yes | pgdata expansion, pgwal expansion |

**Key postmaster parameters currently set:**

| Parameter | Current Value | Notes |
|---|---|---|
| max_connections | 800 | Postmaster — requires restart |
| shared_buffers | (from CR) | Postmaster — requires restart |
| wal_level | replica | Postmaster — requires restart |
| shared_preload_libraries | pg_stat_statements, pgaudit, ... | Postmaster — requires restart |
| synchronous_commit | on | Reloadable |
| max_replication_slots | 50 | Postmaster — requires restart |
| max_wal_senders | 20 | Postmaster — requires restart |
| statement_timeout | 300000ms | Reloadable |
| idle_in_transaction_session_timeout | 120000ms | Reloadable |
| pgaudit.log | ddl,role,write | Reloadable |

---

## 3. Pre-Change Evidence Capture

Before **any** configuration change, capture and record current state. This evidence is required for rollback and for the change record.

### 3a. Confirm OCP Context and Namespace

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI

# Confirm you are on the PROD context — not DR
oc config current-context
# Expected: prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali

oc project
# Expected: prod-pgcluster-uae
```

**STOP if the context is not the PROD context. Never issue change commands on the DR context.**

### 3b. Confirm Patroni Cluster Health

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
```

Expected healthy state before proceeding:
- One pod in Leader/Master role
- One pod in Replica role with Sync Standby tag
- Lag = 0 for all members
- No "Pending restart" flags unless this change is intended to clear them

**STOP if Patroni is not in a healthy state (no sync standby, lag > 0, any member in "start failed" or "stopped" state).**

### 3c. Capture Current CR Snapshot

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json \
  > cr-snapshot-before-${TIMESTAMP}.json

echo "CR snapshot saved: cr-snapshot-before-${TIMESTAMP}.json"
```

### 3d. Capture Specific Parameter Value Before Change

For PostgreSQL parameters:
```bash
# Replace <PARAMETER_NAME> with the actual parameter
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SHOW <PARAMETER_NAME>;"
```

For PgBouncer parameters:
```bash
oc exec -it prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww -n prod-pgcluster-uae -c pgbouncer -- \
  psql -p 5432 pgbouncer -c "SHOW CONFIG;" | grep <parameter_name>
```

**Record the output. The pre-change value is your rollback target.**

---

## 4. PostgreSQL Parameter Change Procedure (Safe Patch Pattern)

### 4a. Reloadable Parameter Change

Reloadable parameters take effect when PostgreSQL receives SIGHUP (pg_reload_conf()). PGO triggers a reload automatically after reconciling the CR.

**Example: Change statement_timeout from 300000 to 600000**

Step 1 — Capture old value:
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SHOW statement_timeout;"
# Record: statement_timeout = 300000ms
```

Step 2 — Apply the patch:
```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae --type=merge \
  -p '{"spec":{"patroni":{"dynamicConfiguration":{"postgresql":{"parameters":{"statement_timeout":"600000"}}}}}}'
```

Step 3 — Wait for operator reconciliation (typically 30-90 seconds):
```bash
oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json \
  | jq '.status.conditions[] | select(.type=="PGBackRestRepoHostReady" or .type=="ProxyAvailable" or .type=="DatabaseReadyForRestore")'
```

Step 4 — Verify new value is active:
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SHOW statement_timeout;"
# Expected: statement_timeout = 600000ms
```

Step 5 — Verify on standby:
```bash
oc exec -it prod-pgcluster-uae-dc1-5c2q-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SHOW statement_timeout;"
```

### 4b. Postmaster Parameter Change (Requires Restart)

Postmaster parameters require the PostgreSQL process to be restarted. In a Patroni-managed cluster, this is performed as a rolling restart: the standby restarts first, then a switchover occurs (promoting the old standby), and then the old leader restarts as the new standby.

**IMPORTANT:** This causes a brief failover. Notify application teams and confirm the change window before proceeding.

**Example: Change max_connections from 800 to 900**

Step 1 — Capture old value and record it:
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SHOW max_connections;"
# Record: max_connections = 800
```

Step 2 — Apply the patch:
```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae --type=merge \
  -p '{"spec":{"patroni":{"dynamicConfiguration":{"postgresql":{"parameters":{"max_connections":"900"}}}}}}'
```

Step 3 — Wait for operator reconciliation and check for "Pending restart":
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
# Look for "Pending restart" column showing "yes" on one or both members
```

Step 4 — Initiate rolling restart via Patroni (restarts standby first, then leader):
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml restart prod-pgcluster-uae-ha --force
```

Step 5 — Monitor restart progress:
```bash
# Watch pods recover
oc get pods -n prod-pgcluster-uae -w

# Confirm Patroni healthy after restart
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
```

Step 6 — Verify new value on the current leader:
```bash
# The current leader may have changed after the rolling restart
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SHOW max_connections;"
```

---

## 5. pgBackRest Configuration Change Procedure

pgBackRest configuration is managed via `spec.backups.pgbackrest.global` in the PostgresCluster CR. PGO reconciles this into `prod-pgcluster-uae-pgbackrest-config`.

**Example: Change full backup retention from 2 to 3**

Step 1 — Capture current retention setting:
```bash
oc get configmap prod-pgcluster-uae-pgbackrest-config -n prod-pgcluster-uae -o yaml \
  | grep retention
```

Step 2 — Apply the patch:
```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae --type=merge \
  -p '{"spec":{"backups":{"pgbackrest":{"global":{"repo1-retention-full":"3"}}}}}'
```

Step 3 — Verify ConfigMap is updated by operator:
```bash
sleep 60
oc get configmap prod-pgcluster-uae-pgbackrest-config -n prod-pgcluster-uae -o yaml \
  | grep retention
# Expected: repo1-retention-full=3
```

Step 4 — Verify pgBackRest can still read the repository:
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
  pgbackrest --stanza=db info
# Expected: status: ok
```

**S3 Bucket reference:** pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
**Stanza:** db, **Repo:** repo1

---

## 6. PgBouncer Configuration Change Procedure

PgBouncer configuration is managed via `spec.proxy.pgBouncer.config.global` in the PostgresCluster CR. PGO reconciles this into `prod-pgcluster-uae-pgbouncer`.

**Current PgBouncer settings:**
- pool_mode = transaction
- max_client_conn = 2000
- default_pool_size = 50
- max_db_connections = 150

**Example: Change default_pool_size from 50 to 75**

Step 1 — Capture current value:
```bash
oc exec -it prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww -n prod-pgcluster-uae -c pgbouncer -- \
  psql -p 5432 pgbouncer -c "SHOW CONFIG;" | grep default_pool_size
```

Step 2 — Apply the patch:
```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae --type=merge \
  -p '{"spec":{"proxy":{"pgBouncer":{"config":{"global":{"default_pool_size":"75"}}}}}}'
```

Step 3 — Wait for ConfigMap reconciliation:
```bash
sleep 60
oc get configmap prod-pgcluster-uae-pgbouncer -n prod-pgcluster-uae -o yaml \
  | grep default_pool_size
```

Step 4 — Verify PgBouncer pods picked up the new configuration:
```bash
# Check both PgBouncer pods
for POD in prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl; do
  echo "=== $POD ==="
  oc exec -it $POD -n prod-pgcluster-uae -c pgbouncer -- \
    psql -p 5432 pgbouncer -c "SHOW CONFIG;" | grep default_pool_size
done
```

---

## 7. Rollback Pattern

The rollback for any CR-based change is another `oc patch` restoring the prior value. This is always safe because the patch goes through the same operator reconciliation path.

**Critical principle: the rollback value must be captured BEFORE the change is applied.** This is non-negotiable. If the old value was not recorded, do not guess — retrieve it from the pre-change CR snapshot.

**Rollback from CR snapshot:**
```bash
# Use the captured snapshot file
cat cr-snapshot-before-${TIMESTAMP}.json | jq '.spec.patroni.dynamicConfiguration.postgresql.parameters'
# Extract the old value, then patch it back
```

**Rollback example (statement_timeout back to 300000):**
```bash
oc patch postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae --type=merge \
  -p '{"spec":{"patroni":{"dynamicConfiguration":{"postgresql":{"parameters":{"statement_timeout":"300000"}}}}}}'
```

**Rollback rules:**
- Rollback = another CR patch to the documented old value. Nothing else.
- Never restore a ConfigMap directly from git or by hand — PGO will overwrite it.
- Do not restart pods as a rollback action for parameter changes. The parameter change itself is the fix.
- If a postmaster parameter was changed and a rolling restart was performed, rolling back requires another patch AND another rolling restart.

---

## 8. Pending Restart Check

After patching a postmaster parameter, Patroni marks each cluster member with a "Pending restart" flag. This flag will appear in `patronictl list` output.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list

# Output columns: Member | Host | Role | State | TL | Lag in MB | Pending restart
# Pending restart = * means the member needs a restart to apply postmaster-level changes
```

**Restart implications:**
- Patroni performs a rolling restart: standby restarts first, then a switchover occurs, then the old leader restarts as the new standby.
- During the restart, there is a brief period of failover (typically < 30 seconds) where applications must reconnect.
- PgBouncer absorbs reconnection spikes if pool_mode=transaction is in use, but applications may see a momentary connection error.
- Notify application teams and DBA on-call before initiating a rolling restart.
- Schedule postmaster restarts during a low-traffic window.

---

## 9. ConfigMap and Secret Inventory Reference

### ConfigMaps (Generated by PGO — Do Not Edit Directly)

| ConfigMap Name | Purpose | Owner |
|---|---|---|
| prod-pgcluster-uae-config | Patroni configuration, PostgreSQL parameters, pg_hba.conf | PGO from CR spec.patroni |
| prod-pgcluster-uae-pgbackrest-config | pgBackRest global configuration, stanza settings, S3 endpoint | PGO from CR spec.backups.pgbackrest |
| prod-pgcluster-uae-pgbouncer | PgBouncer configuration (pgbouncer.ini) | PGO from CR spec.proxy.pgBouncer |

### Secrets (Names Documented Only — Values Never Stored in Documentation)

| Secret Name | Purpose |
|---|---|
| prod-pgcluster-uae-pgbackrest-secret | S3 credentials for pgBackRest repository access |
| prod-pgcluster-uae-pguser-* | PostgreSQL application user credentials (one Secret per pgUser) |
| prod-pgcluster-uae-replication | Replication user credentials |
| prod-pgcluster-uae-patroni | Patroni REST API credentials |
| prod-pgcluster-uae-pgbouncer | PgBouncer authentication credentials |
| prod-pgcluster-uae-cluster-cert | TLS certificates for cluster internal communication |

**IMPORTANT:** Secret values are never decoded or recorded in any SOP, ticket, or log. Retrieve values only through the approved secure credential store.

---

## 10. Change Window Requirements and Sign-off

### Reloadable Parameter Changes
- May be applied during business hours with DBA lead awareness.
- No application team notification required unless the parameter directly affects application behavior (e.g., statement_timeout changes).
- Requires: pre-change evidence capture, post-change verification, change ticket closed with evidence.

### Postmaster Parameter Changes (Require Restart)
- Must be applied during approved change window (low-traffic period, typically off-hours).
- Requires: CAB approval, application team notification minimum 24 hours in advance, DBA lead sign-off, rollback plan documented, rollback drill confirmed.
- Post-change: verify patronictl list shows healthy cluster with no Pending restart flags before closing the window.

### Emergency Changes
- If a configuration change is required to resolve a production incident, it must be approved by DBA lead verbally (followed by written record within 2 hours).
- Evidence capture rules still apply even in emergency scenarios.

### Sign-off Checklist

| Step | Completed (initials + timestamp) |
|---|---|
| Context confirmed as PROD | |
| Pre-change Patroni health verified | |
| Pre-change CR snapshot captured | |
| Old parameter value recorded | |
| Rollback value documented | |
| Change applied via oc patch | |
| Operator reconciliation confirmed | |
| Post-change parameter value verified on leader | |
| Post-change parameter value verified on standby | |
| Patroni healthy (no Pending restart, lag=0) | |
| pgBackRest status=ok | |
| Change ticket updated and closed | |

