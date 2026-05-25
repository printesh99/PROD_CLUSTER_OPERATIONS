# RUNBOOK: Unplanned Failover — Habib Bank UAE PostgreSQL 18

**Cluster:** prod-pgcluster-uae | **Patroni Scope:** prod-pgcluster-uae-ha | **Namespace:** prod-pgcluster-uae  
**PGO Version:** Crunchy Data PGO v5 | **Last Validated:** 2026-05-22

---

## Quick Reference — Critical Commands

```bash
# 1. Check pod status
oc get pods -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae

# 2. Check Patroni cluster state
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha

# 3. Force manual failover (only if auto-promotion failed)
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml failover prod-pgcluster-uae-ha --force

# 4. Verify new primary accepts writes
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), inet_server_addr(), now();"

# 5. Check DR streaming resumed
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, state, sent_lsn, replay_lsn, sync_state FROM pg_stat_replication;"
```

---

## Decision Tree: Is the Primary Really Dead?

```
Primary pod unresponsive or crash detected?
│
├─► oc get pods -n prod-pgcluster-uae          ← Pod in CrashLoopBackOff / Error / Terminating?
│    │
│    ├─ NO (pod Running) ──────────────────────► Check pg_isready (Step 1.3)
│    │
│    └─ YES (pod not Running) ────────────────► Check Patroni state (Step 1.2)
│         │
│         ├─ Patroni shows new Leader already?
│         │    ├─ YES ──────────────────────────► Go to Phase 2: Confirm auto-promotion
│         │    └─ NO ───────────────────────────► Go to Phase 3: Manual failover
│         │
│         └─ Patroni DCS unreachable? ──────────► STOP — escalate. Do NOT failover.
│                                                   (Split-brain risk)
```

**Warning:** Never trigger a manual failover if the primary is merely slow or the DCS (etcd) is unreachable. Confirm true primary death first.

---

## Phase 1: Detect

**Estimated time: 2–5 minutes**

### 1.1 Check Pod Status

```bash
oc get pods -n prod-pgcluster-uae -o wide
```

Expected output when primary is down:
```
prod-pgcluster-uae-dc1-9c5j-0    0/3   CrashLoopBackOff  5   8m   (primary — DEAD)
prod-pgcluster-uae-dc1-5c2q-0    3/3   Running           0   8d   (sync standby)
prod-pgcluster-uae-pgbouncer-...  2/2   Running           0   8d
```

### 1.2 Check Patroni Cluster State

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

Expected output when primary is dead and standby is still replica:
```
+ Cluster: prod-pgcluster-uae-ha (7890123456789012345) ----+----+-----------+
| Member                              | Host  | Role    | State   | TL | Lag in MB |
+-------------------------------------+-------+---------+---------+----+-----------+
| prod-pgcluster-uae-dc1-9c5j-0      | ...   | Leader  | stopped |  8 |           |
| prod-pgcluster-uae-dc1-5c2q-0      | ...   | Replica | running |  8 |         0 |
+-------------------------------------+-------+---------+---------+----+-----------+
```

### 1.3 pg_isready Check on Primary

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pg_isready -U postgres
```

If primary is truly dead, this will time out or return a connection refused error.

### 1.4 Check PostgreSQL Logs on Primary

```bash
oc logs -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database --tail=100
```

### 1.5 Check Timeline on Sync Standby

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT timeline_id, reason FROM pg_control_checkpoint();" 2>/dev/null || \
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  pg_controldata | grep "Latest checkpoint's TimeLineID"
```

Timeline should be 8 (matching TL:8). After promotion it will increment to 9.

---

## Phase 2: Confirm Auto-Promotion Happened

**Estimated time: 1–3 minutes** (Patroni TTL default ~30s)

Patroni with `sync_mode: on` and `synchronous_node_count: 1` will auto-promote the sync standby (prod-pgcluster-uae-dc1-5c2q-0) after the TTL expires.

### 2.1 Poll Patroni Until Leader Changes

```bash
watch -n 5 'oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha'
```

Wait for output showing dc1-5c2q-0 as **Leader**:
```
| prod-pgcluster-uae-dc1-5c2q-0  | ...  | Leader  | running |  9 |         0 |
```

Timeline increments from 8 → 9 confirming promotion.

### 2.2 Confirm New Primary Via Patroni REST API

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  curl -s http://localhost:8008/master | python3 -m json.tool
```

Should return HTTP 200 with `"role": "master"`.

---

## Phase 3: Manual Failover (Only if Auto-Promotion Failed)

**Estimated time: 2–5 minutes**

Use only if Patroni has NOT auto-promoted after 2–3 minutes and the primary is confirmed dead.

### 3.1 Trigger Manual Failover

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml failover prod-pgcluster-uae-ha \
  --master prod-pgcluster-uae-dc1-9c5j-0 \
  --candidate prod-pgcluster-uae-dc1-5c2q-0 \
  --force
```

### 3.2 If patronictl is Unreachable from Standby Pod

Exec into the standby pod and check DCS connectivity:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  curl -s http://$(oc get svc -n prod-pgcluster-uae prod-pgcluster-uae-ha -o jsonpath='{.spec.clusterIP}'):2379/health
```

### 3.3 Emergency: Promote PostgreSQL Directly (Last Resort)

Only if Patroni itself is failing. This bypasses Patroni — re-integrate carefully afterward.

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT pg_promote(wait => true, wait_seconds => 60);"
```

---

## Phase 4: Verify New Primary Accepting Writes

**Estimated time: 2–3 minutes**

### 4.1 pg_is_in_recovery Must Return False

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), current_setting('transaction_read_only'), now();"
```

Expected:
```
 pg_is_in_recovery | current_setting | now
-------------------+-----------------+-----
 f                 | off             | 2026-05-24 ...
```

### 4.2 Write Test

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "CREATE TABLE IF NOT EXISTS failover_test (ts timestamptz DEFAULT now()); INSERT INTO failover_test DEFAULT VALUES; SELECT * FROM failover_test ORDER BY ts DESC LIMIT 1; DROP TABLE failover_test;"
```

### 4.3 Verify PgBouncer Points to New Primary

PgBouncer (10.171.1.205:5555) should auto-detect via Patroni's PgBouncer integration. Confirm:

```bash
oc exec -n prod-pgcluster-uae \
  $(oc get pod -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/role=pgbouncer -o jsonpath='{.items[0].metadata.name}') \
  -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "SHOW POOLS;"
```

### 4.4 Check Primary LB (10.171.1.229:5555)

```bash
pg_isready -h 10.171.1.229 -p 5555 -U postgres
```

---

## Phase 5: Rebuild Fallen Node as New Replica

**Estimated time: 15–60 minutes depending on data volume**

Once the old primary pod restarts (or is manually recreated by PGO), Patroni will attempt to rejoin it as a replica.

### 5.1 Check if PGO Has Restarted the Pod

```bash
oc get pods -n prod-pgcluster-uae -w
```

### 5.2 If Pod Restarts but Fails to Rejoin (pg_rewind needed)

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml reinit prod-pgcluster-uae-ha \
  prod-pgcluster-uae-dc1-9c5j-0 --force
```

This triggers pg_basebackup from the new primary to rebuild the fallen node.

### 5.3 Monitor Reinit Progress

```bash
oc logs -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -f
```

### 5.4 Confirm Replica is Streaming

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, state, sent_lsn, replay_lsn, sync_state, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
```

---

## Phase 6: Re-Enable Synchronous Replication

**Estimated time: 2–5 minutes**

After the fallen node rejoins as a replica, verify sync replication is re-established.

### 6.1 Check synchronous_standby_names

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SHOW synchronous_standby_names;"
```

### 6.2 Verify Patroni Sync Mode is Active

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

The rebuilt node should appear as `Sync Standby` in the Role column.

### 6.3 Confirm Sync State in pg_stat_replication

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, sync_state FROM pg_stat_replication;"
```

Expected: `sync_state = sync` for at least one replica (synchronous_node_count=1).

---

## Phase 7: Verify DR Streaming Resumed

**Estimated time: 5–10 minutes**

DR standby (dr-pgcluster-uae in DC2) has `spec.standby.enabled=true` and must reattach to new primary's timeline.

### 7.1 Check DR Standby Pod Status

```bash
oc get pods -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/cluster=dr-pgcluster-uae
```

### 7.2 Check pg_stat_replication for DR Connection

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -c "SELECT application_name, client_addr, state, sent_lsn, replay_lsn, sync_state FROM pg_stat_replication WHERE application_name LIKE '%dr%' OR client_addr NOT IN (SELECT addr FROM pg_stat_activity WHERE datname IS NOT NULL LIMIT 1);"
```

### 7.3 Check DR Standby Recovery Status

```bash
oc exec -n prod-pgcluster-uae \
  $(oc get pod -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/cluster=dr-pgcluster-uae -o jsonpath='{.items[0].metadata.name}') \
  -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"
```

### 7.4 If DR Standby is Stuck on Old Timeline

DR standby may need pgBackRest to fetch WAL from new timeline. Check pgBackRest repo access:

```bash
oc exec -n prod-pgcluster-uae \
  $(oc get pod -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/cluster=dr-pgcluster-uae -o jsonpath='{.items[0].metadata.name}') \
  -c database -- \
  pgbackrest --stanza=db --repo=1 info
```

---

## Post-Failover Checklist

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 1 | New primary running | `oc get pods -n prod-pgcluster-uae` | dc1-5c2q-0 Running |
| 2 | Not in recovery | `SELECT pg_is_in_recovery()` | `f` |
| 3 | Timeline incremented | `patronictl list` | TL: 9 |
| 4 | Sync standby present | `SELECT sync_state FROM pg_stat_replication` | `sync` |
| 5 | PgBouncer healthy | `SHOW POOLS` on pgbouncer | active connections |
| 6 | LB (10.171.1.229:5555) reachable | `pg_isready -h 10.171.1.229 -p 5555` | accepting connections |
| 7 | DR streaming resumed | `SELECT pg_last_wal_replay_lsn()` on DR | advancing LSN |
| 8 | pgBackRest backup working | `pgbackrest --stanza=db info` | stanza: ok |
| 9 | WAL slot health | `SELECT slot_name, active, wal_status, safe_wal_size FROM pg_replication_slots` | no `lost` slots |
| 10 | max_slot_wal_keep_size | `SHOW max_slot_wal_keep_size` | 300GB |
| 11 | Connections within limit | `SELECT count(*) FROM pg_stat_activity` | < 800 |
| 12 | Incident ticket updated | Manual | RCA filed |

---

## Escalation Contacts

- **DBA On-Call:** Page immediately if Phase 3 is reached
- **Infrastructure/OpenShift:** If pod will not restart after 10 minutes
- **Application Team:** Notify once new primary is confirmed accepting writes
- **DR Team:** Confirm DC2 streaming within 30 minutes of promotion

---

## Key Timings Reference

| Event | Expected Duration |
|-------|------------------|
| Patroni auto-detection of primary failure | ~TTL (default 30s) |
| Auto-promotion of sync standby | 30–90 seconds |
| Manual failover via patronictl | 15–60 seconds |
| Replica rebuild via pg_basebackup | 15–60 minutes |
| DR streaming reattachment | 2–10 minutes |
| Total RTO (unplanned failover) | 5–15 minutes |

