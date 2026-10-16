#!/usr/bin/env bash
# kubectl in a container, so the Jenkins machine only needs Docker.
# Uses the kubeconfig at $KUBECONFIG_FILE (default ./.kube/config) and runs from the current folder.
exec docker run --rm -i --network host --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e KUBECONFIG=/kube/config \
  -v "${KUBECONFIG_FILE:-$PWD/.kube/config}:/kube/config:ro" \
  -v "$PWD:$PWD" -w "$PWD" \
  "${KUBECTL_IMAGE:-registry.k8s.io/kubectl:v1.35.0}" "$@"
