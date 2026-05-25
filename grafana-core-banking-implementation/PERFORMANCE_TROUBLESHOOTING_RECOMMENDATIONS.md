# Performance Troubleshooting Recommendations

Created: 2026-05-25

This file captures practical recommendations from the local metadata environment and `pg_report_3.html` analysis. It is intended for future production troubleshooting where the live production cluster has the same or similar database structure.

Use this as a checklist and query pack. Do not run corrective production changes without validating current live metrics, business impact, and an approved change window.

## Scope

The local lab contains schema and metadata only. It does not contain production data or workload. Recommendations below combine:

- Metadata imported from the PostgreSQL Inspector report.
- Object counts and foreign-key/index structure from the local lab.
- Reported size/activity evidence from the original HTML report.

## Key Findings To Remember

| Area | Finding |
|---|---|
| Largest database | `ae_tps_uat`, about `833 GB` in the report |
| Largest reported table | `ae_tps_uat.tps.transaction_audit_sequence`, about `426 GB` |
| Missing FK child indexes | `538` metadata candidates across `16` databases |
| Replication slots | `12` logical slots, active in the report |
| Activity issue | Many JDBC sessions were `idle in transaction` with `SELECT 1` |
| Dead tuple risk | Several CRM/service tables showed high dead tuple percentage |

## 1. Autovacuum And Bloat Review

Why it matters:

- Long-lived transactions and high churn can prevent vacuum cleanup.
- High dead tuple percentages increase table/index scan cost and storage use.
- Stale statistics can cause poor execution plans.

Run in production:

```sql
select
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
  last_vacuum,
  last_autovacuum,
  last_analyze,
  last_autoanalyze
from pg_stat_user_tables
where n_dead_tup > 1000
order by dead_pct desc nulls last, n_dead_tup desc
limit 100;
```

Follow-up checks:

```sql
select
  schemaname,
  relname,
  vacuum_count,
  autovacuum_count,
  analyze_count,
  autoanalyze_count
from pg_stat_user_tables
order by n_dead_tup desc
limit 100;
```

Recommended action:

- Start with targeted `ANALYZE` for stale planner stats.
- Use targeted `VACUUM (ANALYZE)` for high dead tuple tables.
- Tune autovacuum per large/high-churn table only after confirming workload patterns.
- Avoid broad manual vacuum jobs across all large databases during business hours.

## 2. Idle Transaction Cleanup

Why it matters:

- `idle in transaction` sessions can hold snapshots.
- Held snapshots can block vacuum cleanup.
- They can cause bloat growth and old row versions to remain visible.

Run in production:

```sql
select
  pid,
  usename,
  application_name,
  client_addr,
  state,
  now() - xact_start as xact_age,
  now() - query_start as query_age,
  left(query, 200) as query
from pg_stat_activity
where state = 'idle in transaction'
order by xact_start nulls last
limit 100;
```

If many rows show simple `SELECT 1`, review application connection handling. Health checks should not leave open transactions.

Recommended action:

- Fix application transaction handling.
- Confirm JDBC/autocommit behavior.
- Consider `idle_in_transaction_session_timeout` if not already enforced.
- Terminate only clearly safe sessions after approval.

Safe terminate template:

```sql
select pg_terminate_backend(<pid>);
```

## 3. Missing Foreign-Key Child Indexes

Why it matters:

- Missing child-side FK indexes can make parent deletes/updates expensive.
- Joins and referential checks may scan large child tables.
- The metadata analysis found `538` candidate foreign keys without matching leading-column indexes.

The detailed candidate list is in:

```text
INDEX_RECOMMENDATIONS.md
```

Highest priority candidates from report size evidence include:

| Database | Table | Columns | Report size |
|---|---|---|---:|
| `ae_tps_uat` | `tps.transaction_ledger` | `transaction_id, sequence_number` | `109 GB` |
| `ae_tps_uat` | `tps.unposted_transaction` | `account_number` | `95 GB` |
| `ae_tps_uat` | `tps.transaction_audit` | `login_name` | `47 GB` |
| `sa_tps_uat` | `tps.transaction_ledger` | `transaction_id, sequence_number` | `17 GB` |
| `sa_tps_uat` | `tps.unposted_transaction` | `account_number` | `14 GB` |
| `ae_tps_uat` | `tps.transaction_reference` | `branch_id` | `12 GB` |

Production validation query:

```sql
with fk as (
  select con.oid, con.conname, n.nspname as schema_name, c.relname as table_name,
         con.conrelid, con.conkey,
         array_agg(a.attname order by ord.n) as fk_columns
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  join unnest(con.conkey) with ordinality as ord(attnum,n) on true
  join pg_attribute a on a.attrelid = con.conrelid and a.attnum = ord.attnum
  where con.contype = 'f'
    and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
  group by con.oid, con.conname, n.nspname, c.relname, con.conrelid, con.conkey
), idx as (
  select i.indrelid, i.indexrelid::regclass::text as index_name, i.indkey::int2[] as indkey
  from pg_index i
  where i.indisvalid and i.indisready
)
select fk.schema_name, fk.table_name, fk.conname,
       array_to_string(fk.fk_columns, ', ') as fk_columns
from fk
where not exists (
  select 1
  from idx
  where idx.indrelid = fk.conrelid
    and idx.indkey[0:array_length(fk.conkey,1)-1] = fk.conkey
)
order by fk.schema_name, fk.table_name, fk.conname;
```

Safe index creation pattern:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_<table>_<columns>_fk
ON schema_name.table_name (column_1, column_2);
```

Rules:

- Do not create all candidate indexes at once.
- Prefer the biggest/hottest tables first.
- Confirm existing indexes are not already covering the FK columns with the same leading order.
- Create indexes one at a time and monitor write overhead.

## 4. Huge Or Zero-Scan Index Review

Why it matters:

- Large unused indexes waste storage and slow writes.
- A short stats window can falsely show important indexes as unused.

Run in production:

```sql
select
  schemaname,
  relname as table_name,
  indexrelname as index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch
from pg_stat_user_indexes
order by pg_relation_size(indexrelid) desc
limit 100;
```

Check stats reset time:

```sql
select stats_reset
from pg_stat_database
where datname = current_database();
```

Recommended action:

- Observe over a full business cycle before dropping any index.
- Keep indexes used by constraints, foreign keys, rare reports, or end-of-day jobs.
- Drop only after confirming no dependency and no workload need.

## 5. Partitioning Candidates

Why it matters:

- Very large transaction/history tables may benefit from range partitioning.
- Partitioning can improve maintenance, retention, vacuum, and archive workflows.

Report tables worth reviewing:

| Database | Table | Report size |
|---|---|---:|
| `ae_tps_uat` | `tps.transaction_audit_sequence` | `426 GB` |
| `ae_tps_warehouse_uat` | `tps_warehouse.transaction_ledger` | `125 GB` |
| `ae_tps_uat` | `tps.hplus_transaction_received` | `122 GB` |
| `ae_tps_uat` | `tps.transaction_ledger` | `109 GB` |
| `ae_tps_uat` | `tps.unposted_transaction` | `95 GB` |
| `ae_tps_uat` | `tps.transaction_audit` | `47 GB` |

Production validation:

```sql
select
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
where schemaname in ('tps', 'tps_warehouse')
order by pg_total_relation_size(relid) desc
limit 50;
```

Recommended action:

- Identify natural partition key: posting date, transaction date, created date, value date, or business period.
- Do not retrofit partitioning during incidents.
- Treat partitioning as a project with migration testing and rollback planning.

## 6. Logical Replication Slot Monitoring

Why it matters:

- Inactive or lagging logical slots retain WAL.
- Retained WAL can fill storage.
- The report had 12 logical slots and all were active at report time.

Run in production:

```sql
select
  slot_name,
  plugin,
  slot_type,
  database,
  active,
  restart_lsn,
  confirmed_flush_lsn,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal
from pg_replication_slots
order by slot_name;
```

Check logical replication workers:

```sql
select
  pid,
  usename,
  application_name,
  client_addr,
  state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  sync_state
from pg_stat_replication
order by application_name;
```

Recommended action:

- Alert on inactive logical slots.
- Alert on retained WAL size per slot.
- Do not drop a slot until the subscription/application owner confirms it is obsolete.

## 7. Connection Pooling Review

Why it matters:

- The report showed `max_connections = 1000`.
- High direct connection counts can increase memory pressure.
- Applications should go through PgBouncer unless they have a clear reason not to.

Run in production:

```sql
select
  datname,
  usename,
  application_name,
  client_addr,
  state,
  count(*) as sessions
from pg_stat_activity
group by datname, usename, application_name, client_addr, state
order by sessions desc
limit 100;
```

Recommended action:

- Confirm app connection strings point to PgBouncer.
- Review pool sizes per app.
- Keep idle app sessions low.
- Separate admin/reporting connections from transactional app pools.

## 8. Statistics Freshness

Why it matters:

- Poor statistics cause poor plans.
- After restore, bulk load, purge, or schema migration, stats may be stale.

Run in production:

```sql
select
  schemaname,
  relname,
  n_live_tup,
  n_mod_since_analyze,
  last_analyze,
  last_autoanalyze
from pg_stat_user_tables
where n_mod_since_analyze > 10000
order by n_mod_since_analyze desc
limit 100;
```

Targeted refresh:

```sql
ANALYZE schema_name.table_name;
```

For large volatile tables, consider per-table settings only after review:

```sql
alter table schema_name.table_name
set (
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_scale_factor = 0.02
);
```

## 9. Safe Production Change Workflow

Before applying any performance change:

1. Capture current evidence.
2. Reproduce or explain the issue.
3. Confirm the exact database, schema, table, query, and application.
4. Check locks, replication lag, disk space, and backup status.
5. Prepare rollback steps.
6. Apply one controlled change at a time.
7. Measure before and after.
8. Document the result.

For index creation:

```sql
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_name
ON schema_name.table_name (column_name);
```

For index removal:

```sql
DROP INDEX CONCURRENTLY IF EXISTS schema_name.index_name;
```

Only drop indexes after a long enough observation window and dependency check.

Dependency check:

```sql
select
  objid::regclass as object,
  refobjid::regclass as referenced_object,
  deptype
from pg_depend
where refobjid = 'schema_name.index_name'::regclass;
```

## Related Repo Files

| File | Purpose |
|---|---|
| `LOCAL_METADATA_ENVIRONMENT.md` | Local metadata-only database inventory and troubleshooting context |
| `INDEX_RECOMMENDATIONS.md` | Detailed missing foreign-key child index candidates |
| `05-terminal-troubleshooting-runbook.md` | General terminal troubleshooting commands |
| `SOP_INDEX.md` | SOP index for operational procedures |

## Final Guidance

Use the local metadata environment to understand structure and prepare changes. Use live production metrics to decide whether a change is actually needed.

The strongest immediate production checks are:

1. Idle transactions.
2. Autovacuum/dead tuple backlog.
3. Logical slot retained WAL.
4. Missing FK indexes on the largest TPS tables.
5. Huge zero-scan indexes after a full workload observation window.
