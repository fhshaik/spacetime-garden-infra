#!/usr/bin/env bash
# Fetch Argo CD initial admin password and start a port-forward.
# Default cluster: $CLUSTER_NAME or "garden-dev".
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-garden-dev}"
NAMESPACE="argocd"

PASS=$(kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" \
  get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

echo "Argo CD admin credentials"
echo "========================="
echo "Username: admin"
echo "Password: $PASS"
echo
echo "Starting port-forward on https://localhost:8080 ..."
echo "(Argo CD uses self-signed cert; accept browser warning)"
echo "Press Ctrl-C to stop."
kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" port-forward svc/argocd-server 8080:443
