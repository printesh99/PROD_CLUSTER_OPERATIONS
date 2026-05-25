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

## Grafana Monitoring Roadmap

The current production estate is already monitored through Zabbix. Grafana should not replace that immediately. Use Grafana as the single observability layer that combines Zabbix infrastructure signals, PostgreSQL database metrics, Kubernetes/Patroni status, application logs, traces, and business-domain KPIs.

Target outcome:

- Application teams see their own business workflow health without needing DBA access.
- DBA team sees PostgreSQL, Patroni, replication, capacity, waits, locks, and query health.
- Management sees service availability, risk, SLA/SLO health, major incidents, and capacity runway.
- WB UI and the database console can later embed or deep-link to the exact Grafana panels for one database, app, region, or incident window.

### Recommended Grafana Data Sources

| Source | Purpose |
|---|---|
| Zabbix plugin | Reuse existing server, VM, network, disk, CPU, and legacy alert signals |
| Prometheus | Primary metrics store for PostgreSQL exporters, Kubernetes, Patroni, PgBouncer, node, and app metrics |
| PostgreSQL data source | Controlled SQL panels for metadata, object counts, table growth, slow sessions, locks, and DBA reports |
| Loki | PostgreSQL, application, API gateway, Kubernetes, and ETL logs |
| Tempo or Jaeger | Distributed traces from WB UI, API, service layer, and database calls |
| Alertmanager | Alert routing, grouping, silencing, escalation, and on-call integration |
| Object storage or backup exporter | Backup age, backup success, restore validation, WAL archive health |

### Standard Dashboard Variables

Every dashboard should use the same variables so it can be embedded later into the WB UI and database console.

| Variable | Example values |
|---|---|
| `$environment` | `uat`, `prod`, `dr` |
| `$region` | `ae`, `ch`, `sa`, `uk` |
| `$database` | `ae_tps_uat`, `uk_service_uat` |
| `$domain` | `api_gateway`, `common`, `document`, `service`, `tps`, `warehouse`, `replication` |
| `$schema` | `tps`, `crm`, `tps_warehouse`, `api_gateway`, `document` |
| `$table` | selected table from `pg_stat_user_tables` |
| `$application` | application name from connection string or app metrics |
| `$team` | owning application or DBA team |
| `$pod` | Kubernetes pod name |
| `$time_window` | incident or SLA window |

Minimum labels to standardize in exporters and app metrics:

- `environment`
- `region`
- `cluster`
- `namespace`
- `pod`
- `database`
- `schema`
- `application`
- `team`
- `service`
- `endpoint`
- `severity`

## Banking Core Monitoring Perspective

Because this database estate supports core banking workflows, monitoring must go beyond server health and query speed. Dashboards must prove transaction integrity, customer-impact visibility, auditability, operational control, and regulatory readiness.

### Core Banking Risk Areas

| Risk area | What to monitor |
|---|---|
| Transaction integrity | posted vs unposted transactions, duplicate references, failed posting, ledger sequence gaps, rollback spikes |
| Financial reconciliation | TPS vs warehouse counts, failed records, end-of-day load freshness, balance table freshness |
| Customer access | login success/failure, account lockouts, abnormal failed login spikes, session growth |
| Maker-checker/control | reference/config changes, approval workflow failures, changes during freeze windows |
| Audit and evidence | audit table growth, audit write failures, missing audit entries, retention pressure |
| Regulatory continuity | backup freshness, restore validation, DR replication health, RPO/RTO indicators |
| Fraud/security signals | abnormal failed logins, unusual transaction failure patterns, suspicious access bursts |
| Operational resilience | lock waits, idle transactions, replication lag, WAL retention, disk/PVC capacity runway |
| Data quality | failed ETL records, stale reporting data, invalid status transitions, orphan records |
| Change risk | deployment/change window correlation with DB errors, latency, locks, and failed business events |

### Banking Executive KPIs

Management dashboards should translate technical symptoms into banking risk:

- Customer login availability and latency.
- Transaction posting availability and latency.
- Unposted transaction backlog and oldest unposted transaction age.
- Failed transaction rate by region.
- TPS ledger growth and abnormal spike detection.
- Warehouse data freshness for business reporting.
- Backup success and last restore test age.
- Replication RPO status by critical data flow.
- Critical reference data changes in the selected window.
- Open P1/P2 incidents by business service.
- Capacity runway for transaction, audit, WAL, and warehouse growth.

### Transaction Integrity Signals

For TPS databases, the highest-value Grafana panels should answer:

- Are transactions being received, posted, and audited at normal rates?
- Is `tps.unposted_transaction` growing?
- What is the oldest unposted transaction age?
- Are there repeated failures for the same account, branch, channel, or transaction reference?
- Are ledger/audit sequence tables growing normally?
- Did transaction failures start after a deployment, configuration change, or replication issue?
- Are TPS tables blocked by locks or waiting on I/O during posting peaks?

Recommended panels:

- Posted vs unposted transaction count.
- Unposted backlog by age bucket.
- Failed transaction rate by region and channel if available.
- Ledger insert rate and audit insert rate.
- TPS long queries and lock waits during posting windows.
- Transaction table growth against expected daily baseline.

### Reconciliation And Reporting Signals

Warehouse dashboards should not only show table size. They should show whether business reports can be trusted.

Monitor:

- Last successful warehouse load time.
- ETL freshness by region.
- Failed record count and growth trend.
- Difference between TPS source counts and warehouse loaded counts where a safe reconciliation query exists.
- Reporting query latency and timeout count.
- Stale analyze statistics after ETL loads.
- Temp file growth during reporting queries.

Escalate when:

- Warehouse is stale beyond reporting SLA.
- Failed records grow and do not drain.
- TPS-to-warehouse reconciliation count differs beyond agreed tolerance.
- Reporting is green technically but data freshness is red.

### Audit, Compliance, And Evidence

Core banking dashboards must retain evidence for incident review and audit.

Monitor:

- Audit table insert rate.
- Audit table growth and retention runway.
- Audit write errors from application logs.
- Login audit success/failure trend.
- Reference/config change history.
- Administrative user activity if available from logs or audit tables.
- Backup completion, WAL archive continuity, and restore validation.

Evidence to preserve during incidents:

- Exact time window with timezone.
- Affected region, database, schema, application, and business workflow.
- Grafana dashboard link with variables and time range.
- Top wait events, locks, long queries, and app error rates.
- Relevant config/reference changes.
- Deployment/change records.
- Replication and backup status.

### Maker-Checker And Reference Data Control

For `banking_admin`, `admin`, and common reference schemas, monitoring should detect risky changes.

Panels:

- Reference/config DML volume by table.
- Recently changed reference tables.
- Changes outside approved windows.
- Region-to-region reference data drift where comparable.
- Failed approval or workflow events if captured by application logs.
- Long-running queries on reference lookup tables.

Alerts:

- Critical reference table updated during freeze window.
- Unexpected delete/truncate-like volume on configuration tables.
- Config drift detected between regions.
- Reference data change followed by spike in TPS/service errors.

### Security And Fraud-Oriented Signals

This is not a replacement for SIEM/fraud tooling, but Grafana can expose database-backed early warning signals.

Monitor:

- Failed login spike by region.
- Repeated failures for the same user, channel, client, branch, or IP where safe and compliant.
- Sudden session count increase.
- Administrative connection attempts.
- Application users connecting from unexpected hosts.
- High failed transaction rate for the same channel or branch.
- Unusual after-hours access to critical schemas.

Security notes:

- Do not expose customer PII in Grafana panels.
- Aggregate by region, service, status, channel, or anonymized identifier.
- Limit raw audit drill-down to approved DBA/security roles.
- Use Grafana folder permissions for management, app team, DBA, and security views.

### Banking Alert Severity Guidance

Use banking impact to set severity, not only technical thresholds.

| Severity | Banking interpretation |
|---|---|
| `P1` | Login unavailable, transaction posting unavailable, data integrity risk, ledger/audit write failure, primary database unavailable |
| `P2` | TPS backlog growing, replication RPO breach, warehouse reporting SLA missed, severe lock waits, reference data control breach |
| `P3` | Dead tuples, stale stats, index risk, moderate latency, ETL delay within tolerance, growing but controlled capacity risk |
| `P4` | Hygiene, dashboard improvement, low-risk tuning, documentation, non-urgent capacity review |

### Banking Dashboard Design Rule

Every core banking dashboard should separate three layers:

1. Business state: customer login, transaction posting, reporting freshness, backlog, failed business events.
2. Application state: errors, latency, job queues, API health, logs, traces.
3. Database state: sessions, locks, waits, queries, vacuum, replication, WAL, capacity.

This makes it possible to tell management whether the bank is impacted, tell application teams where their workflow is failing, and tell DBA/platform teams what technical condition needs action.

## Core Banking Grafana Dashboard SQL Pack

Use this section as the base for one comprehensive Grafana dashboard named `Core Banking Regional Operations`.

The SQL below is based on the imported table structure from the production report. It is intended for Grafana PostgreSQL data sources. Because PostgreSQL does not query across databases unless FDW/dblink is configured, create one data source per database or per region/domain and repeat the same panel by data source.

Regional database naming convention:

| Domain | Regional databases |
|---|---|
| API Gateway | `ae_api_gateway_uat`, `sa_api_gateway_uat`, `uk_api_gateway_uat`; API tables also exist in `*_service_uat` |
| Common/reference | `ae_common_uat`, `ch_common_uat`, `sa_common_uat`, `uk_common_uat` |
| Document | `ae_document_uat`, `sa_document_uat`, `uk_document_uat`; `ch_document_uat` has no base tables in this report |
| Service/CRM | `ae_service_uat`, `ch_service_uat`, `sa_service_uat`, `uk_service_uat` |
| TPS | `ae_tps_uat`, `ch_tps_uat`, `sa_tps_uat`, `uk_tps_uat` |
| TPS Warehouse | `ae_tps_warehouse_uat`, `ch_tps_warehouse_uat`, `sa_tps_warehouse_uat`, `uk_tps_warehouse_uat` |

Recommended dashboard variables:

- `$region`: `ae`, `ch`, `sa`, `uk`
- `$domain`: `api_gateway`, `common`, `document`, `service`, `tps`, `warehouse`
- `$database`: Grafana data source or database variable mapped to the selected region/domain
- `$branch_id`: optional branch filter where a table has `branch_id`
- `$status`: optional status filter

### Row 1: Executive Banking Health

Panel: current database and object source confirmation.

```sql
select
  current_database() as database_name,
  current_user as grafana_user,
  now() as collected_at;
```

Panel: largest user tables for selected database.

```sql
select
  current_database() as database_name,
  schemaname,
  relname as table_name,
  pg_total_relation_size(relid) as total_bytes,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
order by pg_total_relation_size(relid) desc
limit 25;
```

Panel: database object count by schema.

```sql
select
  current_database() as database_name,
  n.nspname as schema_name,
  c.relkind,
  count(*) as object_count
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname not in ('pg_catalog', 'information_schema')
group by n.nspname, c.relkind
order by n.nspname, c.relkind;
```

### Row 2: Customer Login And Access

Run against `*_api_gateway_uat` or `*_service_uat`.

Panel: access sessions by status.

```sql
select
  date_trunc('hour', access_time) as time,
  status,
  count(*) as sessions
from api_gateway.access_session
where $__timeFilter(access_time)
group by 1, status
order by 1, status;
```

Panel: active login sessions.

```sql
select
  count(*) as active_login_sessions
from api_gateway.login_audit
where logged_out_time is null;
```

Panel: login activity by device type.

```sql
select
  date_trunc('hour', la.logged_in_time) as time,
  coalesce(dt.name, la.device_type::text) as device_type,
  count(*) as logins
from api_gateway.login_audit la
left join api_gateway.device_type dt on dt.id = la.device_type
where $__timeFilter(la.logged_in_time)
group by 1, coalesce(dt.name, la.device_type::text)
order by 1, 2;
```

Panel: API route/menu access volume.

```sql
select
  date_trunc('hour', access_time) as time,
  service_id,
  menu_id,
  route_id,
  count(*) as access_count
from api_gateway.login_audit_log
where $__timeFilter(access_time)
group by 1, service_id, menu_id, route_id
order by 1, access_count desc;
```

### Row 3: TPS Transaction Posting

Run against `*_tps_uat`.

Panel: transaction references by branch and date.

```sql
select
  "date"::timestamp as time,
  branch_id,
  count(*) as transaction_count
from tps.transaction_reference
where "date" >= $__timeFrom()::date
  and "date" < ($__timeTo()::date + interval '1 day')
group by "date", branch_id
order by "date", branch_id;
```

Panel: ledger postings by effective date.

```sql
select
  effective_date::timestamp as time,
  transaction_type,
  transaction_sub_type,
  count(*) as ledger_rows,
  sum(fc_amount) as fc_amount,
  sum(lc_amount) as lc_amount
from tps.transaction_ledger
where effective_date >= $__timeFrom()::date
  and effective_date < ($__timeTo()::date + interval '1 day')
group by effective_date, transaction_type, transaction_sub_type
order by effective_date, transaction_type, transaction_sub_type;
```

Panel: unposted transaction backlog by effective date.

```sql
select
  effective_date::timestamp as time,
  transaction_type,
  transaction_sub_type,
  hold_flag,
  count(*) as unposted_rows,
  sum(fc_amount) as fc_amount,
  sum(lc_amount) as lc_amount
from tps.unposted_transaction
where effective_date >= $__timeFrom()::date
  and effective_date < ($__timeTo()::date + interval '1 day')
group by effective_date, transaction_type, transaction_sub_type, hold_flag
order by effective_date, transaction_type, transaction_sub_type, hold_flag;
```

Panel: current unposted transaction count and amount.

```sql
select
  count(*) as unposted_rows,
  count(distinct transaction_id) as unposted_transactions,
  min(effective_date) as oldest_effective_date,
  max(effective_date) as newest_effective_date,
  sum(fc_amount) as fc_amount,
  sum(lc_amount) as lc_amount
from tps.unposted_transaction;
```

Panel: transaction audit status by action.

```sql
select
  date_trunc('hour', action_time) as time,
  action,
  status,
  count(*) as audit_events
from tps.transaction_audit
where $__timeFilter(action_time)
group by 1, action, status
order by 1, action, status;
```

Panel: service/path status from transaction audit sequence.

```sql
select
  service_name,
  path,
  http_request_type,
  financial,
  status,
  count(*) as events
from tps.transaction_audit_sequence
group by service_name, path, http_request_type, financial, status
order by events desc
limit 50;
```

Panel: transaction balance update status.

```sql
select
  status,
  count(*) as balance_update_rows
from tps.transaction_balance_update
group by status
order by balance_update_rows desc;
```

Panel: transaction integrity check, references without ledger rows.

```sql
select
  tr."date"::timestamp as time,
  tr.branch_id,
  count(*) as references_without_ledger
from tps.transaction_reference tr
left join tps.transaction_ledger tl on tl.transaction_id = tr.transaction_id
where tl.transaction_id is null
  and tr."date" >= $__timeFrom()::date
  and tr."date" < ($__timeTo()::date + interval '1 day')
group by tr."date", tr.branch_id
order by tr."date", tr.branch_id;
```

Panel: transaction ledger rows without audit sequence.

```sql
select
  count(*) as ledger_rows_without_audit_sequence
from tps.transaction_ledger tl
left join tps.transaction_audit_sequence tas
  on tas.transaction_id = tl.transaction_id
 and tas.sequence_number = tl.sequence_number
where tas.transaction_id is null;
```

### Row 4: Account And Customer Risk

Use `*_service_uat` for customer onboarding, account opening, and account control risk. Use `*_tps_uat` for replicated account balance exposure.

Panel: customer status by branch and category.

```sql
select
  branch_id,
  category,
  status,
  count(*) as customers
from crm.customer
group by branch_id, category, status
order by customers desc;
```

Panel: customer onboarding trend from relationship start date.

```sql
select
  relationship_start_date::timestamp as time,
  branch_id,
  category,
  count(*) as customers_started
from crm.customer
where relationship_start_date >= $__timeFrom()::date
  and relationship_start_date < ($__timeTo()::date + interval '1 day')
group by relationship_start_date, branch_id, category
order by relationship_start_date, branch_id, category;
```

Panel: account opening trend.

```sql
select
  opened_on::timestamp as time,
  branch_unit_id,
  product_id,
  currency_id,
  status,
  count(*) as accounts_opened
from crm.account
where opened_on >= $__timeFrom()::date
  and opened_on < ($__timeTo()::date + interval '1 day')
group by opened_on, branch_unit_id, product_id, currency_id, status
order by opened_on, branch_unit_id, product_id, currency_id, status;
```

Panel: account control risk flags. Run against `*_service_uat`.

```sql
select
  status,
  is_freeze_debit_transaction,
  is_freeze_credit_transactions,
  is_no_transactions,
  is_deceased,
  is_high_risk,
  is_restrict_account_access,
  count(*) as accounts
from crm.account_control
group by
  status,
  is_freeze_debit_transaction,
  is_freeze_credit_transactions,
  is_no_transactions,
  is_deceased,
  is_high_risk,
  is_restrict_account_access
order by accounts desc;
```

Panel: account balances by product/currency. Run against `*_tps_uat`.

```sql
select
  product_id,
  currency_id,
  count(*) as accounts,
  sum(fc_balance) as fc_balance,
  sum(lc_balance) as lc_balance,
  sum(blocked_amount) as blocked_amount,
  sum(lien_amount) as lien_amount
from crm.account
group by product_id, currency_id
order by abs(sum(lc_balance)) desc nulls last
limit 50;
```

### Row 5: Warehouse And Reconciliation

Run against `*_tps_warehouse_uat`.

Panel: warehouse ledger processed status.

```sql
select
  effective_date::timestamp as time,
  is_processed,
  count(*) as ledger_rows,
  sum(fc_amount) as fc_amount,
  sum(lc_amount) as lc_amount
from tps_warehouse.transaction_ledger
where effective_date >= $__timeFrom()::date
  and effective_date < ($__timeTo()::date + interval '1 day')
group by effective_date, is_processed
order by effective_date, is_processed;
```

Panel: warehouse failed records.

```sql
select
  date_trunc('hour', created_at) as time,
  type,
  count(*) as failed_records
from tps_warehouse.failed_record
where $__timeFilter(created_at)
group by 1, type
order by 1, type;
```

Panel: warehouse balance freshness.

```sql
select
  'balance_during' as table_name,
  max(updated_at) as last_updated_at,
  count(*) as rows
from tps_warehouse.balance_during
union all
select
  'balance_during_value_date' as table_name,
  max(updated_at) as last_updated_at,
  count(*) as rows
from tps_warehouse.balance_during_value_date
union all
select
  'account_serial_balance_during' as table_name,
  max(updated_at) as last_updated_at,
  count(*) as rows
from tps_warehouse.account_serial_balance_during
union all
select
  'account_serial_balance_during_value_date' as table_name,
  max(updated_at) as last_updated_at,
  count(*) as rows
from tps_warehouse.account_serial_balance_during_value_date;
```

Panel: warehouse transaction map by branch route.

```sql
select
  "date"::timestamp as time,
  r_country,
  r_zone,
  r_branch,
  count(*) as mapped_transactions
from tps_warehouse.hplus_transaction_map
where "date" >= $__timeFrom()::date
  and "date" < ($__timeTo()::date + interval '1 day')
group by "date", r_country, r_zone, r_branch
order by "date", r_country, r_zone, r_branch;
```

Panel: TPS-to-warehouse reconciliation, Grafana transformation method.

Run this query on the TPS datasource:

```sql
select
  "date"::timestamp as time,
  count(*) as tps_transaction_references
from tps.transaction_reference
where "date" >= $__timeFrom()::date
  and "date" < ($__timeTo()::date + interval '1 day')
group by "date"
order by "date";
```

Run this query on the warehouse datasource and join by `time` in Grafana transformations:

```sql
select
  "date"::timestamp as time,
  count(*) as warehouse_transaction_maps
from tps_warehouse.hplus_transaction_map
where "date" >= $__timeFrom()::date
  and "date" < ($__timeTo()::date + interval '1 day')
group by "date"
order by "date";
```

### Row 6: Service Jobs And Integration Backlog

Run against `*_service_uat`.

Panel: JobRunr job state.

```sql
select
  date_trunc('hour', createdat) as time,
  state,
  count(*) as jobs
from jobrunr.jobrunr_jobs
where $__timeFilter(createdat)
group by 1, state
order by 1, state;
```

Panel: old or stuck JobRunr jobs.

```sql
select
  state,
  count(*) as jobs,
  min(createdat) as oldest_createdat,
  max(updatedat) as newest_updatedat,
  max(scheduledat) as newest_scheduledat
from jobrunr.jobrunr_jobs
group by state
order by jobs desc;
```

Panel: Kafka recovery failures.

```sql
select
  topic,
  group_name,
  status,
  type,
  count(*) as failed_records,
  max(retry_count) as max_retry_count
from kafka_recovery.kafka_fail_record
group by topic, group_name, status, type
order by failed_records desc
limit 50;
```

Panel: outstanding Kafka recovery records.

```sql
select
  k.topic,
  k.group_name,
  k.status,
  k.type,
  count(*) as outstanding_records,
  max(k.retry_count) as max_retry_count
from kafka_recovery.out_standing_record o
join kafka_recovery.kafka_fail_record k on k.id = o.kafka_fail_record_id
group by k.topic, k.group_name, k.status, k.type
order by outstanding_records desc;
```

### Row 7: Maker-Checker, Audit, And Reference Controls

Run against `*_service_uat` for operational maker-checker tables and `*_common_uat` for common reference tables.

Panel: transaction log status by module.

```sql
select 'admin' as module, status, count(*) as transactions
from admin.transaction_log
group by status
union all
select 'crm' as module, status, count(*) as transactions
from crm.transaction_log
group by status
union all
select 'charge' as module, status, count(*) as transactions
from charge.transaction_log
group by status
union all
select 'locker' as module, status, count(*) as transactions
from locker.transaction_log
group by status
order by module, status;
```

Panel: pending/proposed maintenance rows by schema.

```sql
select 'admin' as schema_name, count(*) as rows from admin.e_hplus_system_user
union all
select 'crm' as schema_name, count(*) as rows from crm.e_customer
union all
select 'crm' as schema_name, count(*) as rows from crm.e_account
union all
select 'banking_admin' as schema_name, count(*) as rows from banking_admin.e_product
union all
select 'banking_admin' as schema_name, count(*) as rows from banking_admin.e_currency
union all
select 'charge' as schema_name, count(*) as rows from charge.e_override_charge_account
union all
select 'locker' as schema_name, count(*) as rows from locker.e_locker_customer
order by rows desc;
```

Panel: reference branch working date and status.

```sql
select
  b.id as branch_id,
  b.name as branch_name,
  b.short_name,
  b.status,
  b.working_date,
  b.time_zone,
  o.name as organization_name
from banking_admin.branch b
join banking_admin.organization o on o.id = b.organization_id
order by b.id;
```

Panel: product status and control flags.

```sql
select
  id as product_id,
  short_name,
  status,
  ledger_type,
  balance_control,
  debit_transaction_flag,
  credit_transaction_flag,
  limit_check_flag,
  deep_freeze_flag,
  allow_user_transaction_flag
from banking_admin.product
order by status, product_id;
```

Panel: currency master.

```sql
select
  id as currency_id,
  iso_code,
  name,
  "decimal",
  decimal_name
from banking_admin.currency
order by id;
```

### Row 8: Document And Statement Access

Run against `*_document_uat` where tables exist.

Panel: document uploads by type and size.

```sql
select
  date_trunc('hour', "date") as time,
  documenttype,
  contenttype,
  count(*) as documents,
  sum(size) as total_size_bytes
from document.document
where $__timeFilter("date")
group by 1, documenttype, contenttype
order by 1, documenttype, contenttype;
```

Panel: document access by user/source/access type.

```sql
select
  date_trunc('hour', "date") as time,
  source,
  accesstype,
  username,
  count(*) as access_count
from document.document_access_log
where $__timeFilter("date")
group by 1, source, accesstype, username
order by 1, access_count desc;
```

Panel: document metadata status by route.

```sql
select
  serviceid,
  menuid,
  routeid,
  status,
  count(*) as metadata_rows
from document.document_metadata
group by serviceid, menuid, routeid, status
order by metadata_rows desc;
```

Run against `*_tps_warehouse_uat` for statement access:

```sql
select
  date_trunc('hour', created_at) as time,
  login_name,
  count(*) as statement_access_count
from tps_warehouse.statement_access_log
where $__timeFilter(created_at)
group by 1, login_name
order by 1, statement_access_count desc;
```

### Row 9: OTP, Mobile, Locker, And Charge

Run against `*_service_uat`.

Panel: OTP status and failures.

```sql
select
  date_trunc('hour', sent_at) as time,
  otp_status,
  failure_reason,
  count(*) as otp_count,
  sum(attempts) as attempts,
  sum(resend_count) as resend_count
from mobile.otp_transaction
where $__timeFilter(sent_at)
group by 1, otp_status, failure_reason
order by 1, otp_status, failure_reason;
```

Panel: OTP audit log.

```sql
select
  date_trunc('hour', log_date) as time,
  otp_status,
  failure_reason,
  count(*) as otp_audit_events,
  sum(attempts) as attempts,
  sum(resend_count) as resend_count
from mobile.otp_audit_log
where $__timeFilter(log_date)
group by 1, otp_status, failure_reason
order by 1, otp_status, failure_reason;
```

Panel: locker pending/proposed operations.

```sql
select
  http_request_type,
  locker_status,
  branch_id,
  count(*) as locker_customer_rows
from locker.e_locker_customer
group by http_request_type, locker_status, branch_id
order by locker_customer_rows desc;
```

Panel: charge overrides by type.

```sql
select
  'override_charge_account' as source_table,
  charge_type_id,
  currency_id,
  count(*) as rows,
  sum(charge) as total_charge
from charge.override_charge_account
group by charge_type_id, currency_id
union all
select
  'override_charge_customer' as source_table,
  charge_type_id,
  currency_id,
  count(*) as rows,
  sum(charge) as total_charge
from charge.override_charge_customer
group by charge_type_id, currency_id
order by source_table, rows desc;
```

### Row 10: Database Reliability For Banking Incidents

Run against every database data source.

Panel: active sessions by application.

```sql
select
  current_database() as database_name,
  application_name,
  usename,
  state,
  wait_event_type,
  wait_event,
  count(*) as sessions
from pg_stat_activity
where state <> 'idle'
group by current_database(), application_name, usename, state, wait_event_type, wait_event
order by sessions desc;
```

Panel: long-running active statements.

```sql
select
  current_database() as database_name,
  pid,
  usename,
  application_name,
  client_addr,
  state,
  wait_event_type,
  wait_event,
  now() - query_start as query_age,
  left(query, 500) as query_text
from pg_stat_activity
where state <> 'idle'
  and query_start is not null
order by query_age desc
limit 50;
```

Panel: idle-in-transaction sessions.

```sql
select
  current_database() as database_name,
  pid,
  usename,
  application_name,
  client_addr,
  now() - xact_start as transaction_age,
  now() - state_change as idle_age,
  left(query, 500) as last_query
from pg_stat_activity
where state = 'idle in transaction'
order by transaction_age desc
limit 50;
```

Panel: table vacuum/analyze freshness.

```sql
select
  current_database() as database_name,
  schemaname,
  relname as table_name,
  n_live_tup,
  n_dead_tup,
  round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2) as dead_tuple_pct,
  last_autovacuum,
  last_autoanalyze,
  n_mod_since_analyze
from pg_stat_user_tables
order by dead_tuple_pct desc nulls last, n_dead_tup desc
limit 50;
```

Panel: unused or rarely used large indexes.

```sql
select
  current_database() as database_name,
  schemaname,
  relname as table_name,
  indexrelname as index_name,
  idx_scan,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size
from pg_stat_user_indexes
where idx_scan = 0
order by pg_relation_size(indexrelid) desc
limit 50;
```

### Dashboard Alert Candidates

Use these alert candidates after baseline collection:

| Panel | Alert condition |
|---|---|
| Active login sessions | abnormal spike compared with baseline |
| Access sessions by status | failure/error status spike |
| Unposted transaction backlog | count greater than agreed threshold or oldest effective date too old |
| Transaction references without ledger | count greater than zero after posting window |
| Ledger rows without audit sequence | count greater than zero |
| Warehouse failed records | count increasing and not draining |
| Warehouse balance freshness | `last_updated_at` older than SLA |
| JobRunr state | failed jobs or stuck scheduled jobs increasing |
| Kafka outstanding records | count greater than zero for sustained period |
| Account control risk flags | high-risk/freeze/no-transaction changes spike |
| Reference branch working date | stale or unexpected branch working date |
| OTP failures | failure rate spike |
| Idle-in-transaction sessions | age above agreed threshold |
| Replication retained WAL | retained WAL above agreed threshold |

## Comprehensive Dashboard Set

### 1. Management Command Center

Audience: CIO, CTO, service owners, operations managers.

Purpose: one page that answers whether the banking platform is healthy, what is at risk, and whether customers or internal users are affected.

Panels:

- Overall health score by region and domain.
- Current active incidents by severity.
- SLO burn rate for API, TPS, service, warehouse, and database platform.
- Top 5 slow business services.
- Top 5 databases by risk: disk, connections, long queries, replication lag, dead tuples.
- Availability by region: AE, CH, SA, UK.
- Backup status and last restore validation.
- Replication health summary.
- Capacity runway: database size, WAL growth, PVC/disk growth.
- Change window overlay: deployments, schema changes, maintenance.
- Business impact summary: failed logins, unposted transactions, failed warehouse records, notification backlog.

Management thresholds should be business-facing:

- Red when customer transaction posting, login, or critical service APIs are affected.
- Amber when capacity, lag, or backlog is growing but service is still available.
- Green only when service health, database health, replication, backup, and capacity are all inside thresholds.

### 2. Application Team Overview

Audience: all application teams.

Purpose: one landing dashboard with links to each team's deep dashboard.

Panels:

- Service health by team.
- Request rate, error rate, and latency by application.
- Database connections by application.
- Slow SQL count by application name.
- Lock waits by application name.
- Idle-in-transaction sessions by application name.
- Dead tuple and table growth risk by owning schema.
- Top incident-producing services over the selected window.

Required application behavior:

- Every service should set PostgreSQL `application_name`.
- Every API request should carry a correlation ID.
- Every log line should include `region`, `service`, `endpoint`, `correlation_id`, and `database` when available.
- Every service should expose RED metrics: request rate, errors, duration.

### 3. DBA / PostgreSQL Reliability

Audience: DBA and platform team.

Panels:

- Connections by database, user, state, application, and client.
- Connection saturation vs `max_connections`.
- PgBouncer pool usage if PgBouncer is introduced.
- Long-running queries.
- Idle-in-transaction sessions.
- Blocked sessions and blocking queries.
- Wait events by type.
- Top queries from `pg_stat_statements`: total time, mean time, P95/P99 if available, calls, rows, temp blocks.
- Database size and growth.
- Table and index growth.
- Dead tuples and autovacuum freshness.
- Tables needing analyze.
- Cache hit ratio.
- Temp file creation and temp bytes.
- Checkpoint frequency and checkpoint write time.
- WAL generation rate.
- Replication slots and retained WAL.
- Patroni leader, replica, failover, and timeline status.
- Kubernetes pod restarts, CPU, memory, PVC, and readiness.

DBA panels should link to:

- `LOCAL_METADATA_ENVIRONMENT.md` for imported object counts.
- `INDEX_RECOMMENDATIONS.md` for missing FK index candidates.
- `PERFORMANCE_TROUBLESHOOTING_RECOMMENDATIONS.md` for runbooks and investigation SQL.

### 4. API Gateway / Login Dashboard

Relevant databases:

- `ae_api_gateway_uat`
- `ch_api_gateway_uat`
- `sa_api_gateway_uat`
- `uk_api_gateway_uat`

Business panels:

- Login attempts, success, failure, lockout, and timeout rate.
- Login latency P50/P95/P99.
- Authentication failure reason split.
- Active session count.
- Session creation/deletion rate.
- Device/browser/client distribution if available in logs.
- Spike in failed login attempts by region.

Database panels:

- Growth of `login_audit`, `session`, and auth-related tables.
- Slow login queries.
- Lock waits in API gateway database.
- Connections from gateway services.
- Dead tuple ratio for high-churn session/audit tables.

Recommended alerts:

- Failed login rate spike.
- Login P95/P99 latency breach.
- Session table growth abnormal.
- Gateway database connection spike.
- Gateway queries blocked longer than agreed threshold.

### 5. Common / Reference Data Dashboard

Relevant databases:

- `ae_common_uat`
- `ch_common_uat`
- `sa_common_uat`
- `uk_common_uat`

Business panels:

- Reference/config table changes by region.
- Product, branch, currency, holiday, limit, or parameter changes during incident windows.
- Config drift between regions.
- Recently changed reference records.
- Replication lag from service/common publishers where applicable.

Database panels:

- DML volume on reference schemas.
- Tables with high update/delete activity.
- Long queries on reference lookups.
- Missing FK index candidates on reference tables.

Recommended alerts:

- Reference data changed during freeze window.
- Region-to-region config mismatch.
- Unexpected DML volume on mostly static reference tables.

### 6. Document Management Dashboard

Relevant databases:

- `ae_document_uat`
- `sa_document_uat`
- `uk_document_uat`

Business panels:

- Document upload count and failure count.
- Document search latency.
- Document access/download rate.
- Metadata/tag update volume.
- Document-related audit volume.

Database panels:

- Growth of document metadata tables.
- Dead tuples on metadata/audit tables.
- Slow document search queries.
- Index usage on document lookup columns.
- Tables with sequential scans during document searches.

Recommended alerts:

- Upload failures above threshold.
- Document search latency breach.
- Metadata/audit table growth spike.
- Sequential scan spike on large document tables.

### 7. Service / CRM Dashboard

Relevant databases:

- `ae_service_uat`
- `ch_service_uat`
- `sa_service_uat`
- `uk_service_uat`

Business panels:

- Customer onboarding volume and failures.
- Account/customer profile update rate.
- CRM request latency and errors.
- Jobrunr queued, running, failed, and retried jobs.
- Kafka recovery backlog.
- Locker workflow success/failure.
- Charge calculation/config lookup latency.
- Mobile notification request backlog and failure rate.

Database panels:

- CRM table growth and dead tuples.
- `jobrunr` table growth and old failed jobs.
- `kafka_recovery` backlog tables.
- Locks and long queries by service application.
- Tables with high `n_mod_since_analyze`.
- Large tables with missing FK indexes from `INDEX_RECOMMENDATIONS.md`.

Recommended alerts:

- Jobrunr failed jobs increasing.
- Kafka recovery backlog not draining.
- CRM table dead tuple ratio high.
- Service database idle-in-transaction sessions.
- Locker or charge tables blocked during business hours.

### 8. TPS Transaction Dashboard

Relevant databases:

- `ae_tps_uat`
- `ch_tps_uat`
- `sa_tps_uat`
- `uk_tps_uat`

Business panels:

- Transaction throughput by region.
- Posted vs unposted transaction count.
- Transaction failure rate.
- Transaction audit sequence growth.
- Ledger insert rate.
- Transaction processing latency.
- VAT-related transaction activity.
- Branch/account-level hot spots if safe to aggregate.

Database panels:

- Size/growth for `tps.transaction_ledger`, `tps.unposted_transaction`, `tps.transaction_audit`, `tps.transaction_reference`.
- Long-running TPS queries.
- Lock waits on transaction tables.
- Temp file usage during TPS queries.
- Missing FK child indexes on large TPS tables.
- Partitioning candidates by table size and time/range key.

Recommended alerts:

- `unposted_transaction` backlog grows for more than agreed duration.
- TPS P95/P99 posting latency breach.
- Transaction table lock wait above threshold.
- WAL generation spike during TPS peak.
- TPS table growth exceeds expected daily baseline.

### 9. TPS Warehouse / Reporting Dashboard

Relevant databases:

- `ae_tps_warehouse_uat`
- `ch_tps_warehouse_uat`
- `sa_tps_warehouse_uat`
- `uk_tps_warehouse_uat`

Business panels:

- ETL freshness by region.
- Last successful load time.
- Failed record count.
- Reporting query latency.
- Warehouse row growth by major fact table.
- Data availability SLA for business reports.

Database panels:

- Growth for `tps_warehouse.transaction_ledger`, `balance_during`, `balance_during_value_date`, `account_serial_balance_during`, and `failed_record`.
- Long reporting queries.
- Temp bytes and temp files from reporting workloads.
- Dead tuples after ETL loads.
- Analyze freshness after load completion.

Recommended alerts:

- ETL freshness breach.
- Failed records growing.
- Reporting queries blocked.
- Warehouse table analyze stale after load.
- Temp file spike during report execution.

### 10. Replication / Integration Dashboard

Audience: DBA, integration, application owners.

Panels:

- Logical replication slot active/inactive.
- Retained WAL by slot.
- Subscription worker status.
- Apply lag where available.
- Publisher/subscriber connectivity.
- WAL archive status.
- Replication errors from logs.
- Cross-database flow map: service to common, service to TPS, TPS to warehouse.

Recommended alerts:

- Expected logical slot inactive.
- Retained WAL above threshold.
- Subscription worker reconnect loop.
- WAL disk/PVC pressure.
- Apply lag breaches RPO.

### 11. Kubernetes / Patroni Platform Dashboard

Panels:

- Patroni leader and replicas.
- Failover count and timeline changes.
- Pod restarts.
- Pod CPU and memory.
- PVC usage and growth.
- Kubernetes events for PostgreSQL pods.
- PGO operator reconciliation status if available.
- Service endpoint readiness.
- Backup/restore job status.

Recommended alerts:

- Patroni leader not healthy.
- Replica not streaming.
- Pod crash loop.
- PVC usage above threshold.
- Backup missing or failed.
- Restore validation older than agreed threshold.

## Alert Routing Model

| Alert class | Primary owner | Secondary owner |
|---|---|---|
| Login/API latency or errors | API gateway team | DBA if DB wait/lock is present |
| CRM/service failures | Service team | DBA/platform |
| TPS backlog or transaction latency | TPS team | DBA |
| Warehouse freshness/reporting latency | Warehouse team | DBA |
| Replication lag/WAL retention | DBA | Integration team |
| Kubernetes/Patroni/PVC | Platform/DBA | Infrastructure |
| CPU/memory/network from existing monitoring | Infrastructure/Zabbix owner | DBA if DB impact exists |
| Executive SLO breach | Service owner | DBA/app/platform based on root cause |

Use severity consistently:

- `P1`: customer-impacting outage, transaction posting failure, login unavailable, data loss risk, or database unavailable.
- `P2`: major degradation, growing backlog, replication RPO breach, severe lock contention, or capacity risk.
- `P3`: trend risk, stale statistics, dead tuples, index review, non-critical ETL delay.
- `P4`: hygiene, documentation, dashboard gap, or non-urgent optimization.

## WB UI And Database Console Integration

The future WB UI and database console can use Grafana as the observability backend instead of rebuilding every chart manually.

Integration phases:

1. Deep links: add links from each WB UI database/application page to filtered Grafana dashboards using `var-database`, `var-region`, `var-domain`, and time range parameters.
2. Embedded panels: embed selected Grafana panels in the database console for database health, active sessions, locks, table growth, and replication status.
3. Health API: use Grafana or Prometheus APIs to show status cards in WB UI: green/amber/red, open alerts, SLO burn, and current incident count.
4. Incident workspace: from a WB UI incident page, open the matching Grafana view, logs in Loki, traces in Tempo, and SQL evidence pack for the same time window.
5. Role-based views: management sees business health, app teams see their domains, DBA sees all database panels.

Required design rules for integration:

- Never expose unrestricted ad hoc SQL to application teams.
- Use read-only PostgreSQL users for Grafana SQL panels.
- Keep sensitive customer data out of panel results.
- Prefer counts, rates, percentiles, and anonymized identifiers.
- Every embedded panel must have a clear owner and runbook link.

## Initial SLO Candidates

| Service area | SLO idea |
|---|---|
| API Gateway | Login API success rate and P95/P99 latency |
| TPS | Transaction posting success rate, unposted backlog drain time, posting latency |
| Service/CRM | Customer/account workflow success rate and API latency |
| Document | Upload/search success rate and latency |
| Warehouse | ETL freshness and report availability |
| Replication | Apply lag or data freshness within agreed RPO |
| Database platform | PostgreSQL availability, connection saturation, lock wait budget |
| Backup/restore | Backup success and restore validation freshness |

## Example Grafana SQL Panels

Active non-idle sessions by application:

```sql
select
  application_name,
  datname,
  state,
  count(*) as sessions
from pg_stat_activity
where state <> 'idle'
group by application_name, datname, state
order by sessions desc;
```

Blocked sessions:

```sql
select
  blocked.pid as blocked_pid,
  blocked.application_name as blocked_app,
  blocked.datname,
  now() - blocked.query_start as blocked_age,
  blocker.pid as blocker_pid,
  blocker.application_name as blocker_app,
  now() - blocker.query_start as blocker_age,
  left(blocked.query, 200) as blocked_query,
  left(blocker.query, 200) as blocker_query
from pg_stat_activity blocked
join pg_locks blocked_locks on blocked_locks.pid = blocked.pid
join pg_locks blocker_locks
  on blocker_locks.locktype = blocked_locks.locktype
 and blocker_locks.database is not distinct from blocked_locks.database
 and blocker_locks.relation is not distinct from blocked_locks.relation
 and blocker_locks.page is not distinct from blocked_locks.page
 and blocker_locks.tuple is not distinct from blocked_locks.tuple
 and blocker_locks.virtualxid is not distinct from blocked_locks.virtualxid
 and blocker_locks.transactionid is not distinct from blocked_locks.transactionid
 and blocker_locks.classid is not distinct from blocked_locks.classid
 and blocker_locks.objid is not distinct from blocked_locks.objid
 and blocker_locks.objsubid is not distinct from blocked_locks.objsubid
 and blocker_locks.pid <> blocked_locks.pid
join pg_stat_activity blocker on blocker.pid = blocker_locks.pid
where not blocked_locks.granted
  and blocker_locks.granted
order by blocked_age desc;
```

Top table growth and churn:

```sql
select
  current_database() as database_name,
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  n_live_tup,
  n_dead_tup,
  n_tup_ins,
  n_tup_upd,
  n_tup_del,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
order by pg_total_relation_size(relid) desc
limit 50;
```

Logical slot WAL retained:

```sql
select
  slot_name,
  database,
  active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal,
  restart_lsn,
  confirmed_flush_lsn
from pg_replication_slots
order by pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) desc;
```

## Example Prometheus / Grafana Panels

Metric names depend on the selected exporters, but the dashboard intent should stay consistent.

| Panel | Metric intent |
|---|---|
| PostgreSQL connections | active connections by database/user/application |
| PostgreSQL database size | size bytes by database |
| PostgreSQL cache hit ratio | block hits vs reads |
| Replication slot retained WAL | retained WAL bytes by slot |
| Long transactions | transaction age by database/application |
| Kubernetes pod restarts | restart count by PostgreSQL pod |
| PVC usage | used bytes and percent by volume |
| Node CPU/memory | node saturation from existing Zabbix or Prometheus metrics |
| App RED metrics | request rate, error rate, duration by service/endpoint |
| Business backlog | unposted transactions, failed warehouse records, job queue backlog |

## Governance And Dashboard Ownership

- Each dashboard must have an owner: DBA, platform, API gateway, service, TPS, warehouse, or management.
- Each alert must have an owner, severity, threshold, runbook, and escalation path.
- Thresholds must be reviewed after collecting real baseline data.
- Management dashboards should show business impact, not raw database internals.
- DBA dashboards should keep raw internals and direct SQL investigation links.
- Application dashboards should show the database symptoms that the team can act on.
- Zabbix alerts should be mapped into Grafana folders so the same incident view shows infrastructure and database evidence together.
- Any panel using SQL against production must be read-only, bounded, indexed, and reviewed before deployment.

## Recommended Dashboards

Create dashboards in folders by audience and app domain:

| Folder | Dashboard | Panels |
|---|---|---|
| Management | Command Center | SLO, incidents, capacity runway, backup, business impact |
| Application Teams | API Gateway | login audit growth, active sessions, slow login queries, login SLA |
| Application Teams | CRM / Service | dead tuples, top table growth, idle transactions, jobrunr/kafka tables |
| Application Teams | TPS | top TPS table size, transaction backlog, missing-index candidates, long queries |
| Application Teams | Warehouse | ETL freshness, failed records, long reporting queries, temp usage |
| DBA | PostgreSQL Reliability | sessions, locks, waits, queries, autovacuum, WAL, checkpoints |
| DBA | Replication | slot active status, retained WAL, walsender sessions, apply lag |
| Platform | Kubernetes / Patroni | leader, replica, pod, PVC, backup, PGO status |
| Integration | Cross-Service Flow | service to common, service to TPS, TPS to warehouse, lag/error view |
| WB UI / Console | Embedded Health | selected DB/app panels prepared for iframe or API consumption |

## Priority Actions

1. Build the DBA PostgreSQL Reliability dashboard first because it provides the foundation for every application incident.
2. Connect existing Zabbix signals into Grafana so management sees infrastructure and database symptoms in one place.
3. Build alert for `idle in transaction` over an agreed threshold.
4. Build alert for logical slot retained WAL growth.
5. Review top missing FK child indexes on large TPS tables.
6. Review autovacuum behavior on CRM/service tables with high dead tuple percentages.
7. Review huge zero-scan indexes over a full workload cycle.
8. Plan partitioning review for very large TPS and warehouse tables.
9. Standardize `application_name`, correlation ID, service labels, and region labels across application teams.
10. Build the Management Command Center after baseline thresholds are agreed with application owners.
11. Prepare WB UI and database console deep links using Grafana dashboard variables.
12. Add banking-core panels for posted vs unposted transactions, failed transaction rate, and oldest unposted transaction age.
13. Add reconciliation panels for TPS-to-warehouse freshness and failed warehouse records.
14. Add audit/control panels for login audit growth, reference data changes, backup freshness, and restore validation.
15. Define P1/P2 banking-impact rules with application owners, DBA, security, and management.
