# SOP Master Index — Habib Bank UAE Production PostgreSQL Platform

Created: 2026-05-23  
Based on live cluster capture: 2026-05-22  
Platform: PostgreSQL 18 · Crunchy PGO · Patroni · pgBackRest · PgBouncer · OpenShift

---

## Quick Reference

| Item | Value |
|---|---|
| PROD OCP API | `https://api.ocp-prod.habibbank.local:6443` |
| PROD namespace | `prod-pgcluster-uae` |
| PROD leader pod | `prod-pgcluster-uae-dc1-9c5j-0` |
| PROD sync standby | `prod-pgcluster-uae-dc1-5c2q-0` |
| PROD primary LB | `10.171.1.229:5555` |
| PROD PgBouncer LB | `10.171.1.205:5555` |
| pgBackRest stanza | `db`, repo `repo1` |
| DR namespace | `dr-pgcluster-uae` |
| Working directory | `/home/mohsinali@habibbank.local/PROD_PATRONI` |

---

## Document Map

| Document | Format | Purpose |
|---|---|---|
| [THEORY-00-architecture-and-theory.md](THEORY-00-architecture-and-theory.md) / [.docx](THEORY-00-architecture-and-theory.docx) | Theory | Full theoretical foundation: PostgreSQL 18, Patroni HA, PGO operator, pgBackRest, PgBouncer, DR streaming, monitoring, security |
| [SOP-01-daily-health-check.md](SOP-01-daily-health-check.md) / [.docx](SOP-01-daily-health-check.docx) | SOP | 12-step daily cluster health check with pass/fail criteria for every component |
| [SOP-02-backup-management-and-verification.md](SOP-02-backup-management-and-verification.md) / [.docx](SOP-02-backup-management-and-verification.docx) | SOP | Backup schedule verification, job failure triage, manual backup, WAL archive readiness test |
| [SOP-03-pitr-and-restore-procedure.md](SOP-03-pitr-and-restore-procedure.md) / [.docx](SOP-03-pitr-and-restore-procedure.docx) | SOP | Full PITR flow: temporary clone cluster, validated restore procedure, critical lessons from 2026-05-21 run |
| [SOP-04-dr-streaming-health-and-cutover.md](SOP-04-dr-streaming-health-and-cutover.md) / [.docx](SOP-04-dr-streaming-health-and-cutover.docx) | SOP | DR health checks, lag measurement, known blockers, planned switchover, disaster failover, switchback |
| [SOP-05-configuration-change-management.md](SOP-05-configuration-change-management.md) / [.docx](SOP-05-configuration-change-management.docx) | SOP | Safe CR patch pattern, parameter change classification, pgBackRest/PgBouncer config change, rollback |
| [SOP-06-incident-triage-and-escalation.md](SOP-06-incident-triage-and-escalation.md) / [.docx](SOP-06-incident-triage-and-escalation.docx) | SOP | Incident category decision trees (A–G), stop-and-escalate rules, evidence collection, escalation template |
| [SOP-07-replication-and-slots-management.md](SOP-07-replication-and-slots-management.md) / [.docx](SOP-07-replication-and-slots-management.docx) | SOP | Synchronous replication theory, lag thresholds, slot monitoring, WAL status progression, risk scenarios |
| [SOP-08-cluster-rebuild-and-manifest-recovery.md](SOP-08-cluster-rebuild-and-manifest-recovery.md) / [.docx](SOP-08-cluster-rebuild-and-manifest-recovery.docx) | SOP | Rebuild from manifest bundle, operator install, Secret recreation, S3 restore, post-rebuild validation |
| [SIMULATOR-cluster-operations.html](SIMULATOR-cluster-operations.html) | Simulator | Interactive HTML simulator: topology dashboard, scenario drills, command generator, decision tree navigator |

---

## Use-Case Lookup

| Situation | Go To |
|---|---|
| Starting shift — verify cluster is healthy | SOP-01 |
| Backup job showed Failed status | SOP-02 → Section: Backup Failure Triage |
| Need to restore data to a point in time | SOP-03 |
| DR streaming lag is high / DR API unreachable | SOP-04 |
| Changing a PostgreSQL parameter | SOP-05 |
| Application is alerting — unclear root cause | SOP-06 |
| Replication slot retaining excessive WAL | SOP-07 |
| Cluster needs to be rebuilt in new environment | SOP-08 |
| Need to understand why a config value is what it is | THEORY-00 |
| Want interactive guided commands and scenario drills | SIMULATOR |

---

## Safety Rules (Always Apply)

1. Verify OCP context before every command: `oc config current-context`
2. Use `oc`, not `kubectl`, for this OpenShift environment.
3. All persistent config changes go through `oc patch postgrescluster`. Do not use `patronictl edit-config`. Do not edit generated ConfigMaps.
4. Never decode or print Kubernetes Secret values into documentation or chat.
5. Never restore over the live production cluster. Always use a temporary isolated PostgresCluster for PITR.
6. Do not promote DR while PROD is still running or reachable as a writable primary (split-brain).
7. Do not drop replication slots, terminate sessions, delete pods/PVCs, or shut down the cluster without formal approval.
8. Always capture before-state evidence before any change.

---

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

Expected PROD context: `prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali`

---

## Source Files (Original Operational Docs)

| File | Purpose |
|---|---|
| `01-environment-overview.md` | PROD topology, pods, services, PVCs, key parameters |
| `02-pgbackrest-s3-backup-restore.md` | pgBackRest/S3 details, schedules, retention, PITR commands |
| `03-dc2-dr-streaming-and-cutover.md` | DR/DC2 standby design, cutover flow |
| `04-config-inventory-and-change-control.md` | ConfigMaps, Secret names, safe patch method |
| `05-terminal-troubleshooting-runbook.md` | Copy/paste terminal checks for all operational scenarios |
| `configs/` | Captured PROD pgBackRest, PgBouncer, Patroni, PostgresCluster configs |
| `manifests/` | Cluster manifest export/rebuild bundle |
| `scripts/export-prod-cluster-manifests.sh` | Read-only manifest exporter |
