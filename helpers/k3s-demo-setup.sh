#!/bin/bash
# NOMAD Oasis - k3s Demo Setup for a single GCE VM
#
# Stands up a public, single-node demo on one Google Compute Engine VM using k3s.
# Unlike minikube, k3s runs directly on the host, so the ingress controller binds
# the VM's port 80
#
# The hostname is derived automatically from the VM's external IP via nip.io
# (e.g. 34.1.2.3.nip.io), so Keycloak login and the ingress host match out of the box.
#
# Run from the repository root, on the VM:
#   ./helpers/k3s-demo-setup.sh                    # central NOMAD Keycloak (default)
#   ./helpers/k3s-demo-setup.sh --local-keycloak   # in-cluster Keycloak (admin/admin)
#
# Override the hostname (e.g. a real domain) with:
#   NOMAD_HOSTNAME=demo.example.com ./helpers/k3s-demo-setup.sh

set -euo pipefail

# Parse flags
LOCAL_KEYCLOAK=false
for arg in "$@"; do
  case "$arg" in
    --local-keycloak) LOCAL_KEYCLOAK=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

RELEASE_NAME="${RELEASE_NAME:-nomad-oasis}"
NAMESPACE="${NAMESPACE:-nomad-oasis}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="k3s kubectl"

if [ -z "${NOMAD_HOSTNAME:-}" ]; then
  echo "Detecting external IP from the GCE metadata server..."
  EXTERNAL_IP="$(curl -s -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' || true)"
  if [ -z "$EXTERNAL_IP" ]; then
    echo "Error: could not detect external IP. Set NOMAD_HOSTNAME=<host> and re-run."
    exit 1
  fi
  NOMAD_HOSTNAME="${EXTERNAL_IP}.nip.io"
fi

echo "=== NOMAD Oasis k3s Demo Setup ==="
echo "Hostname: $NOMAD_HOSTNAME"
echo "Namespace: $NAMESPACE"
echo ""

echo "Step 1: Installing k3s..."
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | sh -s - \
    --disable traefik \
    --write-kubeconfig-mode 644
fi
echo "Waiting for the k3s node to be Ready..."
$KUBECTL wait --for=condition=Ready node --all --timeout=120s

echo ""
echo "Step 2: Ensuring helm is installed..."
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo ""
echo "Step 3: Installing ingress-nginx..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --wait --timeout 5m
echo "Waiting for the ingress-nginx controller (and its admission webhook)..."
$KUBECTL wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo ""
echo "Step 4: Creating data directories on the host..."
sudo mkdir -p /app/.volumes/fs/{staging,public,tmp,north/users}
sudo chown -R 1000:1000 /app/.volumes/fs
sudo chmod -R 755 /app/.volumes/fs

echo ""
echo "Step 5: Updating Helm dependencies..."
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/charts/default"
helm dependency update .

echo ""
echo "Step 6: Creating namespace and secrets..."
$KUBECTL create namespace "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL create secret generic nomad-hub-service-api-token \
  --from-literal=token=secret-token \
  -n "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -

echo ""
echo "Step 7: Installing NOMAD Oasis chart..."
# Reuse the minikube values (single-node, hostPath) and override only the
# host-dependent fields so the public nip.io URL works for login + NORTH.
HELM_ARGS=(
  -f custom-values/minikube.yaml
  --set "nomad.config.services.api_host=$NOMAD_HOSTNAME"
  --set "jupyterhub.hub.config.GenericOAuthenticator.oauth_callback_url=http://$NOMAD_HOSTNAME/nomad-oasis/north/hub/oauth_callback"
  --set "jupyterhub.ingress.hosts[0]=$NOMAD_HOSTNAME"
)

if $LOCAL_KEYCLOAK; then
  # NOMAD app/worker pods do server-side OIDC discovery, so they must resolve the
  # Keycloak ingress host. Point $NOMAD_HOSTNAME at the in-cluster nginx ClusterIP
  # via hostAliases (avoids hairpin NAT back through the VM's external IP).
  NGINX_IP=$($KUBECTL get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.spec.clusterIP}')
  if [ -z "$NGINX_IP" ]; then
    echo "Error: could not resolve ingress-nginx-controller ClusterIP."
    exit 1
  fi
  echo "  Local Keycloak enabled; wiring hostAliases ($NOMAD_HOSTNAME -> $NGINX_IP)"
  # local-keycloak.yaml hardcodes nomad-oasis.local everywhere; override each
  # host-bearing field to the dynamic $NOMAD_HOSTNAME.
  HELM_ARGS+=(
    -f custom-values/local-keycloak.yaml
    --set "keycloak.ingress.rules[0].host=$NOMAD_HOSTNAME"
    --set "nomad.config.keycloak.server_url=http://$NOMAD_HOSTNAME/auth/"
    --set "jupyterhub.hub.config.GenericOAuthenticator.authorize_url=http://$NOMAD_HOSTNAME/auth/realms/nomad-oasis/protocol/openid-connect/auth"
    --set "jupyterhub.hub.config.GenericOAuthenticator.token_url=http://$NOMAD_HOSTNAME/auth/realms/nomad-oasis/protocol/openid-connect/token"
    --set "jupyterhub.hub.config.GenericOAuthenticator.userdata_url=http://$NOMAD_HOSTNAME/auth/realms/nomad-oasis/protocol/openid-connect/userinfo"
    --set "nomad.app.hostAliases[0].ip=$NGINX_IP"
    --set "nomad.app.hostAliases[0].hostnames[0]=$NOMAD_HOSTNAME"
    --set "nomad.worker.hostAliases[0].ip=$NGINX_IP"
    --set "nomad.worker.hostAliases[0].hostnames[0]=$NOMAD_HOSTNAME"
  )
fi

helm upgrade --install "$RELEASE_NAME" . "${HELM_ARGS[@]}" -n "$NAMESPACE" --timeout 15m

echo ""
echo "Step 8: Waiting for the app pod to be ready (plugins take a few minutes)..."
$KUBECTL wait --for=condition=ready pod \
  -l "app.kubernetes.io/component=app" \
  --timeout=600s \
  -n "$NAMESPACE" || echo "Warning: App pod not ready yet (may still be loading)"

echo ""
echo "=== Installation Complete ==="
$KUBECTL get pods -n "$NAMESPACE"
echo ""
echo "Open the demo at:"
echo "  http://$NOMAD_HOSTNAME/nomad-oasis/gui/"
echo ""

if $LOCAL_KEYCLOAK; then
  # The realm JSON pins redirectUris/webOrigins to nomad-oasis.local; substitute
  # the real host so OAuth login succeeds, and drop it where it's easy to grab.
  REALM_SRC="$REPO_ROOT/charts/default/custom-values/local-keycloak-realm.json"
  REALM_OUT="$REPO_ROOT/local-keycloak-realm.$NOMAD_HOSTNAME.json"
  sed "s/nomad-oasis.local/$NOMAD_HOSTNAME/g" "$REALM_SRC" > "$REALM_OUT"
  echo "=== Local Keycloak: import the realm (one-time) ==="
  echo ""
  echo "A host-corrected realm file was written to:"
  echo "  $REALM_OUT"
  echo ""
  echo "  1. Open the Keycloak admin console (admin / admin):"
  echo "       http://$NOMAD_HOSTNAME/auth/admin"
  echo "  2. Top-left realm dropdown -> 'Create realm'"
  echo "  3. 'Resource file' -> upload the file above"
  echo "       (copy it to your laptop first, e.g. via the browser-SSH download)"
  echo "  4. Click 'Create'. Log in as test/test or admin/admin."
  echo ""
  echo "  NOTE: if you instead import the original repo JSON, the client redirect"
  echo "  URIs will point at nomad-oasis.local and login will fail. Either use the"
  echo "  substituted file above, or edit the 'nomad_public' client afterwards:"
  echo "    Valid redirect URIs -> http://$NOMAD_HOSTNAME/*"
  echo "    Web origins         -> http://$NOMAD_HOSTNAME"
  echo ""
fi

echo "To check status:   ./helpers/check-status.sh"
echo "To uninstall:      helm uninstall $RELEASE_NAME -n $NAMESPACE"
