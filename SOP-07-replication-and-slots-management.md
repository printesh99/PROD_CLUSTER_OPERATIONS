# SOP-07: Replication and Slots Management
## Habib Bank UAE Production PostgreSQL Cluster

**Cluster:** prod-pgcluster-uae
**OCP Context:** prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali
**Namespace:** prod-pgcluster-uae
**PostgresCluster CR:** prod-pgcluster-uae
**Leader Pod:** prod-pgcluster-uae-dc1-9c5j-0
**Sync Standby Pod:** prod-pgcluster-uae-dc1-5c2q-0
**Working Directory:** /home/mohsinali@habibbank.local/PROD_PATRONI
**Last Reviewed:** 2026-05-22

---

## 1. Replication Architecture Overview

The PROD cluster uses Patroni-managed synchronous streaming replication with the following key parameters:

| Parameter | Value | Location in CR |
|---|---|---|
| synchronous_mode | true | spec.patroni.dynamicConfiguration.synchronous_mode |
| synchronous_node_count | 1 | spec.patroni.dynamicConfiguration.synchronous_node_count |
| synchronous_commit | on | spec.patroni.dynamicConfiguration.postgresql.parameters |
| synchronous_mode_strict | false | spec.patroni.dynamicConfiguration |
| hot_standby | on | spec.patroni.dynamicConfiguration.postgresql.parameters |
| hot_standby_feedback | on | spec.patroni.dynamicConfiguration.postgresql.parameters |
| max_wal_senders | 20 | spec.patroni.dynamicConfiguration.postgresql.parameters |
| max_replication_slots | 50 | spec.patroni.dynamicConfiguration.postgresql.parameters |
| max_slot_wal_keep_size | 300GB | spec.patroni.dynamicConfiguration.postgresql.parameters |
| use_pg_rewind | true | spec.patroni.dynamicConfiguration |
| remove_data_directory_on_diverged_timelines | false | spec.patroni.dynamicConfiguration |
| remove_data_directory_on_rewind_failure | false | spec.patroni.dynamicConfiguration |

**Patroni scope:** prod-pgcluster-uae-ha

**Architecture:**
- Primary (Leader): prod-pgcluster-uae-dc1-9c5j-0 — accepts all reads and writes
- Sync Standby: prod-pgcluster-uae-dc1-5c2q-0 — streaming WAL, must acknowledge write before primary confirms to client
- WAL shipping to S3 via pgBackRest for PITR (independent of streaming replication)
- Physical replication slot per standby maintained by Patroni

---

## 2. Understanding Synchronous Commit

### What synchronous_mode=true means

When synchronous_mode is enabled, Patroni automatically writes the sync standby member name into PostgreSQL's `synchronous_standby_names` parameter. This means PostgreSQL will wait for at least one standby to acknowledge receiving and flushing each WAL record before confirming the commit to the client.

With `synchronous_node_count=1`, exactly **one** sync standby must acknowledge every write. This provides strong durability: a confirmed write exists on at least two nodes (primary + one standby).

### What happens if the sync standby falls behind or disconnects

- If the sync standby disconnects and `synchronous_mode_strict=false` (current configuration), Patroni will delist the failed standby from synchronous_standby_names after the leader lock TTL expires. Writes will then proceed without a synchronous standby — durability guarantee is temporarily reduced to primary-only.
- If `synchronous_mode_strict=true` were configured, writes would block until a synchronous standby is available again. This provides stronger durability at the cost of availability during standby failure.
- **Current setting (strict=false):** Prioritizes availability over strict durability during standby failure. This is the trade-off chosen for this cluster. Monitor pg_stat_replication closely if the standby is degraded.

### Effect on write latency

Each write must round-trip to the sync standby and back before the client sees commit confirmation. This adds network latency (typically microseconds to low milliseconds on a local network). If the standby is on a degraded network path, write latency will increase. Monitor write_lag in pg_stat_replication.

---

## 3. Monitoring Replication

### 3a. Primary-side: pg_stat_replication

Run on the **leader pod** only.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT
      application_name,
      client_addr,
      state,
      sync_state,
      sent_lsn,
      write_lsn,
      flush_lsn,
      replay_lsn,
      pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag_bytes,
      pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn)) AS flush_lag_bytes,
      pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes,
      write_lag,
      flush_lag,
      replay_lag
    FROM pg_stat_replication
    ORDER BY application_name;"
```

**Expected healthy output (from 2026-05-22 live capture):**

| Column | Expected Value |
|---|---|
| application_name | dc1-5c2q-0 |
| state | streaming |
| sync_state | sync |
| write_lag | (empty / NULL — sub-millisecond) |
| flush_lag | (empty / NULL — sub-millisecond) |
| replay_lag | (empty / NULL — sub-millisecond) |
| write_lag_bytes | 0 bytes |
| flush_lag_bytes | 0 bytes |
| replay_lag_bytes | 0 bytes |

**sync_state values and their meaning:**

| sync_state | Meaning | Action |
|---|---|---|
| sync | Normal — this standby is the synchronous standby | None |
| potential | Standby is connected and could become sync if the current sync standby fails | None (informational) |
| async | Standby is streaming but not synchronous — durability reduced | Investigate |
| quorum | Quorum-based sync mode (not currently configured) | N/A |

### 3b. Standby-side: Recovery status

Run on the **standby pod**.

```bash
oc exec -it prod-pgcluster-uae-dc1-5c2q-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT
      pg_is_in_recovery() AS in_recovery,
      pg_last_wal_receive_lsn() AS last_receive_lsn,
      pg_last_wal_replay_lsn() AS last_replay_lsn,
      pg_last_xact_replay_timestamp() AS last_replay_time,
      now() - pg_last_xact_replay_timestamp() AS replay_delay;"
```

**Expected:**
- in_recovery: true
- last_receive_lsn and last_replay_lsn: very close or identical to primary's current LSN
- replay_delay: sub-second

### 3c. Patroni cluster topology

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
```

Expected output columns: Member | Host | Role | State | TL | Lag in MB

**Healthy state:**
- dc1-9c5j-0: Leader, running, Lag=0
- dc1-5c2q-0: Replica (Sync Standby), running, Lag=0
- TL (timeline): both on the same timeline (currently timeline 8 — see Section 7)

---

## 4. Replication Lag Thresholds

| Metric | Target | Acceptable (short burst) | Alert Threshold | Escalate Threshold |
|---|---|---|---|---|
| byte_lag (write_lsn diff) | 0 bytes | < 1 MB | > 10 MB | > 100 MB for > 5 minutes |
| write_lag (time) | NULL / empty | < 10ms | > 100ms | > 1s sustained |
| flush_lag (time) | NULL / empty | < 10ms | > 100ms | > 1s sustained |
| replay_lag (time) | NULL / empty | < 10ms | > 100ms | > 1s sustained |
| patronictl Lag in MB | 0 | < 1 | > 10 | > 100 for > 5 minutes |

**If lag is growing:**
1. Check for large transactions or bulk loads on the primary generating high WAL volume
2. Check standby pod resource utilization (CPU, disk I/O on the pgwal PVC)
3. Check WAL receiver logs on the standby for errors
4. If lag > 100 MB for more than 5 minutes, escalate per SOP-06 Category B

---

## 5. Replication Slot Management

### 5a. Viewing current slots

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT
      slot_name,
      slot_type,
      active,
      active_pid,
      restart_lsn,
      confirmed_flush_lsn,
      wal_status,
      safe_wal_size,
      pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
    FROM pg_replication_slots
    ORDER BY retained_wal DESC NULLS LAST;"
```

### 5b. Slot fields explained

| Column | Meaning |
|---|---|
| slot_name | Identifier for the slot — Patroni names slots after the member (e.g., dc1-5c2q-0) |
| slot_type | physical (streaming replication) or logical (logical decoding) |
| active | true = WAL receiver currently connected; false = slot is retained but not in use |
| restart_lsn | The WAL position this slot requires PostgreSQL to retain — all WAL from here forward is kept |
| wal_status | healthy / extended / reserved / lost — see below |
| safe_wal_size | Bytes of WAL that can be generated before this slot reaches max_slot_wal_keep_size limit |
| retained_wal | Calculated: amount of WAL currently held for this slot |

### 5c. WAL status progression

```
healthy → extended → reserved → lost
```

| wal_status | Meaning | Action |
|---|---|---|
| healthy | Slot within normal operating range | None |
| extended | Slot retaining WAL beyond wal_keep_size but within limits | Monitor; investigate why standby is behind |
| reserved | Slot is consuming reserved WAL space; safe_wal_size is shrinking | Alert; investigate immediately |
| lost | Slot has been invalidated — PostgreSQL dropped WAL beyond max_slot_wal_keep_size | Standby must re-sync from backup |

**Monitor safe_wal_size proactively.** When safe_wal_size approaches 0, the slot status will transition to lost and the standby must perform a full re-synchronization from a backup.

### 5d. Inactive slot risk

An inactive physical slot (active=false) continues retaining WAL on the primary indefinitely. If the standby pod is down for an extended period:
- WAL accumulates in pg_wal (on the pgwal PVC, 500Gi)
- max_slot_wal_keep_size=300GB is the safety cap: if retained_wal exceeds 300GB, PostgreSQL automatically invalidates the slot (wal_status → lost)
- Slot invalidation means the standby cannot resume streaming — it must re-sync via pgBackRest restore (similar to a new standby initialization)

**Do NOT drop replication slots without DBA lead approval.** Dropping a slot used by Patroni will require Patroni to recreate it and potentially trigger a standby re-sync.

### 5e. Ongoing slot monitoring (run periodically during incidents)

```bash
# Watch slot status every 60 seconds
watch -n 60 'oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT slot_name, active, wal_status, safe_wal_size,
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
    FROM pg_replication_slots;"'
```

---

## 6. Risk Scenarios

### Scenario 1: Inactive slot + extended standby outage → WAL accumulation → PVC full

**Sequence of events:**
1. Standby pod goes down (crashloop, node failure, maintenance)
2. Physical replication slot remains active=false, retaining WAL from the standby's last received LSN
3. Primary continues generating WAL; each new segment is retained because the slot needs it
4. pgwal PVC (500Gi) begins filling
5. If max_slot_wal_keep_size=300GB is reached, PostgreSQL drops the slot (wal_status → lost)
6. If WAL accumulates faster than the slot cap and fills the PVC, PostgreSQL PANICs

**Detection:**
```bash
# Check pgwal PVC fill rate
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  du -sh /pgwal/pg18_wal/

# Check slot retained_wal
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT slot_name, active, wal_status, safe_wal_size FROM pg_replication_slots;"
```

**Response:** If PVC usage > 70% and slot is inactive, escalate immediately. Do not drop the slot without DBA lead approval.

### Scenario 2: wal_status=reserved — approaching slot invalidation

When wal_status transitions to reserved, the slot is within the max_slot_wal_keep_size buffer. PostgreSQL will drop the slot when safe_wal_size reaches 0.

**Immediate actions (with DBA lead approval):**
- Attempt to restart the standby pod so it can resume streaming and clear the backlog
- If the standby cannot resume, consider whether a full re-sync is preferable to slot invalidation
- Do not attempt to manually adjust max_slot_wal_keep_size without evaluating PVC capacity

### Scenario 3: Slot invalidated (wal_status=lost) — standby must re-sync

When a slot is lost, the standby cannot resume streaming from its last position. Patroni will detect this and trigger a re-initialization of the standby member via pg_basebackup or pgBackRest restore.

**What Patroni does:**
- Patroni detects the diverged/missing slot on the standby
- Depending on `remove_data_directory_on_diverged_timelines=false`, Patroni will attempt pg_rewind before wiping the standby data directory
- With `use_pg_rewind=true`, Patroni first tries pg_rewind to align the standby without a full re-sync

---

## 7. Timeline and pg_rewind

### Current timeline

The cluster is currently on **timeline 8**. Each switchover or failover increments the timeline counter by 1. Timeline 8 means 8 leadership changes have occurred in the history of this cluster.

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "SELECT timeline_id FROM pg_control_checkpoint();"
```

### pg_rewind — fast standby re-synchronization

`use_pg_rewind=true` allows Patroni to use `pg_rewind` to bring a diverged member back in sync without a full base backup. pg_rewind works by finding the divergence point and copying only the changed blocks from the new primary.

**When pg_rewind is used:**
- Old leader rejoins after a failover — it has diverged WAL from the new timeline
- Patroni detects the divergence and runs pg_rewind automatically before starting the standby

**Protections in place:**
- `remove_data_directory_on_diverged_timelines=false` — Patroni will NOT automatically wipe a diverged standby's data directory. It will attempt pg_rewind first.
- `remove_data_directory_on_rewind_failure=false` — if pg_rewind fails, Patroni will NOT automatically wipe the data directory. Manual intervention is required.

**Manual pg_rewind (if needed — DBA lead approval required):**
```bash
# This should only be run under explicit DBA lead direction
# Check pg_rewind eligibility first:
oc exec -it prod-pgcluster-uae-dc1-5c2q-0 -n prod-pgcluster-uae -c database -- \
  pg_rewind --target-pgdata=/pgdata/pg18 \
    --source-server="host=prod-pgcluster-uae-dc1-9c5j-0 user=replication" \
    --dry-run
```

---

## 8. WAL Keep Size Settings

These settings control how much WAL is retained on the primary pg_wal directory for standby catch-up (independent of replication slot retention):

| Parameter | Value | Effect |
|---|---|---|
| wal_keep_size | 2048MB | PostgreSQL keeps at least 2GB of WAL segments in pg_wal, regardless of slots, so a briefly lagging standby can catch up without needing to fetch from pgBackRest |
| max_wal_size | 64GB | Maximum WAL accumulation between checkpoints before PostgreSQL forces a checkpoint. High value reduces checkpoint frequency at the cost of potentially more WAL on disk |
| min_wal_size | 8GB | Minimum WAL segment space reserved in pg_wal (below this, PostgreSQL recycles segments) |
| max_slot_wal_keep_size | 300GB | Maximum WAL that any single replication slot can cause PostgreSQL to retain. Slots exceeding this are invalidated (wal_status → lost) |

**Interaction:** `wal_keep_size` sets a baseline floor. Replication slots can retain WAL beyond wal_keep_size, up to max_slot_wal_keep_size. The total WAL in pg_wal can therefore be up to 300GB (from a slow slot) plus the normal WAL from max_wal_size cycling.

---

## 9. Checking WAL and Spool Disk Usage

### 9a. WAL directory usage on leader pod

```bash
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  bash -c "
    echo '=== pg_wal (pgwal PVC mount) ==='
    du -sh /pgwal/pg18_wal/
    ls /pgwal/pg18_wal/ | wc -l

    echo '=== pgdata total ==='
    du -sh /pgdata/

    echo '=== pgbackrest-spool ==='
    du -sh /pgdata/pgbackrest-spool/ 2>/dev/null || echo 'spool path not found at this location'
  "
```

### 9b. pgBackRest spool backlog

The pgBackRest spool directory holds WAL segments that have been locally queued for archiving to S3 but have not yet been shipped. A high file count indicates S3 archiving is lagging.

```bash
# Count WAL files waiting to be archived
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  bash -c "ls /pgdata/pgbackrest-spool/archive/db/out/ 2>/dev/null | wc -l"

# Normal: < 10 files (small backlog between archive cycles)
# Concerning: > 100 files (archiving falling behind)
# Critical: > 1000 files (archiving significantly behind, S3 likely unreachable)
```

### 9c. PVC usage from OCP perspective

```bash
oc get pvc -n prod-pgcluster-uae -o custom-columns=\
NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage,\
STORAGECLASS:.spec.storageClassName
```

### 9d. Combined replication health check (run during monitoring rounds)

```bash
echo "=== $(date) — Replication Health Check ==="

echo "--- pg_stat_replication ---"
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT application_name, state, sync_state,
           pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS total_lag_bytes,
           write_lag, flush_lag, replay_lag
    FROM pg_stat_replication;"

echo "--- pg_replication_slots ---"
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT slot_name, active, wal_status, safe_wal_size,
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
    FROM pg_replication_slots;"

echo "--- WAL archiver ---"
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  psql -U postgres -c "
    SELECT archived_count, failed_count, last_archived_time,
           now() - last_archived_time AS time_since_last_archive
    FROM pg_stat_archiver;"

echo "--- Patroni list ---"
oc exec -it prod-pgcluster-uae-dc1-9c5j-0 -n prod-pgcluster-uae -c database -- \
  patronictl -c /etc/patroni/patroni.yaml list
```

