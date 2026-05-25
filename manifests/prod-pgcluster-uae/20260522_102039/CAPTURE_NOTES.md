# Capture Notes

Capture: `20260522_102039`

Captured successfully:

- Namespace and `PostgresCluster` CR
- 15 ConfigMaps
- 13 Services and 4 Routes
- 6 NetworkPolicies
- 5 Deployments, 2 StatefulSets, 4 CronJobs, 16 Jobs
- 10 ServiceAccounts, 6 Roles, 12 RoleBindings
- 5 PVCs and 7 StorageClasses
- 17 ClusterServiceVersions visible in the namespace
- 22 Secrets as key-name inventory and no-value templates only

Permission-limited items:

- Monitoring CRs were not captured because this user cannot list `servicemonitors`, `podmonitors`, `prometheusrules`, `prometheuses`, or `alertmanagers` in `prod-pgcluster-uae`.
- Cluster-scope CRDs were not captured because this user cannot list `customresourcedefinitions.apiextensions.k8s.io`.
- Node label inventory was not captured because this user cannot list cluster-scope `nodes`.

For a complete whole-platform rebuild bundle, rerun `./scripts/export-prod-cluster-manifests.sh` using an approved account that has read access to those cluster-scope and monitoring resources.
