#!/usr/bin/env bash
# Deploys the data services (MongoDB and Kafka) to one environment, creates the Kafka topics, then proves both work.
#
#   ./scripts/deploy-data.sh <environment>
#   ./scripts/deploy-data.sh sit-01
#
# Deploy this before turning on PERSISTENCE_ENABLED for aip-api or deploying aip-audit-service.
# Safe to run again: the images are pinned, data is kept on persistent volumes, and topics are only created if missing.
# Optional env: ROLLOUT_TIMEOUT (default 300s), KUBECTL (default "kubectl").
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy-data.sh <environment>}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
KUBECTL="${KUBECTL:-kubectl}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="${ROOT}/k8s/environments/${ENVIRONMENT}/aip-data"
[ -f "${ENV_DIR}/kustomization.yaml" ] || { echo "No data services config for ${ENVIRONMENT}"; exit 1; }
NAMESPACE="${ENVIRONMENT}-data"

echo "==> Deploying MongoDB and Kafka to ${NAMESPACE}"
"$KUBECTL" apply -k "$ENV_DIR"

echo "==> Waiting for them to start (timeout ${ROLLOUT_TIMEOUT})"
"$KUBECTL" -n "$NAMESPACE" rollout status statefulset/mongodb --timeout="$ROLLOUT_TIMEOUT"
"$KUBECTL" -n "$NAMESPACE" rollout status statefulset/kafka --timeout="$ROLLOUT_TIMEOUT"

topics() { "$KUBECTL" -n "$NAMESPACE" exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }

echo "==> Waiting for the Kafka broker to accept requests"
for attempt in $(seq 1 30); do
  topics --list > /dev/null 2>&1 && break
  [ "$attempt" = 30 ] && { echo "!! Kafka did not become ready"; exit 1; }
  sleep 5
done

echo "==> Creating topics (if missing)"
# 3 partitions: events for one application (same key) stay in order, and up to 3 consumers can share the work
topics --create --if-not-exists --topic aip.decisions --partitions 3 --replication-factor 1
topics --create --if-not-exists --topic aip.decisions.dlq --partitions 1 --replication-factor 1

echo "==> Smoke test"
"$KUBECTL" -n "$NAMESPACE" exec mongodb-0 -- mongosh --quiet --eval "db.adminCommand('ping').ok" | grep -q 1
echo " MongoDB answers ping"
listed="$(topics --list)"
for topic in aip.decisions aip.decisions.dlq; do
  echo "$listed" | grep -qx "$topic" || { echo "!! Topic $topic is missing"; exit 1; }
done
echo " Kafka topics: $(echo "$listed" | grep '^aip' | tr '\n' ' ')"

echo
echo "✅ Data services are ready in ${NAMESPACE}"
echo "   MongoDB: mongodb://mongodb.${NAMESPACE}.svc.cluster.local:27017"
echo "   Kafka:   kafka.${NAMESPACE}.svc.cluster.local:9092"
"$KUBECTL" -n "$NAMESPACE" get pods,pvc
