#!/usr/bin/env bash
# Sends logs, metrics and traces from the cluster to Grafana Cloud (free tier) and loads the AIP dashboard.
#
#   scripts/monitoring-setup.sh install      create the secret and install Grafana Kubernetes Monitoring (Alloy + Beyla)
#   scripts/monitoring-setup.sh dashboard    upload monitoring/dashboards/aip-platform-overview.json to Grafana
#   scripts/monitoring-setup.sh preview      render the Kubernetes objects without installing (helm template)
#   scripts/monitoring-setup.sh status       show the monitoring pods
#   scripts/monitoring-setup.sh uninstall    remove everything from the monitoring namespace
#
# Settings come from environment variables (see README, "Observability with Grafana Cloud"). Never commit them.
#   install:   GRAFANA_CLOUD_PROMETHEUS_URL  GRAFANA_CLOUD_PROMETHEUS_USER
#              GRAFANA_CLOUD_LOKI_URL        GRAFANA_CLOUD_LOKI_USER
#              GRAFANA_CLOUD_OTLP_URL        GRAFANA_CLOUD_OTLP_USER
#              GRAFANA_CLOUD_TOKEN           (access policy token: metrics:write, logs:write, traces:write)
#              CLUSTER_NAME                  optional, default aip-local
#   dashboard: GRAFANA_URL                   e.g. https://yourstack.grafana.net
#              GRAFANA_SA_TOKEN              Grafana service account token with the Editor role
set -euo pipefail

NAMESPACE=monitoring
RELEASE=k8s-monitoring
CHART=grafana/k8s-monitoring
CHART_VERSION=4.5.3
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES="$ROOT/monitoring/k8s-monitoring-values.yaml"
DASHBOARD="$ROOT/monitoring/dashboards/aip-platform-overview.json"
CLUSTER_NAME="${CLUSTER_NAME:-aip-local}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_tools() {
  for tool in "$@"; do command -v "$tool" >/dev/null || die "$tool is not installed (macOS: brew install $tool)"; done
}

need_env() {
  local missing=()
  for name in "$@"; do [ -n "${!name:-}" ] || missing+=("$name"); done
  [ ${#missing[@]} -eq 0 ] || die "set these environment variables first: ${missing[*]}"
}

helm_args() {
  echo --namespace "$NAMESPACE" --version "$CHART_VERSION" --values "$VALUES" \
    --set "cluster.name=$CLUSTER_NAME" \
    --set "destinations.grafana-cloud-metrics.url=$GRAFANA_CLOUD_PROMETHEUS_URL" \
    --set "destinations.grafana-cloud-logs.url=$GRAFANA_CLOUD_LOKI_URL" \
    --set "destinations.grafana-cloud-traces.url=$GRAFANA_CLOUD_OTLP_URL"
}

add_repo() {
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update grafana >/dev/null
}

install() {
  need_tools kubectl helm
  need_env GRAFANA_CLOUD_PROMETHEUS_URL GRAFANA_CLOUD_PROMETHEUS_USER GRAFANA_CLOUD_LOKI_URL GRAFANA_CLOUD_LOKI_USER \
           GRAFANA_CLOUD_OTLP_URL GRAFANA_CLOUD_OTLP_USER GRAFANA_CLOUD_TOKEN

  echo "==> Namespace $NAMESPACE"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  echo "==> Secret grafana-cloud (values are not printed)"
  kubectl -n "$NAMESPACE" create secret generic grafana-cloud \
    --from-literal=prometheus-username="$GRAFANA_CLOUD_PROMETHEUS_USER" \
    --from-literal=loki-username="$GRAFANA_CLOUD_LOKI_USER" \
    --from-literal=otlp-username="$GRAFANA_CLOUD_OTLP_USER" \
    --from-literal=access-token="$GRAFANA_CLOUD_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  echo "==> Helm chart $CHART $CHART_VERSION (cluster name: $CLUSTER_NAME)"
  add_repo
  # shellcheck disable=SC2046
  helm upgrade --install "$RELEASE" "$CHART" $(helm_args) --wait --timeout 10m

  echo "==> Done. Data appears in Grafana Cloud within a few minutes:"
  echo "    Kubernetes: Observability > Kubernetes   Services: Observability > Application"
  echo "    Logs: Drilldown > Logs                   Dashboard: scripts/monitoring-setup.sh dashboard"
  status
}

preview() {
  need_tools helm
  # Placeholder URLs are enough to render the objects
  GRAFANA_CLOUD_PROMETHEUS_URL="${GRAFANA_CLOUD_PROMETHEUS_URL:-https://prometheus.example.grafana.net/api/prom/push}"
  GRAFANA_CLOUD_LOKI_URL="${GRAFANA_CLOUD_LOKI_URL:-https://logs.example.grafana.net/loki/api/v1/push}"
  GRAFANA_CLOUD_OTLP_URL="${GRAFANA_CLOUD_OTLP_URL:-https://otlp-gateway.example.grafana.net/otlp}"
  add_repo
  # shellcheck disable=SC2046
  helm template "$RELEASE" "$CHART" $(helm_args)
}

dashboard() {
  need_tools curl
  need_env GRAFANA_URL GRAFANA_SA_TOKEN
  echo "==> Uploading AIP Platform Overview to ${GRAFANA_URL%/}"
  local body response
  body=$(printf '{"dashboard": %s, "overwrite": true, "message": "scripts/monitoring-setup.sh"}' \
    "$(sed 's/"version": [0-9]*,//' "$DASHBOARD")")
  response=$(curl -sS -w '\n%{http_code}' -X POST "${GRAFANA_URL%/}/api/dashboards/db" \
    -H "Authorization: Bearer $GRAFANA_SA_TOKEN" -H "Content-Type: application/json" --data-binary "$body")
  local code="${response##*$'\n'}"
  [ "$code" = "200" ] || die "Grafana returned HTTP $code: ${response%$'\n'*}"
  echo "    ${GRAFANA_URL%/}/d/aip-platform-overview"
}

status() {
  need_tools kubectl
  kubectl -n "$NAMESPACE" get pods -o wide
}

uninstall() {
  need_tools kubectl helm
  helm uninstall "$RELEASE" --namespace "$NAMESPACE" --wait || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
}

case "${1:-}" in
  install) install ;;
  dashboard) dashboard ;;
  preview) preview ;;
  status) status ;;
  uninstall) uninstall ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
