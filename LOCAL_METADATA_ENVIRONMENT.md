# Local Metadata Environment

Created: 2026-05-25

This file documents the local Kubernetes PostgreSQL lab used for production-structure troubleshooting. The lab contains database structure and metadata imported from `pg_report_3.html`; it does not contain production data.

## Purpose

Use this local environment to inspect schema layout, object names, relationship metadata, indexes, constraints, and basic PostgreSQL behavior when a live production issue needs offline analysis.

This is useful for:

- Understanding table/index/constraint layout before touching production.
- Reproducing metadata-level errors.
- Checking object existence, naming, dependencies, and ownership.
- Preparing safe diagnostic SQL for live production.
- Reviewing performance metadata such as large tables, indexes, and replication-related objects from the original report.

Do not use this environment as a production performance benchmark. It has no production data volume, no production workload, and runs on local kind storage.

## Local Cluster

| Item | Value |
|---|---|
| Kubernetes context | `kind-patroni-prod-local` |
| Namespace | `prod-pgcluster-uae-local` |
| PostgresCluster | `prod-pgcluster-uae` |
| Patroni cluster | `prod-pgcluster-uae-ha` |
| Local PostgreSQL | `PostgreSQL 18.3 on aarch64-unknown-linux-gnu` |
| Source report PostgreSQL | `PostgreSQL 17.6 on x86_64-pc-linux-gnu` |
| Import type | Metadata/schema only |
| Data imported | No |
| Sample app DBs removed | `tps`, `tps_dw`, `service`, `common` |
| Sample app roles removed | `tps-app`, `tpsdw-app`, `service-app`, `common-app`, `ro-user` |

Current Patroni state at capture:

```text
Leader:       prod-pgcluster-uae-dc1-4s5d-0
Sync Standby: prod-pgcluster-uae-dc1-v9mm-0
Lag:          0
```

## Source Metadata

The metadata was imported from:

```text
pg_report_3.html
```

Report facts:

| Item | Value |
|---|---|
| Report title | PostgreSQL Inspector Report |
| Generated | `2026-05-07T15:43:16.578658+00:00` |
| Databases in report | `26` including `postgres` |
| Imported non-default databases | `25` |
| Report total size | `1346.6 GB` |
| Report max connections | `1000` |
| Report WAL level | `logical` |
| Report logical slots | `12`, all active at report time |

The HTML report contains embedded `metadata_ddl` sections. The local import extracted those blocks into `tmp/pg_report_3_ddl/*.sql` and applied them to the local cluster. The `tmp/` directory is intentionally ignored by Git.

## Import Limitations

- This is metadata only. No table rows were loaded.
- `pg_toast` system index DDL from the report was ignored because it cannot be recreated manually.
- The report referenced `system_stats` C functions; that extension/library is not present in the local image.
- A missing report type, `application_status`, was recreated locally as an empty enum so service schemas could be created.
- PostgreSQL version differs: report was PostgreSQL 17.6; local lab is PostgreSQL 18.3.
- Object counts below exclude `postgres`, template databases, `pg_catalog`, `information_schema`, and `pg_toast`.

## Object Totals

| Object type | Count |
|---|---:|
| Imported databases | 25 |
| Schemas | 122 |
| Base tables | 2479 |
| Partitioned tables | 0 |
| Indexes | 3758 |
| Sequences | 337 |
| Views | 53 |
| Materialized views | 0 |
| Functions | 125 |
| Constraints | 17853 |
| Triggers | 0 |
| User-defined/system-visible non-catalog types | 5072 |
| Extension count summed per DB | 50 |

## Per-Database Object Counts

Columns:

```text
database | schemas | tables | partitioned_tables | indexes | sequences | views | matviews | functions | constraints | triggers | types | extensions
```

| Database | Schemas | Tables | Part Tables | Indexes | Sequences | Views | Matviews | Functions | Constraints | Triggers | Types | Extensions |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `ae_api_gateway_uat` | 2 | 4 | 0 | 6 | 2 | 2 | 0 | 5 | 25 | 0 | 12 | 2 |
| `ae_common_uat` | 2 | 13 | 0 | 13 | 2 | 2 | 0 | 5 | 89 | 0 | 30 | 2 |
| `ae_document_uat` | 2 | 4 | 0 | 9 | 4 | 2 | 0 | 5 | 21 | 0 | 12 | 2 |
| `ae_service_uat` | 13 | 457 | 0 | 724 | 66 | 3 | 0 | 5 | 3444 | 0 | 922 | 2 |
| `ae_tps_uat` | 8 | 81 | 0 | 89 | 5 | 2 | 0 | 5 | 570 | 0 | 166 | 2 |
| `ae_tps_warehouse_uat` | 3 | 15 | 0 | 25 | 2 | 2 | 0 | 5 | 115 | 0 | 34 | 2 |
| `ch_common_uat` | 2 | 15 | 0 | 14 | 2 | 2 | 0 | 5 | 98 | 0 | 34 | 2 |
| `ch_document_uat` | 2 | 0 | 0 | 0 | 0 | 2 | 0 | 5 | 0 | 0 | 4 | 2 |
| `ch_service_uat` | 13 | 473 | 0 | 741 | 68 | 2 | 0 | 5 | 3488 | 0 | 952 | 2 |
| `ch_tps_uat` | 8 | 84 | 0 | 90 | 4 | 2 | 0 | 5 | 579 | 0 | 172 | 2 |
| `ch_tps_warehouse_uat` | 3 | 17 | 0 | 26 | 2 | 2 | 0 | 5 | 124 | 0 | 38 | 2 |
| `druatrhbk` | 1 | 88 | 0 | 196 | 0 | 2 | 0 | 5 | 438 | 0 | 180 | 2 |
| `landlord_uat` | 3 | 8 | 0 | 11 | 14 | 2 | 0 | 5 | 39 | 0 | 20 | 2 |
| `sa_api_gateway_uat` | 2 | 6 | 0 | 7 | 2 | 2 | 0 | 5 | 34 | 0 | 16 | 2 |
| `sa_common_uat` | 2 | 15 | 0 | 14 | 2 | 2 | 0 | 5 | 98 | 0 | 34 | 2 |
| `sa_document_uat` | 2 | 6 | 0 | 10 | 4 | 2 | 0 | 5 | 30 | 0 | 16 | 2 |
| `sa_service_uat` | 13 | 482 | 0 | 760 | 69 | 3 | 0 | 5 | 3550 | 0 | 972 | 2 |
| `sa_tps_uat` | 8 | 84 | 0 | 90 | 4 | 2 | 0 | 5 | 580 | 0 | 172 | 2 |
| `sa_tps_warehouse_uat` | 3 | 17 | 0 | 26 | 2 | 2 | 0 | 5 | 124 | 0 | 38 | 2 |
| `uk_api_gateway_uat` | 2 | 6 | 0 | 7 | 2 | 2 | 0 | 5 | 34 | 0 | 16 | 2 |
| `uk_common_uat` | 2 | 15 | 0 | 14 | 2 | 2 | 0 | 5 | 98 | 0 | 34 | 2 |
| `uk_document_uat` | 2 | 6 | 0 | 10 | 4 | 2 | 0 | 5 | 30 | 0 | 16 | 2 |
| `uk_service_uat` | 13 | 482 | 0 | 760 | 69 | 3 | 0 | 5 | 3541 | 0 | 972 | 2 |
| `uk_tps_uat` | 8 | 84 | 0 | 90 | 4 | 2 | 0 | 5 | 580 | 0 | 172 | 2 |
| `uk_tps_warehouse_uat` | 3 | 17 | 0 | 26 | 2 | 2 | 0 | 5 | 124 | 0 | 38 | 2 |

## Connect And Inspect

Set context:

```bash
kubectl config use-context kind-patroni-prod-local
kubectl -n prod-pgcluster-uae-local get pods
```

Find the current leader:

```bash
PRIMARY=$(kubectl -n prod-pgcluster-uae-local get pod \
  -l postgres-operator.crunchydata.com/cluster=prod-pgcluster-uae,postgres-operator.crunchydata.com/role=master \
  -o jsonpath='{.items[0].metadata.name}')
```

Open `psql`:

```bash
kubectl -n prod-pgcluster-uae-local exec -it "$PRIMARY" -c database -- psql -U postgres -d postgres
```

Connect to a specific imported database:

```bash
kubectl -n prod-pgcluster-uae-local exec -it "$PRIMARY" -c database -- psql -U postgres -d ae_service_uat
```

Check Patroni:

```bash
kubectl -n prod-pgcluster-uae-local exec "$PRIMARY" -c database -- patronictl list
```

## Useful Metadata Queries

List databases:

```sql
select datname
from pg_database
where datistemplate = false
order by datname;
```

Count user tables in the current database:

```sql
select count(*)
from information_schema.tables
where table_type = 'BASE TABLE'
  and table_schema not in ('pg_catalog', 'information_schema');
```

Count object types in the current database:

```sql
with rels as (
  select c.relkind
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
)
select
  count(*) filter (where relkind = 'r') as tables,
  count(*) filter (where relkind = 'p') as partitioned_tables,
  count(*) filter (where relkind = 'i') as indexes,
  count(*) filter (where relkind = 'S') as sequences,
  count(*) filter (where relkind = 'v') as views,
  count(*) filter (where relkind = 'm') as materialized_views
from rels;
```

Find largest tables when connected to a real production database:

```sql
select
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(format('%I.%I', schemaname, relname)::regclass)) as total_size
from pg_stat_user_tables
order by pg_total_relation_size(format('%I.%I', schemaname, relname)::regclass) desc
limit 30;
```

Find idle transactions in production:

```sql
select pid, usename, application_name, client_addr, state,
       now() - xact_start as xact_age,
       now() - query_start as query_age,
       left(query, 200) as query
from pg_stat_activity
where state = 'idle in transaction'
order by xact_start nulls last
limit 50;
```

Check logical replication slots in production:

```sql
select slot_name, plugin, slot_type, database, active,
       restart_lsn, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal
from pg_replication_slots
order by slot_name;
```

## Original Report Findings To Remember

From the source report, not from the local empty lab:

- Largest database: `ae_tps_uat`, about `833 GB`.
- Largest table reported: `ae_tps_uat.tps.transaction_audit_sequence`, about `426 GB`.
- Logical replication had `12` active slots with very low retained WAL in the snapshot.
- Many sessions in the report were `idle in transaction` from JDBC clients running `SELECT 1`.
- Several CRM/service tables had high dead tuple percentages in the report; verify live before action.

Treat all report findings as point-in-time evidence. Re-check live production before making changes.
