#!/usr/bin/env bash
# Post-apply manual setup for Vocareum mode (no IRSA → no ESO/external-dns).
#
# Run AFTER `make apply-dev` completes. Does what ESO + external-dns would
# do automatically in a non-restricted AWS account:
#   1. Create namespaces
#   2. Create K8s Secret with DATABASE_URL for genome + gallery services
#   3. Print the NLB hostname so you can manually create Route53 A record
#
# Idempotent — safe to re-run.
set -euo pipefail

ENV="${ENV:-dev}"
CLUSTER="garden-${ENV}"
TF_DIR="terraform/live/${ENV}"

cd "$(dirname "$0")/.."

# 1. kubectl context
echo "→ Updating kubectl context"
aws eks update-kubeconfig --region us-east-1 --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
kubectl config use-context "$CLUSTER"

# 2. Get RDS endpoint + password from terraform outputs
echo "→ Reading TF outputs"
RDS_ENDPOINT=$(cd "$TF_DIR" && terraform output -raw rds_endpoint | sed 's/:.*//')
DB_PASS=$(cd "$TF_DIR" && terraform output -raw rds_master_password_for_manual_secrets)
DATABASE_URL="postgresql+psycopg://garden_admin:${DB_PASS}@${RDS_ENDPOINT}:5432/garden"

# 3. Create namespaces (Argo CD ApplicationSet will create them too, but
#    Secrets need them to exist first).
for ns in garden-dev garden-uat garden-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 4. Create DATABASE_URL Secret in each namespace for genome + gallery services
for ns in garden-dev garden-uat garden-prod; do
  for svc in genome-service gallery-service; do
    kubectl create secret generic "${svc}-db" \
      --from-literal="DATABASE_URL=${DATABASE_URL}" \
      --namespace "$ns" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  ✓ ${ns}/${svc}-db"
  done
done

# 5. Wait for ingress-nginx Service to get its NLB hostname
echo
echo "→ Waiting for ingress-nginx LoadBalancer to provision..."
for i in {1..60}; do
  NLB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$NLB" ]; then
    break
  fi
  sleep 5
done

if [ -z "${NLB:-}" ]; then
  echo "ERROR: NLB hostname not yet assigned. Check 'kubectl get svc -n ingress-nginx'."
  exit 1
fi

echo
echo "════════════════════════════════════════════════════════════════════"
echo "NLB hostname: ${NLB}"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Manual DNS step (external-dns is disabled on Vocareum):"
echo
echo "Run these AWS CLI commands to create A records in Route53:"
ZONE_ID=$(cd terraform/live/_shared && terraform output -raw route53_zone_id 2>/dev/null || echo "ZONE_ID_NOT_FOUND")
cat <<EOF

aws route53 change-resource-record-sets --hosted-zone-id ${ZONE_ID} \\
  --change-batch '{
    "Changes": [
      {"Action": "UPSERT", "ResourceRecordSet": {
        "Name": "dev.spacetimegarden.xyz", "Type": "CNAME", "TTL": 60,
        "ResourceRecords": [{"Value": "${NLB}"}]
      }},
      {"Action": "UPSERT", "ResourceRecordSet": {
        "Name": "uat.spacetimegarden.xyz", "Type": "CNAME", "TTL": 60,
        "ResourceRecords": [{"Value": "${NLB}"}]
      }},
      {"Action": "UPSERT", "ResourceRecordSet": {
        "Name": "argocd.spacetimegarden.xyz", "Type": "CNAME", "TTL": 60,
        "ResourceRecords": [{"Value": "${NLB}"}]
      }},
      {"Action": "UPSERT", "ResourceRecordSet": {
        "Name": "grafana.spacetimegarden.xyz", "Type": "CNAME", "TTL": 60,
        "ResourceRecords": [{"Value": "${NLB}"}]
      }}
    ]
  }'

EOF

echo "After running, verify with:"
echo "  dig +short dev.spacetimegarden.xyz"
echo
echo "Done. Next: kubectl apply -f gitops/bootstrap/argocd-root-app.yaml"
