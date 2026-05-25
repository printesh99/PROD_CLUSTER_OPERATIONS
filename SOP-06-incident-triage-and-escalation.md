# SOP-06: Incident Triage and Escalation
## Habib Bank UAE Production PostgreSQL Cluster

**Cluster:** prod-pgcluster-uae
**OCP Context:** prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
**Namespace:** prod-pgcluster-uae
**PostgresCluster CR:** prod-pgcluster-uae
**Leader Pod:** prod-pgcluster-uae-dc1-9c5j-0
**Sync Standby Pod:** prod-pgcluster-uae-dc1-5c2q-0
**PgBouncer Pods:** prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww, prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl
**PROD Primary LB:** 10.171.1.229:5555
**PROD PgBouncer LB:** 10.171.1.205:5555
**Working Directory:** /home/mohsinali@habibbank.local/PROD_PATRONI
**Last Reviewed:** 2026-05-22

---

## 1. First Response Commands

These four commands must be run immediately when an incident is reported, in this order. Do not skip any of them.

```bash
# Step 1: Navigate to the working directory
cd /home/mohsinali@habibbank.local/PROD_PATRONI

# Step 2: Confirm you are on the PROD context before issuing any commands
oc config current-context
# Expected output: prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
# STOP if this output is anything else. Switch context first, then re-run.

# Step 3: Check pod status across the namespace
oc get pods -n prod-pgcluster-uae -o wide
# Look for: all pods Running and Ready, no CrashLoopBackOff, no Pending, no Error

# Step 4: Check Patroni cluster state
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
# Expected: Leader (dc1-9c5j-0), Sync Standby (dc1-5c2q-0), Lag=0, no Pending restart

# Step 5: Check pgBackRest repository health
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
  pgbackrest --stanza=db info
# Expected: status: ok, backup set visible with recent timestamps
```

**Record all output before taking any action. These outputs are your triage baseline.**

---

## 2. Incident Category Decision Tree

Use the first response outputs to determine the incident category. Work through each category in order.

---

### CATEGORY A: PROD Database Not Accessible

**Trigger:** Applications cannot connect, or connection tests to 10.171.1.229:5555 or 10.171.1.205:5555 fail.

**Decision flow:**

1. **Are database pods Running and Ready?**
   ```bash
   oc get pods -n prod-pgcluster-uae -o wide | grep -E "dc1|pgbouncer"
   ```
   - If pods are not Running → Go to sub-check A1 (Pod crashloop investigation)
   - If pods are Running → Continue to step 2

2. **Are service endpoints active?**
   ```bash
   oc get endpoints -n prod-pgcluster-uae
   oc get service -n prod-pgcluster-uae
   ```
   - If endpoints are empty → PGO may be in a reconciliation loop; check operator pod health
   - If endpoints are populated → Continue to step 3

3. **Is PgBouncer alive?**
   ```bash
   for POD in prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl; do
     echo "=== $POD ==="
     oc exec -it $POD -n prod-pgcluster-uae -c pgbouncer -- \
       psql -p 5432 pgbouncer -c "SHOW POOLS;" 2>&1 | head -20
   done
   ```
   - If PgBouncer is not responding → Check PgBouncer pod logs for auth/config errors
   - If PgBouncer responds → Continue to step 4

4. **Is PostgreSQL accepting connections?**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "SELECT pg_is_in_recovery(), now();"
   ```
   - If PostgreSQL responds → Check pg_hba.conf rules and TLS configuration
   - If PostgreSQL does not respond → Check database pod logs and Patroni state

**Sub-check A1 — Pod crashloop investigation:**
```bash
oc describe pod <pod-name> -n prod-pgcluster-uae
oc logs <pod-name> -n prod-pgcluster-uae -c database --previous
oc logs <pod-name> -n prod-pgcluster-uae -c database
```

**Likely causes of Category A:**
- Pod crashloop due to PVC mount failure → check `kubectl describe pvc`
- TLS certificate rotation caused a temporary auth failure
- PgBouncer pool exhaustion (max_client_conn=2000 reached) → check SHOW POOLS; cl_waiting column
- Wrong pg_hba.conf entry after a recent config change
- PostgreSQL in crash recovery (postmaster restart after OOM kill)

**STOP AND ESCALATE if:** Pods are in CrashLoopBackOff with unknown root cause after reviewing logs. Do not attempt pod deletion or PVC modifications without DBA lead approval.

---

### CATEGORY B: Replication Broken — No Sync Standby

**Trigger:** patronictl list shows no Sync Standby, or standby lag is greater than 0 for more than 5 minutes.

**Decision flow:**

1. **Confirm patronictl list output:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     patronictl -c /etc/patroni/patroni.yaml list
   ```
   - Count the number of members showing "Leader" role
   - If more than one member shows Leader → **STOP IMMEDIATELY — SPLIT BRAIN RISK** (see Stop Rules, Section 3)

2. **Check WAL sender status on the leader:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT application_name, client_addr, state, sync_state,
              sent_lsn, write_lsn, flush_lsn, replay_lsn,
              write_lag, flush_lag, replay_lag
       FROM pg_stat_replication;"
   ```
   - If no rows returned → Standby WAL receiver has disconnected
   - If rows returned but sync_state is 'async' or 'potential' instead of 'sync' → Synchronous replication degraded

3. **Check standby pod status:**
   ```bash
   oc get pods -n prod-pgcluster-uae | grep dc1-5c2q-0
   oc exec -it prod-pgcluster-uae-dc1-5c2q-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
   ```

4. **Check standby WAL receiver logs:**
   ```bash
   oc logs prod-pgcluster-uae-dc1-5c2q-0 -n prod-pgcluster-uae -c database --tail=100
   ```

**Important — synchronous commit behavior:**
Because `synchronous_commit=on` and `synchronous_mode=true`, if the sync standby is disconnected:
- Patroni may degrade to async mode if `synchronous_mode_strict=false` (current config) — writes continue but durability guarantee is reduced
- Monitor closely: if sync_state shows 'async' instead of 'sync', durability has been reduced

**STOP AND ESCALATE if:** Two members are showing as Leader simultaneously. This is a split-brain condition. Do not issue any write SQL, do not promote anything manually, do not restart anything. Escalate immediately.

**STOP AND ESCALATE if:** You are considering initiating DR promotion while PROD still appears to be running. DR promotion is only safe when PROD is confirmed non-functional.

---

### CATEGORY C: Backup Job Failure

**Trigger:** Alert for failed pgBackRest backup job, or oc get jobs shows Failed status.

**Decision flow:**

1. **Check job status:**
   ```bash
   oc get jobs -n prod-pgcluster-uae
   # Look for: COMPLETIONS 0/1, FAILED count > 0
   ```

2. **If BackoffLimitExceeded — pods are already deleted. Use oc describe:**
   ```bash
   oc describe job <job-name> -n prod-pgcluster-uae
   # Look for: Events section, pod names that were created, failure reasons
   ```

3. **Check pgBackRest repository status:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
     pgbackrest --stanza=db info
   ```
   - If status=ok → The repository is readable and previous backups are intact. The job logic failed (network, S3 timeout, stanza lock), not the repository itself.
   - If status is not ok → Repository is impaired. ESCALATE immediately.

4. **Check S3 connectivity from the pgBackRest pod:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
     curl -v https://s3-endpoint/ 2>&1 | head -30
   ```

5. **Check WAL archiver health (related):**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT archived_count, failed_count, last_archived_wal, last_archived_time,
              last_failed_wal, last_failed_time, stats_reset
       FROM pg_stat_archiver;"
   ```

6. **Check pgBackRest spool disk space:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     du -sh /pgdata/pgbackrest-spool/
   ```

**ESCALATE if:** failed_count is non-zero AND increasing (take two readings 60 seconds apart). WAL archiving failure means the PITR window is shrinking.

**S3 Bucket:** pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e | **Stanza:** db | **Repo:** repo1

---

### CATEGORY D: WAL Archiver Failing

**Trigger:** Monitoring alert for pg_stat_archiver failed_count, or last_archived_time is stale.

**Decision flow:**

1. **Baseline WAL archiver state (take two readings 60 seconds apart):**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT archived_count, failed_count, last_archived_wal,
              last_archived_time, last_failed_wal, last_failed_time
       FROM pg_stat_archiver;"

   sleep 60

   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT archived_count, failed_count, last_archived_wal,
              last_archived_time, last_failed_wal, last_failed_time
       FROM pg_stat_archiver;"
   ```
   - If failed_count is the same on both readings → archiver may have recovered; continue monitoring
   - If failed_count increased → Active archiving failure. Escalate.

2. **Check pgBackRest container logs on the leader pod:**
   ```bash
   oc logs prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest --tail=100
   ```

3. **Check spool disk usage:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     du -sh /pgdata/pgbackrest-spool/
   ls -la /pgdata/pgbackrest-spool/archive/db/out/ | wc -l
   ```
   High spool backlog (thousands of files) means WAL segments are queuing and not being shipped to S3.

4. **Check S3 endpoint reachability:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
     pgbackrest --stanza=db check
   ```

**Risk assessment:**
- If last_archived_time is more than 10 minutes ago and failed_count is growing → PITR window is shrinking. The time since the last successful archive is the maximum data loss window in a restore scenario.
- WAL segments accumulate in pg_wal on the primary until archived. If pg_wal fills the PVC (500Gi pgwal PVC), PostgreSQL will PANIC and shut down.

**ESCALATE if:** last_archived_time > 10 minutes ago AND failed_count is increasing between two readings 60 seconds apart.

---

### CATEGORY E: Session and Connection Pressure

**Trigger:** Application teams report slow queries or connection timeouts. Monitoring shows connection count approaching limits.

**Limits to monitor:**
- PostgreSQL max_connections = 800
- PgBouncer max_client_conn = 2000
- PgBouncer default_pool_size = 50 (per database per user)
- PgBouncer max_db_connections = 150
- query_wait_timeout = 120s (PgBouncer drops client if it waits > 120s for a server connection)

**Decision flow:**

1. **Check current PostgreSQL connection count:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT count(*) AS total_connections,
              count(*) FILTER (WHERE state='idle') AS idle,
              count(*) FILTER (WHERE state='idle in transaction') AS idle_in_txn,
              count(*) FILTER (WHERE state='active') AS active,
              count(*) FILTER (WHERE wait_event_type='Lock') AS waiting_on_lock
       FROM pg_stat_activity
       WHERE pid <> pg_backend_pid();"
   ```

2. **Check idle-in-transaction sessions (these hold locks):**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT pid, usename, application_name, client_addr, state,
              now() - state_change AS duration, query
       FROM pg_stat_activity
       WHERE state = 'idle in transaction'
       ORDER BY duration DESC
       LIMIT 20;"
   ```
   Note: idle_in_transaction_session_timeout=120000ms (2 minutes) is configured and will auto-terminate these after 2 minutes.

3. **Check blocking locks:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT blocking_locks.pid AS blocking_pid,
              blocking_activity.usename AS blocking_user,
              blocked_locks.pid AS blocked_pid,
              blocked_activity.usename AS blocked_user,
              blocked_activity.query AS blocked_statement
       FROM pg_catalog.pg_locks AS blocked_locks
       JOIN pg_catalog.pg_stat_activity AS blocked_activity ON blocked_activity.pid = blocked_locks.pid
       JOIN pg_catalog.pg_locks AS blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
         AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
         AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
         AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
         AND blocking_locks.pid != blocked_locks.pid
       JOIN pg_catalog.pg_stat_activity AS blocking_activity ON blocking_activity.pid = blocking_locks.pid
       WHERE NOT blocked_locks.granted
       LIMIT 20;"
   ```

4. **Check PgBouncer pool state:**
   ```bash
   for POD in prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl; do
     echo "=== $POD ==="
     oc exec -it $POD -n prod-pgcluster-uae -c pgbouncer -- \
       psql -p 5432 pgbouncer -c "SHOW POOLS;"
   done
   # cl_waiting column > 0 means clients are queuing for a server connection
   ```

**DO NOT terminate sessions without explicit DBA lead approval.** The idle_in_transaction_session_timeout will automatically clean up sessions held for more than 2 minutes.

**ESCALATE if:** cl_waiting is consistently non-zero across PgBouncer pools, meaning PgBouncer's client connection queue is growing and query_wait_timeout (120s) will begin dropping client connections.

---

### CATEGORY F: DR Concern

**Trigger:** DR cluster unreachable, DR monitoring shows degraded state, or stakeholders ask about DR status.

**Decision flow:**

1. **Confirm your terminal is connected to the correct VPN and can resolve the DR API:**
   ```bash
   oc config get-contexts
   # Look for: dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali
   ```

2. **Switch to DR context and check (only for observation — never issue write commands on DR while PROD is running):**
   ```bash
   oc config use-context dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali
   oc get pods -n dr-pgcluster-uae -o wide
   # Switch back immediately after checking
   oc config use-context prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
   ```

3. **If DR API is unreachable → troubleshoot VPN/routing first.** DR health cannot be inferred from PROD data. Do not draw conclusions about DR based on what PROD replication looks like.

**Hard rules for DR:**
- Never infer DR health from PROD-side data alone.
- DR promotion (switching DR to accept writes) is only safe when PROD is confirmed non-operational and all PROD pods are stopped.
- **STOP AND ESCALATE if:** Anyone is considering DR promotion while PROD appears to still be running or accepting writes.

**DR Cluster context:** dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali
**DR Namespace:** dr-pgcluster-uae

---

### CATEGORY G: Storage and PVC Pressure

**Trigger:** Disk usage alerts, WAL archiving warnings, or replication slot accumulation.

**Storage allocation:**
- pgdata PVC: 2Ti per pod (StorageClass: ocs-storagecluster-ceph-rbd)
- pgwal PVC: 500Gi per pod
- max_slot_wal_keep_size: 300GB (WAL kept by slots, PostgreSQL drops slots if this is exceeded)

**Decision flow:**

1. **Check disk usage inside the leader pod:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     bash -c "
       echo '=== pgdata ==='; du -sh /pgdata/
       echo '=== pgwal ==='; du -sh /pgwal/
       echo '=== pg_wal directory ==='; du -sh /pgwal/pg18_wal/
       echo '=== pgbackrest-spool ==='; du -sh /pgdata/pgbackrest-spool/ 2>/dev/null || echo 'not found'
     "
   ```

2. **Check PVC usage from OCP:**
   ```bash
   oc get pvc -n prod-pgcluster-uae
   ```

3. **Check for inactive replication slots retaining WAL:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     psql -U postgres -c "
       SELECT slot_name, slot_type, active, restart_lsn, wal_status, safe_wal_size,
              pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
       FROM pg_replication_slots
       ORDER BY retained_wal DESC NULLS LAST;"
   ```
   - If any slot is inactive (active=f) with large retained_wal → that slot is preventing WAL cleanup
   - wal_status=reserved or wal_status=extended → monitor closely
   - wal_status=lost → slot is already invalidated, WAL was dropped

4. **Check pgbackrest-spool backlog:**
   ```bash
   oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
     bash -c "ls /pgdata/pgbackrest-spool/archive/db/out/ 2>/dev/null | wc -l"
   # High count means WAL is queuing and not being shipped
   ```

**ESCALATE if:** PVC usage > 80% on any pod. Do not delete WAL files or replication slots without DBA lead approval.

**Safety cap:** max_slot_wal_keep_size=300GB means PostgreSQL will automatically invalidate replication slots that are retaining more than 300GB of WAL — this protects the PVC but means the standby must perform a full re-sync if its slot is lost.

---

## 3. Stop-and-Escalate Absolute Rules

The following situations require an immediate STOP of all actions and escalation to the DBA lead or on-call senior DBA. No exceptions.

1. **More than one writable primary suspected.** If patronictl list or any other evidence suggests two cluster members are both in Leader/Master state simultaneously, stop all actions. This is a split-brain condition. Do not write to either node. Do not restart anything. Escalate immediately.

2. **DR promotion being considered while PROD may still accept writes.** DR promotion is irreversible in the short term. Initiating it while PROD is running creates a dual-write scenario that can corrupt data. Confirm PROD is fully stopped before any DR promotion command.

3. **pgBackRest repository not readable.** If `pgbackrest --stanza=db info` returns an error or status is not ok, the backup repository may be impaired. Do not attempt backup operations. Escalate to verify S3 bucket integrity.

4. **WAL archiver failed_count is increasing between two readings.** Active WAL archiving failure reduces the PITR window and risks pg_wal PVC exhaustion. Stop non-essential work and investigate S3 connectivity and spool disk space.

5. **Database pods not Ready with unclear root cause.** If all pods are down and log analysis does not clearly identify the cause within 15 minutes, escalate. Do not delete PVCs. Do not delete pods in bulk.

6. **Wrong OCP context or namespace for any command.** Before every command, verify `oc config current-context`. If you issued a command against the DR cluster when intending PROD, or vice versa, STOP and assess impact before continuing.

7. **Any action that would:** delete pods or PVCs, shut down the cluster, patch standby mode (spec.standby.enabled), run destructive SQL (DROP, TRUNCATE, DELETE without WHERE), or remove replication slots — **requires explicit DBA lead approval and must not be performed unilaterally during incident response**.

---

## 4. Evidence Collection Checklist

Collect the following before escalating. Attach all output to the incident ticket.

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EVIDENCE_DIR=~/PROD_PATRONI/incident-evidence-${TIMESTAMP}
mkdir -p $EVIDENCE_DIR

# OCP context
oc config current-context > $EVIDENCE_DIR/oc-context.txt

# Pod status
oc get pods -n prod-pgcluster-uae -o wide > $EVIDENCE_DIR/pods.txt

# Patroni cluster state
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list > $EVIDENCE_DIR/patroni-list.txt 2>&1

# PostgresCluster CR status
oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json \
  | jq '.status' > $EVIDENCE_DIR/cr-status.json

# pgBackRest info
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c pgbackrest -- \
  pgbackrest --stanza=db info > $EVIDENCE_DIR/pgbackrest-info.txt 2>&1

# WAL archiver status
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT * FROM pg_stat_archiver;" \
  > $EVIDENCE_DIR/pg-stat-archiver.txt 2>&1

# Replication slots
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT * FROM pg_replication_slots;" \
  > $EVIDENCE_DIR/replication-slots.txt 2>&1

# pg_stat_replication
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;" \
  > $EVIDENCE_DIR/pg-stat-replication.txt 2>&1

# Connection counts
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;" \
  > $EVIDENCE_DIR/connection-counts.txt 2>&1

# Recent pod logs (leader)
oc logs prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database --tail=200 \
  > $EVIDENCE_DIR/leader-logs.txt 2>&1

# Recent pod logs (standby)
oc logs prod-pgcluster-uae-dc1-5c2q-0 -n prod-pgcluster-uae -c database --tail=200 \
  > $EVIDENCE_DIR/standby-logs.txt 2>&1

echo "Evidence collected in $EVIDENCE_DIR"
ls -la $EVIDENCE_DIR
```

---

## 5. Escalation Template

When escalating to the next tier (DBA lead, on-call senior, or vendor support), provide the following structured information:

```
INCIDENT ESCALATION — Habib Bank UAE PROD PostgreSQL Cluster

Date/Time (UTC):
Reported by:
Incident Ticket:

CLUSTER STATE AT TIME OF ESCALATION:
- OCP context confirmed as PROD: YES / NO
- Pod status: ALL RUNNING / [list any not Running]
- Patroni state: HEALTHY / [describe: missing sync standby / lag / multiple leaders / etc.]
- pgBackRest status: OK / [describe error]
- WAL archiver: OK / FAILING (failed_count increasing: YES / NO)
- PgBouncer: RESPONDING / NOT RESPONDING

INCIDENT SUMMARY:
[2-3 sentences describing what is failing, what impact it is causing, and when it started]

ACTIONS TAKEN SO FAR:
[List of commands run and their outputs, in order]

EVIDENCE COLLECTED:
[Attach evidence directory or paste key outputs]

WHAT DECISION IS NEEDED FROM ESCALATION:
[Specific: e.g., "Approval to delete inactive replication slot X", "Guidance on whether to proceed with DR promotion"]

STOP RULE TRIGGERED (if applicable):
[Which stop-and-escalate rule from Section 3 was triggered]

CURRENT RISK ASSESSMENT:
- Data loss risk: LOW / MEDIUM / HIGH
- Service outage: CURRENT / IMMINENT / RESOLVED
- Backup integrity: CONFIRMED OK / UNCERTAIN / IMPAIRED
```

