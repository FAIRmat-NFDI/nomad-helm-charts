# NOMAD Helm Charts

Helm charts for deploying [NOMAD](https://nomad-lab.eu/) on Kubernetes.

## Repository Structure

```
charts/
  nomad-default/     # Standard NOMAD Oasis deployment
examples/            # Example values files
helpers/             # Utility scripts (minikube setup, diagnostics)
```

## Quick Start

```bash
# Add dependencies
helm dependency update ./charts/nomad-default

# Install with the minikube example values
helm install nomad-oasis ./charts/nomad-default \
  -f ./examples/oasis-minikube-values.yaml \
  --timeout 15m

# Watch pods come up
kubectl get pods -w
```

Or use the automated minikube setup script:

```bash
./helpers/minikube-setup.sh
```

## Configuration

All configuration lives under the `nomad` key in your values file. See [`charts/nomad-default/values.yaml`](charts/nomad-default/values.yaml) for all available options.

| Key | Purpose |
|-----|---------|
| `nomad.config` | NOMAD application settings (written to `/app/nomad.yaml`) |
| `nomad.image` | Container image repository and tag |
| `nomad.proxy`, `nomad.app`, `nomad.worker` | Replica counts, resources, timeouts |
| `nomad.secrets` | API, Keycloak, and other secrets |
| `nomad.infrastructure` | Service host overrides (auto-detected by default) |

### Secrets

The simplest approach for development is auto-generation (the default). For production, use pre-created Kubernetes secrets:

```yaml
nomad:
  secrets:
    api:
      existingSecret: "my-api-secret"
      key: password
```

See the [chart README](charts/nomad-default/README.md) for all six supported secret management methods.

## Example Values

| File | Description |
|------|-------------|
| [`oasis-minikube-values.yaml`](examples/oasis-minikube-values.yaml) | Local development on Minikube with all services enabled |
| [`example-values.yaml`](examples/example-values.yaml) | Minimal production example |

## Bundled Dependencies

The `nomad-default` chart includes these subcharts (all disabled by default, enable as needed):

- **Elasticsearch** 7.17.3 -- Search and indexing
- **MongoDB** 14.0.4 -- Document database
- **Temporal** 0.72.0 -- Workflow orchestration
- **PostgreSQL** 12.1.6 -- Temporal persistence backend
- **JupyterHub** 3.2.1 -- NORTH interactive computing

## Helper Scripts

| Script | Description |
|--------|-------------|
| [`minikube-setup.sh`](helpers/minikube-setup.sh) | Automated minikube environment setup and chart installation |
| [`check-status.sh`](helpers/check-status.sh) | Deployment health diagnostics |
| [`dev-utils.sh`](helpers/dev-utils.sh) | Shell aliases for development (`source helpers/dev-utils.sh`) |

## Further Documentation

See the [chart README](charts/nomad-default/README.md) for detailed documentation on Temporal, Keycloak authentication, NORTH/JupyterHub, architecture, and troubleshooting.
