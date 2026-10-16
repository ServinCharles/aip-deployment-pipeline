#!/usr/bin/env bash
# Deploys one service image to one environment, then proves it works.
#
#   ./scripts/deploy.sh <service> <environment> <image>
#   ./scripts/deploy.sh aip-api sit-01 123456789012.dkr.ecr.eu-west-2.amazonaws.com/aip-api:3f2a1c9
#
# 1. Pins the image on top of k8s/environments/<environment>/<service> and applies it
# 2. Waits for the rollout; if it fails, rolls back to the previous version automatically
# 3. Smoke-tests the service from inside the cluster; rolls back if that fails too
#
# Used by the Jenkins deploy pipeline and for manual deploys.
# Optional env: ROLLOUT_TIMEOUT (default 180s), KUBECTL (default "kubectl"; Jenkins passes a
# containerised kubectl via scripts/kubectl-docker.sh so the Jenkins machine only needs Docker).
set -euo pipefail

SERVICE="${1:?usage: deploy.sh <service> <environment> <image>}"
ENVIRONMENT="${2:?usage: deploy.sh <service> <environment> <image>}"
IMAGE="${3:?usage: deploy.sh <service> <environment> <image>}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
KUBECTL="${KUBECTL:-kubectl}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="${ROOT}/k8s/environments/${ENVIRONMENT}/${SERVICE}"
[ -f "${ENV_DIR}/kustomization.yaml" ] || { echo "No such service/environment: ${SERVICE} in ${ENVIRONMENT}"; exit 1; }

case "$SERVICE" in
  aip-api)    NAMESPACE="${ENVIRONMENT}-api" ;;
  aip-webapp) NAMESPACE="${ENVIRONMENT}-dip" ;;
  *) echo "Unknown service: ${SERVICE}"; exit 1 ;;
esac

# Release overlay: the environment config plus the exact image to run (generated, not committed)
RELEASE_DIR="${ROOT}/k8s/releases/${ENVIRONMENT}/${SERVICE}"
mkdir -p "$RELEASE_DIR"
cat > "${RELEASE_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../environments/${ENVIRONMENT}/${SERVICE}
images:
  - name: ${SERVICE}
    newName: ${IMAGE%:*}
    newTag: "${IMAGE##*:}"
EOF

rollback() {
  echo "!! $1, rolling back ${SERVICE} in ${NAMESPACE}"
  "$KUBECTL" -n "$NAMESPACE" rollout undo "deployment/${SERVICE}" || echo "   (no previous version to roll back to)"
  "$KUBECTL" -n "$NAMESPACE" rollout status "deployment/${SERVICE}" --timeout="$ROLLOUT_TIMEOUT" || true
  "$KUBECTL" -n "$NAMESPACE" get pods -l "app=${SERVICE}" -o wide || true
  exit 1
}

echo "==> Deploying ${IMAGE} to ${NAMESPACE}"
"$KUBECTL" apply -k "$RELEASE_DIR"

echo "==> Waiting for the rollout (timeout ${ROLLOUT_TIMEOUT})"
"$KUBECTL" -n "$NAMESPACE" rollout status "deployment/${SERVICE}" --timeout="$ROLLOUT_TIMEOUT" \
  || rollback "Rollout did not complete"

echo "==> Smoke test from inside the cluster"
case "$SERVICE" in
  aip-api)
    CHECK='curl -sf --retry 5 --retry-connrefused --retry-delay 2 http://aip-api:8080/health'
    ;;
  aip-webapp)
    # Also proves the frontend can reach the API in the backend namespace
    CHECK='curl -sf --retry 5 --retry-connrefused --retry-delay 2 http://aip-webapp/healthz && curl -sf --retry 3 --retry-delay 2 -X POST http://aip-webapp/api/mortgages/dip/decision -H "Content-Type: application/json" -d "{\"annualIncome\":45000,\"loanAmount\":150000}"'
    ;;
esac
"$KUBECTL" -n "$NAMESPACE" run "smoke-${SERVICE}-$(date +%s)" --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.11.1 --command -- sh -c "$CHECK" \
  || rollback "Smoke test failed (for aip-webapp, check aip-api is deployed to ${ENVIRONMENT}-api)"

echo
echo "✅ ${SERVICE} ${IMAGE##*:} is live in ${NAMESPACE}"
"$KUBECTL" -n "$NAMESPACE" get pods -l "app=${SERVICE}"
