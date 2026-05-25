# Environment Overview

Capture time: 2026-05-22 09:27 CEST.

## Platform

| Layer | Value |
|---|---|
| Container platform | Red Hat OpenShift |
| Database operator | Crunchy Data PGO / Postgres Operator |
| Database engine | PostgreSQL 18 |
| HA manager | Patroni |
| Connection pooler | PgBouncer |
| Backup/PITR | pgBackRest, stanza `db`, repo `repo1` |
| Object storage | S3-compatible endpoint in OpenShift storage |
| Monitoring | Prometheus, pgBackRest Pushgateway, custom pg_inspector |

## PROD Cluster Identity

| Item | Value |
|---|---|
| OCP API | `https://api.ocp-prod.habibbank.local:6443` |
| Context | `prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali` |
| Namespace | `prod-pgcluster-uae` |
| PostgresCluster | `prod-pgcluster-uae` |
| Patroni scope | `prod-pgcluster-uae-ha` |
| Instance set | `dc1` |
| PostgreSQL port | `5555` |
| Patroni REST port | `8008` |
| Current leader | `prod-pgcluster-uae-dc1-9c5j-0` |
| Current sync standby | `prod-pgcluster-uae-dc1-5c2q-0` |

## Live Pods

```text
prod-pgcluster-uae-dc1-5c2q-0                  5/5 Running  IP 10.175.14.83   node lupr09c05ocpw5.habibbank.local
prod-pgcluster-uae-dc1-9c5j-0                  5/5 Running  IP 10.175.12.60   node lupr09c05ocpw4.habibbank.local
prod-pgcluster-uae-pgbouncer-6bff86f674-dhhww  2/2 Running  IP 10.175.12.58   node lupr09c05ocpw4.habibbank.local
prod-pgcluster-uae-pgbouncer-6bff86f674-t8wfl  2/2 Running  IP 10.175.14.105  node lupr09c05ocpw5.habibbank.local
prod-pgo18-pgbackrest-pushgateway-...-grw8w    1/1 Running  IP 10.175.12.49
prod-pgo18-prometheus-...-vj9cs                1/1 Running  IP 10.175.12.54
pgadmin-modern-6d857f9c7b-mz4g6                1/1 Running
pg-object-monitor-agent-7d8bd56f6c-swz7d       1/1 Running
```

Check again before using pod names:

```bash
oc get pods -n prod-pgcluster-uae -o wide
oc exec -n prod-pgcluster-uae <database-pod> -c database -- patronictl list
```

## Patroni State At Capture

```text
Cluster: prod-pgcluster-uae-ha
prod-pgcluster-uae-dc1-5c2q-0 = Sync Standby, streaming, TL 8, lag 0
prod-pgcluster-uae-dc1-9c5j-0 = Leader, running, TL 8
```

Replication from leader:

```text
application_name=prod-pgcluster-uae-dc1-5c2q-0
client_addr=10.175.14.83
state=streaming
sync_state=sync
write_lag/flush_lag/replay_lag empty
```

## Services And Endpoints

| Service | Type | Cluster IP | External IP | Port | Purpose |
|---|---|---:|---:|---:|---|
| `prod-pgcluster-uae-primary-lb` | LoadBalancer | `10.176.149.197` | `10.171.1.229` | `5555` | Direct primary endpoint, also DR upstream |
| `prod-pgcluster-uae-pgbouncer-lb` | LoadBalancer | `10.176.253.1` | `10.171.1.205` | `5555` | Application pooler endpoint |
| `prod-pgcluster-uae-pgbouncer` | ClusterIP | `10.176.99.245` | none | `5555` | Internal PgBouncer |
| `prod-pgcluster-uae-app-primary` | ClusterIP | `10.176.79.5` | none | `5555` | Internal app primary |
| `prod-pgcluster-uae-primary` | Headless | none | none | `5555` | Operator primary service |
| `prod-pgcluster-uae-replicas` | ClusterIP | `10.176.23.124` | none | `5555` | Replica service |
| `prod-pgcluster-uae-pods` | Headless | none | none | none | Pod DNS/headless service |

Endpoint check at capture:

```text
prod-pgcluster-uae-primary-lb     -> 10.175.12.60:5555
prod-pgcluster-uae-pgbouncer-lb   -> 10.175.12.58:5555,10.175.14.105:5555
```

## Storage

| PVC | Size | StorageClass |
|---|---:|---|
| `prod-pgcluster-uae-dc1-5c2q-pgdata` | 2Ti | `ocs-storagecluster-ceph-rbd` |
| `prod-pgcluster-uae-dc1-5c2q-pgwal` | 500Gi | `ocs-storagecluster-ceph-rbd` |
| `prod-pgcluster-uae-dc1-9c5j-pgdata` | 2Ti | `ocs-storagecluster-ceph-rbd` |
| `prod-pgcluster-uae-dc1-9c5j-pgwal` | 500Gi | `ocs-storagecluster-ceph-rbd` |

## Instance Sizing

| Item | Value |
|---|---|
| Instance replicas | 2 |
| Data PVC per instance | 2Ti |
| WAL PVC per instance | 500Gi |
| Database CPU request/limit | 16 / 16 |
| Database memory request/limit | 60Gi / 64Gi |
| Node affinity | `dc=dc1` |
| Pod anti-affinity | Required across hostname for database pods |

## Key PostgreSQL Parameters

| Parameter | Value |
|---|---|
| `max_connections` | `800` |
| `shared_buffers` | `24GB` |
| `effective_cache_size` | `48GB` |
| `work_mem` | `16MB` |
| `maintenance_work_mem` | `2GB` |
| `wal_level` | `logical` |
| `archive_mode` | `on` |
| `archive_timeout` | `60s` |
| `archive_command` | `pgbackrest --stanza=db archive-push "%p"` |
| `max_wal_size` | `64GB` |
| `min_wal_size` | `8GB` |
| `max_wal_senders` | `20` |
| `max_replication_slots` | `50` |
| `max_slot_wal_keep_size` | `300GB` |
| `synchronous_commit` | `on` |
| `synchronous_mode` | `true` |
| `synchronous_node_count` | `1` |
| `hot_standby` | `on` |
| `hot_standby_feedback` | `on` |
| `shared_preload_libraries` | `pg_stat_statements,pgaudit` |
| `pgaudit.log` | `ddl,role,write` |
| `statement_timeout` | `300000` ms |
| `idle_in_transaction_session_timeout` | `120000` ms |

## PgBouncer

| Item | Value |
|---|---|
| Replicas | 2 |
| Service port | `5555` |
| External LB | `10.171.1.205:5555` |
| Pool mode | `transaction` |
| `max_client_conn` | `2000` |
| `default_pool_size` | `50` |
| `max_db_connections` | `150` |
| `min_pool_size` | `10` |
| `reserve_pool_size` | `10` |
| Client TLS | required |
| Server TLS | verify-full |
| Auth query | `SELECT username, password from pgbouncer.get_auth($1)` |
| Database route | `* = host=prod-pgcluster-uae-primary port=5555` |

## Database Inventory At Capture

Live databases on 2026-05-22 after the 2026-05-21 UAT logical restore:

```text
uat_object_metrics          1597 MB
ae_service_uat              902 MB
ae_tps_uat                  444 MB
ae_tps_warehouse_uat        291 MB
landlord_uat                15 MB
ae_common_uat               11 MB
postgres                    8054 kB
uk_common_uat               7910 kB
ch_common_uat               7902 kB
ch_service_uat              7902 kB
ch_tps_uat                  7902 kB
ch_tps_warehouse_uat        7902 kB
ke_common_uat               7902 kB
ke_service_uat              7902 kB
ke_tps_warehouse_uat        7902 kB
ke_tps_uat                  7902 kB
sa_common_uat               7902 kB
sa_service_uat              7902 kB
sa_tps_uat                  7902 kB
sa_tps_warehouse_uat        7902 kB
uk_service_uat              7902 kB
uk_tps_uat                  7902 kB
uk_tps_warehouse_uat        7902 kB
```

Important: the PostgresCluster user spec still defines application roles for `service`, `common`, `tps`, and `tps_dw`. Verify actual app connection strings before changing or dropping databases.

## Users Defined In PostgresCluster CR

| Role | Databases in CR | Options |
|---|---|---|
| `postgres` | none | `SUPERUSER` |
| `service-app` | `service` | `LOGIN` |
| `common-app` | `common` | `LOGIN` |
| `tps-app` | `tps` | `LOGIN` |
| `tpsdw-app` | `tps_dw` | `LOGIN` |
| `ro-user` | `tps`, `tps_dw`, `service`, `common` | `LOGIN` |

## Login

Do not put passwords in scripts or shell history.

```bash
oc login https://api.ocp-prod.habibbank.local:6443 -u mohsinali
oc project prod-pgcluster-uae
oc config current-context
```
