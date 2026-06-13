#!/bin/bash
# NOMAD Oasis - k3s Setup for a local Linux laptop (e.g. Ubuntu)
#
# Stands up a single-node demo directly on your machine using k3s. Unlike
# minikube, k3s runs natively on the host, so the ingress controller binds the
# host's port 80 and the demo is reachable at http://nomad-oasis.local/ without
# a tunnel.
#
# The host defaults to nomad-oasis.local, pointed at 127.0.0.1 via /etc/hosts,
# so it matches the bundled custom-values files (minikube.yaml / local-keycloak)
# out of the box.
#
# Run from the repository root:
#   ./helpers/k3s-setup.sh                    # central NOMAD Keycloak (default)
#   ./helpers/k3s-setup.sh --local-keycloak   # in-cluster Keycloak (admin/admin)
#
# Override the hostname (e.g. a real domain) with:
#   NOMAD_HOSTNAME=demo.example.com ./helpers/k3s-setup.sh
#
# Requirements:
#   - sudo (for the /etc/hosts entry and the /app/.volumes data dirs)
#   - host port 80 free (k3s servicelb binds it for the ingress controller)
#   - outbound internet (the default central Keycloak does OIDC to nomad-lab.eu)

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

NOMAD_HOSTNAME="${NOMAD_HOSTNAME:-nomad-oasis.local}"

echo "=== NOMAD Oasis k3s Local Setup ==="
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
echo "Step 4: Preparing the host (data directories + /etc/hosts)..."
sudo mkdir -p /app/.volumes/fs/{staging,public,tmp,north/users}
sudo chown -R 1000:1000 /app/.volumes/fs
sudo chmod -R 755 /app/.volumes/fs

# Ensure $NOMAD_HOSTNAME resolves to 127.0.0.1 so the browser reaches the ingress.
# Self-correct a stale entry (e.g. a leftover minikube IP from a prior setup)
# rather than skipping when the hostname is already present but mispointed.
HOST_RE="$(printf '%s' "$NOMAD_HOSTNAME" | sed 's/[.]/\\./g')"
if ! grep -qE "[[:space:]]${HOST_RE}([[:space:]]|\$)" /etc/hosts; then
  echo "  Adding '127.0.0.1 $NOMAD_HOSTNAME' to /etc/hosts"
  echo "127.0.0.1 $NOMAD_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
elif ! grep -qE "^127\.0\.0\.1[[:space:]].*${HOST_RE}([[:space:]]|\$)" /etc/hosts; then
  echo "  Repointing existing /etc/hosts entry for $NOMAD_HOSTNAME -> 127.0.0.1"
  sudo sed -i -E "/^[0-9.]+[[:space:]].*${HOST_RE}([[:space:]]|\$)/ s/^[0-9.]+/127.0.0.1/" /etc/hosts
fi

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
# Reuse the minikube values (single-node, hostPath). They already target
# nomad-oasis.local, so these host overrides are no-ops for the default and
# only take effect when NOMAD_HOSTNAME is set to a custom host.
HELM_ARGS=(
  -f custom-values/minikube.yaml
  --set "nomad.config.services.api_host=$NOMAD_HOSTNAME"
  --set "jupyterhub.hub.config.GenericOAuthenticator.oauth_callback_url=http://$NOMAD_HOSTNAME/nomad-oasis/north/hub/oauth_callback"
  --set "jupyterhub.ingress.hosts[0]=$NOMAD_HOSTNAME"
)

if $LOCAL_KEYCLOAK; then
  # NOMAD app/worker pods do server-side OIDC discovery, so they must resolve the
  # Keycloak ingress host. Point $NOMAD_HOSTNAME at the in-cluster nginx ClusterIP
  # via hostAliases (the host's /etc/hosts entry only applies on the host, not
  # inside the pods).
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
  REALM_SRC="$REPO_ROOT/charts/default/custom-values/local-keycloak-realm.json"
  if [ "$NOMAD_HOSTNAME" = "nomad-oasis.local" ]; then
    # The bundled realm JSON already targets nomad-oasis.local; import it directly.
    REALM_FILE="$REALM_SRC"
  else
    # The realm JSON pins redirectUris/webOrigins to nomad-oasis.local; substitute
    # the custom host so OAuth login succeeds.
    REALM_FILE="$REPO_ROOT/local-keycloak-realm.$NOMAD_HOSTNAME.json"
    sed "s/nomad-oasis.local/$NOMAD_HOSTNAME/g" "$REALM_SRC" > "$REALM_FILE"
    echo "  (wrote a host-corrected realm file for $NOMAD_HOSTNAME)"
  fi
  echo "=== Local Keycloak: import the realm (one-time) ==="
  echo ""
  echo "  1. Open the Keycloak admin console (admin / admin):"
  echo "       http://$NOMAD_HOSTNAME/auth/admin"
  echo "  2. Top-left realm dropdown -> 'Create realm'"
  echo "  3. 'Resource file' -> upload:"
  echo "       $REALM_FILE"
  echo "  4. Click 'Create'. Log in as test/test or admin/admin."
  echo ""
fi

echo "To check status:   ./helpers/check-status.sh"
echo "To uninstall:      helm uninstall $RELEASE_NAME -n $NAMESPACE"
echo "To remove k3s:     sudo /usr/local/bin/k3s-uninstall.sh"
echo "                   (then delete the '127.0.0.1 $NOMAD_HOSTNAME' line from /etc/hosts)"
