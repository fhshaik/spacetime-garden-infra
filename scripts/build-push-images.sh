#!/usr/bin/env bash
# Build the 4 spacetime-garden microservice images and push to ECR.
set -euo pipefail

APP_REPO="${APP_REPO:-/Users/faadilshaik/Documents/GitHub/spacetime-garden}"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="${ACCOUNT:-306323843443}"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TAG="${TAG:-main}"
PLATFORM="${PLATFORM:-linux/amd64}"

echo "→ Logging Docker into ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# Parallel arrays: SERVICES[i] is the image name, PATHS[i] is the build context.
SERVICES="genome-service breeding-service gallery-service frontend"

for SVC in $SERVICES; do
  case "$SVC" in
    frontend) CTX="$APP_REPO/frontend" ;;
    *)        CTX="$APP_REPO/services/$SVC" ;;
  esac
  IMG="${REGISTRY}/${SVC}:${TAG}"
  echo
  echo "════════════════════════════════════════════════════════"
  echo "Building $SVC  ($CTX → $IMG)"
  echo "════════════════════════════════════════════════════════"
  docker buildx build \
    --platform "$PLATFORM" \
    --tag "$IMG" \
    --push \
    "$CTX"
done

echo
echo "✅ All 4 images pushed to $REGISTRY"
echo
echo "Watch Argo CD reconcile:"
echo "  https://argocd.spacetimegarden.xyz"
echo "  or: kubectl --context garden-dev get rollout -A -w"
