# SOP-02: Backup Management and Verification
## Habib Bank UAE Production PostgreSQL Cluster

**Document ID:** SOP-02  
**Version:** 1.0  
**Effective Date:** 2026-05-22  
**Author:** DBA Operations Team  
**Cluster:** prod-pgcluster-uae  
**pgBackRest Stanza:** db / repo1 (S3)  

---

## 1. Purpose

This SOP defines the procedures for verifying, triaging, and (where approved) manually executing pgBackRest backups for the Habib Bank UAE production PostgreSQL cluster. It also documents the known backup failures observed on 2026-05-22 and the triage path for resolving them.

---

## 2. Theoretical Background: pgBackRest Backup Architecture

pgBackRest operates on a chain model. A full backup creates a complete physical copy of the PostgreSQL data directory, encrypted with AES-256-CBC and compressed with LZ4, stored in the S3 repository at `pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e`. All subsequent differential and incremental backups reference the most recent full backup as their base.

**A critical distinction:** `pgbackrest info` reports whether the stored backup objects are intact in S3 and whether the backup chain is logically consistent. It does NOT tell you whether the most recent backup job succeeded. A status of `ok` from `pgbackrest info` means the existing backup objects are valid — it does not mean the scheduled backup that ran last night completed successfully. The backup job in Kubernetes (the CronJob and its resulting Job pod) must be checked independently through `oc get jobs` to know whether the most recent scheduled run succeeded or failed.

As of 2026-05-22, the latest backup label was `20260517-010001F_20260521-120001I`. This label encodes: the full backup was taken on 2026-05-17 at 01:00:01 UTC (the `F` suffix), and the most recent incremental in the chain was taken on 2026-05-21 at 12:00:01 UTC (the `I` suffix). The chain is intact for PITR purposes — but the differential job scheduled for 2026-05-22 and the incremental job scheduled for 2026-05-22 both failed, meaning the PITR coverage gap is growing from 2026-05-21 12:00 UTC onward.

WAL archiving provides continuous coverage between backups. As long as the WAL archiver is functioning, point-in-time recovery to any second since the last successful backup is possible. If both the backup jobs AND the WAL archiver are failing simultaneously, the RPO window is the timestamp of the last successful backup.

---

## 3. Backup Schedule Reference

| Job Name Pattern | Type | Cron Schedule | Window |
|---|---|---|---|
| `*-repo1-full-*` | Full | `0 1 * * 0` — Sunday 01:00 UTC | ~2–4 hours |
| `*-repo1-diff-*` | Differential | `0 1 * * 1-6` — Mon–Sat 01:00 UTC | ~30–90 minutes |
| `*-repo1-incr-*` | Incremental | `0 */6 * * *` — Every 6 hours | ~5–20 minutes |

**Retention policy:**

| Type | Retention |
|---|---|
| Full backups | 4 (approximately 4 weeks) |
| Differential backups | 7 |
| Incremental backups | Managed by the diff/full chain they depend on |

pgBackRest S3 settings: endpoint `s3-openshift-storage.apps.ocp-prod.habibbank.local`, region `prod`, cipher `aes-256-cbc`, compression `lz4`, `process-max=8`, `archive-async=y`.

---

## 4. Daily Backup Verification Procedure

**4.1 Check CronJob and Job Status**

```bash
# List CronJobs and their last schedule times
oc get cronjobs -n prod-pgcluster-uae

# List all recent backup Jobs (completed and failed)
oc get jobs -n prod-pgcluster-uae --sort-by=.metadata.creationTimestamp

# Look for failed jobs specifically
oc get jobs -n prod-pgcluster-uae \
  -o jsonpath='{range .items[?(@.status.failed>0)]}{.metadata.name}{" failed="}{.status.failed}{" conditions="}{.status.conditions[*].reason}{"\n"}{end}'
```

**4.2 Verify Latest Backup Label and Timestamp**

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 info --output=text
```

Parse the output and record:
- The label of the most recent backup (full, diff, or incr)
- The `timestamp stop` field (when the backup completed)
- The `status` field (`ok` or `error`)

The most recent backup label timestamp must be within the expected window for the current schedule. If it is more than 7 hours old and no incr job is currently running, the incremental schedule is failing silently.

**4.3 WAL Archiver Sampling**

Run the following query twice, 60 seconds apart, and compare results:

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT archived_count, failed_count, last_archived_time,
       now() - last_archived_time AS age
FROM pg_stat_archiver;
"
```

If `archived_count` increased and `failed_count` did not increase, the archiver is healthy. If `failed_count` increased, the archiver is currently failing — proceed to Section 6 of this document.

**4.4 pgBackRest Info and Check**

```bash
# Full stanza info
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 info

# Connectivity and archive check (will produce output on success or failure)
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 check
```

**Daily Verification Pass Criteria:**

| Check | Pass Condition |
|---|---|
| No jobs with `BackoffLimitExceeded` in last 24h | Yes |
| Latest backup label within expected schedule window | Yes |
| WAL archiver `failed_count` not increasing | Yes |
| `pgbackrest info` shows `status: ok` | Yes |
| `pgbackrest check` exits 0 | Yes |

---

## 5. Backup Failure Triage

**5.1 Understanding BackoffLimitExceeded**

When a Kubernetes Job reaches `BackoffLimitExceeded`, it means the job tried to run its pod the maximum number of times allowed (default is 6 retries for pgBackRest jobs) and each attempt failed. The Job itself is then marked as failed and will not retry again automatically. The CronJob will create a new Job at the next scheduled time — it does not re-run the failed Job.

The danger with `BackoffLimitExceeded` is that the failed Job's pods are eventually garbage-collected by Kubernetes. Once the pods are gone, the logs are gone. You must collect logs promptly after a failure is detected.

**5.2 Collecting Logs from a Failed Backup Job**

```bash
# Step 1: Identify the failed job name
oc get jobs -n prod-pgcluster-uae | grep -E 'repo1-(diff|incr|full)'

# Step 2: List the pods associated with the failed job
oc get pods -n prod-pgcluster-uae \
  --selector=job-name=<failed-job-name> \
  --show-all 2>/dev/null || \
oc get pods -n prod-pgcluster-uae | grep <short-job-name>

# Step 3: Collect logs from each failed pod attempt (including previous)
oc logs <failed-pod-name> -n prod-pgcluster-uae
oc logs <failed-pod-name> -n prod-pgcluster-uae --previous 2>/dev/null

# Step 4: Describe the job for condition details
oc describe job <failed-job-name> -n prod-pgcluster-uae
```

As of 2026-05-22, jobs `prod-pgcluster-uae-repo1-diff-29656860` and `prod-pgcluster-uae-repo1-incr-29657160` had both reached `BackoffLimitExceeded`. The diff job is from the Mon–Sat 01:00 schedule; the incr job is from the 6-hour schedule. Both failing simultaneously suggests a common underlying cause rather than a job-specific issue (likely S3 connectivity, credential rotation, or a lock/stale process issue in the pgBackRest repository).

**5.3 S3 Connectivity Test from pgBackRest Container**

If logs show S3 or network errors, test connectivity directly from within the database pod:

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- bash -c "
# Test TCP connectivity to S3 endpoint
timeout 5 bash -c 'echo > /dev/tcp/s3-openshift-storage.apps.ocp-prod.habibbank.local/443' \
  && echo 'S3_REACHABLE' || echo 'S3_UNREACHABLE'
"

# If OpenSSL is available, test TLS handshake:
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- bash -c "
timeout 5 openssl s_client -connect \
  s3-openshift-storage.apps.ocp-prod.habibbank.local:443 \
  -verify_quiet -brief 2>&1 | head -5
"
```

**5.4 Distinguishing WAL Archive Failures from Backup Failures**

These are two independent failure modes that can occur together or separately:

| Failure Type | Symptom | Impact |
|---|---|---|
| WAL archive failure | `failed_count` increasing in `pg_stat_archiver` | PITR coverage degrading; oldest recov point is the last backup |
| Backup job failure | Job `BackoffLimitExceeded` in `oc get jobs` | No new backup taken; existing backups still usable |
| Both failing | Both symptoms present | RPO window is the last successful backup timestamp |

WAL archive failures may produce `archive_status` entries in the PostgreSQL data directory. The pgBackRest `archive-async=y` setting means WAL files are queued locally and pushed to S3 asynchronously — if S3 is unreachable, the local queue will grow. Once S3 is restored, the archiver will replay the queue automatically.

---

## 6. Manual Backup Commands

Manual backups require an approved change request before execution in production. Do not run manual backups without documented approval except in emergency data-loss scenarios, in which case the incident commander must be notified.

```bash
# Manual full backup (requires CAB approval)
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 --type=full backup

# Manual differential backup (requires DBA Lead approval)
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 --type=diff backup

# Manual incremental backup (requires DBA Lead approval)
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 --type=incr backup
```

After any manual backup, re-run `pgbackrest --stanza=db --repo=1 info` to confirm the new backup label appears and `status: ok` is maintained. Record the backup label, start time, stop time, and approver name in the operations log.

---

## 7. WAL Archive Readiness Test (pg_switch_wal)

This test forces a WAL segment switch to verify the archiver can deliver a segment to S3 end-to-end. It requires DBA Lead approval because it generates additional WAL and briefly increases write I/O.

```bash
# Step 1: Note current WAL file
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "SELECT pg_walfile_name(pg_current_wal_lsn());"

# Step 2: Force a WAL switch (APPROVAL REQUIRED)
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "SELECT pg_switch_wal();"

# Step 3: Within 60 seconds, check that last_archived_wal updated
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT last_archived_wal, last_archived_time, failed_count
FROM pg_stat_archiver;
"
```

If `last_archived_wal` shows the newly switched file within 60 seconds, the archiver is working end-to-end. If it does not appear within 120 seconds, or if `failed_count` increased, the archiver is failing and the incident must be escalated.

---

## 8. pgBackRest Check Command Interpretation

The `pgbackrest check` command verifies three things: (1) it can connect to the PostgreSQL instance, (2) it can write to the S3 repository, and (3) the WAL archive path is accessible and a test segment can be archived. If any of these fail, the command exits non-zero and prints a descriptive error.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 check --log-level-console=detail
```

Common error patterns and their meaning:

| Error Pattern | Likely Cause |
|---|---|
| `unable to connect to 's3'` | S3 endpoint unreachable or TLS issue |
| `archive_status: failed` | WAL archiver cannot deliver to S3 |
| `authentication failed` | S3 credentials rotated or expired |
| `lock file exists` | A previous backup process did not clean up; may need manual lock removal |
| `stanza-create` required | Repository was wiped or new stanza setup needed (ESCALATE — do not run stanza-create without DBA Lead) |

---

## 9. Backup Retention Verification

Verify that the retention policy is being applied correctly and that old backups are being pruned.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pgbackrest --stanza=db --repo=1 info | grep -E 'full backup|diff backup|incr backup|label|timestamp'
```

The expected retention state:
- Maximum 4 full backups present. If more than 4 appear, pruning may have failed.
- Maximum 7 differential backups present across the retained full backup chain.
- Incremental backups for the current diff/full chain only.

As of 2026-05-22, 35 backups were present with status `ok`. If the backup count grows unusually large (e.g., > 50 with normal schedule), investigate whether retention pruning is being skipped.

---

## 10. Known Issues at Capture (2026-05-22)

The following issues were active at the time of this document's baseline capture and must be tracked to resolution:

**Issue 1: Differential backup job failed — BackoffLimitExceeded**
Job `prod-pgcluster-uae-repo1-diff-29656860` reached BackoffLimitExceeded. The differential was scheduled for Mon–Sat 01:00 UTC. This job will not retry; the next diff run will be on the following scheduled date. Until resolved, the incremental backups are the only scheduled jobs extending coverage.

**Issue 2: Incremental backup job failed — BackoffLimitExceeded**
Job `prod-pgcluster-uae-repo1-incr-29657160` also reached BackoffLimitExceeded. Incremental backups run every 6 hours. Both the diff and incr failing simultaneously strongly suggests a shared infrastructure failure (S3 connectivity, credential issue, or pgBackRest lock file), not a job-specific configuration problem.

**Action Required:** Collect logs from both failed job pods before they are garbage-collected. Test S3 connectivity. Review pgBackRest logs on the database pod. Identify and resolve the root cause before the next scheduled run. Escalate to DBA Lead if the root cause cannot be identified within 2 hours.

**Historical WAL archive failures:** The `pg_stat_archiver` `failed_count` of 212 represents historical failures from a prior period. This count does not reset between restarts. It is not a current alarm indicator, but the trend must be monitored (see Section 4.3 sampling method).

---

## 11. Escalation Criteria

Escalate immediately to the DBA Lead if any of the following conditions are observed:

| Condition | Action |
|---|---|
| `pgbackrest info` shows `status: error` | Immediate escalation |
| WAL `failed_count` increasing for > 30 minutes | Immediate escalation |
| Backup job has been failing for > 24 hours | Escalate within 2 hours of detection |
| `pgbackrest check` fails | Escalate immediately |
| Latest successful backup older than 26 hours | Escalate to DBA Lead and InfoSec |
| S3 endpoint unreachable | Escalate to Infrastructure team |
| pgBackRest lock file blocking all backups | DBA Lead approval required before removing lock |

