# Production Cluster Manifest Bundle

This directory stores OpenShift/Kubernetes manifests and evidence needed to rebuild another PostgreSQL cluster based on the current PROD cluster.

## Refresh The Bundle

Run from this folder:

```bash
./scripts/export-prod-cluster-manifests.sh
```

Default target:

```text
manifests/prod-pgcluster-uae/<YYYYMMDD_HHMMSS>/
```

The script also updates:

```text
manifests/latest -> prod-pgcluster-uae/<latest-capture>
```

## What Is Captured

| Directory | Contents |
|---|---|
| `00-context/` | OpenShift context, namespace/project, user, API resource discovery |
| `01-core/` | Namespace and `PostgresCluster` custom resource |
| `02-network/` | Services, routes, network policies |
| `03-config/` | ConfigMaps |
| `04-workloads/` | Deployments, StatefulSets, DaemonSets, Jobs, CronJobs |
| `05-storage/` | PVC manifests, StorageClass manifest and inventory |
| `06-rbac/` | ServiceAccounts, Roles, RoleBindings |
| `07-monitoring/` | ServiceMonitor, PodMonitor, PrometheusRule, Prometheus, Alertmanager resources when present |
| `08-operators/` | Operator resources and operator-related CRD snapshots when accessible |
| `09-secrets/` | Secret names, types, key names, and no-value templates |
| `99-evidence/` | Human-readable inventories such as pods, services, PVCs, node labels |

## Secret Handling

Secret values are intentionally not exported. The files under `09-secrets/` contain only:

- Secret names
- Secret types
- Labels and annotations
- Key names
- Placeholder templates

Recreate real secret values through the approved DBA/security process before applying manifests in another cluster.

## Rebuild Guidance

Use this bundle as source material, not as a blind restore.

Typical order for a new cluster:

1. Create or verify the target namespace/project.
2. Install the same required operators and CRDs, especially Crunchy PGO and monitoring CRDs.
3. Recreate required secrets from `09-secrets/` using approved secret values.
4. Review storage class names, node labels, load balancer requirements, S3 endpoint/bucket, and namespace names.
5. Apply the reviewed `PostgresCluster` manifest.
6. Let PGO generate database pods, services, configmaps, and PVCs.
7. Apply only the additional monitoring, RBAC, network, and custom workload manifests that are required in the target cluster.
8. Restore or seed data using the pgBackRest/PITR runbooks.

Do not blindly apply operator-generated StatefulSets, generated ConfigMaps, PVC bindings, or old service cluster IPs into a new cluster.

If `.err` files exist in a capture, they mark resources that the current OpenShift user could not read. Rerun the exporter with an approved account that has those read permissions when a complete whole-platform bundle is required.
