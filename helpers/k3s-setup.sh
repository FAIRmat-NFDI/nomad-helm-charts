#!/bin/bash
# NOMAD Oasis - k3s Setup for a local Linux laptop (e.g. Ubuntu)
#
# Stands up a single-node demo directly on your machine using k3s. Unlike
# minikube, k3s runs natively on the host, so the ingress controller binds the
# host's ports 80/443 and the demo is reachable at https://nomad-oasis.local/
# without a tunnel.
#
# The host defaults to nomad-oasis.local, pointed at 127.0.0.1 via /etc/hosts,
# so it matches the bundled custom-values files (minikube.yaml / local-keycloak)
# out of the box.
#
# Run from the repository root:
#   ./helpers/k3s-setup.sh                    # HTTPS (self-signed), central NOMAD Keycloak (default)
#   ./helpers/k3s-setup.sh --no-tls           # plain HTTP (the new GUI cannot sign in over HTTP)
#   ./helpers/k3s-setup.sh --local-keycloak   # in-cluster Keycloak (admin/admin), plain HTTP
#
# TLS is on by default: the new GUI signs in with WebCrypto, which browsers only
# provide in secure contexts (HTTPS or localhost).
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
USE_TLS=true
LOCAL_KEYCLOAK=false
for arg in "$@"; do
  case "$arg" in
    --tls) USE_TLS=true ;;
    --no-tls) USE_TLS=false ;;
    --local-keycloak) LOCAL_KEYCLOAK=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# The local Keycloak realm (local-keycloak-realm.json) and its ingress are
# HTTP-only, so keep the whole demo on HTTP when it is used.
if $LOCAL_KEYCLOAK && $USE_TLS; then
  echo "Note: --local-keycloak is HTTP-only; disabling TLS. The new GUI cannot sign in"
  echo "      over HTTP, use the classic GUI at /nomad-oasis/gui/v1/ instead."
  USE_TLS=false
fi
SCHEME=http
if $USE_TLS; then
  SCHEME=https
fi

RELEASE_NAME="${RELEASE_NAME:-nomad-oasis}"
NAMESPACE="${NAMESPACE:-nomad-oasis}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="k3s kubectl"

NOMAD_HOSTNAME="${NOMAD_HOSTNAME:-nomad-oasis.local}"

echo "=== NOMAD Oasis k3s Local Setup ==="
echo "Hostname: $NOMAD_HOSTNAME"
echo "Namespace: $NAMESPACE"
if $USE_TLS; then
  echo "TLS: enabled (self-signed via cert-manager)"
fi
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
echo "Step 3: Installing Traefik..."
# k3s was installed with --disable traefik above so the chart-managed Traefik
# below is the only ingress controller (k3s servicelb exposes it on host port 80).
# Ingress objects in this chart use ingressClassName: nginx with ingress-nginx
# annotations; Traefik's Kubernetes Ingress NGINX provider (v3.6.2+) claims that
# class and translates the annotations. The IngressClass must exist for it to
# bind (a real ingress-nginx install would have created it).
$KUBECTL apply -f - <<'EOF_IC'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
EOF_IC
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update
# readTimeout=0: Traefik v3 defaults the entrypoint read timeout to 60s, which
# aborts large NOMAD uploads.
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set providers.kubernetesIngressNGINX.enabled=true \
  --set ports.web.transport.respondingTimeouts.readTimeout=0 \
  --set ports.websecure.transport.respondingTimeouts.readTimeout=0 \
  --set service.type=LoadBalancer \
  --wait --timeout 5m

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

if $USE_TLS; then
  echo ""
  echo "Step 5b: Installing cert-manager and the self-signed issuer..."
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 5m
  $KUBECTL apply -f custom-values/tls-issuer/selfsigned.yaml
  $KUBECTL wait clusterissuer/selfsigned-issuer --for=condition=Ready --timeout=90s
fi

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
  # k3s-specific overlay: k3s enforces NetworkPolicies (via its embedded
  # kube-router controller), unlike minikube/kind. k3s.yaml disables the z2jh
  # policies that would otherwise block the NOMAD app/worker from reaching the
  # hub API (Errno 111 / connection refused).
  -f custom-values/k3s.yaml
)
if $USE_TLS; then
  # minikube-selfsigned.yaml targets nomad-oasis.local; the overrides below
  # retarget its host-bearing fields to $NOMAD_HOSTNAME.
  HELM_ARGS+=(
    -f custom-values/tls.yaml
    -f custom-values/minikube-selfsigned.yaml
    --set "jupyterhub.hub.extraEnv.NOMAD_OASIS_URL=https://$NOMAD_HOSTNAME/nomad-oasis"
    --set "jupyterhub.ingress.tls[0].hosts[0]=$NOMAD_HOSTNAME"
    --set "jupyterhub.ingress.tls[0].secretName=nomad-oasis-jupyterhub-tls"
  )
fi
HELM_ARGS+=(
  --set "nomad.config.services.api_host=$NOMAD_HOSTNAME"
  --set "jupyterhub.hub.config.GenericOAuthenticator.oauth_callback_url=$SCHEME://$NOMAD_HOSTNAME/nomad-oasis/north/hub/oauth_callback"
  --set "jupyterhub.ingress.hosts[0]=$NOMAD_HOSTNAME"
)

if $LOCAL_KEYCLOAK; then
  # NOMAD app/worker pods do server-side OIDC discovery, so they must resolve the
  # Keycloak ingress host. Point $NOMAD_HOSTNAME at the in-cluster Traefik ClusterIP
  # via hostAliases (the host's /etc/hosts entry only applies on the host, not
  # inside the pods).
  INGRESS_IP=$($KUBECTL get svc -n traefik traefik \
    -o jsonpath='{.spec.clusterIP}')
  if [ -z "$INGRESS_IP" ]; then
    echo "Error: could not resolve the traefik Service ClusterIP."
    exit 1
  fi
  echo "  Local Keycloak enabled; wiring hostAliases ($NOMAD_HOSTNAME -> $INGRESS_IP)"
  # local-keycloak.yaml hardcodes nomad-oasis.local everywhere; override each
  # host-bearing field to the dynamic $NOMAD_HOSTNAME.
  HELM_ARGS+=(
    -f custom-values/local-keycloak.yaml
    --set "keycloak.ingress.rules[0].host=$NOMAD_HOSTNAME"
    --set "nomad.config.keycloak.server_url=http://$NOMAD_HOSTNAME/auth/"
    --set "jupyterhub.hub.config.GenericOAuthenticator.authorize_url=http://$NOMAD_HOSTNAME/auth/realms/nomad-oasis/protocol/openid-connect/auth"
    --set "jupyterhub.hub.config.GenericOAuthenticator.token_url=http://$NOMAD_HOSTNAME/auth/realms/nomad-oasis/protocol/openid-connect/token"
    --set "jupyterhub.hub.config.GenericOAuthenticator.userdata_url=http://$NOMAD_HOSTNAME/auth/realms/nomad-oasis/protocol/openid-connect/userinfo"
    --set "nomad.app.hostAliases[0].ip=$INGRESS_IP"
    --set "nomad.app.hostAliases[0].hostnames[0]=$NOMAD_HOSTNAME"
    --set "nomad.worker.hostAliases[0].ip=$INGRESS_IP"
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
echo "  $SCHEME://$NOMAD_HOSTNAME/nomad-oasis/gui/"
if $USE_TLS; then
  echo "  (the certificate is self-signed: accept the browser warning once)"
fi
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
