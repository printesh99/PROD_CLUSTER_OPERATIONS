#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-prod-pgcluster-uae}"
POSTGRES_CLUSTER="${POSTGRES_CLUSTER:-prod-pgcluster-uae}"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-prod-pgcluster-uae/api-ocp-prod-habibbank-local:6443/mohsinali}"
ALLOW_CONTEXT_MISMATCH="${ALLOW_CONTEXT_MISMATCH:-false}"
TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/manifests/$NAMESPACE/$TS}"

log() {
  printf '%s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

safe_name() {
  printf '%s' "$1" | tr '/.' '__' | tr '[:upper:]' '[:lower:]'
}

write_text_cmd() {
  local file="$1"
  shift

  if "$@" >"$file" 2>"$file.err"; then
    rm -f "$file.err"
  else
    log "WARN: failed to capture $*; see $file.err"
  fi
}

scrub_jq='
  def clean_annotations:
    if .annotations then
      .annotations |= del(
        ."kubectl.kubernetes.io/last-applied-configuration",
        ."deployment.kubernetes.io/revision",
        ."openshift.io/sa.scc.mcs",
        ."openshift.io/sa.scc.supplemental-groups",
        ."openshift.io/sa.scc.uid-range"
      )
    else . end;

  def clean_meta:
    if .metadata then
      .metadata |= (
        del(
          .creationTimestamp,
          .generation,
          .managedFields,
          .ownerReferences,
          .resourceVersion,
          .selfLink,
          .uid
        )
        | clean_annotations
      )
    else . end;

  def clean_service:
    if .kind == "Service" and .spec then
      .spec |= del(.clusterIP, .clusterIPs, .ipFamilies, .ipFamilyPolicy)
    else . end;

  def clean_pvc:
    if .kind == "PersistentVolumeClaim" and .spec then
      .spec |= del(.volumeName)
    else . end;

  def clean_job:
    if .kind == "Job" and .spec then
      .spec |= del(.selector)
    else . end;

  def clean_obj:
    clean_meta
    | del(.status)
    | clean_service
    | clean_pvc
    | clean_job;

  clean_meta
  | if has("items") then
      .items |= map(clean_obj)
    else
      clean_obj
    end
'

secret_template_jq='
  def clean_annotations:
    if .annotations then
      .annotations |= del(
        ."kubectl.kubernetes.io/last-applied-configuration",
        ."deployment.kubernetes.io/revision",
        ."openshift.io/sa.scc.mcs",
        ."openshift.io/sa.scc.supplemental-groups",
        ."openshift.io/sa.scc.uid-range"
      )
    else . end;

  def clean_meta:
    if .metadata then
      .metadata |= (
        del(
          .creationTimestamp,
          .generation,
          .managedFields,
          .ownerReferences,
          .resourceVersion,
          .selfLink,
          .uid
        )
        | clean_annotations
      )
    else . end;

  clean_meta
  | .items |= map(
      ((.data // {}) | keys) as $secret_keys
      |
      clean_meta
      | del(.data, .stringData, .status)
      | .stringData = ($secret_keys | map({key: ., value: "REPLACE_WITH_APPROVED_SECRET_VALUE"}) | from_entries)
    )
'

secret_inventory_jq='
  {
    apiVersion: "v1",
    kind: "SecretKeyInventory",
    namespace: "'"$NAMESPACE"'",
    items: [
      .items[]
      | {
          name: .metadata.name,
          type: .type,
          labels: (.metadata.labels // {}),
          annotations: (.metadata.annotations // {} | del(."kubectl.kubernetes.io/last-applied-configuration", ."deployment.kubernetes.io/revision", ."openshift.io/sa.scc.mcs", ."openshift.io/sa.scc.supplemental-groups", ."openshift.io/sa.scc.uid-range")),
          keys: ((.data // {}) | keys)
        }
    ]
  }
'

export_namespaced_resource() {
  local resource="$1"
  local dir="$2"
  local file="$dir/$(safe_name "$resource").manifest.json"
  local tmp err count

  tmp="$(mktemp)"
  err="$(mktemp)"
  if oc get "$resource" -n "$NAMESPACE" -o json >"$tmp" 2>"$err"; then
    count="$(jq 'if has("items") then (.items | length) else 1 end' "$tmp")"
    if [ "$count" = "0" ]; then
      rm -f "$tmp" "$err"
      return 0
    fi
    jq "$scrub_jq" "$tmp" >"$file"
    log "captured namespaced $resource ($count) -> ${file#$ROOT_DIR/}"
  else
    log "WARN: skipped namespaced $resource: $(tr '\n' ' ' <"$err")"
  fi
  rm -f "$tmp" "$err"
}

export_cluster_resource() {
  local resource="$1"
  local dir="$2"
  local file="$dir/$(safe_name "$resource").manifest.json"
  local tmp err count

  tmp="$(mktemp)"
  err="$(mktemp)"
  if oc get "$resource" -o json >"$tmp" 2>"$err"; then
    count="$(jq 'if has("items") then (.items | length) else 1 end' "$tmp")"
    if [ "$count" = "0" ]; then
      rm -f "$tmp" "$err"
      return 0
    fi
    jq "$scrub_jq" "$tmp" >"$file"
    log "captured cluster $resource ($count) -> ${file#$ROOT_DIR/}"
  else
    log "WARN: skipped cluster $resource: $(tr '\n' ' ' <"$err")"
  fi
  rm -f "$tmp" "$err"
}

require_cmd oc
require_cmd jq
require_cmd date
require_cmd mktemp

current_context="$(oc config current-context)"
if [ "$current_context" != "$EXPECTED_CONTEXT" ] && [ "$ALLOW_CONTEXT_MISMATCH" != "true" ]; then
  log "ERROR: current context is '$current_context'"
  log "Expected '$EXPECTED_CONTEXT'."
  log "Set ALLOW_CONTEXT_MISMATCH=true only after manually verifying the target cluster."
  exit 1
fi

mkdir -p \
  "$OUT_DIR/00-context" \
  "$OUT_DIR/01-core" \
  "$OUT_DIR/02-network" \
  "$OUT_DIR/03-config" \
  "$OUT_DIR/04-workloads" \
  "$OUT_DIR/05-storage" \
  "$OUT_DIR/06-rbac" \
  "$OUT_DIR/07-monitoring" \
  "$OUT_DIR/08-operators" \
  "$OUT_DIR/09-secrets" \
  "$OUT_DIR/99-evidence"

log "Export target: $OUT_DIR"
log "Namespace:     $NAMESPACE"
log "Context:       $current_context"

write_text_cmd "$OUT_DIR/00-context/current-context.txt" oc config current-context
write_text_cmd "$OUT_DIR/00-context/project.txt" oc project
write_text_cmd "$OUT_DIR/00-context/whoami.txt" oc whoami
write_text_cmd "$OUT_DIR/99-evidence/api-resources.namespaced.txt" oc api-resources --namespaced=true -o wide
write_text_cmd "$OUT_DIR/99-evidence/api-resources.cluster.txt" oc api-resources --namespaced=false -o wide

export_cluster_resource "namespace/$NAMESPACE" "$OUT_DIR/01-core"
export_namespaced_resource "postgrescluster/$POSTGRES_CLUSTER" "$OUT_DIR/01-core"
export_namespaced_resource "configmap" "$OUT_DIR/03-config"
export_namespaced_resource "service" "$OUT_DIR/02-network"
export_namespaced_resource "route" "$OUT_DIR/02-network"
export_namespaced_resource "networkpolicy" "$OUT_DIR/02-network"
export_namespaced_resource "deployment" "$OUT_DIR/04-workloads"
export_namespaced_resource "statefulset" "$OUT_DIR/04-workloads"
export_namespaced_resource "daemonset" "$OUT_DIR/04-workloads"
export_namespaced_resource "cronjob" "$OUT_DIR/04-workloads"
export_namespaced_resource "job" "$OUT_DIR/04-workloads"
export_namespaced_resource "serviceaccount" "$OUT_DIR/06-rbac"
export_namespaced_resource "role" "$OUT_DIR/06-rbac"
export_namespaced_resource "rolebinding" "$OUT_DIR/06-rbac"
export_namespaced_resource "persistentvolumeclaim" "$OUT_DIR/05-storage"
export_namespaced_resource "servicemonitor.monitoring.coreos.com" "$OUT_DIR/07-monitoring"
export_namespaced_resource "podmonitor.monitoring.coreos.com" "$OUT_DIR/07-monitoring"
export_namespaced_resource "prometheusrule.monitoring.coreos.com" "$OUT_DIR/07-monitoring"
export_namespaced_resource "prometheus.monitoring.coreos.com" "$OUT_DIR/07-monitoring"
export_namespaced_resource "alertmanager.monitoring.coreos.com" "$OUT_DIR/07-monitoring"
export_namespaced_resource "subscription.operators.coreos.com" "$OUT_DIR/08-operators"
export_namespaced_resource "operatorgroup.operators.coreos.com" "$OUT_DIR/08-operators"
export_namespaced_resource "clusterserviceversion.operators.coreos.com" "$OUT_DIR/08-operators"

export_cluster_resource "storageclass" "$OUT_DIR/05-storage"

if oc get secret -n "$NAMESPACE" -o json >"$OUT_DIR/09-secrets/.secrets.tmp.json" 2>"$OUT_DIR/09-secrets/secrets.capture.err"; then
  jq "$secret_inventory_jq" "$OUT_DIR/09-secrets/.secrets.tmp.json" >"$OUT_DIR/09-secrets/secret-key-inventory.json"
  jq "$secret_template_jq" "$OUT_DIR/09-secrets/.secrets.tmp.json" >"$OUT_DIR/09-secrets/secret-templates.no-values.json"
  rm -f "$OUT_DIR/09-secrets/.secrets.tmp.json" "$OUT_DIR/09-secrets/secrets.capture.err"
  log "captured secret key inventory and redacted templates -> ${OUT_DIR#$ROOT_DIR/}/09-secrets"
else
  log "WARN: failed to capture secret inventory; see ${OUT_DIR#$ROOT_DIR/}/09-secrets/secrets.capture.err"
fi

if oc get crd -o json >"$OUT_DIR/08-operators/.crds.tmp.json" 2>"$OUT_DIR/08-operators/crds.capture.err"; then
  jq "$scrub_jq"' | .items |= map(select(.metadata.name | test("(postgres-operator\\.crunchydata\\.com|monitoring\\.coreos\\.com|operators\\.coreos\\.com)$")))' \
    "$OUT_DIR/08-operators/.crds.tmp.json" >"$OUT_DIR/08-operators/operator-related-crds.manifest.json"
  rm -f "$OUT_DIR/08-operators/.crds.tmp.json" "$OUT_DIR/08-operators/crds.capture.err"
  log "captured operator-related CRDs -> ${OUT_DIR#$ROOT_DIR/}/08-operators/operator-related-crds.manifest.json"
else
  log "WARN: failed to capture CRD inventory; see ${OUT_DIR#$ROOT_DIR/}/08-operators/crds.capture.err"
fi

write_text_cmd "$OUT_DIR/05-storage/storageclasses.txt" oc get storageclass -o wide
write_text_cmd "$OUT_DIR/99-evidence/nodes-with-labels.txt" oc get nodes -o wide --show-labels
write_text_cmd "$OUT_DIR/99-evidence/pods-wide.txt" oc get pods -n "$NAMESPACE" -o wide
write_text_cmd "$OUT_DIR/99-evidence/services-wide.txt" oc get svc -n "$NAMESPACE" -o wide
write_text_cmd "$OUT_DIR/99-evidence/pvc-wide.txt" oc get pvc -n "$NAMESPACE" -o wide
write_text_cmd "$OUT_DIR/99-evidence/configmap-secret-names.txt" oc get configmap,secret -n "$NAMESPACE" -o name

cat >"$OUT_DIR/README.md" <<EOF
# Cluster Manifest Export

Capture time: $TS
Namespace: $NAMESPACE
OpenShift context: $current_context

This export is intended as a rebuild/reference bundle for the production PostgreSQL namespace.

Important safety notes:

- Secret values are not present. See \`09-secrets/secret-key-inventory.json\` and recreate values through an approved secure channel.
- JSON files ending in \`.manifest.json\` are Kubernetes manifests that can be inspected with \`jq\` and applied with \`oc apply -f\` after review.
- Runtime fields such as \`status\`, \`uid\`, \`resourceVersion\`, \`managedFields\`, service \`clusterIP\`, and PVC \`volumeName\` were removed.
- Any \`.err\` files indicate resources that could not be captured with the current OpenShift RBAC.
- Operator-generated objects are captured for evidence. For a new PGO cluster, normally install the operator and apply the \`PostgresCluster\` CR first; do not blindly apply generated StatefulSets or generated ConfigMaps over an operator-managed cluster.

Suggested review order:

1. \`00-context/\`
2. \`08-operators/\`
3. \`01-core/\`
4. \`09-secrets/\`
5. \`03-config/\`
6. \`02-network/\`
7. \`05-storage/\`
8. \`06-rbac/\`
9. \`07-monitoring/\`
10. \`04-workloads/\`
11. \`99-evidence/\`
EOF

ln -sfn "$NAMESPACE/$TS" "$ROOT_DIR/manifests/latest"
log "latest symlink -> manifests/$NAMESPACE/$TS"
log "done"
