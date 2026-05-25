# Terminal Troubleshooting Runbook

Use these commands directly from:

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI
```

## 1. Verify Context

```bash
oc config current-context
oc project
```

Expected PROD context:

```text
prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
```

Expected project:

```text
prod-pgcluster-uae
```

## 2. Pod, Service, PVC Inventory

```bash
oc get pods -n prod-pgcluster-uae -o wide
oc get svc -n prod-pgcluster-uae -o wide
oc get endpoints -n prod-pgcluster-uae -o wide
oc get pvc -n prod-pgcluster-uae
```

Key endpoints:

```text
PROD primary LB:    10.171.1.229:5555
PROD PgBouncer LB:  10.171.1.205:5555
```

## 3. Patroni Health

Run from either database pod:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- patronictl list
```

Healthy PROD shape:

```text
one Leader
one Sync Standby
standby state=streaming
lag=0 or very small
no Pending restart unless a restart was intentionally planned
```

## 4. Identify Current Leader

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -XAtc "select pg_is_in_recovery();"

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-5c2q-0 -c database -- \
  psql -U postgres -XAtc "select pg_is_in_recovery();"
```

Interpretation:

```text
f = primary/leader
t = standby
```

## 5. Replication Lag

Run on current leader:

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -A -F '|' -c \
  "SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS byte_lag, write_lag, flush_lag, replay_lag FROM pg_stat_replication ORDER BY application_name;"
```

If no rows are returned, you probably ran it on the standby or replication is broken.

## 6. Session Pressure

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -A -F '|' -c \
  "SELECT count(*) AS total, count(*) FILTER (WHERE state='active') AS active, count(*) FILTER (WHERE state='idle in transaction') AS idle_in_txn FROM pg_stat_activity WHERE datname IS NOT NULL;"
```

Idle-in-transaction detail:

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -c \
  "SELECT pid, usename, datname, client_addr, state, now()-state_change AS idle_for, left(query,120) AS query FROM pg_stat_activity WHERE state='idle in transaction' ORDER BY state_change;"
```

Do not terminate sessions without approval.

## 7. Database Sizes

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -A -F '|' -c \
  "SELECT d.datname, pg_size_pretty(pg_database_size(d.datname)) AS size, s.numbackends FROM pg_database d JOIN pg_stat_database s ON s.datname=d.datname WHERE d.datistemplate=false ORDER BY pg_database_size(d.datname) DESC;"
```

## 8. pgBackRest Status

```bash
oc exec -n prod-pgcluster-uae <database-pod> -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info

oc exec -n prod-pgcluster-uae <database-pod> -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 check
```

Concise JSON:

```bash
oc exec -n prod-pgcluster-uae <database-pod> -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info --output=json | \
  jq -r '.[0] | "stanza=\(.name) status=\(.status.message) cipher=\(.cipher) backups=\(.backup|length) wal_min=\(.archive[0].min) wal_max=\(.archive[0].max)"'
```

## 9. WAL Archiver

Run on leader:

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -XAtc \
  "select archived_count,last_archived_wal,last_archived_time,failed_count,last_failed_wal,last_failed_time from pg_stat_archiver;"
```

Sample twice:

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -XAtc "select now(), archived_count,last_archived_wal,last_archived_time,failed_count,last_failed_time from pg_stat_archiver;"

sleep 60

oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -XAtc "select now(), archived_count,last_archived_wal,last_archived_time,failed_count,last_failed_time from pg_stat_archiver;"
```

Pass condition: `failed_count` does not increase, and WAL archive advances when WAL is generated or switched.

## 10. Backup Jobs

```bash
oc get cronjobs,jobs -n prod-pgcluster-uae
oc describe job <job-name> -n prod-pgcluster-uae
oc logs -n prod-pgcluster-uae job.batch/<job-name> --tail=200
```

If `oc logs job.batch/<job>` times out, check whether failed pods were already deleted:

```bash
oc get pods -n prod-pgcluster-uae -o wide | grep repo1
```

## 11. PgBouncer

```bash
oc get pods -n prod-pgcluster-uae -l postgres-operator.crunchydata.com/role=pgbouncer -o wide
oc get svc prod-pgcluster-uae-pgbouncer-lb -n prod-pgcluster-uae -o wide
oc get endpoints prod-pgcluster-uae-pgbouncer-lb -n prod-pgcluster-uae -o wide
oc logs -n prod-pgcluster-uae <pgbouncer-pod> -c pgbouncer --tail=120
```

Verify PgBouncer config:

```bash
oc get configmap prod-pgcluster-uae-pgbouncer -n prod-pgcluster-uae -o yaml
```

## 12. Replication Slots

Run on leader:

```bash
oc exec -n prod-pgcluster-uae <leader-pod> -c database -- \
  psql -U postgres -A -F '|' -c \
  "SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn, wal_status, safe_wal_size FROM pg_replication_slots ORDER BY slot_name;"
```

Risk signs:

```text
inactive physical slot with large retained WAL
wal_status not healthy
safe_wal_size near zero
```

Do not drop replication slots without approval.

## 13. Local WAL And Spool Disk

```bash
oc exec -n prod-pgcluster-uae <database-pod> -c database -- \
  bash -ceu 'du -sh /pgdata/pg18/pg_wal /pgwal/pg18_wal /pgdata/pgbackrest-spool /pgwal/pgbackrest-spool 2>/dev/null || true'
```

Spool backlog:

```bash
oc exec -n prod-pgcluster-uae <database-pod> -c database -- \
  bash -ceu 'find /pgdata/pgbackrest-spool /pgwal/pgbackrest-spool -type f 2>/dev/null | wc -l'
```

## 14. Logs

Database logs:

```bash
oc logs -n prod-pgcluster-uae <database-pod> -c database --tail=200
```

pgBackRest sidecar logs:

```bash
oc logs -n prod-pgcluster-uae <database-pod> -c pgbackrest --tail=200
```

Operator-generated backup job logs:

```bash
oc logs -n prod-pgcluster-uae job.batch/<backup-job> --tail=200
```

## 15. OpenShift Events

```bash
oc get events -n prod-pgcluster-uae --sort-by=.lastTimestamp
oc describe pod <pod-name> -n prod-pgcluster-uae
```

## 16. DR Quick Check

```bash
DR_CTX='dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali'
DR_NS='dr-pgcluster-uae'

oc --context="$DR_CTX" project -q
oc --context="$DR_CTX" get pods -n "$DR_NS" -o wide
oc --context="$DR_CTX" get postgrescluster dr-pgcluster-uae -n "$DR_NS" -o jsonpath='{.spec.standby}{"\n"}'
```

If the DR API times out, fix VPN/network/API access first. Do not infer DR health from PROD only.

## 17. DR Streaming Check

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  psql -U postgres -XAtc \
  "select 'recovery='||pg_is_in_recovery(); select 'wal_receiver_count='||count(*) from pg_stat_wal_receiver; select 'last_receive='||coalesce(pg_last_wal_receive_lsn()::text,'')||' last_replay='||coalesce(pg_last_wal_replay_lsn()::text,'')||' replay_delay='||coalesce((now()-pg_last_xact_replay_timestamp())::text,'');"
```

DR to PROD primary LB:

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  pg_isready -h 10.171.1.229 -p 5555 -d postgres -t 5
```

## 18. When To Stop

Stop and escalate before taking action if any of these are true:

- More than one writable primary is suspected.
- DR promotion is being considered while PROD may still accept writes.
- pgBackRest repo is not readable.
- WAL archiver failure count is increasing.
- Database pods are not Ready and root cause is unclear.
- Commands point to the wrong context or namespace.
- A command would delete pods/PVCs, shut down the cluster, patch standby mode, or run destructive SQL.
