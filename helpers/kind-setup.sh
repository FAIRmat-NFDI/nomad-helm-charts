#!/bin/bash
# NOMAD Oasis - Reproducible Kind Setup
#
# This script provides a clean, reproducible environment for testing the NOMAD Helm chart.
# Run from the repository root.
#
# Usage: ./helpers/kind-setup.sh

set -euo pipefail

# Check prerequisites
for cmd in docker kind helm kubectl; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "Error: '$cmd' is not installed. Please install it first."
    echo "  docker:  https://docs.docker.com/get-docker/"
    echo "  kind:    https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    echo "  helm:    https://helm.sh/docs/intro/install/"
    echo "  kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi
done

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-nomad-oasis}"
RELEASE_NAME="${RELEASE_NAME:-nomad-oasis}"
NAMESPACE="${NAMESPACE:-nomad-oasis}"

echo "=== NOMAD Oasis Kind Setup ==="
echo "Cluster: $CLUSTER_NAME, Namespace: $NAMESPACE"

# Step 1: Clean up any existing cluster
echo ""
echo "Step 1: Cleaning up existing Kind cluster..."
kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true

# Step 2: Create Kind cluster with ingress-ready config
echo ""
echo "Step 2: Creating Kind cluster..."
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  extraMounts:
  - hostPath: /tmp/nomad-data
    containerPath: /data/nomad
  - hostPath: /tmp/nomad-app
    containerPath: /nomad
EOF

# Step 3: Create host directories for nomad data
echo ""
echo "Step 3: Creating data directories..."
mkdir -p /tmp/nomad-data/{public,staging,north/users}
mkdir -p /tmp/nomad-app
docker exec "$CLUSTER_NAME-control-plane" mkdir -p /data/nomad/{public,staging,north/users}
docker exec "$CLUSTER_NAME-control-plane" chmod -R 777 /data/nomad
docker exec "$CLUSTER_NAME-control-plane" mkdir -p /nomad
docker exec "$CLUSTER_NAME-control-plane" chmod -R 777 /nomad

# Step 4: Install nginx ingress controller for Kind
echo ""
echo "Step 4: Installing nginx ingress controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
echo "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Step 5: Update Helm dependencies
echo ""
echo "Step 5: Updating Helm dependencies..."
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/charts/default"
helm dependency update .

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
helm install "$RELEASE_NAME" . \
  -f custom-values/kind.yaml \
  -n "$NAMESPACE" \
  --timeout 15m

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
echo "To access NOMAD Oasis:"
echo ""
echo "  Open in browser: http://localhost/nomad-oasis/gui/"
echo ""
echo "To check status:"
echo "  ./helpers/check-status.sh"
echo ""
echo "To uninstall:"
echo "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
echo ""
echo "To delete Kind cluster:"
echo "  kind delete cluster --name $CLUSTER_NAME"
