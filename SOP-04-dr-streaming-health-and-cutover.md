# SOP-04: DR Streaming Health and Cutover
## Habib Bank UAE Production PostgreSQL Cluster

**Document ID:** SOP-04  
**Version:** 1.0  
**Effective Date:** 2026-05-22  
**Author:** DBA Operations Team  
**PROD Cluster:** prod-pgcluster-uae / api-ocp-prod-habibbank-local:6443  
**DR Cluster:** dr-pgcluster-uae / api-ocp-dr-habibbank-local:6443  

---

## 1. Purpose

This SOP defines the procedures for monitoring the Habib Bank UAE DR (Disaster Recovery) PostgreSQL cluster's streaming replication health, performing PROD-to-DR lag measurement, executing a planned switchover, and responding to a disaster failover scenario. It also documents all known blockers that were present at the time of the 2026-05-22 baseline capture and must be resolved before a planned switchover can proceed.

---

## 2. Theoretical Background: PGO Standby Cluster Mode

Crunchy Data PGO supports a standby cluster mode in which a secondary PostgresCluster CR continuously streams WAL from an upstream primary cluster. The standby cluster is configured with `spec.standby.enabled=true` and a `primary_conninfo` connection string pointing to the upstream primary's LoadBalancer IP and port.

In standby mode, the DR cluster's Patroni leader is in `standby_leader` mode — it is a PostgreSQL instance in continuous recovery, replaying WAL from the primary's streaming replication feed. Unlike a regular PostgreSQL hot standby that promotes instantly, a PGO standby cluster can only be promoted by patching the `spec.standby.enabled` field to `false` in the PostgresCluster CR via `oc patch`. Patroni then executes the promotion sequence and the cluster becomes a writable primary on the next timeline.

The split-brain risk arises if the original PROD primary is still running and writable at the moment the DR cluster promotes. Both clusters would then accept writes on diverging timelines, and the WAL history would fork. Resolving a split-brain requires choosing one cluster as authoritative, discarding the diverged writes from the other, and rebuilding the loser cluster from scratch. This is why the PROD-to-DR planned switchover must include an explicit PROD fencing step before DR promotion.

---

## 3. DR Architecture Overview

**3.1 Identity Table**

| Property | Value |
|---|---|
| DR OCP API | api-ocp-dr-habibbank-local:6443 |
| DR OCP Context | dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali |
| DR Namespace | dr-pgcluster-uae |
| DR PostgresCluster CR | dr-pgcluster-uae |
| DR Upstream (PROD Primary LB) | 10.171.1.229:5555 |
| DR Pod IPs (from 2026-05-18 precheck) | 10.185.12.74, 10.185.17.38 |
| DR pgBackRest | Same S3 bucket as PROD, no backup schedules on DR |

**3.2 DR Standby Spec**

The DR cluster's `spec.standby` section as it must be configured for normal standby operation:

```yaml
spec:
  standby:
    enabled: true
    host: 10.171.1.229
    port: 5555
    repoName: repo1
```

**3.3 DR pgBackRest Settings**

The DR cluster uses the same S3 bucket (`pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e`) and same stanza (`db`) as production. DR does not run its own backup CronJobs — it reads from the production backup repository for WAL recovery. No separate backup schedules must be configured on the DR cluster to prevent it from writing conflicting backup metadata into the production repository path.

---

## 4. DR Health Check Procedure

**4.1 Verify DR API Reachability First**

Before running any DR commands, test whether the DR OCP API is reachable from the operations terminal. As of 2026-05-22, the DR API (`api-ocp-dr-habibbank-local:6443`, resolving to `10.20.115.14`) was timing out from the operations terminal. This may be a VPN routing issue or a network change in the DR OCP infrastructure.

```bash
# Test DR API connectivity with timeout
timeout 10 curl -sk https://api-ocp-dr-habibbank-local:6443/healthz && echo "DR_API_REACHABLE" || echo "DR_API_TIMEOUT"

# Alternative: direct TCP test to DR API IP
timeout 5 bash -c 'echo > /dev/tcp/10.20.115.14/6443' && echo "TCP_OK" || echo "TCP_FAIL"
```

If the DR API is unreachable, document the result and skip the remaining DR health check steps with status SKIP. Escalate if it has been unreachable for more than 24 consecutive hours.

**4.2 DR Context Setup**

```bash
# Set DR context variable for convenience
DR_CTX="dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali"
DR_NS="dr-pgcluster-uae"

# Verify DR context exists locally
oc config get-contexts | grep dr-pgcluster-uae

# If it does not exist, log in:
oc login https://api-ocp-dr-habibbank-local:6443 -u mohsinali
```

**4.3 DR Pod Status**

```bash
oc --context=$DR_CTX get pods -n $DR_NS -o wide
```

Expected: All DR pods Running with all containers Ready. DR pod IPs as of 2026-05-18 precheck were 10.185.12.74 and 10.185.17.38. Note that these IPs may change if pods are rescheduled.

**4.4 DR PostgresCluster CR Status**

```bash
oc --context=$DR_CTX get postgrescluster dr-pgcluster-uae -n $DR_NS \
  -o jsonpath='{.spec.standby}{"\n"}'
```

Expected output: `{"enabled":true,"host":"10.171.1.229","port":5555,"repoName":"repo1"}`

If `spec.standby.enabled` is `false`, the DR cluster has been promoted (either intentionally or accidentally) and is operating as an independent primary. This is a critical finding — escalate immediately.

**4.5 Patroni Status on DR (Standby Leader)**

```bash
# Run patronictl on a DR pod
DR_POD=$(oc --context=$DR_CTX get pods -n $DR_NS \
  -l postgres-operator.crunchydata.com/cluster=dr-pgcluster-uae \
  -l postgres-operator.crunchydata.com/role=master \
  -o jsonpath='{.items[0].metadata.name}')

oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- patronictl -c /etc/patroni/postgres.yml list
```

Expected: The DR Patroni leader shows `Role: Standby Leader` and `State: running`. The timeline should match or be one behind the production timeline. A plain `Leader` role (without the `Standby` qualifier) means the DR cluster has been promoted.

**4.6 Verify pg_is_in_recovery**

```bash
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "SELECT pg_is_in_recovery();"
```

Expected: `t` (true). If this returns `f` (false), the DR cluster is not in recovery mode and is acting as a writable primary. Escalate immediately.

**4.7 WAL Receiver Status**

```bash
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "
SELECT
  status,
  received_lsn,
  last_msg_send_time,
  last_msg_receipt_time,
  latest_end_lsn,
  sender_host,
  sender_port
FROM pg_stat_wal_receiver;
"
```

Expected: `status = streaming`, `sender_host = 10.171.1.229`, `sender_port = 5555`. The `received_lsn` should be close to the production primary's `pg_current_wal_lsn()`. If `status = waiting`, the WAL receiver is trying to reconnect. If the query returns no rows, streaming has stopped entirely.

**4.8 LSN Comparison**

```bash
# On DR pod: get last received and replayed LSN
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "
SELECT
  pg_last_wal_receive_lsn() AS received_lsn,
  pg_last_wal_replay_lsn() AS replayed_lsn,
  pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS receive_ahead_of_replay_bytes;
"
```

If `receive_ahead_of_replay_bytes` is 0, the DR instance has replayed all received WAL. If it is growing, the DR instance is falling behind on applying received WAL internally.

---

## 5. PROD-to-DR Lag Measurement

Accurate lag measurement requires coordinating queries on both the PROD primary and the DR standby simultaneously. Use the two-terminal method: Terminal A is connected to the PROD primary, Terminal B is connected to the DR standby.

**Terminal A (PROD Primary):**
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT pg_current_wal_lsn() AS prod_current_lsn, now() AS prod_time;
"
```

**Terminal B (DR Standby):**
```bash
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "
SELECT pg_last_wal_replay_lsn() AS dr_replay_lsn, now() AS dr_time;
"
```

**Calculate lag on Terminal A:**
```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- psql -U postgres -c "
SELECT pg_wal_lsn_diff('<prod_current_lsn>', '<dr_replay_lsn>') AS lag_bytes;
"
```

**Pass Threshold for Planned Switchover:** After application writes are frozen, the lag must reach 0 bytes (or < 1 KB due to Patroni heartbeat WAL) before the DR cluster is promoted. If lag is not reaching 0, investigate whether the PROD-to-DR network is flowing normally and whether the DR WAL receiver is in `streaming` status.

---

## 6. DR-to-PROD Connectivity Test

For streaming replication to function, the DR pods must be able to reach the PROD primary's LoadBalancer IP. This requires network policy rules on the PROD OCP cluster to permit ingress from the DR pod IP range.

```bash
# From a DR pod, test connectivity to PROD primary LB
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- pg_isready -h 10.171.1.229 -p 5555

# If pg_isready is not available, use TCP test:
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- bash -c \
  'timeout 5 bash -c "echo > /dev/tcp/10.171.1.229/5555" && echo "TCP_OK" || echo "TCP_FAIL"'
```

---

## 7. Known DR Blockers (from 2026-05-18 Precheck and 2026-05-22 Capture)

The following blockers were documented and unresolved at the time of this document's baseline. No planned switchover may be attempted until all blockers are resolved and signed off.

**Blocker 1: NetworkPolicy CIDR Mismatch**

The DR pods have IPs in the `10.185.x.x` subnet (specifically 10.185.12.74 and 10.185.17.38 as of 2026-05-18). The PROD OCP NetworkPolicy that permits streaming replication ingress allows only the `10.181.1.0/24` CIDR. The DR pod IPs fall outside this range, meaning streaming replication connections from DR pods to PROD are being dropped at the network policy layer.

Resolution: Patch the PROD NetworkPolicy to add `10.185.0.0/16` (or the exact DR pod CIDR) to the allowed ingress sources. Requires infrastructure team approval and a change window. After patching, re-run the DR-to-PROD connectivity test in Section 6.

**Blocker 2: DNS Timeout from DR Pods**

During the 2026-05-18 precheck, DNS resolution for `kubernetes.default.svc` was timing out from within the DR pods. This indicates a DNS or network configuration issue within the DR OCP cluster that may also affect other internal service resolutions. This must be resolved before any cutover, as a DR cluster with broken internal DNS will not function correctly as a promoted primary.

**Blocker 3: DR API Timeout from Ops Terminal**

As of 2026-05-22, the DR OCP API endpoint (`api-ocp-dr-habibbank-local:6443`, IP `10.20.115.14`) was timing out from the operations terminal with `dial tcp 10.20.115.14:6443: i/o timeout`. This may be a VPN routing issue or a DR OCP infrastructure problem. Without API access, no `oc` commands can be run against the DR cluster from the operations terminal.

**Blocker 4: PGBackRestReplicaRepoReady=False (StanzaNotCreated)**

A saved cluster condition from a prior inspection shows `PGBackRestReplicaRepoReady=False` with `reason=StanzaNotCreated`. This means the DR cluster's pgBackRest stanza was not initialized, preventing WAL archive access. This is a prerequisite for streaming recovery from the S3 archive (used when the WAL receiver falls behind). Resolution: The stanza must be created on the DR cluster using `pgbackrest --stanza=db stanza-create` — however, this must only be done by the DBA Lead after confirming the DR S3 path is correct and does not overwrite the production stanza.

**Do not attempt a planned switchover while any of these blockers are unresolved.**

---

## 8. Planned Switchover Safe Sequence

A planned switchover (non-emergency, full preparation) must only be executed during an approved change window with the DBA Lead, infrastructure lead, and application team leads present. All seven steps must be executed in order without skipping.

**Pre-switchover Requirements:**
- All four blockers in Section 7 are resolved and signed off
- Latest PROD backup successful within 24 hours
- Application team has scheduled a maintenance window
- Rollback plan documented and approved
- `prod_dr_cutover.py` script tested in UAT

**Step 1: Run prod_dr_cutover.py precheck**

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI
python3 prod_dr_cutover.py --action=precheck

# This validates: PROD healthy, DR healthy, lag acceptable, network policy, credentials
# DO NOT proceed if precheck reports any failures
```

**Step 2: Generate cutover plan**

```bash
python3 prod_dr_cutover.py --action=generate-plan \
  --target-dr-context=$DR_CTX \
  --prod-namespace=prod-pgcluster-uae \
  --dr-namespace=dr-pgcluster-uae

# Review the generated plan file carefully. Share with incident commander for approval.
```

**Step 3: Freeze Application Writes**

Coordinate with the application team to stop all write traffic to the PROD primary. This must be confirmed by the application team lead before proceeding. The method depends on the application architecture (load balancer rule change, application shutdown, or PgBouncer `PAUSE` command).

```bash
# Option: Pause PgBouncer to stop new queries
oc exec -it prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww -n prod-pgcluster-uae \
  -c pgbouncer -- psql -p 5432 pgbouncer -U pgbouncer -c "PAUSE;"
```

**Step 4: Verify Lag Reaches Zero**

Using the two-terminal method from Section 5, confirm the DR replay LSN matches the PROD current LSN. Do not proceed until lag is 0 bytes.

**Step 5: Fence PROD Primary (Prevent Split-Brain)**

```bash
# Demote the PROD Patroni leader to prevent it from accepting writes
# Use oc to patch the PROD PostgresCluster — do NOT use patronictl edit-config
# The PGO-safe method is to stop the PROD cluster's PostgreSQL via the CR

# Verify PROD is not accepting connections after fencing:
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae \
  -c database -- pg_isready
# Expected after fence: "no response" or rejection
```

**Step 6: Promote DR Cluster**

After PROD is fenced and lag is confirmed at 0, promote the DR cluster by disabling standby mode. Use `oc patch` against the PostgresCluster CR — never patch Patroni DCS directly.

```bash
oc --context=$DR_CTX patch postgrescluster dr-pgcluster-uae \
  -n dr-pgcluster-uae \
  --type=merge \
  -p '{"spec":{"standby":{"enabled":false}}}'
```

PGO will detect the change, Patroni will promote the DR standby leader to a writable primary, and the timeline will increment to 9 (or current TL + 1).

**Step 7: Verify DR Writable and Route Applications**

```bash
# Confirm DR is writable
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "SELECT pg_is_in_recovery();"
# Expected: f

# Confirm new timeline
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "
SELECT timeline_id FROM pg_control_checkpoint();
"

# Coordinate with application team to update connection strings
# to point to the DR LoadBalancer IP and port
```

Record the exact time of promotion and the new timeline number in the operations log.

---

## 9. Disaster Failover Procedure

A disaster failover occurs when the PROD cluster is unavailable and cannot be recovered within the RTO window. This is a higher-stakes operation because PROD cannot be fenced in the normal way — it may already be inaccessible.

**Evidence Requirements Before DR Promotion:**

Before promoting the DR cluster during a disaster, the following evidence must be gathered and reviewed by the incident commander:

| Evidence | Method |
|---|---|
| PROD API confirmed unreachable | `oc get pods -n prod-pgcluster-uae` fails or times out |
| PROD primary pod confirmed not running | Multiple attempts over 15 minutes |
| DR WAL receiver last received LSN noted | `pg_stat_wal_receiver` on DR pod |
| RPO window calculated | Time since last `pg_last_wal_replay_lsn` update |
| Incident commander authorization | Verbal or written approval documented |

**DR Promotion Command:**

```bash
# Disaster promotion — incident commander authorization required
oc --context=$DR_CTX patch postgrescluster dr-pgcluster-uae \
  -n dr-pgcluster-uae \
  --type=merge \
  -p '{"spec":{"standby":{"enabled":false}}}'
```

**Post-Promotion Validation:**

```bash
# Confirm promotion succeeded
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- psql -U postgres -c "
SELECT pg_is_in_recovery() AS in_recovery,
       (SELECT timeline_id FROM pg_control_checkpoint()) AS timeline,
       now() AS promotion_verified_at;
"

# Verify Patroni shows Leader (not Standby Leader)
oc --context=$DR_CTX exec -it $DR_POD -n $DR_NS \
  -c database -- patronictl -c /etc/patroni/postgres.yml list
```

**RPO Documentation:** Record the DR's `pg_last_wal_replay_lsn()` at the moment of promotion and compare it with the PROD primary's last known `pg_current_wal_lsn()`. The difference in bytes represents the data that was not replicated and is lost. This must be reported to the incident commander and risk management.

---

## 10. Switchback Principle

After a disaster failover, once PROD infrastructure is restored, the old PROD primary must NOT be allowed to restart as a writable primary with stale data. The old PROD data directory may contain writes that diverge from the DR timeline.

The correct switchback procedure is:

1. Confirm the old PROD cluster is completely stopped and its data directory is isolated.
2. Rebuild the old PROD as a new standby cluster pointing to the DR cluster (which is now the primary). This means creating a new PostgresCluster CR with `spec.standby.enabled=true` and `spec.standby.host` pointing to the DR primary's LoadBalancer IP.
3. Allow the rebuilt PROD to fully sync from the DR primary via streaming replication.
4. Confirm lag is 0 bytes.
5. Execute a controlled planned switchover (Section 8) to move the primary role back to PROD.

Under no circumstances should the old PROD data directory be used to start a primary after a DR failover. It must be either discarded or used only after being rewound with `pg_rewind` from the DR primary, which is only safe if the PROD timeline and DR timeline share a common WAL history point.

---

## 11. Stop-and-Escalate Triggers

The following conditions require the operator to immediately stop the current procedure and escalate to the DBA Lead and incident commander. Do not attempt to resolve these independently.

| Trigger | Action |
|---|---|
| DR and PROD both show `pg_is_in_recovery()=f` simultaneously | STOP — split-brain; escalate immediately |
| DR promotion fails (PGO does not update status) | STOP — do not retry without DBA Lead |
| `pg_wal_lsn_diff` shows DR is AHEAD of PROD after promotion | STOP — unexpected state; escalate |
| PROD fencing fails and PROD is still accepting writes | STOP — cannot promote DR safely |
| DR API becomes unreachable mid-procedure | STOP — escalate; do not guess at cluster state |
| Any `oc patch` command returns an error | STOP — verify what was applied before proceeding |
| Timeline on DR does not increment after promotion | STOP — Patroni may not have received the promote signal |

