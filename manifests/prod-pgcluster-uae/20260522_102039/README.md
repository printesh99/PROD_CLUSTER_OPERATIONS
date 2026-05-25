# Cluster Manifest Export

Capture time: 20260522_102039
Namespace: prod-pgcluster-uae
OpenShift context: prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali

This export is intended as a rebuild/reference bundle for the production PostgreSQL namespace. See `CAPTURE_NOTES.md` for captured counts and RBAC-limited resources.

Important safety notes:

- Secret values are not present. See `09-secrets/secret-key-inventory.json` and recreate values through an approved secure channel.
- JSON files ending in `.manifest.json` are Kubernetes manifests that can be inspected with `jq` and applied with `oc apply -f` after review.
- Runtime fields such as `status`, `uid`, `resourceVersion`, `managedFields`, service `clusterIP`, and PVC `volumeName` were removed.
- Any `.err` files indicate resources that could not be captured with the current OpenShift RBAC.
- Operator-generated objects are captured for evidence. For a new PGO cluster, normally install the operator and apply the `PostgresCluster` CR first; do not blindly apply generated StatefulSets or generated ConfigMaps over an operator-managed cluster.

Suggested review order:

1. `00-context/`
2. `08-operators/`
3. `01-core/`
4. `09-secrets/`
5. `03-config/`
6. `02-network/`
7. `05-storage/`
8. `06-rbac/`
9. `07-monitoring/`
10. `04-workloads/`
11. `99-evidence/`
