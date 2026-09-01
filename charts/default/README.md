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
      staging_external: /app/.volumes/fs/staging   # Used for volume mounts
      public_external: /app/.volumes/fs/public
      tmp_external: /app/.volumes/fs/tmp
      north_home_external: /app/.volumes/fs/north/users
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
    repository: ghcr.io/fairmat-nfdi/nomad-distro-template
    tag: main

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
    repository: ghcr.io/fairmat-nfdi/nomad-distro-template
    tag: "v2.2.0"
```

> [!TIP]
> To access the latest features and improvements, we recommend updating the `nomad.image.tag` to the latest stable version. You can find the available tags in the [GitHub Container Registry](https://github.com/fairmat-nfdi/nomad-distro-template/pkgs/container/nomad-distro-template).


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

## Persistence / Storage

With the default chart, all data volumes use `hostPath`, which mounts directories from the node's local filesystem. This works well for single-node setups (Minikube, Kind) but causes problems on multi-node clusters where pods can land on different nodes and see different or empty data.

The chart supports configurable persistence: you can switch from `hostPath` to `PersistentVolumeClaim` (PVC) backed by any StorageClass. This is cloud-agnostic — you bring your own StorageClass (e.g., Amazon EFS, NFS, Ceph) and the chart creates the PVCs.

### Volumes managed by this chart

| Volume | Mount Path | Used By | Default hostPath |
|--------|-----------|---------|-----------------|
| `public` | `/app/.volumes/fs/public` | All components | `/app/.volumes/fs/public` |
| `staging` | `/app/.volumes/fs/staging` | All components | `/app/.volumes/fs/staging` |
| `tmp` | `/app/.volumes/fs/tmp` | App + worker | `/app/.volumes/fs/tmp` |
| `north-home` | `/app/.volumes/fs/north/users` | App only | `/app/.volumes/fs/north/users` |

### Enabling PVC-based persistence

Set `nomad.persistence.enabled: true` and provide a StorageClass:

```yaml
nomad:
  persistence:
    enabled: true
    storageClass: efs-sc          # your pre-created StorageClass
    accessMode: ReadWriteMany     # required for multi-node access
```

This creates up to 4 PVCs (one per volume) and all deployments reference them instead of `hostPath` (staging/tmp are skipped when `nomad.worker.storage: memory`).

### Per-volume configuration

Each volume can be configured independently. Per-volume settings override the top-level defaults:

```yaml
nomad:
  persistence:
    enabled: true
    storageClass: efs-sc        # default for all volumes
    accessMode: ReadWriteMany   # default for all volumes

    public:
      size: 10Gi                # storage size for this volume
      storageClass: ""          # empty = inherit top-level (efs-sc)
      accessMode: ""            # empty = inherit top-level (ReadWriteMany)
      existingClaim: ""         # non-empty = use this PVC, skip creation

    staging:
      size: 10Gi

    north-home:
      size: 1Gi
```

**Resolution order:** per-volume value > top-level value > cluster default.

### Using existing PVCs

If you manage PVCs outside the chart (e.g., via Terraform or GitOps), point to them with `existingClaim`:

```yaml
nomad:
  persistence:
    enabled: true
    public:
      existingClaim: my-pre-provisioned-public-pvc
    staging:
      existingClaim: my-pre-provisioned-staging-pvc
    north-home:
      existingClaim: my-pre-provisioned-north-pvc
```

When `existingClaim` is set, the chart references that PVC directly and does not create one.

### Example: AWS EKS with EFS

1. Create an EFS filesystem and install the [EFS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html)
2. Create a `StorageClass`:
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: efs-sc
   provisioner: efs.csi.aws.com
   parameters:
     provisioningMode: efs-ap
     fileSystemId: fs-0123456789abcdef
     directoryPerms: "777"
   ```
3. Configure the chart:
   ```yaml
   nomad:
     persistence:
       enabled: true
       storageClass: efs-sc
   ```

### Staging volume with in-memory storage

The `worker.storage: "memory"` setting is preserved regardless of persistence. When set, the staging volume uses `emptyDir` with `medium: Memory` instead of a PVC:

```yaml
nomad:
  worker:
    storage: "memory"       # staging volume = emptyDir (RAM-backed)
  persistence:
    enabled: true           # other volumes still use PVCs
    storageClass: efs-sc
```

## Secrets Management

For detailed instructions on the supported methods for managing secrets, please see the [Secrets section in the NOMAD Oasis deployment guide](https://nomad-lab.eu/prod/v1/staging/docs/howto/oasis/deploy.html#secrets).

## Local Development

This chart includes ready-to-use values files in the [`custom-values/`](custom-values/) directory for different environments.

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
# Paths must match nomad.config.fs.{staging,public,north_home}_external in
# custom-values/minikube.yaml. Owned by UID 1000 to match the pod runAsUser
# (fsGroup does not apply to hostPath volumes).
minikube ssh -- 'sudo mkdir -p /app/.volumes/fs/{staging,public,tmp,north/users}'
minikube ssh -- 'sudo chown -R 1000:1000 /app/.volumes/fs'
minikube ssh -- 'sudo chmod -R 755 /app/.volumes/fs'

# Update dependencies and install
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/minikube.yaml \
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
EOF

# Create data directories on the kind node.
# Paths must match nomad.config.fs.{staging,public,north_home}_external in
# custom-values/kind.yaml. Owned by UID 1000 to match the pod runAsUser
# (fsGroup does not apply to hostPath volumes).
docker exec nomad-oasis-control-plane mkdir -p /app/.volumes/fs/{staging,public,tmp,north/users}
docker exec nomad-oasis-control-plane chown -R 1000:1000 /app/.volumes/fs
docker exec nomad-oasis-control-plane chmod -R 755 /app/.volumes/fs

# Install nginx ingress controller for Kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# Update dependencies and install
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/kind.yaml \
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
| [`custom-values/minikube.yaml`](custom-values/minikube.yaml) | Minikube local development with all services enabled |
| [`custom-values/kind.yaml`](custom-values/kind.yaml) | Kind local development with all services enabled |
| [`custom-values/aws.yaml`](custom-values/aws.yaml) | AWS EKS with ALB ingress and EFS/EBS storage |

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

### Option 1b: Bundled Keycloak (Local Development)

For local development (Minikube or Kind), the chart can deploy Keycloak as a subchart via the `local-keycloak.yaml` overlay. This runs Keycloak in dev mode with an in-memory H2 database — **no external database is required**, but all Keycloak configuration is lost when the pod restarts.

**Deploy:**

```bash
# Automated (recommended) — resolves the nginx ClusterIP automatically
./helpers/minikube-setup.sh --local-keycloak

# Manual
NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}')
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/minikube.yaml \
  -f ./charts/default/custom-values/local-keycloak.yaml \
  --set "nomad.app.hostAliases[0].ip=$NGINX_IP" \
  --set "nomad.app.hostAliases[0].hostnames[0]=nomad-oasis.local" \
  --set "nomad.worker.hostAliases[0].ip=$NGINX_IP" \
  --set "nomad.worker.hostAliases[0].hostnames[0]=nomad-oasis.local"
```

> The `hostAliases` are required so that the app and worker pods can resolve `nomad-oasis.local` to the nginx ingress ClusterIP, allowing them to reach Keycloak via the same URL the browser uses.

After deployment, complete the one-time Keycloak setup described in the [custom-values README](custom-values/README.md#local-keycloak-development).

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
            image: ghcr.io/fairmat-nfdi/nomad-distro-template/jupyter:main

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
            image: ghcr.io/fairmat-nfdi/nomad-distro-template/jupyter:main
          my-custom-tool:
            image: my-registry/my-tool:latest
```

### NORTH Volume Requirements

NORTH requires a shared filesystem for user home directories:

```yaml
nomad:
  config:
    fs:
      north_home_external: /app/.volumes/fs/north/users  # Must be accessible by all nodes
```

For Minikube:
```bash
minikube ssh -- 'sudo mkdir -p /app/.volumes/fs/north/users'
minikube ssh -- 'sudo chown -R 1000:1000 /app/.volumes/fs/north'
minikube ssh -- 'sudo chmod -R 755 /app/.volumes/fs/north'
```

For Kind:
```bash
docker exec nomad-oasis-control-plane mkdir -p /app/.volumes/fs/north/users
docker exec nomad-oasis-control-plane chown -R 1000:1000 /app/.volumes/fs/north
docker exec nomad-oasis-control-plane chmod -R 755 /app/.volumes/fs/north
```

## Verifying the Deployment (`helm test`)

Healthy pods only prove the processes started — the readiness/liveness probes check that the API answers HTTP, not that data actually flows through parsing, the worker, Temporal, MongoDB and Elasticsearch. A broken plugin in a custom image is the classic trap: every pod is green, but uploads never produce entries.

The chart ships a `helm test` hook that exercises the real pipeline. It is **disabled by default** — enable it per deployment with `nomad.tests.enabled: true` (or `--set nomad.tests.enabled=true`), then run:

```bash
helm test <release-name> --namespace <namespace> --logs
```

It runs as a Pod (reusing `nomad.image`, so no extra pull and the same `imagePullSecrets`) that drives the public API **through the proxy** — no ingress, LoadBalancer or cloud-specific setup required, so it behaves identically on EKS, GKE, minikube and Kind. There are two tiers:

**Tier 1 — component & plugin health (always on, no credentials).** Asserts that the app answers via the proxy, that parsers **and** normalizers are loaded (proving your custom image's plugins registered), and that Elasticsearch responds.

**Tier 2 — full end-to-end (opt-in).** Logs in, uploads a file, waits for processing, asserts the entry is created, searchable, and produced by the expected parser, then deletes the upload and confirms the entries **and** files are gone. This is the only check that proves app → Temporal → worker → Mongo → shared `fs` volumes all work together.

### Configuration (`nomad.tests`)

```yaml
nomad:
  tests:
    enabled: false             # opt in per deployment to render the helm test hook
    expect:                    # per-plugin-type presence checks; empty list = skip that type
      parsers: []              # Tier 1: names from GET /info parsers[]
      normalizers: []          # Tier 1: names from GET /info normalizers[]
      pluginPackages: []       # Tier 1: names from GET /info plugin_packages[] (any type)
      apps: []                 # Tier 1: app id/path from GET /api/v1/apps/entry-points
      apis: []                 # Tier 1: API entry point prefixes (mounted FastAPI)
      dashboards: []           # Tier 1: dashboard id (mounted at <base>/dashboards/<id>)
      actions: []              # Tier 2: action_id from /api/v1/actions/schemas (needs creds)
    upload:
      enabled: false           # Tier 2: needs credentials, off by default
      credentialsSecret: ""    # Secret with a `token` key (recommended) OR `username`+`password`
      timeout: 300             # seconds to wait for processing (and cleanup)
      sampleFileName: test.archive.json
      sampleFileContent: |     # inline text sample (ignored when an existingSample* is set)
        { "metadata": { "entry_name": "nomad-helm-test" } }
      existingSampleConfigMap: ""  # mount a user-created ConfigMap for binary samples (e.g. .zip)
      existingSampleSecret: ""     # ...or a Secret (takes precedence) for sensitive samples
      expectParserName: ""     # assert the entry was produced by THIS parser (proves a plugin ran)
      expectEntryType: ""      # optionally assert the resulting entry_type
```

### Plugin-type coverage

NOMAD plugins come in several entry-point types. Each is loaded independently, so a plugin package can be installed while one of its entry points fails to register — `helm test` verifies each type against the API surface that actually exposes it:

| Plugin type | How it's verified | Endpoint | Tier |
|-------------|-------------------|----------|------|
| Parser | registered + (optionally) **executed** on an upload | `GET /info` `parsers[]`; `expectParserName` after processing | 1 (+2) |
| Normalizer | registered | `GET /info` `normalizers[]` | 1 |
| Schema package | package installed / `entry_type` on a produced entry | `GET /info` `plugin_packages[]`; `expectEntryType` | 1 (+2) |
| App (GUI search app) | loaded | `GET /api/v1/apps/entry-points` | 1 |
| API | FastAPI mounted (its `openapi.json` responds) | `GET <base>/<prefix>/openapi.json` | 1 |
| Dashboard | mounted | `GET <base>/dashboards/<id>` | 1 |
| Action | loaded (login required) | `GET /api/v1/actions/schemas` | 2 |

> [!NOTE]
> `expect.pluginPackages` is the catch-all: `/info` lists every installed plugin package regardless of type, so it confirms a package is present even for a type not individually listed above. The per-type checks go further by proving the *entry point* mounted, not just that the package is on disk. All checks are opt-in — an empty list skips that type.

> [!IMPORTANT]
> `expect.parsers` uses the **bare** parser name as returned by `/info` — the `parsers/` prefix is stripped there (e.g. `crystal`, `fhi-aims`, not `parsers/crystal`). In contrast, `upload.expectParserName` matches the entry's stored `parser_name`, which **keeps** the prefix (e.g. `parsers/vasp`).

Example covering every type of a custom image:

```yaml
nomad:
  tests:
    expect:
      parsers: ["my_parser"]          # bare name as listed by /info (no "parsers/" prefix)
      normalizers: ["MyNormalizer"]
      pluginPackages: ["my-nomad-plugin"]
      apps: ["my_plugin.apps.mysearchapp"]
      apis: ["my-api"]
      dashboards: ["my-dashboard"]
      actions: ["my_action"]          # verified only when upload.enabled + credentials
    upload:
      enabled: true
      credentialsSecret: nomad-test-creds
```

### Authentication for Tier 2

The upload flow needs a NOMAD account. Provide **either** a pre-created app token (recommended — portable, and works even where the Keycloak realm disables the password grant) **or** a username/password:

```bash
# Recommended: an app token created from the NOMAD GUI (user settings)
kubectl create secret generic nomad-test-creds --from-literal=token=<app-token>

# Or username + password
kubectl create secret generic nomad-test-creds \
  --from-literal=username=<user> --from-literal=password=<pass>
```
```yaml
nomad:
  tests:
    upload:
      enabled: true
      credentialsSecret: nomad-test-creds
```

### Testing a custom plugin

To prove a custom parser actually **ran** (not just that it registered), upload a file it matches and assert its `parser_name`:

```yaml
nomad:
  tests:
    expect:
      pluginPackages: ["my-plugin-package"]  # Tier 1: present in the image
    upload:
      enabled: true
      credentialsSecret: nomad-test-creds
      sampleFileName: my_data.dat          # a file your parser matches
      sampleFileContent: |
        ...raw content...
      expectParserName: "parsers/my_plugin"  # Tier 2: proves it executed
```

### Uploading a local `.zip`

NOMAD auto-extracts `.zip`/`.tar` on upload (one entry per mainfile). A binary zip can't be inlined in `values.yaml` (ConfigMaps are text and cap at ~1 MiB), so create a ConfigMap from your local file and reference it:

```bash
kubectl create configmap nomad-test-sample \
  --from-file=sample.zip=./sample.zip -n <namespace>
```
```yaml
nomad:
  tests:
    upload:
      enabled: true
      credentialsSecret: nomad-test-creds
      sampleFileName: sample.zip           # key inside the ConfigMap must match
      existingSampleConfigMap: nomad-test-sample
      expectParserName: "parsers/vasp"      # optional
```

> [!NOTE]
> ConfigMaps/Secrets cap at ~1 MiB. For larger fixtures, use a pre-populated PVC instead.

### Using `helm test` in CI/CD

`helm test` exits non-zero if any check fails, so it plugs straight into a pipeline as the "is the deployment green?" gate. The pattern is: install/upgrade → wait for rollout → run the test → surface logs.

```bash
set -euo pipefail

helm upgrade --install nomad-oasis ./charts/default \
  -f my-values.yaml --namespace nomad --create-namespace --wait --timeout 15m \
  --set nomad.tests.enabled=true

# Optional but recommended: ensure every Deployment finished rolling out
kubectl -n nomad rollout status deploy --timeout=10m

# The gate. Non-zero exit fails the job; --logs prints the per-check PASS/FAIL.
helm test nomad-oasis --namespace nomad --logs
```

For **GitHub Actions**, credentials for Tier 2 go through repository secrets:

```yaml
# .github/workflows/verify.yml (excerpt)
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... set up kubectl/helm and cluster access ...
      - name: Provision Tier 2 credentials
        run: |
          kubectl -n nomad create secret generic nomad-test-creds \
            --from-literal=token='${{ secrets.NOMAD_APP_TOKEN }}' \
            --dry-run=client -o yaml | kubectl apply -f -
      - name: Deploy
        run: |
          helm upgrade --install nomad-oasis ./charts/default \
            -f my-values.yaml -n nomad --create-namespace --wait --timeout 15m \
            --set nomad.tests.enabled=true \
            --set nomad.tests.upload.enabled=true \
            --set nomad.tests.upload.credentialsSecret=nomad-test-creds
      - name: Verify deployment (gate)
        run: helm test nomad-oasis -n nomad --logs
      - name: Dump diagnostics on failure
        if: failure()
        run: |
          kubectl -n nomad get pods
          kubectl -n nomad logs -l app.kubernetes.io/component=test --tail=-1 || true
```

Notes for CI:

- **Prefer an app token over a password** for `credentialsSecret` — it's a single revocable secret and doesn't depend on the Keycloak realm allowing the password grant.
- On a locked-down runner with no internet egress, Tier 1 still runs fully in-cluster; only Tier 2 login needs to reach Keycloak. Keep Tier 2 off in that case (`upload.enabled: false`) and rely on the plugin-entry-point checks.
- The test Pod is left in place after a run (recreated on the next `helm test`), so `kubectl logs -l app.kubernetes.io/component=test` retrieves the result for build artifacts even after the command returns.
- For a scheduled health check of a long-running deployment, run `helm test` on a cron (e.g. a `CronJob` or a scheduled workflow) and alert on non-zero exit.

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
minikube ssh -- 'ls -la /app/.volumes/fs/'

# Kind
docker exec nomad-oasis-control-plane ls -la /app/.volumes/fs/
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
