# RUNBOOK: Planned Switchover — Habib Bank UAE PostgreSQL 18

**Cluster:** prod-pgcluster-uae | **Patroni Scope:** prod-pgcluster-uae-ha | **Namespace:** prod-pgcluster-uae  
**PGO Version:** Crunchy Data PGO v5 | **Last Validated:** 2026-05-22

---

## Quick Reference — Critical Commands

```bash
# 1. Pre-flight: check replication lag
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT application_name, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"

# 2. Pause PgBouncer (optional — reduces write disruption window)
oc exec -n prod-pgcluster-uae \
  $(oc get pod -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/role=pgbouncer -o jsonpath='{.items[0].metadata.name}') \
  -c pgbouncer -- psql -p 5432 -U pgbouncer pgbouncer -c "PAUSE;"

# 3. Execute switchover
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml switchover prod-pgcluster-uae-ha \
  --master prod-pgcluster-uae-dc1-9c5j-0 \
  --candidate prod-pgcluster-uae-dc1-5c2q-0 \
  --scheduled now --force

# 4. Resume PgBouncer
oc exec -n prod-pgcluster-uae \
  $(oc get pod -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/role=pgbouncer -o jsonpath='{.items[0].metadata.name}') \
  -c pgbouncer -- psql -p 5432 -U pgbouncer pgbouncer -c "RESUME;"

# 5. Confirm new leader
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

---

## Overview

A planned switchover gracefully transfers the primary role from prod-pgcluster-uae-dc1-9c5j-0 to prod-pgcluster-uae-dc1-5c2q-0 (or vice versa). Patroni coordinates the transition ensuring zero data loss. Application downtime is typically 5–30 seconds.

**Use cases:**
- Node maintenance (OS patching, hardware work, PVC resizing)
- PostgreSQL minor version upgrades
- Resource rebalancing
- Pre-planned DR drills

**Do NOT use a switchover when:**
- The primary is already failing (use the Failover runbook instead)
- Replication lag exceeds 10 MB (wait for lag to clear first)
- A backup is currently running (pgBackRest full/incr/diff)

---

## Pre-Flight Checks

**Estimated time: 10–15 minutes**

### PF-1: Confirm Cluster Health

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

All members must show `running` state. No member should be in `start failed`, `stopped`, or `creating replica`.

### PF-2: Check Replication Lag (Must Be < 1 MB)

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "
    SELECT
      application_name,
      state,
      sync_state,
      write_lag,
      flush_lag,
      replay_lag,
      pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
    FROM pg_stat_replication;"
```

**Gate:** `lag_bytes` must be < 1048576 (1 MB) before proceeding.

### PF-3: Check No Active Long-Running Transactions

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "
    SELECT pid, usename, datname, now() - xact_start AS duration, state, query
    FROM pg_stat_activity
    WHERE xact_start IS NOT NULL
      AND now() - xact_start > interval '5 minutes'
    ORDER BY duration DESC;"
```

Coordinate with application team to complete or terminate long transactions before switchover.

### PF-4: Confirm No pgBackRest Backup Running

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 info | grep -E "status|type"
```

Wait for any in-progress backup to complete before switching over.

### PF-5: Check Connection Count

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT count(*) AS active_connections, max_conn FROM pg_stat_activity, (SELECT setting::int AS max_conn FROM pg_settings WHERE name='max_connections') mc;"
```

`max_connections = 800`. If > 700 connections, notify application team to drain before switchover.

### PF-6: Notify Team

- Send maintenance notification to application team
- Log change request ticket number
- Confirm DBA on-call awareness
- Set maintenance window in monitoring (mute alerts for 15 minutes)

---

## Step-by-Step Switchover

### Step 1: Pause PgBouncer (Recommended)

Pausing PgBouncer queues client transactions during switchover instead of returning errors, reducing application impact.

```bash
PGBOUNCER_POD=$(oc get pod -n prod-pgcluster-uae \
  -l postgres-operator.crunchydata.com/role=pgbouncer \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "PAUSE;"
```

Confirm PgBouncer paused:

```bash
oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "SHOW POOLS;" | grep -v "^$"
```

**Note:** PgBouncer will queue connections for up to `query_wait_timeout` seconds (default 120s). Switchover must complete before this timeout.

### Step 2: Execute Patroni Switchover

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml switchover prod-pgcluster-uae-ha \
  --master prod-pgcluster-uae-dc1-9c5j-0 \
  --candidate prod-pgcluster-uae-dc1-5c2q-0 \
  --scheduled now \
  --force
```

**What happens internally:**
1. Patroni sets `pg_ctl stop -m fast` on current primary (dc1-9c5j-0)
2. Patroni waits for candidate (dc1-5c2q-0) to catch up fully (zero lag)
3. Candidate promotes itself
4. Former primary restarts as a replica of the new primary
5. Patroni updates DCS (etcd) with new leader election

### Step 3: Monitor Switchover Progress

```bash
watch -n 2 'oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha'
```

Timeline increments from TL:8 → TL:9 confirms successful switchover.

### Step 4: Resume PgBouncer

As soon as the new primary (dc1-5c2q-0) shows `Leader` state:

```bash
oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "RESUME;"
```

Verify PgBouncer connections routing to new primary:

```bash
oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "SHOW SERVERS;"
```

### Step 5: Verify New Primary

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), inet_server_addr(), current_setting('cluster_name'), now();"
```

---

## Monitoring During Switchover

### Watch Patroni Events

```bash
oc logs -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -f &
oc logs -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -f &
```

### Watch PgBouncer Client Wait Queue

```bash
watch -n 2 'oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "SHOW CLIENTS;" | grep -c "waiting"'
```

### Watch Replication Catching Up

After switchover, the former primary should appear as a streaming replica within 30 seconds:

```bash
watch -n 3 'oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;"'
```

---

## Post-Switchover Verification

### V-1: Patroni Cluster State

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

Expected:
- dc1-5c2q-0: Leader, TL:9, running
- dc1-9c5j-0: Sync Standby, TL:9, running, Lag: 0

### V-2: Write Test on New Primary

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "CREATE TABLE IF NOT EXISTS switchover_test (ts timestamptz DEFAULT now()); INSERT INTO switchover_test DEFAULT VALUES; SELECT * FROM switchover_test; DROP TABLE switchover_test;"
```

### V-3: Sync Replication Re-Established

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, sync_state FROM pg_stat_replication;"
```

Expected: `sync_state = sync` for dc1-9c5j-0.

### V-4: LB Health Check

```bash
pg_isready -h 10.171.1.229 -p 5555 -U postgres && echo "LB OK"
pg_isready -h 10.171.1.205 -p 5555 -U postgres && echo "PgBouncer OK"
```

### V-5: DR Streaming Still Active

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

DR standby (dr-pgcluster-uae) should appear with `state = streaming`.

### V-6: pgBackRest Stanza OK

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  pgbackrest --stanza=db --repo=1 info
```

---

## PgBouncer Behavior During Switchover

| Phase | PgBouncer State | Client Behavior |
|-------|----------------|-----------------|
| Before PAUSE | Active, routing to primary | Normal operation |
| After PAUSE | Paused, queuing connections | Transactions queue (no errors) |
| During switchover (5–30s) | Paused | Connections queued up to `query_wait_timeout` |
| After RESUME | Active, routing to new primary | Queued transactions execute |

**PgBouncer config relevant settings:**
- `server_check_query = SELECT 1` — detects broken connections to old primary
- `server_check_delay` — how quickly PgBouncer detects primary change
- Patroni integrates via `/master` health endpoint for service routing

If PgBouncer is NOT paused, clients may receive brief connection errors during the ~5s between old primary shutdown and new primary promotion. Applications with retry logic will handle this transparently.

---

## Application Impact and Expected Downtime

| Scenario | Expected Downtime |
|----------|------------------|
| PgBouncer paused before switchover | 0 errors (connections queued) |
| PgBouncer NOT paused, app has retry | ~5–15 seconds of connection errors |
| PgBouncer NOT paused, app no retry | ~5–30 seconds of errors until reconnect |
| Worst case (heavy load, slow promotion) | Up to 60 seconds |

**RPO:** Zero (Patroni waits for sync standby to be fully caught up before promoting)  
**RTO:** 5–30 seconds for write availability

---

## Rollback Procedure (If Switchover Fails)

### Scenario A: Switchover Hangs (> 2 minutes)

```bash
# Kill the switchover
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml switchover prod-pgcluster-uae-ha --scheduled now \
  --master prod-pgcluster-uae-dc1-5c2q-0 \
  --candidate prod-pgcluster-uae-dc1-9c5j-0 \
  --force
```

Switch back to original primary (dc1-9c5j-0).

### Scenario B: Candidate Failed to Promote

```bash
# Check candidate logs
oc logs -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database --tail=50

# Restart Patroni on candidate
oc delete pod -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0

# Original primary should retain leadership
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

### Scenario C: PgBouncer Stuck in PAUSE

```bash
PGBOUNCER_POD=$(oc get pod -n prod-pgcluster-uae \
  -l postgres-operator.crunchydata.com/role=pgbouncer \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "RESUME;"
```

If PgBouncer pod is unresponsive:

```bash
oc delete pod -n prod-pgcluster-uae ${PGBOUNCER_POD}
```

PGO will restart PgBouncer automatically.

---

## Post-Switchover Checklist

| # | Check | Status |
|---|-------|--------|
| 1 | New primary (dc1-5c2q-0) is Leader | |
| 2 | Timeline incremented to TL:9 | |
| 3 | Former primary (dc1-9c5j-0) is Sync Standby | |
| 4 | Replication lag < 1 MB | |
| 5 | PgBouncer RESUMED | |
| 6 | LB 10.171.1.229:5555 accepting connections | |
| 7 | PgBouncer 10.171.1.205:5555 accepting connections | |
| 8 | DR streaming active | |
| 9 | pgBackRest info shows stanza OK | |
| 10 | Monitoring alerts un-muted | |
| 11 | Change ticket closed | |
| 12 | Team notified of completion | |

