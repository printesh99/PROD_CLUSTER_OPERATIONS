# Core Banking Grafana Implementation Note

This bundle is a handoff package for implementing a comprehensive Grafana monitoring solution for the regional core banking PostgreSQL estate.

Start here. Read this file first, then use the included source guides for detailed SQL, dashboard intent, and operational context.

## Objective

Build a Grafana monitoring layer for regional core banking operations that combines:

- Banking business health.
- Application team monitoring.
- PostgreSQL reliability.
- Patroni/Kubernetes platform health.
- Replication/WAL/backup status.
- Zabbix infrastructure signals.
- Future WB UI and database console integration.

This should not replace Zabbix immediately. Grafana should become the unified observability and management view while Zabbix remains an infrastructure source during migration.

## Included Files

| File | Purpose |
|---|---|
| `IMPLEMENT.md` | Implementation plan and acceptance criteria |
| `CODEX_CLI_PROMPT.md` | Strong prompt to give Codex CLI for implementation |
| `APPLICATION_TEAM_MONITORING.md` | Main monitoring guide with core banking dashboard SQL pack |
| `PERFORMANCE_TROUBLESHOOTING_RECOMMENDATIONS.md` | PostgreSQL performance troubleshooting recommendations |
| `INDEX_RECOMMENDATIONS.md` | Missing FK child index review candidates |
| `LOCAL_METADATA_ENVIRONMENT.md` | Local metadata-only environment and object inventory |
| `README.md` | Original repository map |

## Regional Database Pattern

Use the naming convention to drive dashboard variables and data sources.

| Domain | Regional databases |
|---|---|
| API Gateway | `ae_api_gateway_uat`, `sa_api_gateway_uat`, `uk_api_gateway_uat`; API tables also exist in `*_service_uat` |
| Common/reference | `ae_common_uat`, `ch_common_uat`, `sa_common_uat`, `uk_common_uat` |
| Document | `ae_document_uat`, `sa_document_uat`, `uk_document_uat`; `ch_document_uat` has no base tables in the imported report |
| Service/CRM | `ae_service_uat`, `ch_service_uat`, `sa_service_uat`, `uk_service_uat` |
| TPS | `ae_tps_uat`, `ch_tps_uat`, `sa_tps_uat`, `uk_tps_uat` |
| TPS Warehouse | `ae_tps_warehouse_uat`, `ch_tps_warehouse_uat`, `sa_tps_warehouse_uat`, `uk_tps_warehouse_uat` |

Primary regions:

- `ae`
- `ch`
- `sa`
- `uk`

## Implementation Strategy

### Phase 0: Safety And Access

1. Create a dedicated read-only monitoring user for Grafana.
2. Do not connect Grafana as `postgres`, application users, or superuser.
3. Grant only required `SELECT` permissions.
4. Avoid exposing PII, account-level customer data, raw audit payloads, or unrestricted ad hoc SQL to general users.
5. Use aggregate panels by region, service, branch, product, status, table, or anonymized identifier.
6. Use Grafana folder permissions: management, application teams, DBA, platform, security.

### Phase 1: Data Sources

Configure Grafana data sources:

- PostgreSQL data sources for each regional database or each domain/region group.
- Prometheus for PostgreSQL exporter, Kubernetes, Patroni, PgBouncer, node, and app metrics.
- Zabbix plugin to reuse current infrastructure monitoring.
- Loki for logs.
- Tempo or Jaeger for traces if OpenTelemetry exists.
- Alertmanager for alert routing and silencing.

Recommended PostgreSQL data source naming:

```text
pg-ae-api-gateway-uat
pg-ae-common-uat
pg-ae-document-uat
pg-ae-service-uat
pg-ae-tps-uat
pg-ae-tps-warehouse-uat
```

Repeat for `ch`, `sa`, and `uk` where the database exists.

### Phase 2: Dashboard Provisioning

Create Grafana folders:

- `Management`
- `Core Banking`
- `Application Teams`
- `DBA`
- `Platform`
- `Integration`
- `Security`
- `WB UI Embedded`

Create dashboards:

1. `Core Banking Regional Operations`
2. `Management Command Center`
3. `TPS Command Center`
4. `TPS Warehouse And Reconciliation`
5. `API Gateway And Login`
6. `Service CRM And Customer Operations`
7. `Common Reference Data Controls`
8. `Document And Statement Access`
9. `DBA PostgreSQL Reliability`
10. `Replication WAL And Patroni`
11. `Kubernetes PostgreSQL Platform`
12. `WB UI Embedded Database Health`

Use the SQL pack in `APPLICATION_TEAM_MONITORING.md` as the source for PostgreSQL panels.

### Phase 3: Core Banking Dashboard Rows

Build the `Core Banking Regional Operations` dashboard with these rows:

1. Executive Banking Health
2. Customer Login And Access
3. TPS Transaction Posting
4. Account And Customer Risk
5. Warehouse And Reconciliation
6. Service Jobs And Integration Backlog
7. Maker-Checker, Audit, And Reference Controls
8. Document And Statement Access
9. OTP, Mobile, Locker, And Charge
10. Database Reliability For Banking Incidents

Required variables:

- `$environment`
- `$region`
- `$domain`
- `$database`
- `$schema`
- `$table`
- `$application`
- `$team`
- `$branch_id`
- `$status`
- `$time_window`

### Phase 4: Alerts

Start with these high-value alerts:

- Login failure/status spike.
- Active session spike.
- Unposted transaction backlog.
- Oldest unposted transaction age breach.
- Transaction references without ledger rows.
- Ledger rows without audit sequence.
- Warehouse failed records increasing.
- Warehouse data freshness breach.
- JobRunr failed/stuck jobs.
- Kafka recovery outstanding records.
- Reference/config changes during freeze window.
- OTP failure spike.
- Idle-in-transaction sessions.
- Long blocking locks.
- Replication slot retained WAL growth.
- PVC/disk capacity runway.
- Backup stale or failed.
- Restore validation stale.

Severity mapping:

| Severity | Banking interpretation |
|---|---|
| `P1` | Login unavailable, transaction posting unavailable, data integrity risk, ledger/audit write failure, primary database unavailable |
| `P2` | TPS backlog growing, replication RPO breach, warehouse reporting SLA missed, severe lock waits, reference data control breach |
| `P3` | Dead tuples, stale stats, index risk, moderate latency, ETL delay within tolerance, growing but controlled capacity risk |
| `P4` | Hygiene, dashboard improvement, low-risk tuning, documentation, non-urgent capacity review |

### Phase 5: WB UI And Database Console Integration

Use Grafana as the observability backend for WB UI and the database console.

Implementation sequence:

1. Add dashboard deep links with variables and time ranges.
2. Embed safe Grafana panels for DB health, active sessions, locks, table growth, TPS backlog, and warehouse freshness.
3. Use Grafana or Prometheus APIs to show health cards in WB UI.
4. Build incident workspace links to Grafana, logs, traces, SQL evidence, and deployment/change records.
5. Restrict raw drilldown to DBA/security roles.

## Recommended Repository Output

If implementing inside this repository, create:

```text
grafana/
  README.md
  provisioning/
    datasources/
      postgres-datasources.yaml
      prometheus-datasource.yaml
      zabbix-datasource.yaml
      loki-datasource.yaml
    dashboards/
      dashboard-providers.yaml
  dashboards/
    core-banking-regional-operations.json
    management-command-center.json
    dba-postgresql-reliability.json
    tps-command-center.json
    tps-warehouse-reconciliation.json
    api-gateway-login.json
    service-crm-operations.json
    common-reference-controls.json
    document-statement-access.json
    replication-wal-patroni.json
  sql/
    00-create-monitoring-role.sql
    01-monitoring-schema.sql
    02-monitoring-views.sql
    03-grants.sql
  alerts/
    core-banking-alert-rules.yaml
  runbooks/
    p1-login-unavailable.md
    p1-transaction-posting-unavailable.md
    p2-unposted-backlog.md
    p2-replication-wal-retention.md
    p2-warehouse-freshness.md
```

## Acceptance Criteria

The implementation is acceptable when:

1. Grafana can be started locally or deployed to Kubernetes from documented commands.
2. PostgreSQL data sources are provisioned without using superuser credentials.
3. The `Core Banking Regional Operations` dashboard imports successfully.
4. Dashboard variables support region/domain/database filtering.
5. SQL panels are based on actual imported table structure.
6. At least one dashboard row exists for each core banking area listed above.
7. Alerts are defined but thresholds are clearly marked as baseline-dependent.
8. Zabbix integration path is documented.
9. WB UI/database console integration path is documented.
10. Security notes explicitly prevent broad PII exposure.

## Production Safety Checklist

Before production use:

- Review every SQL panel with DBA.
- Ensure every Grafana database user is read-only.
- Test panel query cost with `EXPLAIN`.
- Add statement timeouts for Grafana users.
- Restrict panel visibility by folder permissions.
- Disable ad hoc query editing for non-DBA users.
- Use secrets management for datasource passwords.
- Confirm audit and compliance signoff for any security dashboards.
- Baseline every threshold before alerting management.
- Test alert routing, silence windows, and escalation.

## First Codex Task

Give Codex CLI the contents of `CODEX_CLI_PROMPT.md`.

Tell it to read this `IMPLEMENT.md` file first and then implement the Grafana monitoring package step by step.
