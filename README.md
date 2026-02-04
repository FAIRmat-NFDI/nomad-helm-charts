# NOMAD Helm Charts

Helm charts for deploying [NOMAD](https://nomad-lab.eu/) on Kubernetes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3.x
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- For local production/development, a Kubernetes cluster:
  - [Minikube](https://minikube.sigs.k8s.io/docs/start/)
  - [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- For cloud deployment, a Kubernetes cluster:
  - [GKE](https://cloud.google.com/kubernetes-engine) [under development]
  - [EKS](https://aws.amazon.com/eks/) [under development]

## Repository Structure

```
charts/
  default/           # Standard NOMAD Oasis deployment (self-hosted)
  GCP-oasis/       # Standard NOMAD Oasis deployment (GCP) [under development]
helpers/             # Utility scripts (minikube/kind setup, diagnostics)
```

## Installation

### From Helm Repository (Recommended)

```bash
# Add the NOMAD Helm repository
helm repo add nomad https://fairmat-nfdi.github.io/nomad-helm-charts
helm repo update

# Install with your custom values file
helm install nomad-oasis nomad/default -f my-values.yaml
```

Create a `my-values.yaml` with your configuration overrides. At minimum, set your hostname:

```yaml
nomad:
  config:
    services:
      api_host: your-domain.com
      api_base_path: /nomad-oasis
  ingress:
    enabled: true
```

See [charts/default/values.yaml](charts/default/values.yaml) for all options, or use [oasis-minikube-values.yaml](charts/default/oasis-minikube-values.yaml) as a starting point.

> **Quick Note:** By default, user authentication uses the central NOMAD Keycloak server. To configure your own identity provider, see the [Authentication section](charts/default/README.md#authentication-keycloak) in the chart documentation.


### From Source

Clone this repository and install directly from the charts directory.

## Quick Start

### Using Minikube

```bash
./helpers/minikube-setup.sh
```

### Using Kind

```bash
./helpers/kind-setup.sh
```

### Manual Install

```bash
helm dependency update ./charts/default

# Minikube
helm install nomad-oasis ./charts/default \
  -f ./charts/default/oasis-minikube-values.yaml \
  --timeout 15m

# Kind
helm install nomad-oasis ./charts/default \
  -f ./charts/default/oasis-kind-values.yaml \
  --timeout 15m

# Watch k8s pods status
kubectl get pods -w
```

## Configuration

All configuration lives under the `nomad` key in your values file. See [`charts/default/values.yaml`](charts/default/values.yaml) for all available options.

| Key | Purpose |
|-----|---------|
| `nomad.config` | NOMAD application settings (written to `/app/nomad.yaml`) |
| `nomad.image` | Container image repository and tag |
| `nomad.proxy`, `nomad.app`, `nomad.worker` | Replica counts, resources, timeouts |
| `nomad.secrets` | API, Keycloak, and other secrets |
| `nomad.infrastructure` | Service host overrides (auto-detected by default) |

### Secrets

The simplest approach for development is auto-generation (the default). For production, use pre-created Kubernetes secrets or use helm directly to apply secrets:

```yaml
nomad:
  secrets:
    api:
      existingSecret: "my-api-secret"
      key: password
```

See the [default chart README](charts/default/README.md) for all six supported secret management methods.

## Charts

| Chart | Description |
|-------|-------------|
| [`default`](charts/default/) | Standard self-hosted NOMAD Oasis with Elasticsearch, MongoDB, Temporal, and optional JupyterHub (NORTH) |

## Bundled Dependencies

The `default` chart includes these subcharts (all disabled by default, enable as needed):

- **Elasticsearch** 7.17.3 -- Search and indexing
- **MongoDB** 14.0.4 -- Document database
- **Temporal** 0.72.0 -- Workflow orchestration
- **PostgreSQL** 12.1.6 -- Temporal persistence backend
- **JupyterHub** 3.2.1 -- NORTH interactive computing

## Helper Scripts

| Script | Description |
|--------|-------------|
| [`minikube-setup.sh`](helpers/minikube-setup.sh) | Automated Minikube environment setup and chart installation |
| [`kind-setup.sh`](helpers/kind-setup.sh) | Automated Kind environment setup and chart installation |
| [`check-status.sh`](helpers/check-status.sh) | Deployment health diagnostics |
| [`dev-utils.sh`](helpers/dev-utils.sh) | Shell aliases for development (`source helpers/dev-utils.sh`) |

## Releases

Chart releases are automated via GitHub Actions. When changes are pushed to `main`:

1. Charts are packaged into `.tgz` files
2. A GitHub Release is created with the package
3. The Helm repository index (`index.yaml`) is updated on the `gh-pages` branch

**Versioning:** Release versions are determined by the `version` field in each chart's `Chart.yaml`. Bump this version following [Semantic Versioning](https://semver.org/) when making changes.

## Further Documentation

See the [default chart README](charts/default/README.md) for detailed documentation on Temporal, Keycloak authentication, NORTH/JupyterHub, architecture, and troubleshooting.
