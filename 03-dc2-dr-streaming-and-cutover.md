# DC2 DR Streaming And Cutover

This document covers the DR/DC2 standby design and the safe cutover process.

Live PROD data was captured on 2026-05-22. Live DR API access from this terminal timed out on 2026-05-22, so DR object details below come from saved local precheck evidence:

```text
/home/mohsinali@habibbank.local/PROD_PATRONI/cutover_runs/20260518_130639_planned-switchover_precheck/
```

## DR Identity

| Item | Value |
|---|---|
| DR OCP API | `https://api.ocp-dr.habibbank.local:6443` |
| DR context | `dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali` |
| DR namespace | `dr-pgcluster-uae` |
| DR PostgresCluster | `dr-pgcluster-uae` |
| DR Patroni cluster | `dr-pgcluster-uae-ha` |
| PostgreSQL port | `5555` |
| Standby enabled | `true` in saved spec |
| Standby upstream host | `10.171.1.229` |
| Standby upstream port | `5555` |
| Standby repo | `repo1` |

DR standby spec from saved evidence:

```json
{
  "enabled": true,
  "host": "10.171.1.229",
  "port": 5555,
  "repoName": "repo1"
}
```

## Architecture

DR is a Crunchy PGO standby cluster. It uses:

- `spec.standby.enabled=true`.
- Upstream host `10.171.1.229:5555`, the PROD primary LB.
- The same S3 bucket and endpoint as PROD for pgBackRest archive recovery.
- `repo1` as the pgBackRest repo.
- PostgreSQL recovery mode until promoted.

Expected DR state before promotion:

```text
DR database pods: pg_is_in_recovery() = true
Patroni role: Standby Leader / Replica, not normal writable Leader
WAL receiver: active if live streaming path to PROD is working
restore_command: pgBackRest archive-get path from S3 repo
```

## DR pgBackRest/S3 Settings

From saved DR PostgresCluster spec:

```text
repo1-type=s3
repo1-path=/pgbackrest/repo1
repo1-s3-bucket=pgbackrest-uae-prod-609d40f1-26e9-4616-9021-3135255d453e
repo1-s3-endpoint=s3-openshift-storage.apps.ocp-prod.habibbank.local
repo1-s3-region=prod
repo1-s3-uri-style=path
repo1-s3-verify-tls=n
repo1-cipher-type=aes-256-cbc
repo1-storage-host=10.20.15.15
secret=dr-pgcluster-uae-pgbackrest-secret
```

DR has no backup schedules in the saved spec. It reads the shared repo for standby/restore. PROD owns the backup schedule.

## Saved DR Pod State From 2026-05-18 Precheck

```text
dr-pgcluster-uae-dc1-p4rh-0  ready=true   pg_is_in_recovery=t  pod_ip=10.185.12.74  node=schr02c10ocpw4.habibbank.local
dr-pgcluster-uae-dc1-lm6b-0  ready=false  pg_is_in_recovery=t  pod_ip=10.185.17.38  node=schr02c10ocpw6.habibbank.local
```

Saved DR status conditions:

```text
PGBackRestReplicaRepoReady=False reason=StanzaNotCreated
PGBackRestReplicaCreate=False reason=RepoBackupNotComplete
ProxyAvailable=True
status.instances: readyReplicas=1 replicas=2 updatedReplicas=2
```

Saved pgBackRest info from DR still returned OK from the probe pod:

```text
stanza=db
status=ok
cipher=aes-256-cbc
backup_count=30
archive_min=000000010000000000000001
archive_max=000000040000000000000075
```

## Known DR Blockers From Existing SOP

The DR cutover SOP recorded these blockers at preparation time:

```text
DR pods -> 10.171.1.229:5555 = no response
PROD leader -> 10.171.1.229:5555 = accepting connections
```

Likely area: network policy/firewall/routing. PROD policy allowed `10.181.1.0/24`, while DR database pod IPs were observed in `10.185.x.x`.

Second issue:

```text
DR pod DNS timeout for kubernetes.default.svc and DR pod headless service names.
Direct pod IP 10.185.12.74:5555 was accepting connections.
```

Do not proceed with planned DR switchover while DR pod readiness, DNS, or DR-to-PROD streaming is broken.

## Current DR API Access From This Terminal

On 2026-05-22, this command timed out:

```bash
oc --context=dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali \
  get postgrescluster dr-pgcluster-uae -n dr-pgcluster-uae
```

Error:

```text
dial tcp 10.20.115.14:6443: i/o timeout
```

Before a real DR check, confirm VPN/routing/firewall access to `api.ocp-dr.habibbank.local:6443`.

## DR Health Commands

```bash
DR_CTX='dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali'
DR_NS='dr-pgcluster-uae'
DR_CLUSTER='dr-pgcluster-uae'

oc --context="$DR_CTX" project -q
oc --context="$DR_CTX" get postgrescluster "$DR_CLUSTER" -n "$DR_NS" -o json
oc --context="$DR_CTX" get pods -n "$DR_NS" -o wide
oc --context="$DR_CTX" get svc,endpoints -n "$DR_NS" -o wide
```

Patroni:

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- patronictl list
```

Recovery and WAL receiver:

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  psql -U postgres -d postgres -XAtc \
  "select pg_is_in_recovery(), pg_is_wal_replay_paused(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), (select count(*) from pg_stat_wal_receiver);"
```

Recovery config:

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  psql -U postgres -d postgres -XAtc "show primary_conninfo; show restore_command; show primary_slot_name;"
```

pgBackRest from DR:

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  pgbackrest --stanza=db --repo=1 info
```

## PROD To DR Lag Check

```bash
PROD_CTX='prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali'
PROD_NS='prod-pgcluster-uae'
DR_CTX='dr-pgcluster-uae/api-ocp-dr-habibbank-local:6443/mohsinali'
DR_NS='dr-pgcluster-uae'

PROD_LEADER_POD='<current-prod-leader>'
DR_STANDBY_POD='<current-dr-standby-leader-or-ready-pod>'

PROD_LSN="$(oc --context="$PROD_CTX" exec -n "$PROD_NS" "$PROD_LEADER_POD" -c database -- psql -U postgres -XAtc "select pg_current_wal_lsn();")"
DR_LSN="$(oc --context="$DR_CTX" exec -n "$DR_NS" "$DR_STANDBY_POD" -c database -- psql -U postgres -XAtc "select pg_last_wal_replay_lsn();")"

echo "PROD_LSN=$PROD_LSN"
echo "DR_REPLAY_LSN=$DR_LSN"

oc --context="$PROD_CTX" exec -n "$PROD_NS" "$PROD_LEADER_POD" -c database -- \
  psql -U postgres -XAtc "select pg_size_pretty(pg_wal_lsn_diff('$PROD_LSN', '$DR_LSN'));"
```

For a planned switchover, target lag is zero bytes after application writes are frozen.

## DR To PROD Connectivity

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  pg_isready -h 10.171.1.229 -p 5555 -d postgres -t 5
```

If `pg_isready` is unavailable or inconclusive:

```bash
oc --context="$DR_CTX" exec -n "$DR_NS" <dr-db-pod> -c database -- \
  bash -ceu 'timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.171.1.229/5555" && echo tcp_ok || echo tcp_failed'
```

## Planned Switchover Safe Sequence

Use the automation script:

```text
/home/mohsinali@habibbank.local/PROD_PATRONI/prod_dr_cutover.py
```

Full SOP:

```text
/home/mohsinali@habibbank.local/PROD_PATRONI/PROD_DR_CUTOVER_SOP.md
```

Safe sequence:

```text
1. Freeze application writes.
2. Verify final PROD to DR WAL lag is acceptable, preferably zero bytes.
3. Shutdown or fence active PROD PostgresCluster.
4. Verify PROD database pods are stopped.
5. Disable DR standby mode.
6. Verify DR is writable primary.
7. Route applications to DR only after verification.
```

Do not use `patronictl failover` for cross-site DR promotion. PGO standby promotion is done by patching DR `spec.standby.enabled=false` only after PROD is fenced or shut down.

## Planned Switchover Commands

Precheck:

```bash
cd /home/mohsinali@habibbank.local/PROD_PATRONI

python3 prod_dr_cutover.py precheck \
  --mode planned-switchover \
  --max-lag-bytes 0 \
  --max-replay-delay-seconds 30 \
  --max-archive-age-seconds 600 \
  --archiver-sample-seconds 60 \
  --postgres-port 5555 \
  --ignore-db-users postgres
```

Generate review files:

```bash
python3 prod_dr_cutover.py generate \
  --mode planned-switchover \
  --run-dir cutover_runs/<PRECHECK_RUN_DIR>
```

Dry-run execute:

```bash
python3 prod_dr_cutover.py execute \
  --manifest cutover_runs/<PRECHECK_RUN_DIR>/command_manifest.json \
  --dry-run-execute
```

High-risk steps require approval token and gate files. Do not run them from this README without a formal approved change window.

## Disaster Failover Principle

Use disaster failover only when PROD is unreachable, lost, or formally fenced.

Minimum evidence before DR promotion:

```text
Incident commander confirms PROD cannot accept writes.
Network/storage/routing confirms PROD is fenced or lost.
RPO is accepted based on DR replay and pgBackRest evidence.
DR pgBackRest repo is readable.
DR recovery state and replay LSN are documented.
```

Promotion command shape:

```bash
oc --context="$DR_CTX" patch postgrescluster dr-pgcluster-uae \
  -n dr-pgcluster-uae \
  --type=merge \
  -p '{"spec":{"standby":{"enabled":false}}}'
```

## Switchback Principle

After DR has accepted writes, old PROD must not be restarted as a writable primary with stale data.

Switchback requires a rebuild or reinitialization of former PROD as a standby from the current DR/S3 source, then a separate controlled switchover back.
