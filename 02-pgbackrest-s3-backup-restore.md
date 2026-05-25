# pgBackRest, S3, Backup, Restore, and PITR

Capture time: 2026-05-22 09:27 CEST.

## Repository Identity

| Item | Value |
|---|---|
| Stanza | `db` |
| Repo name | `repo1` |
| CLI repo number | `--repo=1` |
| Repo type | `s3` |
| Repo path | `/pgbackrest/repo1` |
| S3 bucket | `pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e` |
| S3 endpoint | `s3-openshift-storage.apps.ocp-prod.habibbank.local` |
| S3 region | `prod` |
| S3 URI style | `path` |
| TLS verification | `repo1-s3-verify-tls=n` |
| Cipher | `aes-256-cbc` |
| Compression | `lz4`, level `3` |
| Process max | `8` |
| Archive async | `y` |
| Spool path | `/pgdata/pgbackrest-spool` |
| Main Secret | `prod-pgcluster-uae-pgbackrest-secret` |
| Operator TLS Secret | `prod-pgcluster-uae-pgbackrest` |
| ConfigMap | `prod-pgcluster-uae-pgbackrest-config` |

The extracted live pgBackRest config is saved in `configs/prod-pgbackrest-config.md`.

## Backup Schedules And Retention

| Backup type | Schedule |
|---|---|
| Full | `0 1 * * 0` |
| Differential | `0 1 * * 1-6` |
| Incremental | `0 */6 * * *` |

Retention:

```text
repo1-retention-full=4
repo1-retention-full-type=count
repo1-retention-diff=7
```

## Live pgBackRest Status At Capture

Command:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info --output=json
```

Summary:

```text
stanza=db
status=ok
cipher=aes-256-cbc
backup_count=35
wal_min=000000010000000000000001
wal_max=000000080000000300000027
```

Latest five listed successful backups:

```text
20260517-010001F_20260520-180001I  incr  2026-05-20T18:00:01Z  2026-05-20T18:00:03Z
20260517-010001F_20260521-000001I  incr  2026-05-21T00:00:01Z  2026-05-21T00:00:03Z
20260517-010001F_20260521-010001D  diff  2026-05-21T01:00:01Z  2026-05-21T01:00:03Z
20260517-010001F_20260521-060001I  incr  2026-05-21T06:00:01Z  2026-05-21T06:00:02Z
20260517-010001F_20260521-120001I  incr  2026-05-21T12:00:01Z  2026-05-21T12:00:03Z
```

Important: `pgbackrest info status=ok` means the repository and retained backup metadata are readable. It does not prove the latest scheduled CronJob succeeded. Always check `oc get cronjobs,jobs`.

## WAL Archiving Status At Capture

Command:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -A -F '|' -c \
  "SELECT archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time, stats_reset FROM pg_stat_archiver;"
```

Captured output:

```text
archived_count=704
last_archived_wal=000000080000000300000027
last_archived_time=2026-05-22 07:22:28.128142+00
failed_count=212
last_failed_wal=000000040000000000000072
last_failed_time=2026-05-18 10:24:14.098124+00
stats_reset=2026-05-12 11:34:41.842963+00
```

The failure counter is historical. During a real incident, sample it twice 60 seconds apart to prove it is not increasing.

## Scheduled Backup Jobs At Capture

```text
cronjob/prod-pgcluster-uae-repo1-full   0 1 * * 0      last schedule 5d6h
cronjob/prod-pgcluster-uae-repo1-diff   0 1 * * 1-6    last schedule 6h24m
cronjob/prod-pgcluster-uae-repo1-incr   0 */6 * * *    last schedule 84m
```

Failed jobs visible at capture:

```text
job.batch/prod-pgcluster-uae-repo1-diff-29656860  Failed
job.batch/prod-pgcluster-uae-repo1-incr-29657160  Failed
```

The incremental failed job had 7 failed pods and hit `BackoffLimitExceeded`. Pods were already gone when `oc logs job.batch/...` was attempted, so use `oc describe job` and check new job pods immediately if this repeats.

## Standard Health Commands

```bash
oc get cronjobs,jobs -n prod-pgcluster-uae

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 check

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -XAtc "select archived_count,last_archived_wal,last_archived_time,failed_count,last_failed_wal,last_failed_time from pg_stat_archiver;"
```

Show concise backup inventory:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info --output=json | \
  jq -r '.[0].backup | sort_by(.timestamp.start) | .[-10:][] | [.label, .type, (.timestamp.start|todate), (.timestamp.stop|todate), .archive.start, .archive.stop] | @tsv'
```

## Manual Backup Commands

Use only in an approved change/operations window. These read data and write backup objects to S3.

```bash
# Full backup
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 backup --type=full

# Differential backup
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 backup --type=diff

# Incremental backup
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 backup --type=incr
```

## WAL Archive Readiness Test

The validated 2026-05-21 SOP is:

```text
/home/mohsinali@habibbank.local/PROD_PATRONI/SOP_PROD_PGBACKREST_WAL_ARCHIVE_PITR_READINESS.md
```

Summary from that run:

```text
Result: PASS
archive_mode=on
archive_command=pgbackrest --stanza=db archive-push "%p"
wal_level=logical
WAL archive max advanced after pg_switch_wal()
Patroni sync standby stayed streaming with lag 0
```

`pg_switch_wal()` is non-destructive but state-changing. Use only when approved:

```bash
oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -A -F '|' -c "SELECT now() AS switch_time, pg_switch_wal() AS switched_at_lsn;"
```

## PITR Validation Summary

The validated 2026-05-21 PITR SOP is:

```text
/home/mohsinali@habibbank.local/PROD_PATRONI/SOP_PROD_PGBACKREST_PITR_VALIDATION.md
```

Validated result:

```text
Result: PASS
Temporary clone cluster: pitr-clone-20260521
Run ID: PITR_TEST_20260521_093616
PITR target time: 2026-05-21 07:37:42.809448+00
Restored service/common/tps/tps_dw marker table rows: 5 each
Clone timeline: 9
Clone became writable leader
```

Working manifest and artifacts:

```text
/home/mohsinali@habibbank.local/PROD_PATRONI/pitr_validation_runs/20260521_093616/pitr-clone-20260521.yaml
/home/mohsinali@habibbank.local/PROD_PATRONI/pitr_validation_runs/20260521_093616/pitr-restore-20260521.yaml
/home/mohsinali@habibbank.local/PROD_PATRONI/pitr_validation_runs/20260521_093616/
```

Critical PITR lessons from the validated run:

- Clone manifests must include `backups.pgbackrest`.
- Do not add `--target-action=promote`; PGO handles this when a target is used.
- Quote the target timestamp in YAML.
- Use a clone-specific backup repo path, for example:

```yaml
repo1-path: /pgbackrest/pitr-clone-20260521/repo1
```

## Temporary Restore Pattern

Do not restore over the live production cluster. Restore into a temporary isolated `PostgresCluster`, validate, export what is needed, then remove temporary objects after approval.

High-level flow:

```text
1. Confirm PROD Patroni and pgBackRest are healthy.
2. Prepare a temporary PostgresCluster manifest with dataSource/pgBackRest repo.
3. Use the same S3 bucket/endpoint and pgBackRest secret pattern.
4. Use a unique cluster name and clone-specific repo path for clone backup output.
5. Apply manifest.
6. Wait for restore job completion.
7. Confirm Patroni leader and pg_is_in_recovery=false for the clone.
8. Validate databases and row counts.
9. Dump or copy only approved data.
10. Delete temporary cluster after evidence is saved and approved.
```

## Backup Failure Triage

```bash
oc get cronjobs,jobs -n prod-pgcluster-uae
oc get pods -n prod-pgcluster-uae -o wide | grep -E 'repo1|pgbackrest'

oc describe job <failed-job-name> -n prod-pgcluster-uae
oc logs -n prod-pgcluster-uae job.batch/<failed-job-name> --tail=200

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c pgbackrest -- \
  pgbackrest --stanza=db --repo=1 info

oc exec -n prod-pgcluster-uae prod-pgcluster-uae-dc1-9c5j-0 -c database -- \
  psql -U postgres -XAtc "select archived_count,last_archived_wal,last_archived_time,failed_count,last_failed_wal,last_failed_time from pg_stat_archiver;"
```

If job pods are deleted before logs are collected, check the next CronJob run immediately or temporarily increase failed job retention through an approved operator change.
