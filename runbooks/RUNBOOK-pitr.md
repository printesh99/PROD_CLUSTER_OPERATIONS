# RUNBOOK: Point-in-Time Recovery (PITR) — Habib Bank UAE PostgreSQL 18

**Cluster:** prod-pgcluster-uae | **Namespace:** prod-pgcluster-uae  
**pgBackRest Stanza:** db | **Repo:** repo1 | **Backend:** S3/ODF Nooba (pgbackrest-uae-prod-609d40f1)  
**Encryption:** aes-256-cbc | **Compression:** lz4  
**PGO Version:** Crunchy Data PGO v5 | **Last Validated:** 2026-05-21

---

## Quick Reference — Critical Commands

```bash
# 1. List available backups to find recovery base
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 info

# 2. Stop PostgreSQL before restore (via Patroni pause + pg_ctl)
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml pause prod-pgcluster-uae-ha --wait

# 3. Execute PITR restore to target time (inside primary pod)
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 restore \
  --type=time --target="2026-05-21 14:30:00+04" \
  --target-action=promote --delta --force

# 4. Monitor WAL replay progress
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS recovery_lag, pg_last_wal_replay_lsn();"

# 5. Promote after verification
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT pg_promote(wait => true, wait_seconds => 120);"
```

---

## When to Use PITR vs Replica Promotion

| Scenario | Recommended Action |
|----------|-------------------|
| Primary pod crashed, standby healthy | **Replica Promotion** (Failover runbook) — seconds |
| Accidental DROP TABLE / DELETE without WHERE | **PITR** — recover to point before the event |
| Data corruption detected | **PITR** to last known good state |
| Ransomware / bulk data deletion | **PITR** from pgBackRest S3 backup |
| Regulatory requirement for point-in-time audit | **PITR** |
| Hardware failure with replica also affected | **PITR** from S3 |
| Single table corrupted (most data intact) | **Single Table Recovery** runbook |

**PITR Impact:** PITR takes the cluster offline for the duration of restore + WAL replay. Plan for 1–4 hours depending on backup age and WAL volume. The 2026-05-21 PITR validation took approximately **2.5 hours** for reference (full restore + WAL replay to target time).

---

## Step 1: Identify Target Time

**Estimated time: 15–30 minutes**

### 1.1 Get Target Time from Application Team

Obtain the exact timestamp (with timezone) of the last known good state:
- Review application logs for the last successful transaction
- Check database audit logs
- Confirm with application team: "What was the last timestamp of valid data?"

Target time format: `YYYY-MM-DD HH:MM:SS+04` (Asia/Dubai, UTC+4)

### 1.2 List Available pgBackRest Backups

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 info
```

Confirm there is a full backup older than the target time. WAL must be continuous from that backup to the target time.

### 1.3 Check WAL Archive Continuity

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 check
```

A clean `stanza check` output confirms WAL is continuous to S3.

### 1.4 Document the Recovery Parameters

```
Target Time:         ____________________  (e.g. 2026-05-21 14:30:00+04)
Base Backup Label:   ____________________  (from pgbackrest info)
Backup Start LSN:    ____________________
Incident Ticket:     ____________________
Authorized by:       ____________________
```

---

## Step 2: Isolate the Cluster

**Estimated time: 5–10 minutes**

### 2.1 Notify All Stakeholders

- Application team: cluster going offline for PITR
- DBA team lead: authorization
- Management: estimated downtime window

### 2.2 Pause PgBouncer to Block New Connections

```bash
PGBOUNCER_POD=$(oc get pod -n prod-pgcluster-uae \
  -l postgres-operator.crunchydata.com/role=pgbouncer \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "PAUSE;"
```

### 2.3 Pause Patroni (Prevent Automatic Actions)

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml pause prod-pgcluster-uae-ha --wait
```

Verify Patroni is paused:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

The cluster should show `Cluster is paused`.

### 2.4 Terminate Active Connections to PostgreSQL

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND state <> 'idle';"
```

### 2.5 Stop PostgreSQL on Primary

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pg_ctl stop -D /pgdata/pg18 -m fast
```

### 2.6 Stop PostgreSQL on Sync Standby

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  pg_ctl stop -D /pgdata/pg18 -m fast
```

---

## Step 3: Execute pgBackRest PITR Restore

**Estimated time: 30–120 minutes** (depends on backup size and WAL volume)

### 3.1 Run Restore on Primary Pod

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 restore \
  --type=time \
  --target="2026-05-21 14:30:00+04" \
  --target-action=pause \
  --delta \
  --force \
  --log-level-console=info \
  --log-level-file=detail
```

**Flag explanation:**
- `--type=time` — restore to a specific timestamp
- `--target` — the exact timestamp (must be quoted, include timezone offset)
- `--target-action=pause` — PostgreSQL pauses at target time for verification before promoting
- `--delta` — only restore changed files (faster than full restore if data dir exists)
- `--force` — overwrite existing PGDATA
- Use `--target-action=promote` to auto-promote after reaching target (skip manual Step 7)

### 3.2 Monitor Restore Progress

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  tail -f /tmp/pgbackrest/log/pgbackrest.log
```

Restore phases:
1. Download base backup files from S3 (main duration)
2. Restore WAL segments from archive
3. Write `recovery.signal` and `postgresql.auto.conf`

---

## Step 4: Verify Recovery Configuration Files

**Estimated time: 2–3 minutes**

pgBackRest automatically writes these files. Verify they are correct:

### 4.1 Check recovery.signal Exists

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  ls -la /pgdata/pg18/recovery.signal
```

### 4.2 Check postgresql.auto.conf Recovery Settings

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  cat /pgdata/pg18/postgresql.auto.conf
```

Expected entries written by pgBackRest:
```ini
# Recovery settings written by pgBackRest
restore_command = 'pgbackrest --stanza=db archive-get %f "%p"'
recovery_target_time = '2026-05-21 14:30:00+04'
recovery_target_action = 'pause'
```

### 4.3 Verify Patroni Configuration Not Overriding Recovery

Since Patroni is paused, it will not interfere with the manual recovery. However, confirm:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  cat /etc/patroni/patroni.yaml | grep -A5 "recovery"
```

---

## Step 5: Start PostgreSQL in Recovery Mode

**Estimated time: 2–5 minutes to start, then WAL replay begins**

### 5.1 Start PostgreSQL

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pg_ctl start -D /pgdata/pg18 -l /tmp/postgres-recovery.log
```

### 5.2 Verify PostgreSQL Started in Recovery Mode

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
```

Expected: `t` (true — in recovery)

### 5.3 Check PostgreSQL Log for Recovery Start

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  tail -f /tmp/postgres-recovery.log
```

Look for:
```
LOG:  starting point-in-time recovery to 2026-05-21 14:30:00+04
LOG:  restored log file "000000080000..." from archive
LOG:  redo in progress
```

---

## Step 6: Monitor WAL Replay Progress

**Estimated time: 10 minutes – 2 hours** (depends on WAL gap)

### 6.1 Primary Monitoring Query

```bash
watch -n 10 'oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "
    SELECT
      now() AS current_time,
      pg_last_xact_replay_timestamp() AS last_replayed_ts,
      now() - pg_last_xact_replay_timestamp() AS lag_from_now,
      pg_last_wal_replay_lsn() AS replay_lsn,
      pg_is_in_recovery() AS in_recovery;"'
```

### 6.2 Watch for Recovery Pause at Target Time

When `pg_last_xact_replay_timestamp()` reaches the target time, PostgreSQL will pause (due to `recovery_target_action = pause`). Log message:

```
LOG:  recovery stopping before commit of transaction ..., time 2026-05-21 14:30:00.xxxxxx+04
LOG:  pausing at the end of recovery
HINT:  Execute pg_wal_replay_resume() to promote.
```

### 6.3 Check PostgreSQL Recovery Status

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT * FROM pg_stat_recovery_prefetch;" 2>/dev/null || \
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT pg_last_xact_replay_timestamp(), pg_is_wal_replay_paused();"
```

---

## Step 7: Verify Data Integrity Before Promoting

**Estimated time: 15–30 minutes**

**Critical:** Perform data verification BEFORE promoting. Once promoted, you cannot return to a different point in time without another full restore.

### 7.1 Verify the Target Data State

Work with the application team to query the specific tables/records that were affected:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    SELECT count(*) FROM <affected_table>;
    SELECT max(created_at) FROM <affected_table>;"
```

### 7.2 Check Row Counts on Key Tables

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -d <target_database> -c "
    SELECT schemaname, tablename, n_live_tup
    FROM pg_stat_user_tables
    ORDER BY n_live_tup DESC
    LIMIT 20;"
```

### 7.3 Application Team Sign-Off

Document application team confirmation that data state is correct at target time before proceeding to promote.

---

## Step 8: Promote with pg_promote()

**Estimated time: 1–2 minutes**

### 8.1 Resume WAL Replay and Promote

If `--target-action=pause` was used (recommended):

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT pg_wal_replay_resume();"
```

Or use direct promotion:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT pg_promote(wait => true, wait_seconds => 120);"
```

### 8.2 Confirm Promotion

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), pg_current_wal_lsn(), now();"
```

Expected: `pg_is_in_recovery = f`

### 8.3 Check recovery.signal Removed

PostgreSQL removes `recovery.signal` on successful promotion:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  ls /pgdata/pg18/recovery.signal 2>&1
```

Expected: `No such file or directory`

---

## Step 9: Rebuild Patroni Cluster

**Estimated time: 30–90 minutes**

After PITR promotion, Patroni must be re-initialized to recognize the restored primary and rebuild replicas.

### 9.1 Resume Patroni

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml resume prod-pgcluster-uae-ha --wait
```

### 9.2 Reinitialize the Sync Standby

The standby is now on a diverged timeline and must be rebuilt from the restored primary:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml reinit prod-pgcluster-uae-ha \
  prod-pgcluster-uae-dc1-5c2q-0 --force
```

This triggers `pg_basebackup` from the PITR-restored primary to the standby.

### 9.3 Monitor Standby Rebuild

```bash
oc logs -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -f
```

### 9.4 Verify Patroni Cluster Health

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list prod-pgcluster-uae-ha
```

Expected:
- dc1-9c5j-0: Leader, new TL (e.g. TL:9)
- dc1-5c2q-0: Sync Standby, Lag: 0

### 9.5 Resume PgBouncer

```bash
PGBOUNCER_POD=$(oc get pod -n prod-pgcluster-uae \
  -l postgres-operator.crunchydata.com/role=pgbouncer \
  -o jsonpath='{.items[0].metadata.name}')

oc exec -n prod-pgcluster-uae ${PGBOUNCER_POD} -c pgbouncer -- \
  psql -p 5432 -U pgbouncer pgbouncer -c "RESUME;"
```

### 9.6 Take a New pgBackRest Full Backup

After PITR, the WAL archive baseline changes. Take a fresh full backup immediately:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  pgbackrest --stanza=db --repo=1 backup --type=full --log-level-console=info
```

### 9.7 Verify DR Standby Reattaches

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -c "SELECT application_name, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

DR standby (dr-pgcluster-uae) may also need reinit if it diverged. If so:

```bash
# On DR cluster namespace (adjust namespace if different)
oc exec -n prod-pgcluster-uae \
  $(oc get pod -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/cluster=dr-pgcluster-uae -o jsonpath='{.items[0].metadata.name}') \
  -c database -- \
  pgbackrest --stanza=db --repo=1 restore --delta --force
```

---

## Full Timeline Estimate

| Phase | Estimated Duration |
|-------|--------------------|
| Stakeholder notification and authorization | 15–30 min |
| Cluster isolation and PostgreSQL stop | 10–15 min |
| pgBackRest restore from S3 | 30–90 min |
| WAL replay to target time | 15–120 min |
| Data verification with application team | 15–30 min |
| pg_promote() | 1–2 min |
| Patroni resume and standby rebuild | 30–60 min |
| New full pgBackRest backup | 30–60 min |
| **Total (reference: 2026-05-21 PITR validation)** | **~2.5 hours** |

---

## Post-PITR Checklist

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 1 | Primary not in recovery | `SELECT pg_is_in_recovery()` | `f` |
| 2 | Data at correct timestamp | Application team query | Confirmed |
| 3 | Patroni cluster healthy | `patronictl list` | Leader + Sync Standby |
| 4 | Sync replication active | `SELECT sync_state FROM pg_stat_replication` | `sync` |
| 5 | PgBouncer resumed | `SHOW POOLS` | Active connections |
| 6 | LB reachable | `pg_isready -h 10.171.1.229 -p 5555` | Accepting |
| 7 | DR streaming resumed | `SELECT replay_lsn FROM pg_stat_replication` | Advancing |
| 8 | New full backup taken | `pgbackrest info` | New backup entry |
| 9 | WAL archiving resumed | `pgbackrest check` | Clean |
| 10 | Incident RCA filed | Manual | Filed |
| 11 | Recovery signal removed | `ls /pgdata/pg18/recovery.signal` | Not found |

