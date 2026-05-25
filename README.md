# Production PostgreSQL Cluster Operations README

Created: 2026-05-22 09:27:02 CEST (+0200)

This folder is a terminal-first operations reference for the Habib Bank UAE production PostgreSQL platform. It is intended to be usable when Codex or any AI helper is not available.

No Kubernetes Secret values, passwords, private keys, or S3 access keys are decoded in these files. Secret object names are documented so an approved DBA can retrieve them from OpenShift when required.

## Folder Map

| File | Purpose |
|---|---|
| `01-environment-overview.md` | Current PROD topology, pods, services, PVCs, database inventory, users, key parameters |
| `02-pgbackrest-s3-backup-restore.md` | pgBackRest/S3 repository details, schedules, retention, live status, PITR and restore commands |
| `03-dc2-dr-streaming-and-cutover.md` | DR/DC2 standby streaming design, known DR blockers, planned switchover and disaster flow |
| `04-config-inventory-and-change-control.md` | ConfigMaps, Secret names, exported config references, safe patch method |
| `05-terminal-troubleshooting-runbook.md` | Copy/paste terminal checks for health, replication, pgBackRest, jobs, services, logs, DR |
| `manifests/README.md` | Cluster manifest export/rebuild bundle instructions |
| `local-kind/README.md` | Minimal macOS kind lab for PostgreSQL 18, Patroni, PGO, and PgBouncer |
| `LOCAL_METADATA_ENVIRONMENT.md` | Local metadata-only database environment and object inventory for troubleshooting |
| `INDEX_RECOMMENDATIONS.md` | Metadata-driven missing foreign-key child index analysis and validation SQL |
| `scripts/export-prod-cluster-manifests.sh` | Read-only exporter for PROD namespace manifests and rebuild evidence |
| `configs/prod-pgbackrest-config.md` | Captured PROD pgBackRest ConfigMap and instance config |
| `configs/prod-pgbouncer.ini` | Captured PROD PgBouncer operator config |
| `configs/prod-patroni.yaml` | Captured PROD Patroni operator config |
| `configs/prod-postgrescluster-summary.md` | Captured PROD PostgresCluster spec summary |
| `configs/dr-postgrescluster-summary-from-20260518.md` | Saved DR PostgresCluster spec summary from cutover precheck evidence |

## Critical Facts

| Item | Value |
|---|---|
| PROD OCP API | `https://api.ocp-prod.habibbank.local:6443` |
| PROD context | `prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali` |
| PROD namespace | `prod-pgcluster-uae` |
| PROD PostgresCluster | `prod-pgcluster-uae` |
| PROD Patroni cluster | `prod-pgcluster-uae-ha` |
| PostgreSQL | 18 |
| PostgreSQL port | `5555` |
| Live PROD leader at capture | `prod-pgcluster-uae-dc1-9c5j-0` |
| Live PROD sync standby at capture | `prod-pgcluster-uae-dc1-5c2q-0` |
| PROD primary LB | `10.171.1.229:5555` |
| PROD PgBouncer LB | `10.171.1.205:5555` |
| pgBackRest stanza/repo | `db`, `repo1` / `--repo=1` |
| S3 bucket | `pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e` |
| S3 endpoint | `s3-openshift-storage.apps.ocp-prod.habibbank.local` |
| S3 region | `prod` |
| DR OCP API | `https://api.ocp-dr.habibbank.local:6443` |
| DR context | `dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali` |
| DR namespace | `dr-pgcluster-uae` |
| DR PostgresCluster | `dr-pgcluster-uae` |
| DR standby upstream | `10.171.1.229:5555`, repo `repo1` |

## First Commands In Any Incident

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI

oc config current-context
oc project

oc get pods -n prod-pgcluster-uae -o wide
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- patronictl list

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info
```

Expected PROD context:

```text
prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
```

## Current Known Items From 2026-05-22 Capture

- PROD API was reachable from this terminal.
- DR API timed out from this terminal even after an escalated read-only attempt:
  `dial tcp 10.20.115.14:6443: i/o timeout`.
- PROD Patroni was healthy: one leader and one synchronous standby, both timeline 8, lag 0.
- pgBackRest stanza `db` reported `status=ok`, cipher `aes-256-cbc`, backup count `35`.
- Latest listed successful pgBackRest backup was `20260517-010001F_20260521-120001I`.
- WAL archiving was current at capture: archive max `000000080000000300000027`, `last_archived_time=2026-05-22 07:22:28.128142+00`.
- Scheduled backup jobs on 2026-05-22 had failures:
  `prod-pgcluster-uae-repo1-diff-29656860` and `prod-pgcluster-uae-repo1-incr-29657160`.
- `prod-pg-inspector-object-metrics` jobs were failing with HTTP 400 from the Pushgateway.
- Live database inventory shows the restored UAT payload databases from the 2026-05-21 logical restore, while the PostgresCluster user spec still defines the original app users for `service`, `common`, `tps`, and `tps_dw`.

## Safety Rules

- Do not restart, shut down, promote, delete pods/PVCs, patch standby mode, or run destructive SQL without formal approval.
- Use `oc`, not plain `kubectl`, for this OpenShift environment.
- For persistent PostgreSQL config changes, patch the `PostgresCluster` CR. Do not use `patronictl edit-config`; the operator can overwrite it.
- Always verify context and namespace before every command.
- Always check Patroni and replication lag before and after any production change.
- Never paste decoded secret values into documentation, tickets, or chat.
- Manifest exports in `manifests/` intentionally contain Secret names/key names only. Recreate Secret values through an approved secure channel before building another cluster.

## Source Material Used

These docs were built from live read-only PROD checks on 2026-05-22 plus existing local evidence and SOP files:

- `/home/mohsinali@habibbank.local/PROD_PATRONI/ENVIRONMENT.md`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/PROD_DR_CUTOVER_SOP.md`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/dr_prod_replication_lag_check_commands.md`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/SOP_PROD_PGBACKREST_WAL_ARCHIVE_PITR_READINESS.md`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/SOP_PROD_PGBACKREST_PITR_VALIDATION.md`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/SOP_PROD_LOGICAL_RESTORE_FROM_UAT.md`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/cutover_runs/20260518_130639_planned-switchover_precheck/`
- `/home/mohsinali@habibbank.local/PROD_PATRONI/pitr_validation_runs/20260521_093616/`
