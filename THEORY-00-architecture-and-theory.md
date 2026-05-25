# THEORY-00: Architecture and Theoretical Foundation
## Habib Bank UAE Production PostgreSQL Platform

**Document Class:** Theoretical Reference  
**Cluster:** prod-pgcluster-uae (PostgresCluster CR, namespace prod-pgcluster-uae)  
**Operator:** Crunchy Data PGO on Red Hat OpenShift (OCP)  
**Database Engine:** PostgreSQL 18  
**Captured State Date:** 2026-05-22  
**Author:** Platform Engineering — Database Infrastructure

---

## 1. Platform Overview — How the Layers Fit Together

The Habib Bank UAE production PostgreSQL platform is a layered technology stack where each component has a distinct responsibility boundary, and the health of the entire system depends on understanding how these layers interact.

At the lowest hardware level, compute nodes in the OpenShift cluster (such as `lupr09c05ocpw4` and `lupr09c05ocpw5`) provide CPU, RAM, and block storage. Above that sits **Red Hat OpenShift Container Platform (OCP)**, which is a Kubernetes distribution that schedules pods, enforces network policies, and manages persistent volume claims (PVCs). OpenShift provides the API server at `https://api.ocp-prod.habibbank.local:6443`, the etcd cluster that backs all Kubernetes state, and the OCS (OpenShift Container Storage) subsystem that provisions Ceph RBD block volumes.

The next layer is the **Crunchy Data PostgreSQL Operator (PGO)**. PGO is a Kubernetes operator — a control loop implemented as a running pod — that watches a custom resource called `PostgresCluster`. When the operator sees the CR, it reconciles the real cluster state to match the desired state described in that manifest: it creates StatefulSets, Services, Secrets, ConfigMaps, ServiceAccounts, CronJobs for backups, and the PgBouncer Deployment. PGO owns all of these child resources. If you modify a child resource directly (e.g., edit the Patroni ConfigMap), the operator will overwrite your change on the next reconciliation loop. This is the single most important operational constraint for this platform.

Inside the pods managed by PGO, **PostgreSQL 18** is the actual database engine. It manages the data files under `/pgdata`, writes Write-Ahead Log (WAL) to the separate `/pgwal` volume, and services SQL connections. Alongside PostgreSQL runs **Patroni**, an open-source high-availability agent. Patroni manages the cluster topology: it knows which instance is the primary, coordinates switchover and failover, and writes its cluster state to a Distributed Configuration Store (DCS). In this PGO-managed cluster, the DCS is the Kubernetes API itself — Patroni uses Kubernetes ConfigMaps and Endpoints (or Leases) as its consensus mechanism rather than a separate etcd or Consul cluster.

Application connections never reach PostgreSQL directly. They first hit **PgBouncer**, a lightweight connection pooler deployed as a separate Kubernetes Deployment with two replicas behind a LoadBalancer service (external IP `10.171.1.205:5555`). PgBouncer multiplexes thousands of client connections into a much smaller pool of real server connections, using transaction-mode pooling. PgBouncer handles client TLS termination and then establishes its own TLS-verified connections to the PostgreSQL primary.

For backups and point-in-time recovery, **pgBackRest** is integrated into every PostgreSQL pod as a sidecar process. It archives WAL segments to an S3-compatible object store (OpenShift OCS S3 gateway) and performs scheduled full, differential, and incremental backups via Kubernetes CronJobs. A pgBackRest TLS server runs in each pod, providing a secure channel for cross-pod backup operations.

Finally, the **monitoring stack** consists of a Prometheus instance scraping PostgreSQL metrics (via `pg_stat_statements`, connection stats, and a custom `pg_inspector` agent), plus a **pgBackRest Pushgateway** that accepts push-based metrics from backup jobs and exposes them to Prometheus.

---

## 2. PostgreSQL 18 Core Concepts and Parameter Rationale

### Write-Ahead Logging (WAL)

PostgreSQL's WAL is the foundation of both durability and replication. Every change to the database — an INSERT, UPDATE, DELETE, DDL statement — is first written to the WAL before the data pages are modified in shared_buffers or on disk. This guarantees that if the process crashes after writing WAL but before flushing data pages, the WAL can be replayed at startup to reconstruct the committed state.

This cluster uses `wal_level=logical`. The `logical` level is a superset of `replica`; in addition to the physical change records needed for streaming replication, it includes enough information to decode changes into logical operations (old and new row values). This is required for logical replication slots and tools like `pg_logical` or `pgoutgoing` replication. At `logical` level, WAL records are slightly larger, which has a minor write amplification effect, but the benefit is maximum flexibility for CDC pipelines and logical replication consumers.

`archive_mode=on` means every completed WAL segment is handed to the archive command (pgBackRest's `archive-push`). `archive_timeout=60s` forces a WAL segment switch every 60 seconds even if the segment is not full, bounding the maximum data loss window to 60 seconds in the event of a complete S3 failure (WAL not yet archived). `max_wal_size=64GB` allows the WAL directory to grow up to 64 GB before checkpoint pressure forces more frequent checkpoints. `min_wal_size=8GB` ensures that recycled WAL segment files are kept pre-allocated rather than deleted and re-created, reducing file system pressure during bursts.

### MVCC and Vacuum

PostgreSQL uses Multi-Version Concurrency Control (MVCC): instead of locking rows on read, it keeps old row versions (called "dead tuples") in the heap until a vacuum process can safely remove them. The `autovacuum` process runs continuously in the background, reclaiming space and updating visibility maps. On a busy OLTP cluster with 800 max connections and high write throughput, autovacuum tuning is critical. `maintenance_work_mem=2GB` is set at the cluster level to give autovacuum workers and manual `VACUUM` operations sufficient sort buffer space to process large tables efficiently. Transaction ID wraparound is an existential risk on any PostgreSQL cluster; autovacuum's anti-wraparound passes are protected from cancellation by design.

### Shared Buffers and Memory Sizing

`shared_buffers=24GB` represents approximately 40% of the pod's 60 Gi RAM request. PostgreSQL's conventional wisdom is 25–40% of RAM for shared_buffers, because the OS page cache also caches database files and the two caches would compete if shared_buffers were set too high. `effective_cache_size=48GB` is not a memory allocation — it is a hint to the query planner about how much memory is available in shared_buffers plus OS cache combined. The planner uses this value to decide whether index scans (which benefit from large caches) are likely to be cheaper than sequential scans. At 48 GB (80% of RAM), the planner will favor index scans aggressively, appropriate for an OLTP banking workload. `work_mem=16MB` is the per-sort-operation, per-hash-join allocation. With up to 800 connections and queries that may use multiple sort nodes each, peak memory usage from work_mem alone could reach `800 × multiple_nodes × 16MB` — hence keeping this conservative rather than generous.

### Replication Slots and Logical Parameters

`max_replication_slots=50` and `max_wal_senders=20` are set well above the active usage to accommodate future logical replication consumers (CDC, analytics) without a restart. `max_slot_wal_keep_size=300GB` is a safety cap: if a replication slot's consumer falls behind, PostgreSQL will not retain more than 300 GB of WAL on disk for that slot before it invalidates the slot. Without this cap, a lagging consumer could fill the pgwal PVC (500 Gi) and crash the primary.

### Timeouts and Safety Rails

`statement_timeout=300000ms` (5 minutes) kills any query running longer than 5 minutes. For a banking application, runaway queries are a reliability risk — this setting prevents them from starving the connection pool. `idle_in_transaction_session_timeout=120000ms` (2 minutes) closes sessions that have opened a transaction but gone idle, which prevents long-held row locks from blocking concurrent writes.

---

## 3. Patroni HA Theory

Patroni is an open-source high-availability framework for PostgreSQL. In a PGO-managed cluster, Patroni does not rely on an external DCS like etcd or ZooKeeper — instead it uses Kubernetes native resources (ConfigMaps, Endpoints, or Lease objects) as its consensus store. The Patroni process on each pod continuously writes a heartbeat key with a TTL into the DCS. If the leader pod fails to renew its heartbeat within the TTL window, other Patroni agents detect the lapse and initiate a leader election.

The key Patroni timing parameters are: `loop_wait` (how often Patroni runs its health check loop), `ttl` (how long a leader lock remains valid without renewal), and `retry_timeout` (how long to wait for a DCS operation before considering it failed). These three values define the worst-case failover time and the minimum observable unavailability window during an unplanned outage.

### Synchronous Mode

This cluster runs with `synchronous_mode=true` and `synchronous_node_count=1`. In synchronous mode, Patroni dynamically manages the `synchronous_standby_names` PostgreSQL parameter. With `synchronous_node_count=1`, at least one standby must confirm receipt of each WAL record before the primary acknowledges the commit to the client. Combined with `synchronous_commit=on`, this means zero data loss on primary failure — the sync standby always has every committed transaction. The trade-off is latency: every write must survive a network round trip to the sync standby before the application sees a commit acknowledgment. On this cluster the sync standby (`prod-pgcluster-uae-dc1-5c2q-0`, IP `10.175.14.83`) is on a different OCP worker node (`lupr09c05ocpw5`) from the primary, providing node-level fault tolerance.

### Failover vs Switchover

A **switchover** is a controlled operation: the primary gracefully demotes itself, the chosen standby is promoted, and the old primary re-attaches as a new standby. Patroni's `patronictl switchover` command orchestrates this. A **failover** is an uncontrolled event: the primary is unreachable, Patroni agents on the surviving standbys determine the leader lock has expired, and the most up-to-date standby promotes itself. After failover, the old primary may have diverged from the new primary if it was not fully in sync. `pg_rewind` is used in this scenario — it replays the minimum delta from the new primary's timeline back onto the old primary so it can rejoin as a standby without a full base backup.

### Timeline History

Every time a PostgreSQL cluster experiences a promotion (planned or emergency), the timeline counter increments. Timeline `8` on this cluster means there have been seven prior promotions or PITR restores in the cluster's history. The timeline is recorded in every WAL segment filename, making it impossible to accidentally apply WAL from the wrong history branch during recovery.

---

## 4. Crunchy Data PGO Operator Model

PGO implements the Kubernetes operator pattern: it is a controller that watches the `PostgresCluster` custom resource and continuously reconciles the observed cluster state toward the desired state expressed in the CR spec. The CR for this cluster is named `prod-pgcluster-uae` in namespace `prod-pgcluster-uae`.

When a change is made to the CR (for example, increasing `shared_buffers`, modifying a Patroni parameter, or changing the backup schedule), the operator detects the change, computes the required actions, and applies them — potentially rolling pods, regenerating ConfigMaps, or updating CronJob specs. This reconciliation loop means that the CR is the **single source of truth** for cluster configuration. Operators must never modify the operator-generated ConfigMaps, Patroni DCS keys, or StatefulSet specs directly; such changes will be silently overwritten at the next reconciliation.

PGO also manages the pgBackRest TLS infrastructure. It generates a Certificate Authority and per-pod TLS certificates stored as Kubernetes Secrets, mounts them into the PostgreSQL pods and the pgBackRest repository host (if used), and configures the pgBackRest TLS server in each pod for cross-pod communication during backup and restore operations.

The instance set `dc1` defines the replica count (2 in this cluster). PGO creates a StatefulSet named `prod-pgcluster-uae-dc1`, with pods `prod-pgcluster-uae-dc1-9c5j-0` (currently the Patroni leader) and `prod-pgcluster-uae-dc1-5c2q-0` (currently the sync standby).

---

## 5. pgBackRest Backup Theory

pgBackRest organizes its repository under a **stanza** — a named logical unit corresponding to one PostgreSQL cluster. The stanza `db` on this cluster maps to the S3 bucket `pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e`, accessed via the OCS S3 endpoint `s3-openshift-storage.apps.ocp-prod.habibbank.local`.

### Backup Chain Hierarchy

pgBackRest supports three backup types that form a dependency chain. A **full backup** copies every file in the PostgreSQL data directory. A **differential backup** copies only files changed since the last full backup. An **incremental backup** copies only files changed since the last backup of any type (full, diff, or incr). On this cluster the schedule is: full every Sunday at 01:00, differential Monday–Saturday at 01:00, and incremental every 6 hours. This means the worst-case recovery time (in terms of backup data to restore) is bounded by the most recent incremental — at most 6 hours of changed blocks.

The retention policy (`full=4`, `diff=7`) means pgBackRest keeps 4 full backup sets (roughly 4 weeks) and 7 differential backups per full set. Any incremental that would be orphaned by differential expiry is also expired. Critically, pgBackRest also keeps all WAL archived since the oldest retained backup, because WAL is needed to replay from a backup to any point-in-time target.

### WAL Archiving and Async Mode

`archive-async=y` with `spool-path=/pgdata/pgbackrest-spool` enables asynchronous WAL archiving. When PostgreSQL calls the archive command for a completed WAL segment, pgBackRest returns success immediately after spooling the segment to the local spool directory, then sends it to S3 in background threads (controlled by `process-max=8`). This prevents S3 latency spikes from stalling PostgreSQL archiving and causing `archive_timeout` violations. The spool directory lives on the pgdata PVC, which is sized at 2 Ti — the spool is a transient buffer, not a permanent archive.

### Point-in-Time Recovery

PITR works by restoring a backup, then replaying WAL segments from the archive until the target time, transaction ID, or LSN is reached. The `restore_command` in PostgreSQL's recovery configuration calls `pgbackrest archive-get`, which fetches WAL segments from S3 in order. The replay is deterministic: every committed transaction in every WAL segment is re-applied in order until the target is met. This is why continuous WAL archiving and backup retention must always be aligned — a gap in the WAL archive between the backup LSN and the target time makes PITR impossible.

### Encryption and Compression

`cipher=aes-256-cbc` encrypts every file written to the S3 repository. The encryption key is stored in the pgBackRest configuration (managed by PGO Secrets) and never appears in the repository itself. `lz4` compression at level 3 provides fast compression with moderate ratio — suitable for a backup pipeline where CPU is limited to 8 parallel processes (`process-max=8`) and S3 bandwidth is the primary bottleneck, not CPU. `lz4` level 3 is a good balance between speed and compression ratio for PostgreSQL data files, which contain a mix of compressible text/numeric data and partially-compressible binary structures.

---

## 6. PgBouncer Connection Pooling Theory

PgBouncer sits in front of PostgreSQL and manages a pool of real server connections, multiplexing a much larger number of client connections through them. This cluster uses **transaction mode pooling**, the most efficient but also most restrictive mode. In transaction mode, a server connection is assigned to a client only for the duration of one transaction — the moment a COMMIT or ROLLBACK is issued, the server connection returns to the pool and can be claimed by a different client. This allows far more clients than server connections without leaving idle connections open on the PostgreSQL side.

The relationship between the key parameters is: `max_client_conn=2000` defines the maximum number of inbound client connections PgBouncer will accept. `default_pool_size=50` defines how many real PostgreSQL connections PgBouncer will maintain per database/user pair. `max_db_connections=150` caps the total real connections to PostgreSQL across all pools for a given database, regardless of pool fragmentation. `min_pool_size=10` ensures a minimum of 10 warm connections always exist even during idle periods, avoiding connection establishment latency for bursty workloads. `reserve_pool_size=10` is a small emergency pool that can be activated when the main pool is saturated — clients reaching `reserve_pool_timeout` can borrow from the reserve rather than immediately receiving a "pool full" error. `query_wait_timeout` (default 120s) is the maximum time a client can wait in the queue for a server connection before being disconnected with an error — critical for banking applications where a stuck connection queue should fail fast rather than pile up indefinitely.

### Authentication

PgBouncer uses the `auth_query` mechanism: `pgbouncer.get_auth()` is a stored function in PostgreSQL that PgBouncer calls to retrieve hashed credentials for a connecting user. This avoids maintaining a static userlist.txt file that must be synchronized separately. The function returns the SCRAM-SHA-256 verifier for the requested username, allowing PgBouncer to verify client credentials without storing cleartext passwords.

Client TLS is set to `require` (clients must use TLS) and server TLS to `verify-full` (PgBouncer verifies the PostgreSQL server's certificate against its CA). This provides end-to-end TLS from client → PgBouncer (TLS terminated at PgBouncer) and PgBouncer → PostgreSQL (new TLS session, certificate verified).

---

## 7. DR Streaming Replication Theory

The DR cluster (`dr-pgcluster-uae`, namespace `dr-pgcluster-uae`, OCP API `https://api.ocp-dr.habibbank.local:6443`) is a PGO-managed **standby cluster** with `spec.standby.enabled=true`. In PGO standby mode, PGO provisions the cluster in recovery mode from the start: it configures `primary_conninfo` pointing to the PROD primary's replication endpoint (via the PROD primary LB at `10.171.1.229:5555`) and sets a `restore_command` that fetches WAL from the shared S3 repository (`repo1`) as a fallback.

### WAL Receiver vs Archive Recovery

The DR standby uses a combination of streaming replication (WAL receiver process connecting to the PROD primary) and archive recovery (fetching WAL from S3 when the stream is interrupted). Streaming replication delivers WAL in near-real-time — the stream lag is reported as `0` on the PROD side, meaning the sync standby is current, though this refers to the PROD sync standby (`dc1-5c2q-0`), not the DR cluster. The DR cluster has an independent replication channel.

`restore_command` from S3 provides resilience: if the streaming replication connection is interrupted (network partition, PROD pod restart), the DR standby falls back to replaying WAL from S3 until the stream reconnects. This means the DR cluster's recovery lag is bounded in the worst case by the S3 archiving lag (at most `archive_timeout=60s` plus S3 write latency).

### Split-Brain and Fencing

Before promoting the DR cluster to primary, the PROD primary **must be fenced** — either the PROD pods must be stopped, or network access from clients to PROD must be blocked. If both clusters become primary simultaneously (split-brain), they will each accept writes that diverge from a common history. Merging diverged timelines is not possible without data loss; the only recovery is to discard one cluster's changes entirely. PGO's standby mechanism does not include automatic fencing — this is an operational procedure documented in the DR runbook.

### Network Blocker — Known Issue (2026-05-22)

The DR pods have IPs in the `10.185.x.x` CIDR, but the PROD primary's `pg_hba.conf` (managed via the PGO CR) allows replication from `10.181.1.0/24`. This CIDR mismatch prevents the DR WAL receiver from authenticating. The fix is to patch the `PostgresCluster` CR in the PROD namespace to add the DR pod CIDR to the replication host rules, then wait for PGO to reconcile the `pg_hba.conf`.

---

## 8. Storage Architecture

Each PostgreSQL pod has two persistent volumes:

| Volume | Storage Class | Size | Purpose |
|---|---|---|---|
| pgdata | ocs-storagecluster-ceph-rbd | 2 Ti | PostgreSQL data files, pg_wal (WAL on same volume default), pgbackrest-spool |
| pgwal | ocs-storagecluster-ceph-rbd | 500 Gi | Dedicated WAL volume (mounted as `pg_wal` symlink) |

Separating pgdata and pgwal onto distinct Ceph RBD volumes provides I/O isolation: WAL writes are sequential and latency-sensitive (they are on the critical path of every commit), while data file reads/writes are random and bulk. When both compete on the same volume, WAL latency spikes can cause commit latency spikes. The dedicated 500 Gi pgwal volume ensures WAL throughput is not starved by checkpoint I/O.

Ceph RBD (RADOS Block Device) provides block-level storage with replication within the Ceph cluster. OCS (OpenShift Container Storage) manages the Ceph cluster and exposes PVCs via the `ocs-storagecluster-ceph-rbd` StorageClass. RBD volumes provide ReadWriteOnce access — only one pod can mount a given PVC at a time, which is the correct semantics for a database data directory.

`max_slot_wal_keep_size=300GB` bounds the WAL that PostgreSQL will retain on the pgwal PVC for replication slots. With a 500 Gi pgwal PVC, this reserves approximately 200 Gi headroom for normal WAL growth beyond slot retention. Without this cap, a stalled replication slot consumer (DR cluster, logical consumer) could fill the PVC and crash the primary.

---

## 9. Monitoring Stack

### pg_stat_statements

The `pg_stat_statements` extension (loaded via `shared_preload_libraries`) tracks execution statistics for every normalized query: total calls, total/min/max/mean execution time, rows returned, buffer hits and misses. This is the primary tool for identifying slow queries, high-frequency queries, and buffer pressure. Because it is loaded at startup via `shared_preload_libraries`, it requires no per-session activation.

### pgaudit

`pgaudit` (also loaded via `shared_preload_libraries`) provides detailed audit logging. The setting `pgaudit.log=ddl,role,write` means every DDL statement (CREATE TABLE, ALTER, DROP), every role management statement (GRANT, REVOKE, CREATE USER), and every write DML (INSERT, UPDATE, DELETE, TRUNCATE) is logged to PostgreSQL's log destination. This satisfies banking regulatory requirements for audit trails of data modifications. The logs are sent to the pod's stdout, where OpenShift's log aggregation captures them for SIEM forwarding.

### pgBackRest Pushgateway — HTTP 400 Errors (2026-05-22)

The pgBackRest monitoring integration pushes metrics to a Prometheus Pushgateway. The HTTP 400 errors observed on 2026-05-22 indicate a **metric format mismatch** between the pgBackRest version's output format and the Pushgateway's expected format — specifically, the `pgbackrest_info` label set or metric type declaration is likely non-conformant with the Pushgateway's OpenMetrics validation. This does not affect backup operation; it only affects the visibility of backup metrics in Prometheus. The fix involves either upgrading pgBackRest to a version whose push format matches the Pushgateway, or providing a format-translation sidecar.

---

## 10. Security Model

This platform implements defense-in-depth across every communication channel.

**TLS everywhere:** Patroni's REST API (used for health checks and operator communication) is TLS-protected with certificates generated by PGO. pgBackRest operates a TLS server in each pod for cross-pod backup communication, with client certificates for mutual authentication. PgBouncer requires TLS from clients (`client_tls_sslmode=require`) and verifies the PostgreSQL server certificate (`server_tls_sslmode=verify-full`). PostgreSQL itself is configured with TLS, so every TCP connection to port 5432 is encrypted.

**Authentication:** PostgreSQL uses `scram-sha-256` for all user authentication — the SCRAM protocol means the cleartext password never traverses the network, only a hash proof. PgBouncer's `auth_query` mechanism retrieves the SCRAM verifier from PostgreSQL rather than maintaining a local password file, keeping credentials synchronized automatically.

**Secret Management:** All sensitive values — S3 credentials, pgBackRest encryption keys, TLS private keys, PostgreSQL superuser passwords, PgBouncer credentials — are stored in OpenShift Secrets. PGO creates and manages these Secrets. They are never embedded in documentation, committed to version control, or echoed in terminal sessions. Reference to Secrets in runbooks always uses `kubectl get secret <name> -o jsonpath=...` patterns, not hardcoded values.

**Network Policy:** OpenShift NetworkPolicy resources restrict which pods can communicate with the PostgreSQL pods. The known DR blocker (pod CIDR `10.185.x.x` not in the PROD allowed range `10.181.1.0/24`) is an example of how these policies enforce boundaries — the DR WAL receiver cannot reach the PROD primary without an explicit policy change.

---

## 11. Known Cluster State Issues (2026-05-22)

### UAT Databases Present on PROD

Several UAT-environment databases were found to exist on the PROD cluster, likely as artifacts of logical restore operations (pg_restore or pgBackRest logical restore to PROD). These databases consume PROD storage, potentially receive PROD-tier backups, and present a data governance risk if UAT data was accidentally restored from a PROD backup or vice versa. These databases should be inventoried, confirmed not to be in active use by any application, and dropped after a change-managed maintenance window.

### Backup Job Failures — BackoffLimitExceeded

Kubernetes CronJobs for pgBackRest backups (differential or incremental) have failed with `BackoffLimitExceeded`, meaning the job's pods failed repeatedly and exceeded the configured retry limit. This status does not necessarily mean backups are failing — pgBackRest may have completed successfully in an earlier attempt, and only the Kubernetes Job wrapper is in a failed terminal state. The operational distinction is: check pgBackRest directly (`pgbackrest info --stanza=db`) for backup status (confirmed OK with 35 backups and `status=ok` on 2026-05-22), and separately investigate the Job failure root cause (typically a pod startup race, resource limit, or pgBackRest lock contention). Stale failed Jobs accumulate and should be pruned.

### HTTP 400 Pushgateway Errors

As described in Section 9, the pgBackRest Pushgateway integration is generating HTTP 400 errors due to a metric format incompatibility. Backup operations are unaffected. Prometheus scraping of these metrics will show gaps or stale values until the format issue is resolved. Operators should not interpret the absence of fresh Pushgateway metrics as a backup failure — use `pgbackrest info` as the authoritative source.

### DR API Timeout (2026-05-22)

`kubectl` commands targeting the DR OCP API (`https://api.ocp-dr.habibbank.local:6443`) timed out during the 2026-05-22 session. This may indicate: the DR OCP cluster API server was unavailable, the terminal host lacked network connectivity to the DR OCP network, or a firewall rule was blocking port 6443. This did not affect PROD operations but means DR cluster state (Patroni status, WAL receiver lag, pod health) could not be verified. DR operability must be confirmed by a team member with direct network access to the DR OCP environment.

### DR Network Blocker — Pod CIDR Mismatch

The DR PostgreSQL pods have IP addresses in the `10.185.x.x` range. The PROD cluster's replication authentication configuration (pg_hba.conf, managed by PGO) allows replication connections from `10.181.1.0/24`. The DR pod IPs fall outside this range, preventing the DR WAL receiver from authenticating to the PROD primary. Until this is resolved, the DR cluster cannot receive streaming replication from PROD. It may still recover via WAL archiving from S3, but streaming replication is unavailable. The remediation is to patch the PROD `PostgresCluster` CR to add a `pg_hba` entry for the `10.185.0.0/16` (or appropriate DR pod CIDR), then allow PGO to reconcile. No direct editing of pg_hba.conf files on the pods.

---

## Appendix A: Key Parameter Reference Table

| Parameter | Value | Rationale |
|---|---|---|
| max_connections | 800 | Headroom for PgBouncer server connections + monitoring + DBA sessions |
| shared_buffers | 24 GB | ~40% of 60 Gi RAM; primary PostgreSQL cache |
| effective_cache_size | 48 GB | 80% of RAM; planner hint favoring index scans |
| work_mem | 16 MB | Conservative to avoid OOM at high connection counts |
| maintenance_work_mem | 2 GB | Autovacuum, VACUUM, index builds |
| wal_level | logical | Required for logical replication and CDC |
| max_wal_size | 64 GB | Allows burst WAL growth before checkpoint pressure |
| min_wal_size | 8 GB | Pre-allocates WAL segments to reduce file system churn |
| max_slot_wal_keep_size | 300 GB | Safety cap — prevents slot lag from filling pgwal PVC |
| synchronous_commit | on | Zero data loss — required for banking |
| synchronous_node_count | 1 | One sync standby (dc1-5c2q-0) must confirm each WAL record |
| archive_timeout | 60 s | Maximum WAL loss window if S3 is unreachable |
| statement_timeout | 300 000 ms | Kills runaway queries after 5 minutes |
| idle_in_transaction_session_timeout | 120 000 ms | Closes idle-in-transaction sessions after 2 minutes |
| pgaudit.log | ddl, role, write | Regulatory audit coverage of all destructive and structural operations |

---

## Appendix B: Service IP Reference Table

| Service | IP:Port | Protocol | Notes |
|---|---|---|---|
| PROD Primary LB | 10.171.1.229:5555 | PostgreSQL / replication | DR upstream; direct connections bypassing PgBouncer |
| PROD PgBouncer LB | 10.171.1.205:5555 | PostgreSQL (via PgBouncer) | Application-facing entry point |
| OCP API (PROD) | api.ocp-prod.habibbank.local:6443 | HTTPS/kubectl | Cluster management |
| OCP API (DR) | api.ocp-dr.habibbank.local:6443 | HTTPS/kubectl | DR cluster management (timed out 2026-05-22) |
| S3 Endpoint | s3-openshift-storage.apps.ocp-prod.habibbank.local | HTTPS | pgBackRest repository |

---

*End of THEORY-00 — Architecture and Theoretical Foundation*  
*This document describes the theoretical model underpinning the production cluster as observed on 2026-05-22. For operational procedures, refer to the numbered runbooks in this repository.*
