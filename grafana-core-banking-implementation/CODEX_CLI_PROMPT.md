# Codex CLI Prompt

You are Codex CLI working inside a repository that contains a PostgreSQL core banking operations documentation bundle.

Your task is to implement a comprehensive Grafana monitoring package for a regional core banking PostgreSQL estate.

Read `IMPLEMENT.md` first. Then read these included files:

1. `APPLICATION_TEAM_MONITORING.md`
2. `PERFORMANCE_TROUBLESHOOTING_RECOMMENDATIONS.md`
3. `INDEX_RECOMMENDATIONS.md`
4. `LOCAL_METADATA_ENVIRONMENT.md`
5. `README.md`

Important context:

- This is a banking core application database estate.
- Regions are `ae`, `ch`, `sa`, and `uk`.
- Main database domains are API Gateway, Common/reference, Document, Service/CRM, TPS, and TPS Warehouse.
- The main dashboard must be business-aware, not only database-infrastructure focused.
- Zabbix already exists and should be integrated into Grafana instead of replaced immediately.
- Later, the dashboard should integrate with an existing WB UI three-tier application and database console.
- Security matters: avoid exposing PII, raw customer data, account-sensitive details, unrestricted audit data, or superuser credentials.

Implement the following deliverables.

## Deliverables

Create a `grafana/` directory with:

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

## Dashboard Requirements

Build `core-banking-regional-operations.json` as the primary dashboard.

It must include rows for:

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

Use the exact SQL panels from `APPLICATION_TEAM_MONITORING.md`, section `Core Banking Grafana Dashboard SQL Pack`.

Where Grafana macros are used, preserve them:

- `$__timeFilter(column)`
- `$__timeFrom()`
- `$__timeTo()`

Dashboard variables must include:

- `environment`
- `region`
- `domain`
- `database`
- `schema`
- `table`
- `application`
- `team`
- `branch_id`
- `status`

## Data Sources

Provision placeholders for:

- PostgreSQL regional databases.
- Prometheus.
- Zabbix.
- Loki.

Do not hardcode real passwords. Use environment variables such as:

- `${GRAFANA_PG_MONITOR_USER}`
- `${GRAFANA_PG_MONITOR_PASSWORD}`
- `${GRAFANA_PROMETHEUS_URL}`
- `${GRAFANA_ZABBIX_URL}`
- `${GRAFANA_LOKI_URL}`

PostgreSQL datasource names should follow this pattern:

```text
pg-ae-api-gateway-uat
pg-ae-common-uat
pg-ae-document-uat
pg-ae-service-uat
pg-ae-tps-uat
pg-ae-tps-warehouse-uat
```

Repeat the pattern for `ch`, `sa`, and `uk` where databases exist.

## SQL Requirements

Create SQL scripts that:

1. Create a read-only Grafana monitoring role.
2. Create a `monitoring` schema.
3. Create safe views where useful.
4. Grant minimal select permissions.
5. Set a safe `statement_timeout` for the monitoring role.

Do not grant superuser.
Do not grant write permissions.
Do not expose PII in general-purpose views.

## Alerts

Create alert rule templates for:

- Login status/failure spike.
- Unposted transaction backlog.
- Oldest unposted transaction age breach.
- Transaction references without ledger.
- Ledger rows without audit sequence.
- Warehouse failed records.
- Warehouse freshness.
- JobRunr failed/stuck jobs.
- Kafka recovery backlog.
- OTP failure spike.
- Idle-in-transaction sessions.
- Long blocking locks.
- Replication slot retained WAL.
- PVC/disk capacity.
- Backup freshness.

Mark thresholds as placeholders until production baselines are collected.

Severity mapping:

- `P1`: login unavailable, transaction posting unavailable, data integrity risk, ledger/audit write failure, primary DB unavailable.
- `P2`: TPS backlog growing, replication RPO breach, warehouse SLA missed, severe lock waits, reference-data control breach.
- `P3`: dead tuples, stale stats, index risk, moderate latency, ETL delay within tolerance.
- `P4`: hygiene, dashboard improvement, low-risk tuning, documentation.

## Runbooks

Create short runbooks for:

- Login unavailable.
- Transaction posting unavailable.
- Unposted transaction backlog.
- Replication retained WAL.
- Warehouse freshness breach.

Each runbook must include:

- Symptoms.
- Grafana panels to check.
- SQL evidence to capture.
- Application team owner.
- DBA/platform checks.
- Escalation path.
- Evidence required for audit/management.

## README

Create `grafana/README.md` with:

- How to configure environment variables.
- How to start Grafana locally if Docker Compose is available.
- How to import dashboards manually.
- How to provision dashboards automatically.
- How to connect Zabbix.
- How to use the dashboard variables.
- Production safety checklist.
- WB UI/database console integration plan.

## Quality Requirements

- Keep files human-readable.
- Use valid JSON for dashboards.
- Use valid YAML for provisioning and alert templates.
- Do not use real secrets.
- Do not overwrite unrelated user changes.
- If this repo already has a style or existing Grafana folder, follow it.
- Validate JSON/YAML syntax where possible.
- Summarize what was created and what still needs production credentials/baselines.

## Important

This is a banking monitoring implementation. Favor safety, auditability, least privilege, and clear ownership over speed.

Start by reading `IMPLEMENT.md`.
