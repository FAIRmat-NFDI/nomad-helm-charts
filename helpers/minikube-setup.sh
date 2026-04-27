#!/bin/bash
# NOMAD Oasis - Reproducible Minikube Setup
#
# This script provides a clean, reproducible environment for testing the NOMAD Helm chart.
# Run from the repository root.
#
# Usage:
#   ./helpers/minikube-setup.sh                    # HTTP (no TLS), central Keycloak
#   ./helpers/minikube-setup.sh --tls              # HTTPS with self-signed cert-manager certificates
#   ./helpers/minikube-setup.sh --local-keycloak   # in-cluster Keycloak (admin/admin)

set -euo pipefail

# Parse flags
USE_TLS=false
LOCAL_KEYCLOAK=false
for arg in "$@"; do
  case "$arg" in
    --tls) USE_TLS=true ;;
    --local-keycloak) LOCAL_KEYCLOAK=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# Check prerequisites
for cmd in docker minikube helm kubectl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: '$cmd' is not installed. Please install it first."
    echo "  docker:   https://docs.docker.com/get-docker/"
    echo "  minikube: https://minikube.sigs.k8s.io/docs/start/"
    echo "  helm:     https://helm.sh/docs/intro/install/"
    echo "  kubectl:  https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi
done

# Configuration
MINIKUBE_CPUS="${MINIKUBE_CPUS:-6}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-12288}"
MINIKUBE_DISK="${MINIKUBE_DISK:-40g}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
RELEASE_NAME="${RELEASE_NAME:-nomad-oasis}"
NAMESPACE="${NAMESPACE:-nomad-oasis}"
HOSTNAME="${HOSTNAME:-nomad-oasis.local}"

echo "=== NOMAD Oasis Minikube Setup ==="
echo "CPUs: $MINIKUBE_CPUS, Memory: ${MINIKUBE_MEMORY}MB, Disk: $MINIKUBE_DISK"
echo "Namespace: $NAMESPACE, Hostname: $HOSTNAME"
if $USE_TLS; then
  echo "TLS: enabled (self-signed via cert-manager)"
fi
if $LOCAL_KEYCLOAK; then
  echo "Keycloak: local (in-cluster, dev mode)"
fi

# Step 1: Clean up any existing minikube
echo ""
echo "Step 1: Cleaning up existing minikube..."
minikube delete 2>/dev/null || true

# Step 2: Start fresh minikube
echo ""
echo "Step 2: Starting fresh minikube..."
minikube start \
  --cpus="$MINIKUBE_CPUS" \
  --memory="$MINIKUBE_MEMORY" \
  --disk-size="$MINIKUBE_DISK" \
  --driver="$MINIKUBE_DRIVER"

# Step 3: Enable required addons
echo ""
echo "Step 3: Enabling addons..."
minikube addons enable ingress
minikube addons enable storage-provisioner

# Step 4: Create host directories for nomad data
# These match the default hostPath volumes in values.yaml (fs.staging_external,
# fs.public_external, fs.north_home_external). Pre-creating them with UID 1000
# (the nomad user) avoids a PermissionError on first write, since Kubernetes
# creates hostPath directories as root and fsGroup does not apply to hostPath.
echo ""
echo "Step 4: Creating data directories on minikube node..."
minikube ssh -- 'sudo mkdir -p /app/.volumes/fs/{staging,public,north/users} /nomad'
minikube ssh -- 'sudo chown -R 1000:1000 /app/.volumes/fs'
minikube ssh -- 'sudo chmod -R 755 /app/.volumes/fs'
minikube ssh -- 'sudo chmod -R 777 /nomad'

# Step 5: Update Helm dependencies
echo ""
echo "Step 5: Updating Helm dependencies..."
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/charts/default"
helm dependency update .

# Step 5b (TLS only): Install cert-manager and self-signed issuer
if $USE_TLS; then
  echo ""
  echo "Step 5b: Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 5m

  echo ""
  echo "Step 5c: Applying self-signed ClusterIssuers..."
  kubectl apply -f "$REPO_ROOT/charts/default/custom-values/tls-issuer/selfsigned.yaml"

  echo "Waiting for selfsigned-issuer to become ready..."
  kubectl wait clusterissuer/selfsigned-issuer \
    --for=condition=Ready --timeout=60s
fi

# Step 6: Create namespace and secrets
echo ""
echo "Step 6: Creating namespace and secrets..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic nomad-hub-service-api-token \
  --from-literal=token=secret-token \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Step 7: Install the chart
echo ""
echo "Step 7: Installing NOMAD Oasis chart..."
HELM_ARGS=(-f custom-values/minikube.yaml)
if $USE_TLS; then
  HELM_ARGS+=(-f custom-values/tls.yaml -f custom-values/minikube-selfsigned.yaml)
fi
if $LOCAL_KEYCLOAK; then
  # NOMAD pods need to resolve $HOSTNAME (the Keycloak ingress host) to the
  # in-cluster nginx ClusterIP, since OIDC discovery happens server-side.
  NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.spec.clusterIP}')
  if [ -z "$NGINX_IP" ]; then
    echo "Error: could not resolve ingress-nginx-controller ClusterIP."
    exit 1
  fi
  echo "  Wiring local Keycloak via hostAliases ($HOSTNAME -> $NGINX_IP)"
  HELM_ARGS+=(
    -f custom-values/local-keycloak.yaml
    --set "nomad.app.hostAliases[0].ip=$NGINX_IP"
    --set "nomad.app.hostAliases[0].hostnames[0]=$HOSTNAME"
    --set "nomad.worker.hostAliases[0].ip=$NGINX_IP"
    --set "nomad.worker.hostAliases[0].hostnames[0]=$HOSTNAME"
  )
fi
helm install "$RELEASE_NAME" . "${HELM_ARGS[@]}" -n "$NAMESPACE" --timeout 15m

# Step 8: Wait for pods
echo ""
echo "Step 8: Waiting for pods to be ready..."
echo "This may take several minutes as the app loads plugins..."
kubectl wait --for=condition=ready pod \
  -l "app.kubernetes.io/component=app" \
  --timeout=600s \
  -n "$NAMESPACE" || echo "Warning: App pod not ready yet (may still be loading)"

# Step 9: Show status
echo ""
echo "=== Installation Complete ==="
echo ""
kubectl get pods -n "$NAMESPACE"
echo ""

# Step 10: Setup /etc/hosts
MINIKUBE_IP=$(minikube ip)
echo "To access NOMAD Oasis:"
echo ""
echo "  1. Add to /etc/hosts:"
echo "     echo '$MINIKUBE_IP $HOSTNAME' | sudo tee -a /etc/hosts"
echo ""
echo "  2. Start tunnel (in separate terminal):"
echo "     minikube tunnel"
echo ""
echo "  3. Open in browser:"
echo "     http://$HOSTNAME/nomad-oasis/gui/"
echo ""

if [ "$LOCAL_KEYCLOAK" = "true" ]; then
  echo "=== Local Keycloak Setup Required ==="
  echo ""
  echo "Keycloak is running but needs the realm and client imported."
  echo "Once all pods are ready:"
  echo ""
  echo "  1. Open the Keycloak admin console:"
  echo "     http://$HOSTNAME/auth/admin  (admin / admin)"
  echo ""
  echo "  2. Top-left realm dropdown -> 'Create realm'"
  echo ""
  echo "  3. 'Resource file' -> upload:"
  echo "     charts/default/custom-values/local-keycloak-realm.json"
  echo ""
  echo "  4. Click 'Create'. This sets up the nomad-oasis realm, the"
  echo "     nomad_public client, an admin user (admin/admin) with the"
  echo "     realm-admin role NOMAD needs, and a test user (test/test)."
  echo ""
fi

echo "To check status:"
echo "  ./helpers/check-status.sh"
echo ""
echo "To uninstall:"
echo "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
echo ""
echo "To delete minikube completely:"
echo "  minikube delete"
