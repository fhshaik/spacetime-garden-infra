#!/usr/bin/env bash
# Pre-flight: validate that required tooling exists and credentials work.
# Run before `make plan-*` or `make apply-*`.
set -euo pipefail

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}OK${NC}    $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; ERRORS=$((ERRORS+1)); }

ERRORS=0

echo "Pre-flight checks"
echo "================="

echo "Tools:"
for cmd in aws terraform kubectl helm gh yq jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd: $($cmd --version 2>&1 | head -n1)"
  else
    fail "$cmd not found"
  fi
done

echo
echo "AWS credentials:"
if aws sts get-caller-identity >/dev/null 2>&1; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  ARN=$(aws sts get-caller-identity --query Arn --output text)
  ok "account=$ACCOUNT  arn=$ARN"
else
  fail "aws sts get-caller-identity failed — set AWS_PROFILE or run 'aws configure'"
fi

echo
echo "GitHub CLI:"
if gh auth status >/dev/null 2>&1; then
  ok "gh authenticated"
else
  warn "gh not authenticated — run 'gh auth login' if you'll create the PAT/OAuth App from CLI"
fi

echo
if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}Pre-flight failed with $ERRORS error(s).${NC}"
  exit 1
fi
echo -e "${GREEN}Pre-flight passed.${NC}"
