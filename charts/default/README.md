# NOMAD Local Oasis Helm Chart

A Helm chart for deploying NOMAD on Kubernetes, including all required services (Elasticsearch, MongoDB, Temporal).

## Prerequisites

- [Helm](https://helm.sh/docs/intro/install/) >= 3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured for your cluster
- A running Kubernetes cluster (see [Local Development](#local-development) for Minikube or Kind)

## Configuration Structure

All settings are under the `nomad` key:

### `nomad.config` (App Configuration)
Application-level NOMAD configuration. These values are written to `/app/nomad.yaml` in the container and also used by Kubernetes templates for ingress, volumes, and probes. You can check [here](https://nomad-lab.eu/prod/v1/docs/reference/config.html) to see the complete list of all available features and settings.

```yaml
nomad:
  config:
    services:
      api_host: localhost           # Used by ingress
      api_base_path: /nomad-oasis   # Used by ingress, nginx, probes
      api_port: 80
      https: false
    fs:
      staging_external: /data/nomad/staging   # Used for volume mounts
      public_external: /data/nomad/public
      north_home_external: /data/nomad/north/users
      nomad: /nomad
    mongo:
      db_name: nomad_oasis
      port: 27017
    temporal:
      enabled: true
      namespace: default
    # ... other NOMAD settings
```

### `nomad.*` (K8s Deployment Settings)
Kubernetes deployment configuration (replicas, resources, timeouts, secrets).

```yaml
nomad:
  enabled: true
  image:
    repository: gitlab-registry.mpcdf.mpg.de/nomad-lab/nomad-distro
    tag: latest

  proxy:
    replicaCount: 1
    timeout: 60
  app:
    replicaCount: 1
    resources:
      requests:
        memory: "512Mi"
  worker:
    replicaCount: 1
    terminationGracePeriodSeconds: 300

  secrets:
    api:
      existingSecret: ""    # Use pre-created K8s secret
      key: password
      value: ""             # Or set value directly (creates secret)
      autoGenerate: true    # Or auto-generate random secret
```

### `nomad.infrastructure` (Service Discovery)
Host overrides for external services. If empty, hosts are auto-computed from the release name.

```yaml
nomad:
  infrastructure:
    mongo:
      host: ""  # defaults to {{ .Release.Name }}-mongodb
    elastic:
      host: ""  # defaults to elasticsearch-master
```

## Customizing Your Installation

When deploying your own NOMAD Oasis, you should create a custom values file based on one of the provided examples. These are the key settings to review:

### Instance Identity (`nomad.config.meta`)

Defines how your NOMAD instance presents itself:

```yaml
nomad:
  config:
    meta:
      service: my-lab-oasis               # Instance name
      homepage: https://my-lab.org/nomad   # Public URL shown in the UI
      maintainer_email: admin@my-lab.org   # Contact email shown in the UI
```

### Hostname and Base Path (`nomad.config.services`)

Must match your actual hostname and ingress configuration:

```yaml
nomad:
  config:
    services:
      api_host: my-lab.org            # Your domain or hostname
      api_base_path: /nomad-oasis     # URL path prefix
      https: true                     # Enable for production
```

### Admin User (`nomad.config.services`)

Set an admin user ID to manage the instance:

```yaml
nomad:
  config:
    services:
      admin_user_id: "your-keycloak-user-id"
```

### Container Image (`nomad.image`)

Pin a specific version rather than using `latest`:

```yaml
nomad:
  image:
    repository: gitlab-registry.mpcdf.mpg.de/nomad-lab/nomad-distro
    tag: "v1.2.2"
```

### Authentication (`nomad.config.keycloak`)

By default, the chart uses the NOMAD central Keycloak. For a private instance, configure your own identity provider — see [Authentication](#authentication-keycloak) below.

### MongoDB (`mongodb`)

The chart deploys MongoDB using the official `mongo` Docker image with a pinned version.

**Authentication** is enabled by default. You must provide a root password using one of these methods:

1. **Values or secrets file**:
   ```yaml
   mongodb:
     auth:
       rootPassword: "my-secure-password"
   ```
   Or in a separate `secrets.yaml` (keep out of git):
   ```bash
   helm install nomad-oasis ./charts/default -f values.yaml -f secrets.yaml
   ```

2. **Pre-created Kubernetes secret**:
   ```yaml
   mongodb:
     auth:
       existingSecret: "my-mongodb-secret"
   ```
   Create the secret:
   ```bash
   kubectl create secret generic my-mongodb-secret \
     --from-literal=mongodb-root-password=$(openssl rand -hex 32)
   ```

3. **`--set` flag**:
   ```bash
   helm install nomad-oasis ./charts/default \
     -f values.yaml \
     --set mongodb.auth.rootPassword="${MONGO_ROOT_PASSWORD}"
   ```

To disable authentication (e.g. for development reasons):
```yaml
mongodb:
  auth:
    enabled: false
```

> [!WARNING]
> Disabling MongoDB authentication is not recommended for production. Even within a Kubernetes cluster, any pod in the same namespace can access an unauthenticated MongoDB instance.

## Secrets Management

The chart supports multiple methods for managing secrets:

### Method 1: Pre-created Kubernetes Secrets (Production)
```yaml
nomad:
  secrets:
    api:
      existingSecret: "my-api-secret"
      key: password
```

Create the secret manually:
```bash
kubectl create secret generic my-api-secret --from-literal=password=$(openssl rand -hex 32)
```

### Method 2: Values File (Development)
```yaml
nomad:
  secrets:
    api:
      value: "my-secret-value"
```

### Method 3: Auto-generate (Default)
```yaml
nomad:
  secrets:
    api:
      autoGenerate: true
```

### Method 4: Separate secrets.yaml File
Create a `secrets.yaml` file (keep out of git):
```yaml
nomad:
  secrets:
    api:
      value: "my-api-secret-here"
    keycloak:
      clientSecret:
        value: "keycloak-client-secret"
      password:
        value: "keycloak-password"
```

Install with both files:
```bash
helm install nomad ./charts/default -f values.yaml -f secrets.yaml
```

### Method 5: Environment Variables with --set
```bash
helm install nomad ./charts/default \
  -f values.yaml \
  --set nomad.secrets.api.value="${NOMAD_API_SECRET}"
```

### Method 6: helm-secrets Plugin
```bash
# Encrypt secrets with SOPS
sops -e secrets.yaml > secrets.enc.yaml

# Install with encrypted secrets
helm secrets install nomad ./charts/default -f values.yaml -f secrets://secrets.enc.yaml
```

## Local Development

This chart includes values files for local Kubernetes environments. Both produce an equivalent deployment.

### Option A: Minikube

#### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)

#### Automated Setup

```bash
./helpers/minikube-setup.sh
```

#### Manual Setup

```bash
# Start minikube with adequate resources
minikube start --cpus=6 --memory=12288

# Enable ingress
minikube addons enable ingress

# Create required directories
minikube ssh -- 'sudo mkdir -p /data/nomad/{public,staging,tmp,north/users} && sudo chmod -R 777 /data/nomad'
minikube ssh -- 'sudo mkdir -p /nomad && sudo chmod -R 777 /nomad'

# Update dependencies and install
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/oasis-minikube-values.yaml \
  --timeout 15m
```

#### Access

```bash
# Via port-forward
kubectl port-forward svc/nomad-oasis-proxy 8080:80
# Open http://localhost:8080/nomad-oasis/gui/

# Via ingress (add to /etc/hosts)
echo "$(minikube ip) nomad-oasis.local" | sudo tee -a /etc/hosts
minikube tunnel
# Open http://nomad-oasis.local/nomad-oasis/gui/
```

### Option B: Kind

#### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)

#### Automated Setup

```bash
./helpers/kind-setup.sh
```

#### Manual Setup

```bash
# Create cluster with ingress port mappings
cat <<EOF | kind create cluster --name nomad-oasis --config=-
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

# Create data directories
mkdir -p /tmp/nomad-data/{public,staging,north/users,tmp}
mkdir -p /tmp/nomad-app
docker exec nomad-oasis-control-plane mkdir -p /data/nomad/{public,staging,north/users,tmp}
docker exec nomad-oasis-control-plane chmod -R 777 /data/nomad
docker exec nomad-oasis-control-plane mkdir -p /nomad
docker exec nomad-oasis-control-plane chmod -R 777 /nomad

# Install nginx ingress controller for Kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Update dependencies and install
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/oasis-kind-values.yaml \
  --timeout 15m
```

#### Access

```bash
# Open directly (ports 80/443 are mapped to localhost)
# http://localhost/nomad-oasis/gui/
```

### Test Endpoints

```bash
# Alive check
curl http://localhost:8080/nomad-oasis/alive

# API info
curl http://localhost:8080/nomad-oasis/api/v1/info

# GUI
curl -I http://localhost:8080/nomad-oasis/gui/
```

### Uninstall

```bash
helm uninstall nomad-oasis
```

## Values Files

| File | Description |
|------|-------------|
| `values.yaml` | Chart defaults (all subcharts disabled) |
| `oasis-minikube-values.yaml` | Minikube development with all services enabled |
| `oasis-kind-values.yaml` | Kind development with all services enabled |

## Temporal Workflow Engine

The chart includes Temporal for workflow orchestration. Key configuration:

```yaml
nomad:
  config:
    temporal:
      enabled: true
      namespace: default

temporal:
  enabled: true
  server:
    replicaCount: 1
  worker:
    # Temporal's internal system worker - disabled by default due to
    # known SDK client timeout issue in Temporal helm chart 0.72.0
    replicaCount: 0

postgresql:
  enabled: true  # Required for Temporal persistence
```

After installation, you may need to create the default namespace manually:
```bash
kubectl exec -it $(kubectl get pod -l app.kubernetes.io/name=temporal,app.kubernetes.io/component=admintools -o jsonpath='{.items[0].metadata.name}') \
  -- tctl --address nomad-oasis-temporal-frontend:7233 namespace register default --retention 168h
```

## Authentication (Keycloak)

NOMAD uses Keycloak for authentication. The chart supports three scenarios:

### Default: NOMAD Central Keycloak

By default, the chart points to the NOMAD central Keycloak server:

```yaml
nomad:
  config:
    keycloak:
      server_url: https://nomad-lab.eu/fairdi/keycloak/auth/
      realm_name: fairdi_nomad_prod  # or fairdi_nomad_test for development/testing
      client_id: nomad_public
```

### Option 1: Local Keycloak Instance

For a self-hosted Keycloak (e.g., deployed alongside NOMAD):

```yaml
nomad:
  config:
    keycloak:
      server_url: http://keycloak.default.svc.cluster.local:8080/auth/
      realm_name: nomad
      username: admin
      client_id: nomad_oasis

  secrets:
    keycloak:
      clientSecret:
        existingSecret: "keycloak-client-secret"
      password:
        existingSecret: "keycloak-admin-password"
```

Create the required secrets:
```bash
kubectl create secret generic keycloak-client-secret --from-literal=password=<your-client-secret>
kubectl create secret generic keycloak-admin-password --from-literal=password=<your-admin-password>
```

### Option 2: Institution-Managed SSO

For integration with your institution's existing identity provider:

```yaml
nomad:
  config:
    keycloak:
      server_url: https://sso.your-institution.edu/auth/
      realm_name: institution_realm
      username: nomad-service-account
      client_id: nomad_oasis

  secrets:
    keycloak:
      clientSecret:
        existingSecret: "institution-sso-client-secret"
      password:
        existingSecret: "institution-sso-password"
```

> [!IMPORTANT]
> When using external SSO, coordinate with your institution's identity team to:
> - Register NOMAD as an OIDC client
> - Configure appropriate redirect URIs
> - Obtain client credentials

### Keycloak + JupyterHub (NORTH)

If NORTH is enabled, JupyterHub also needs OAuth configuration pointing to the same Keycloak realm:

```yaml
jupyterhub:
  hub:
    baseUrl: "/nomad-oasis/north"  # Must match api_base_path + /north
    config:
      GenericOAuthenticator:
        client_id: nomad_public
        oauth_callback_url: http://your-host/nomad-oasis/north/hub/oauth_callback
        authorize_url: https://nomad-lab.eu/fairdi/keycloak/auth/realms/fairdi_nomad_prod/protocol/openid-connect/auth
        token_url: https://nomad-lab.eu/fairdi/keycloak/auth/realms/fairdi_nomad_prod/protocol/openid-connect/token
        userdata_url: https://nomad-lab.eu/fairdi/keycloak/auth/realms/fairdi_nomad_prod/protocol/openid-connect/userinfo
```

> [!NOTE]
> The `oauth_callback_url` must be registered as a valid redirect URI in the Keycloak client configuration.

## NORTH (JupyterHub Integration)

NORTH provides interactive computing environments via JupyterHub, allowing users to run analysis tools directly from NOMAD.

```yaml
nomad:
  config:
    north:
      enabled: false  # Disabled by default
```

### Enabling NORTH

To enable NORTH with JupyterHub:

```yaml
nomad:
  config:
    north:
      enabled: true
      hub_service_api_token: "your-secure-token"  # Used for NOMAD-JupyterHub communication
      hub_host: nomad-oasis-jupyterhub-hub        # JupyterHub hub service name
      hub_port: 8081                               # JupyterHub hub service port
      tools:
        options:
          jupyter:
            image: gitlab-registry.mpcdf.mpg.de/nomad-lab/nomad-distro/jupyter:develop

jupyterhub:
  enabled: true
  fullnameOverride: "nomad-oasis-jupyterhub"
  hub:
    baseUrl: "/nomad-oasis/north"
    config:
      GenericOAuthenticator:
        client_id: nomad_public
        oauth_callback_url: http://your-host/nomad-oasis/north/hub/oauth_callback
        authorize_url: https://nomad-lab.eu/fairdi/keycloak/auth/realms/fairdi_nomad_prod/protocol/openid-connect/auth
        token_url: https://nomad-lab.eu/fairdi/keycloak/auth/realms/fairdi_nomad_prod/protocol/openid-connect/token
        userdata_url: https://nomad-lab.eu/fairdi/keycloak/auth/realms/fairdi_nomad_prod/protocol/openid-connect/userinfo
```

Create the hub service API token secret:
```bash
kubectl create secret generic nomad-hub-service-api-token \
  --from-literal=token=$(openssl rand -hex 32)
```

When enabled, the chart will:
1. Deploy the JupyterHub subchart
2. Configure nginx proxy to route `/api_base_path/north/` to JupyterHub
3. Configure OAuth authentication via Keycloak

### Custom Tools

Add custom tools to the NORTH configuration:

```yaml
nomad:
  config:
    north:
      enabled: true
      tools:
        options:
          jupyter:
            image: gitlab-registry.mpcdf.mpg.de/nomad-lab/nomad-distro/jupyter:develop
          my-custom-tool:
            image: my-registry/my-tool:latest
```

### NORTH Volume Requirements

NORTH requires a shared filesystem for user home directories:

```yaml
nomad:
  config:
    fs:
      north_home_external: /data/nomad/north/users  # Must be accessible by all nodes
```

For Minikube:
```bash
minikube ssh -- 'sudo mkdir -p /data/nomad/north/users && sudo chmod -R 777 /data/nomad/north/users'
```

For Kind:
```bash
docker exec nomad-oasis-control-plane mkdir -p /data/nomad/north/users
docker exec nomad-oasis-control-plane chmod -R 777 /data/nomad/north/users
```

## Troubleshooting

### Pods not starting
Check pod events:
```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

### Temporal schema job failing
The schema job may fail if PostgreSQL isn't ready. Delete and let it retry:
```bash
kubectl delete job --all
helm upgrade nomad-oasis ./charts/default -f <values-file>
```

### Volume mount issues
Ensure directories exist on the node:
```bash
# Minikube
minikube ssh -- 'ls -la /data/nomad/'

# Kind
docker exec nomad-oasis-control-plane ls -la /data/nomad/
```

### Configuration Validation Warnings

The chart will display warnings during installation if there are configuration issues:
- `temporal is enabled in nomad.config but temporal subchart is disabled`
- `north is enabled in nomad.config but jupyterhub is disabled`
- `No API secret configured`

## Architecture

```
                    ┌─────────────┐
                    │   Ingress   │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │    Proxy    │ (nginx)
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
       ┌──────▼──────┐     │     ┌──────▼──────┐
       │     App     │     │     │   Worker    │
       └──────┬──────┘     │     └──────┬──────┘
              │            │            │
              └────────────┼────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
  ┌──────▼───────┐   ┌─────▼─────┐   ┌───────▼─────┐
  │ Elasticsearch│   │   MongoDB │   │  Temporal   │
  └──────────────┘   └───────────┘   └─────────────┘
```
