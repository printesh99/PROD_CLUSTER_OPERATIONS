# PROD PostgresCluster Spec Summary

Captured live from:

```bash
oc get postgrescluster prod-pgcluster-uae -n prod-pgcluster-uae -o json
```

Capture date: 2026-05-22.

## Identity

```text
name=prod-pgcluster-uae
namespace=prod-pgcluster-uae
postgresVersion=18
port=5555
standby=null
```

## Instance Set

```yaml
instances:
  - name: dc1
    replicas: 2
    dataVolumeClaimSpec:
      storageClassName: ocs-storagecluster-ceph-rbd
      resources:
        requests:
          storage: 2Ti
    walVolumeClaimSpec:
      storageClassName: ocs-storagecluster-ceph-rbd
      resources:
        requests:
          storage: 500Gi
    resources:
      requests:
        cpu: "16"
        memory: 60Gi
      limits:
        cpu: "16"
        memory: 64Gi
    affinity:
      nodeAffinity:
        dc: dc1
      podAntiAffinity:
        required: hostname
```

## Patroni Dynamic Configuration

```yaml
loop_wait: 10
retry_timeout: 10
ttl: 30
master_start_timeout: 300
maximum_lag_on_failover: 1048576
synchronous_mode: true
synchronous_mode_strict: false
synchronous_node_count: 1
postgresql:
  remove_data_directory_on_diverged_timelines: false
  remove_data_directory_on_rewind_failure: false
  use_pg_rewind: true
```

## PostgreSQL Parameters

```text
archive_mode=on
archive_timeout=60s
autovacuum_analyze_scale_factor=0.005
autovacuum_max_workers=6
autovacuum_naptime=30s
autovacuum_vacuum_cost_delay=2ms
autovacuum_vacuum_cost_limit=4000
autovacuum_vacuum_scale_factor=0.01
autovacuum_work_mem=1GB
checkpoint_completion_target=0.9
checkpoint_timeout=15min
effective_cache_size=48GB
effective_io_concurrency=200
hot_standby=on
hot_standby_feedback=on
idle_in_transaction_session_timeout=120000
log_autovacuum_min_duration=500
log_checkpoints=on
log_line_prefix=%m [%p] %q%u@%d/%a 
log_lock_waits=on
log_min_duration_statement=1000
log_temp_files=1MB
maintenance_work_mem=2GB
max_connections=800
max_parallel_workers=8
max_parallel_workers_per_gather=4
max_replication_slots=50
max_slot_wal_keep_size=300GB
max_wal_senders=20
max_wal_size=64GB
max_worker_processes=16
min_wal_size=8GB
password_encryption=scram-sha-256
pg_stat_statements.max=20000
pg_stat_statements.track=all
pgaudit.log=ddl,role,write
pgaudit.log_catalog=off
pgaudit.log_relation=on
random_page_cost=1.1
seq_page_cost=1.0
shared_buffers=24GB
shared_preload_libraries=pg_stat_statements,pgaudit
ssl=on
statement_timeout=300000
superuser_reserved_connections=5
synchronous_commit=on
temp_buffers=32MB
vacuum_cost_delay=0
wal_buffers=64MB
wal_compression=lz4
wal_keep_size=2048MB
wal_level=logical
work_mem=16MB
```

## pgBackRest

```yaml
backups:
  pgbackrest:
    configuration:
      - secret:
          name: prod-pgcluster-uae-pgbackrest-secret
    global:
      archive-async: "y"
      compress-level: "3"
      compress-type: lz4
      process-max: "8"
      repo1-cipher-type: aes-256-cbc
      repo1-retention-diff: "7"
      repo1-retention-full: "4"
      repo1-retention-full-type: count
      repo1-s3-uri-style: path
      repo1-s3-verify-tls: "n"
      spool-path: /pgdata/pgbackrest-spool
    repos:
      - name: repo1
        s3:
          bucket: pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
          endpoint: s3-openshift-storage.apps.ocp-prod.habibbank.local
          region: prod
        schedules:
          full: "0 1 * * 0"
          differential: "0 1 * * 1-6"
          incremental: "0 */6 * * *"
    repoHost:
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
      nodeAffinity:
        dc: dc1
```

## PgBouncer Proxy

```yaml
proxy:
  pgBouncer:
    port: 5555
    replicas: 2
    service:
      type: ClusterIP
    resources:
      requests:
        cpu: "2"
        memory: 1Gi
      limits:
        cpu: "2"
        memory: 1Gi
    config:
      global:
        pool_mode: transaction
        max_client_conn: "2000"
        default_pool_size: "50"
        max_db_connections: "150"
        min_pool_size: "10"
        reserve_pool_size: "10"
        reserve_pool_timeout: "3"
        query_wait_timeout: "120"
        server_connect_timeout: "15"
        server_idle_timeout: "600"
        server_lifetime: "3600"
        server_login_retry: "15"
        server_reset_query: DISCARD ALL
        listen_backlog: "4096"
        log_connections: "0"
        log_disconnections: "0"
        stats_period: "60"
```

## Users In CR

```yaml
users:
  - name: postgres
    options: SUPERUSER
    databases: []
  - name: tps-app
    options: LOGIN
    databases: [tps]
  - name: tpsdw-app
    options: LOGIN
    databases: [tps_dw]
  - name: service-app
    options: LOGIN
    databases: [service]
  - name: common-app
    options: LOGIN
    databases: [common]
  - name: ro-user
    options: LOGIN
    databases: [tps, tps_dw, service, common]
```

## Status Conditions At Capture

```text
PGBackRestReplicaRepoReady=True
PGBackRestReplicaCreate=True
ProxyAvailable=True
```
