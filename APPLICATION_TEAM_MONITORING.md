# Application Team Monitoring Guide

Created: 2026-05-25

This guide maps the imported database structure to application-team monitoring checks. It is based on the local metadata-only lab and the source PostgreSQL Inspector report. Use it to help application teams monitor database-facing behavior and provide better evidence during incidents.

This is not a replacement for database platform monitoring. It is an application-aligned checklist: which teams should watch which database signals, what SQL to run, and what symptoms to escalate.

## Structure Summary

The imported metadata shows country/region-specific UAT databases:

- `ae_*`
- `ch_*`
- `sa_*`
- `uk_*`

Main application domains:

| Domain | Databases / schemas |
|---|---|
| API Gateway | `*_api_gateway_uat`, schema `api_gateway` |
| Common / Banking Admin | `*_common_uat`, schema `banking_admin` |
| Document | `*_document_uat`, schema `document`; also `landlord_uat.document` |
| Service / CRM platform | `*_service_uat`, schemas `crm`, `admin`, `charge`, `locker`, `mobile`, `dashboard`, `jobrunr`, `kafka_recovery`, `profile_management`, `chatbot`, `api_gateway`, `banking_admin` |
| TPS | `*_tps_uat`, schemas `tps`, `tps_communicator`, `vat`, `crm`, `banking_admin`, `admin` |
| TPS Warehouse | `*_tps_warehouse_uat`, schema `tps_warehouse` |
| Landlord | `landlord_uat`, schemas `landlord`, `document` |
| DR / special database | `druatrhbk`, schema `public` |

## Application Team Dashboard Signals

Every application team should monitor these baseline database-facing signals:

| Signal | Why it matters |
|---|---|
| Active sessions by application/user/client | Detect connection storms and app pool leaks |
| Idle in transaction sessions | Detect transaction handling bugs that block vacuum |
| Long-running queries | Detect stuck jobs, slow APIs, missing indexes |
| Lock waits | Detect blocked releases, batch jobs, or DDL conflicts |
| Table growth | Detect runaway queues/logs/audit tables |
| Dead tuple ratio | Detect vacuum pressure from app churn |
| Failed or stuck queue/job tables | Detect application workflow failures |
| Logical replication lag/slot retention | Detect downstream sync failure and WAL retention risk |
| Top query fingerprints | Detect regressions after deployments |

## 1. API Gateway Team

Relevant databases:

- `ae_api_gateway_uat`
- `sa_api_gateway_uat`
- `uk_api_gateway_uat`
- `*_service_uat` also contains `api_gateway` schema

Key tables from metadata:

- `api_gateway.access_session`
- `api_gateway.login_audit`
- `api_gateway.login_audit_log`
- `api_gateway.device_type`

Monitor:

- Login audit insert rate.
- Growth of `login_audit` and `login_audit_log`.
- Slow queries on `access_id`, `device_type`, and login timestamp columns.
- Missing FK child indexes noted in `INDEX_RECOMMENDATIONS.md`, especially:
  - `api_gateway.login_audit(access_id)`
  - `api_gateway.login_audit(device_type)`

SQL checks:

```sql
select
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'api_gateway'
order by n_dead_tup desc;
```

```sql
select
  now() - query_start as query_age,
  pid,
  usename,
  application_name,
  client_addr,
  state,
  left(query, 200) as query
from pg_stat_activity
where query ilike '%api_gateway%'
order by query_start nulls last
limit 50;
```

Escalate when:

- Login audit tables grow unexpectedly.
- App sessions are idle in transaction.
- API login/logout queries are blocked or waiting on locks.

## 2. Common / Banking Admin Team

Relevant databases:

- `ae_common_uat`
- `ch_common_uat`
- `sa_common_uat`
- `uk_common_uat`
- `banking_admin` schema inside TPS and service databases

Key metadata areas:

- Branches, zones, cities, countries, organizations, products, currencies.

Monitor:

- Unexpected DML on reference tables.
- Slow joins against branch/product/currency tables.
- Missing FK child indexes on branch/product/currency references.

SQL checks:

```sql
select
  schemaname,
  relname,
  n_tup_ins,
  n_tup_upd,
  n_tup_del,
  n_mod_since_analyze,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'banking_admin'
order by n_mod_since_analyze desc;
```

Escalate when:

- Reference data changes cause widespread slow TPS/service joins.
- Batch jobs update reference tables during business hours.

## 3. Document Team

Relevant databases:

- `ae_document_uat`
- `sa_document_uat`
- `uk_document_uat`
- `landlord_uat.document`
- `ch_document_uat` has document schemas/views but no base tables in the imported metadata.

Key tables:

- `document.document`
- `document.document_access_log`
- `document.document_tag_value`
- `document.document_metadata`

Monitor:

- Document table growth.
- Access log growth.
- Dead tuple percentage on document metadata tables.
- Slow searches by document identifiers or tags.

SQL checks:

```sql
select
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'document'
order by pg_total_relation_size(relid) desc;
```

Escalate when:

- Access logs grow abnormally.
- Document metadata queries become slow after upload/import batches.

## 4. Service / CRM Platform Team

Relevant databases:

- `ae_service_uat`
- `ch_service_uat`
- `sa_service_uat`
- `uk_service_uat`

Important schemas:

- `crm`
- `admin`
- `charge`
- `locker`
- `mobile`
- `dashboard`
- `jobrunr`
- `kafka_recovery`
- `profile_management`

Report concerns:

- Service databases have the largest number of tables and constraints.
- Several `crm` tables in the report had high dead tuple percentages.
- Missing FK child index candidates are highest in service databases:
  - `ae_service_uat`: `86`
  - `ch_service_uat`: `83`
  - `sa_service_uat`: `83`
  - `uk_service_uat`: `83`

Monitor:

- CRM table bloat/dead tuple ratio.
- JobRunr queue tables.
- Kafka recovery/fail record tables.
- Locker operation tables.
- Mobile notification tables.
- Charge parameter/config updates.

CRM dead tuple check:

```sql
select
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'crm'
order by dead_pct desc nulls last, n_dead_tup desc
limit 50;
```

JobRunr health check:

```sql
select
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'jobrunr'
order by pg_total_relation_size(relid) desc;
```

Kafka recovery check:

```sql
select
  schemaname,
  relname,
  n_live_tup,
  n_dead_tup,
  n_mod_since_analyze,
  last_autovacuum
from pg_stat_user_tables
where schemaname = 'kafka_recovery'
order by n_live_tup desc, n_dead_tup desc;
```

Escalate when:

- `kafka_recovery` tables grow continuously.
- `jobrunr` tables accumulate old jobs.
- CRM dead tuple ratio stays high after autovacuum.
- Service app sessions are idle in transaction.

## 5. TPS Team

Relevant databases:

- `ae_tps_uat`
- `ch_tps_uat`
- `sa_tps_uat`
- `uk_tps_uat`

Important schemas:

- `tps`
- `tps_communicator`
- `vat`
- `crm`
- `banking_admin`

High-priority report tables:

- `tps.transaction_audit_sequence`
- `tps.transaction_ledger`
- `tps.unposted_transaction`
- `tps.hplus_transaction_received`
- `tps.transaction_audit`
- `tps.transaction_reference`

Monitor:

- TPS transaction table growth.
- Slow lookups on `transaction_id`, `sequence_number`, `account_number`, `login_name`, and `branch_id`.
- Unposted transaction accumulation.
- Missing FK child indexes from `INDEX_RECOMMENDATIONS.md`.
- Partitioning feasibility for very large transaction/history tables.

TPS table size check:

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
where schemaname = 'tps'
order by pg_total_relation_size(relid) desc
limit 50;
```

Long-running TPS query check:

```sql
select
  now() - query_start as query_age,
  pid,
  usename,
  application_name,
  client_addr,
  wait_event_type,
  wait_event,
  left(query, 300) as query
from pg_stat_activity
where query ilike '%tps.%'
order by query_start nulls last
limit 50;
```

Escalate when:

- `unposted_transaction` grows unexpectedly.
- Transaction tables grow faster than retention assumptions.
- TPS queries wait on locks or I/O during peak periods.
- Logical replication from service/TPS has WAL retention growth.

## 6. TPS Warehouse / Reporting Team

Relevant databases:

- `ae_tps_warehouse_uat`
- `ch_tps_warehouse_uat`
- `sa_tps_warehouse_uat`
- `uk_tps_warehouse_uat`

Important schema:

- `tps_warehouse`

High-priority tables:

- `tps_warehouse.transaction_ledger`
- `tps_warehouse.balance_during`
- `tps_warehouse.balance_during_value_date`
- `tps_warehouse.account_serial_balance_during`
- `tps_warehouse.account_serial_balance_during_value_date`
- `tps_warehouse.failed_record`

Monitor:

- Warehouse table growth.
- Reporting query duration.
- Dead tuple ratio after ETL/reporting loads.
- Failed records.

SQL checks:

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
where schemaname = 'tps_warehouse'
order by pg_total_relation_size(relid) desc
limit 50;
```

Escalate when:

- Warehouse loads cause long locks.
- Failed records grow continuously.
- Reporting queries scan very large tables without partition pruning or useful indexes.

## 7. Charge Team

Relevant schema:

- `charge` inside `*_service_uat`

Monitor:

- Charge parameter/config changes.
- Slow charge lookup queries.
- Unexpected DML volume on parameter/config tables.

SQL checks:

```sql
select
  relname,
  n_tup_ins,
  n_tup_upd,
  n_tup_del,
  n_mod_since_analyze,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = 'charge'
order by n_mod_since_analyze desc;
```

Escalate when:

- Charge reference/config tables change during transaction processing issues.
- Charge queries appear in long-running query lists.

## 8. Locker Team

Relevant schema:

- `locker` inside `*_service_uat`

Monitor:

- Locker operation history growth.
- Locker operation auth waits.
- Missing composite FK indexes on `locker_number, branch_id` candidates.

SQL checks:

```sql
select
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  n_live_tup,
  n_dead_tup,
  last_autovacuum
from pg_stat_user_tables
where schemaname = 'locker'
order by pg_total_relation_size(relid) desc;
```

Escalate when:

- Locker operation tables grow abnormally.
- Locker workflows show lock waits or slow FK checks.

## 9. Mobile / Notification Team

Relevant schema:

- `mobile` inside `*_service_uat`

Monitor:

- Notification request backlog.
- External notification request growth.
- Request status transitions.

SQL checks:

```sql
select
  relname,
  n_live_tup,
  n_dead_tup,
  n_mod_since_analyze,
  last_autovacuum
from pg_stat_user_tables
where schemaname = 'mobile'
order by n_live_tup desc, n_dead_tup desc;
```

Escalate when:

- Notification requests accumulate.
- Mobile request tables show high churn without vacuum/analyze.

## 10. Replication / Integration Team

The report showed logical subscriptions/slots linking service databases to common, TPS, and TPS warehouse databases.

Monitor:

- Logical slot active status.
- Retained WAL by slot.
- Subscription worker sessions.
- Apply lag, if available on subscriber side.

Publisher-side checks:

```sql
select
  slot_name,
  plugin,
  database,
  active,
  restart_lsn,
  confirmed_flush_lsn,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal
from pg_replication_slots
order by slot_name;
```

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
  replay_lsn
from pg_stat_replication
order by application_name;
```

Escalate when:

- Any expected logical slot is inactive.
- Retained WAL grows.
- Subscription workers reconnect repeatedly.
- WAL disk pressure increases.

## 11. Application Incident Evidence Pack

When an app team reports slow performance, ask for:

- Application name and owning team.
- Database name.
- Schema/table names if known.
- Time window with timezone.
- Example request/correlation ID.
- Slow SQL or endpoint.
- Expected vs actual latency.
- Deployment/change history in the same window.

DBA-side initial evidence:

```sql
select now();
select datname, numbackends from pg_stat_database order by numbackends desc;
```

```sql
select
  pid,
  datname,
  usename,
  application_name,
  client_addr,
  state,
  wait_event_type,
  wait_event,
  now() - query_start as query_age,
  left(query, 300) as query
from pg_stat_activity
where state <> 'idle'
order by query_start nulls last
limit 100;
```

```sql
select
  locktype,
  database,
  relation::regclass,
  mode,
  granted,
  pid
from pg_locks
where not granted
order by pid;
```

## Recommended Dashboards

Create dashboards by app domain:

| Dashboard | Panels |
|---|---|
| API Gateway | login audit growth, active sessions, slow login queries |
| CRM / Service | dead tuples, top table growth, idle transactions, jobrunr/kafka tables |
| TPS | top TPS table size, transaction backlog, missing-index candidates, long queries |
| Warehouse | ETL table growth, failed records, long reporting queries |
| Replication | slot active status, retained WAL, walsender sessions |
| Pooling | sessions by app/client/user/state, idle in transaction, connection spikes |

## Priority Actions

1. Build alert for `idle in transaction` over an agreed threshold.
2. Build alert for logical slot retained WAL growth.
3. Review top missing FK child indexes on large TPS tables.
4. Review autovacuum behavior on CRM/service tables with high dead tuple percentages.
5. Review huge zero-scan indexes over a full workload cycle.
6. Plan partitioning review for very large TPS and warehouse tables.
