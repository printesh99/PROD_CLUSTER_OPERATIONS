# SOP-01: Daily Health Check
## Habib Bank UAE Production PostgreSQL Cluster

**Document ID:** SOP-01  
**Version:** 1.0  
**Effective Date:** 2026-05-22  
**Author:** DBA Operations Team  
**Cluster:** prod-pgcluster-uae  
**OCP Namespace:** prod-pgcluster-uae  

---

## 1. Purpose

This SOP defines the mandatory daily health check procedure for the Habib Bank UAE production PostgreSQL cluster managed by Crunchy Data PGO (PostgreSQL Operator). The goal is to detect and triage failures in Patroni HA, streaming replication, pgBackRest backup archiving, PgBouncer connection pooling, and the DR standby cluster before they escalate into service-impacting incidents.

This document must be executed at minimum once every 24 hours, and again after any scheduled maintenance window, failover, or configuration change. All observations must be recorded in the daily shift log.

---

## 2. Scope

This procedure covers the following components:

| Component | Scope |
|---|---|
| OCP cluster | prod-pgcluster-uae / api-ocp-prod-habibbank-local:6443 |
| PostgresCluster CR | prod-pgcluster-uae |
| Patroni scope | prod-pgcluster-uae-ha |
| Primary pod | prod-pgcluster-uae-dc1-9c5j-0 |
| Sync standby pod | prod-pgcluster-uae-dc1-5c2q-0 |
| PgBouncer pods | prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww, prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl |
| Primary LB | 10.171.1.229:5555 |
| PgBouncer LB | 10.171.1.205:5555 |
| pgBackRest stanza | db / repo1 (S3) |
| DR cluster | dr-pgcluster-uae / api-ocp-dr-habibbank-local:6443 |

---

## 3. Prerequisites

Before beginning the health check, the operator must satisfy the following prerequisites:

**3.1 Access Requirements**

The operator must have `oc` CLI access (never `kubectl`) to the production OCP cluster using the `mohsinali` service account. VPN must be active and the OCP token must be valid (tokens expire; re-login if commands return `Unauthorized`).

**3.2 Working Directory**

All commands must be run from or referencing:
```
/home/mohsinali@habibbank.local/PROD_PATRONI
```

**3.3 OCP Login Verification**

Before any check, confirm the active OCP context is correct. An incorrect context risks running commands against the wrong cluster.

```bash
oc config current-context
```

Expected output:
```
prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
```

If the output does not match exactly, do not proceed. See Step 1 for context switching instructions.

---

## 4. Frequency

| Trigger | Frequency |
|---|---|
| Routine operations | Daily minimum, at shift start |
| After any maintenance | Immediately upon completion |
| After a backup job failure alert | Within 1 hour of alert |
| After a network change or OCP node drain | Within 30 minutes |
| After a Patroni leader election | Immediately |

---

## 5. Health Check Steps

---

### Step 1: Verify OCP Context and Namespace

Verify the active OCP context is pointing to the production cluster before executing any command. A wrong context can silently run commands against the DR cluster or a UAT cluster.

```bash
# Check current context
oc config current-context

# Expected output:
# prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali

# If wrong, switch context explicitly:
oc config use-context prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali

# Verify you can reach the API server:
oc whoami

# Expected:
# mohsinali

# Confirm namespace default is set (optional but avoids flag repetition):
oc project prod-pgcluster-uae
```

**Pass Criteria:** Context string matches exactly. `oc whoami` returns `mohsinali` without error.

**Fail Action:** If `oc config use-context` fails with a name not found error, the kubeconfig may need to be refreshed. Log in again:
```bash
oc login https://api-ocp-prod-habibbank-local:6443 -u mohsinali
```

---

### Step 2: Pod Inventory Check

Confirm all PostgreSQL cluster pods are Running and all containers within those pods are Ready.

```bash
oc get pods -n prod-pgcluster-uae -o wide
```

**Expected Output (reference baseline from 2026-05-22):**

| POD | READY | STATUS | NODE | IP |
|---|---|---|---|---|
| prod-pgcluster-uae-dc1-9c5j-0 | 4/4 | Running | (node) | 10.175.12.60 |
| prod-pgcluster-uae-dc1-5c2q-0 | 4/4 | Running | (node) | 10.175.14.83 |
| prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww | 2/2 | Running | (node) | (assigned IP) |
| prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl | 2/2 | Running | (node) | (assigned IP) |

**Pass/Fail Criteria Table:**

| Observation | Status |
|---|---|
| All pods in STATUS=Running | PASS |
| All containers in READY=N/N (no partial) | PASS |
| Any pod in Pending or ContainerCreating > 5 min | FAIL |
| Any pod in CrashLoopBackOff or Error | FAIL |
| Any pod in Terminating > 10 min | FAIL |
| Pod count fewer than 4 | FAIL |
| PostgreSQL pod IP matches baseline (dc1-9c5j-0 = 10.175.12.60) | PASS |

If any pod fails, collect events immediately before they are garbage-collected:
```bash
oc describe pod <pod-name> -n prod-pgcluster-uae | tail -40
oc logs <pod-name> -n prod-pgcluster-uae --all-containers --previous 2>/dev/null | tail -100
```

---

### Step 3: Patroni Health Check

Patroni manages the leader election and streaming replication topology. The expected topology is one Leader (the primary, currently `prod-pgcluster-uae-dc1-9c5j-0`) and one Sync Standby (`prod-pgcluster-uae-dc1-5c2q-0`) on timeline 8 with zero replication lag.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- patronictl -c /etc/patroni/postgres.yml list
```

**Expected Output:**

```
+ Cluster: prod-pgcluster-uae-ha (xxxxxxxxxxxxxxxx) +---------+----+-----------+
| Member                           | Host           | Role         | State   | TL | Lag in MB |
+----------------------------------+----------------+--------------+---------+----+-----------+
| prod-pgcluster-uae-dc1-9c5j-0   | 10.175.12.60:5555 | Leader    | running |  8 |           |
| prod-pgcluster-uae-dc1-5c2q-0   | 10.175.14.83:5555 | Sync Standby | running |  8 |         0 |
+----------------------------------+----------------+--------------+---------+----+-----------+
```

**Pass Criteria:** Exactly one Leader. Timeline (TL) = 8 for both members (or higher if a switchover occurred — document the new TL). Sync Standby role (not plain Replica). Lag in MB = 0 for the standby.

**Fail Conditions:**

| Observation | Severity | Immediate Action |
|---|---|---|
| No Leader in output | CRITICAL | Escalate immediately — cluster may be read-only or partitioned |
| Two nodes both show Leader | CRITICAL | Split-brain scenario — escalate immediately, do not write to either |
| Standby shows Replica instead of Sync Standby | HIGH | Check `synchronous_mode` parameter; review Patroni logs |
| Lag in MB > 0 | MEDIUM | Check network between nodes; check pg_stat_replication |
| State = stopped or crashed | HIGH | Check pod logs; attempt pod restart only after approval |
| TL incremented unexpectedly | MEDIUM | Document; review patroni.log for recent election |

---

### Step 4: Replication Lag Verification

Connect to the leader pod and query `pg_stat_replication` to verify streaming replication from the primary to the sync standby. This is more granular than the Patroni lag field.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT
  application_name,
  client_addr,
  state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  (sent_lsn - replay_lsn) AS byte_lag,
  write_lag,
  flush_lag,
  replay_lag,
  sync_state
FROM pg_stat_replication;
"
```

**Interpretation:**

| Column | Description | Pass Threshold |
|---|---|---|
| `byte_lag` | Bytes sent but not yet replayed | 0, or < 1 MB under load |
| `write_lag` | Delay for standby to write WAL to disk | NULL or < 100ms |
| `flush_lag` | Delay for standby to flush WAL | NULL or < 100ms |
| `replay_lag` | Delay for standby to apply WAL | NULL or < 200ms |
| `sync_state` | Must be `sync` for the sync standby | `sync` |

A `byte_lag` of 0 with all time lags NULL/empty indicates the standby is fully caught up and synchronous commit is functioning normally. Under write load, a transient lag of a few KB is acceptable. A sustained lag above 10 MB or time lags above 1 second requires investigation.

If `pg_stat_replication` returns no rows, the standby is either disconnected or the pod is down. Cross-reference Step 2 and Step 3.

---

### Step 5: pgBackRest Repository Health

Check the pgBackRest stanza health and backup inventory. This confirms S3 connectivity and that the backup chain is intact.

```bash
# Run on the leader pod
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 info
```

**Expected indicators in output:**

```
stanza: db
    status: ok
    cipher: aes-256-cbc

    db (current)
        wal archive min/max (16): ...

        full backup: ...
        diff backup: ...
        incr backup: ...
```

The critical fields are `status: ok`, `cipher: aes-256-cbc`, and the presence of recent backup labels. As of 2026-05-22, the latest backup label was `20260517-010001F_20260521-120001I` and the total backup count was 35.

```bash
# Run the check command to verify WAL archiving and S3 connectivity
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 check
```

**Pass Criteria:**

| Check | Pass |
|---|---|
| `status: ok` in info output | Yes |
| `cipher: aes-256-cbc` confirmed | Yes |
| At least 1 full backup present | Yes |
| `check` command exits 0 with no errors | Yes |
| Latest backup label timestamp within last 7 days (incr) or 24 hours | Yes |

**Fail Action:** If `status: error` or if `check` fails, proceed immediately to SOP-02 Backup Failure Triage. Do not attempt manual backup commands without approval.

---

### Step 6: WAL Archiver Status

The WAL archiver is the bridge between PostgreSQL's continuous WAL stream and pgBackRest's S3 repository. A stalled archiver means PITR coverage is degrading silently even if backups appear healthy.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT
  archived_count,
  last_archived_wal,
  last_archived_time,
  failed_count,
  last_failed_wal,
  last_failed_time,
  now() - last_archived_time AS time_since_last_archive
FROM pg_stat_archiver;
"
```

**Sampling Method:** Run this query twice, 60 seconds apart. Compare `archived_count` and `failed_count` between the two samples.

**Pass Criteria:**

| Observation | Status |
|---|---|
| `archived_count` increased between samples (WAL activity present) | PASS |
| `failed_count` did NOT increase between samples | PASS |
| `last_archived_time` within 5 minutes of now | PASS |
| `last_failed_time` is NULL or older than 24 hours | PASS |

**Important context:** As of the 2026-05-22 capture, `archived_count` was 704 and `failed_count` was 212. The failed_count of 212 represents historical failures (likely from a previous misconfiguration) and is not a current alarm by itself — what matters is whether `failed_count` is actively increasing. If it increases between the two 60-second samples, the archiver is currently failing and must be investigated immediately using SOP-02.

---

### Step 7: Backup Job Status

Kubernetes CronJobs schedule the pgBackRest backup jobs. Check both CronJob schedules and recent Job results to detect failures.

```bash
# List all CronJobs and recent Jobs
oc get cronjobs,jobs -n prod-pgcluster-uae

# For any failed job, get details:
oc describe job <job-name> -n prod-pgcluster-uae

# Get logs from a completed or failed backup job pod:
oc get pods -n prod-pgcluster-uae | grep repo1
oc logs <job-pod-name> -n prod-pgcluster-uae
```

**Expected CronJob Schedule Reference:**

| CronJob | Schedule | Type |
|---|---|---|
| prod-pgcluster-uae-repo1-full | 0 1 * * 0 (Sun 01:00) | Full backup |
| prod-pgcluster-uae-repo1-diff | 0 1 * * 1-6 (Mon-Sat 01:00) | Differential backup |
| prod-pgcluster-uae-repo1-incr | 0 */6 * * * (every 6h) | Incremental backup |

**Pass/Fail Criteria:**

| Observation | Status |
|---|---|
| All CronJobs show a recent `LAST SCHEDULE` | PASS |
| No jobs with `COMPLETIONS` showing 0/1 in a failed state | PASS |
| No jobs with status `BackoffLimitExceeded` | PASS |
| Latest incr job completed within last 7 hours | PASS |

**Known issue (2026-05-22):** Jobs `prod-pgcluster-uae-repo1-diff-29656860` and `prod-pgcluster-uae-repo1-incr-29657160` were in `BackoffLimitExceeded` state at the time of the daily capture. This must be tracked until resolved. See SOP-02 for triage procedure.

---

### Step 8: PgBouncer Health

PgBouncer is the application-facing connection pooler. All application traffic reaches the database through PgBouncer. Both pods must be running and the LoadBalancer service endpoint must be active.

```bash
# Check pod status
oc get pods -n prod-pgcluster-uae | grep pgbouncer

# Check the PgBouncer service and endpoint
oc get svc -n prod-pgcluster-uae | grep pgbouncer
oc get endpoints -n prod-pgcluster-uae | grep pgbouncer

# Tail recent PgBouncer logs (last 50 lines from each pod)
oc logs prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww -n prod-pgcluster-uae --tail=50
oc logs prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl -n prod-pgcluster-uae --tail=50
```

**Pass Criteria:**

| Check | Pass |
|---|---|
| Both pgbouncer pods Running 2/2 | Yes |
| PgBouncer LB service ExternalIP = 10.171.1.205 port 5555 | Yes |
| No `ERROR` or `FATAL` lines in recent logs | Yes |
| No `client_login_timeout` flood in logs | Yes |

**PgBouncer configuration reference (pool_mode=transaction, max_client_conn=2000, default_pool_size=50, max_db_connections=150):** If logs show client queue warnings or max client connection rejections, this may indicate application connection spike requiring pool size review.

---

### Step 9: Service Endpoints Verification

Verify that the Kubernetes service endpoints resolve to the correct pod IPs. A stale endpoint entry can silently route traffic to a terminated pod.

```bash
oc get endpoints -n prod-pgcluster-uae
```

**Expected Endpoints (baseline from 2026-05-22):**

| Service | Expected Endpoint(s) |
|---|---|
| Primary PostgreSQL LB | 10.175.12.60:5555 (leader pod) |
| PgBouncer LB | 10.175.12.58:5555 and 10.175.14.105:5555 |
| Patroni HA service | 10.175.12.60:5555 |

If the primary LB endpoint does not point to the current Patroni leader IP (which can change after a failover), investigate the service selector and ensure the DCS (etcd/consul within Patroni) is correctly updating the endpoint.

After any Patroni leader election, re-run this step to confirm the endpoint updated. If the endpoint did not update within 60 seconds of a leader change, there may be a PGO controller issue.

---

### Step 10: DR Quick Check

Verify the DR cluster connectivity and standby health. As of 2026-05-22, the DR OCP API (`api-ocp-dr-habibbank-local:6443`) was timing out from the operations terminal — this may be a VPN routing issue. Document the result regardless.

```bash
# Test DR API reachability (timeout in 10s)
timeout 10 oc --context=dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali \
  get pods -n dr-pgcluster-uae 2>&1 || echo "DR_API_UNREACHABLE"

# If reachable, check DR pod status:
oc --context=dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali \
  get pods -n dr-pgcluster-uae -o wide

# Check DR PostgresCluster standby mode:
oc --context=dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali \
  get postgrescluster dr-pgcluster-uae -n dr-pgcluster-uae \
  -o jsonpath='{.spec.standby}{"\n"}'
```

**Expected DR standby spec output:**
```json
{"enabled":true,"host":"10.171.1.229","port":5555,"repoName":"repo1"}
```

**Pass Criteria:**

| Observation | Status |
|---|---|
| DR API reachable | PASS |
| DR API unreachable (document, do not fail the overall check if known) | SKIP with note |
| DR pods Running | PASS |
| `spec.standby.enabled=true` confirmed | PASS |
| DR pod in state `Standby Leader` (via patronictl) | PASS |

If the DR API is unreachable, mark the DR step as SKIP and escalate if it has been unreachable for more than 24 hours. See SOP-04 for full DR health check procedure and known blockers.

---

### Step 11: Database Size and Session Pressure

Check database sizes and active session counts to detect unexpected data growth or session accumulation.

```bash
# Database sizes on leader
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT
  datname,
  pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
"

# Session counts by state
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT
  state,
  count(*) AS count,
  max(now() - state_change) AS longest
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY state
ORDER BY count DESC;
"

# Check max_connections headroom
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT
  count(*) AS total_connections,
  (SELECT setting::int FROM pg_settings WHERE name='max_connections') AS max_connections,
  (SELECT setting::int FROM pg_settings WHERE name='max_connections') - count(*) AS remaining
FROM pg_stat_activity;
"
```

**Pass Thresholds:**

| Metric | Pass Threshold |
|---|---|
| `idle in transaction` sessions | < 10, longest < 30 minutes |
| `active` sessions | < 200 sustained (max_connections=800) |
| Total connections | < 700 (leaving 100 for superuser reserve) |
| Database size change vs previous day | < 20% growth; flag if > 20% |

A large number of `idle in transaction` sessions indicates application connection management issues and can block autovacuum. If `idle in transaction` longest > 30 minutes, escalate to the application team.

---

### Step 12: Health Check Sign-Off

Complete the sign-off table after completing all steps. Record the date, operator name, and any FAIL or SKIP results with explanatory notes.

**Date:** _______________  
**Operator:** _______________  
**Shift:** _______________

| Step | Check | Status | Notes |
|---|---|---|---|
| 1 | OCP Context Verified | PASS / FAIL | |
| 2 | All Pods Running/Ready | PASS / FAIL | |
| 3 | Patroni Leader + Sync Standby TL 8, lag=0 | PASS / FAIL | |
| 4 | pg_stat_replication byte_lag=0 | PASS / FAIL | |
| 5 | pgBackRest status=ok, cipher=aes-256-cbc | PASS / FAIL | |
| 6 | WAL archiver not accumulating failures | PASS / FAIL | |
| 7 | No Failed/BackoffLimitExceeded backup jobs | PASS / FAIL | |
| 8 | Both PgBouncer pods Running, LB active | PASS / FAIL | |
| 9 | Service endpoints match expected pod IPs | PASS / FAIL | |
| 10 | DR API reachable, standby.enabled=true | PASS / FAIL / SKIP | |
| 11 | Session counts and DB sizes within threshold | PASS / FAIL | |

**Escalation Criteria:** Escalate immediately if any of the following are observed: no Patroni leader, split-brain (two leaders), standby streaming disconnected with byte_lag > 100 MB, pgBackRest status=error, PgBouncer LB service has no endpoints, or both PostgreSQL pods are not Running.

---

## 6. Escalation Contacts

| Role | Contact | Channel |
|---|---|---|
| DBA Lead | [PLACEHOLDER] | [PLACEHOLDER] |
| Infrastructure Lead | [PLACEHOLDER] | [PLACEHOLDER] |
| On-call Engineer | [PLACEHOLDER] | [PLACEHOLDER] |
| Crunchy Data Support | [PLACEHOLDER] | support.crunchydata.com |

---

## 7. Sign-Off

**Completed by:** _______________  
**Date/Time (UTC):** _______________  
**Signature:** _______________  
**Reviewed by (if applicable):** _______________

