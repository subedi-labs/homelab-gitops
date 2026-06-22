#!/usr/bin/env bash
# bootstrap-infisical.sh
# Run ONCE before ArgoCD syncs Infisical. Fully idempotent — safe to re-run.
# Usage: ./bootstrap-infisical.sh [--dry-run]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
NAMESPACE="infisical"
DB_SECRET="infisical-db-credentials"
APP_SECRET="infisical-secrets"
DB_USER="infisical"
DB_HOST="infisical-db-rw.${NAMESPACE}.svc.cluster.local"
DB_PORT="5432"
DB_NAME="infisical"
REDIS_URL="redis://infisical-redis-master.${NAMESPACE}.svc.cluster.local:6379"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "  [bootstrap] $*"; }
ok()   { echo "✔ $*"; }
skip() { echo "↩ $* — already exists, skipping"; }
err()  { echo "✘ $*" >&2; exit 1; }

kubectl_apply() {
  if $DRY_RUN; then
    echo "[dry-run] would run: kubectl $*"
  else
    kubectl "$@"
  fi
}

secret_exists() {
  kubectl get secret "$1" -n "$NAMESPACE" &>/dev/null
}

# ── Preflight ─────────────────────────────────────────────────────────────────
log "Checking dependencies..."
command -v kubectl  &>/dev/null || err "kubectl not found"
command -v openssl  &>/dev/null || err "openssl not found"

log "Checking cluster connectivity..."
kubectl cluster-info &>/dev/null || err "Cannot reach cluster — check your kubeconfig"

$DRY_RUN && log "DRY RUN mode — no changes will be made"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Infisical Secret Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Step 1: Namespace ─────────────────────────────────────────────────────────
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
  skip "namespace/$NAMESPACE"
else
  log "Creating namespace $NAMESPACE..."
  kubectl_apply create namespace "$NAMESPACE"
  ok "namespace/$NAMESPACE created"
fi

# ── Step 2: DB credentials ────────────────────────────────────────────────────
if secret_exists "$DB_SECRET"; then
  skip "secret/$DB_SECRET"
  # Read existing password for use in app secret below
  DB_PASS=$(kubectl get secret "$DB_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.password}' | base64 -d)
else
  log "Generating DB credentials..."
  DB_PASS=$(openssl rand -base64 24 | tr -d '\n')

  kubectl_apply create secret generic "$DB_SECRET" \
    --namespace "$NAMESPACE" \
    --from-literal=username="$DB_USER" \
    --from-literal=password="$DB_PASS"

  ok "secret/$DB_SECRET created"
fi

# ── Step 3: App secret ────────────────────────────────────────────────────────
if secret_exists "$APP_SECRET"; then
  skip "secret/$APP_SECRET"
else
  log "Generating app secrets..."
  ENCRYPTION_KEY=$(openssl rand -hex 16)
  AUTH_SECRET=$(openssl rand -base64 32 | tr -d '\n')
  DB_URI="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

  kubectl_apply create secret generic "$APP_SECRET" \
    --namespace "$NAMESPACE" \
    --from-literal=ENCRYPTION_KEY="$ENCRYPTION_KEY" \
    --from-literal=AUTH_SECRET="$AUTH_SECRET" \
    --from-literal=DB_CONNECTION_URI="$DB_URI" \
    --from-literal=REDIS_URL="$REDIS_URL"

  ok "secret/$APP_SECRET created"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Bootstrap complete. Safe to sync:"
echo "   argocd app sync infisical"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"