# Custom Values Files

Ready-to-use Helm values files for deploying NOMAD Oasis on different environments.

| File                           | Environment      | Ingress | Storage   | TLS               |
| ------------------------------ | ---------------- | ------- | --------- | ----------------- |
| [minikube.yaml](minikube.yaml) | Local (Minikube) | Traefik | hostPath  | cert-manager      |
| [kind.yaml](kind.yaml)         | Local (Kind)     | Traefik | hostPath  | cert-manager      |
| [aws.yaml](aws.yaml)           | AWS EKS          | ALB     | EFS + EBS | ACM (AWS-managed) |
| [gke.yaml](gke.yaml)           | Google GKE       | GCE LB  | Filestore + PD | Google-managed certs |
| [tls.yaml](tls.yaml)           | Self-hosted overlay | any  | —         | cert-manager      |

---

## Self-Hosted

Covers local development (Kind, Minikube) and on-premises Kubernetes clusters. Uses the [Traefik](https://traefik.io/) ingress controller (see [Ingress controller](#ingress-controller)). TLS is handled by cert-manager — no cloud account required.

### Quick Start (local)

```bash
# Minikube (automated)
./helpers/minikube-setup.sh

# Kind (automated)
./helpers/kind-setup.sh
```

Or install manually:

```bash
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/kind.yaml \
  --timeout 15m
```

### Ingress controller

The chart renders standard Kubernetes `Ingress` resources with `ingressClassName: nginx` and `nginx.ingress.kubernetes.io/*` annotations (connection limits, timeouts, upload size, request streaming). Two controllers understand them:

- **Traefik ≥ 3.6.2 (recommended)** with its [Kubernetes Ingress NGINX provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/): it claims the `nginx` IngressClass and translates the annotations — `limit-connections`/`limit-rps` become InFlightReq/RateLimit middlewares, timeouts and body size map to their Traefik equivalents. No chart values change.
- **ingress-nginx** — retired upstream (end-of-life March 2026); existing installations keep working until they migrate.

Install Traefik once per cluster. The `nginx` IngressClass must exist (ingress-nginx creates it; on a fresh cluster create it yourself), and the entrypoint `readTimeout` must be 0 — Traefik v3 defaults it to 60 s, which aborts large uploads:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
EOF
helm repo add traefik https://traefik.github.io/charts
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set providers.kubernetesIngressNGINX.enabled=true \
  --set ports.web.transport.respondingTimeouts.readTimeout=0 \
  --set ports.websecure.transport.respondingTimeouts.readTimeout=0
```

Not translated by Traefik: `denylist-source-range` (use an `IPAllowList`, a NetworkPolicy, or a Traefik plugin) and `proxy-buffer-size`/`proxy-buffers-number` (not needed; Traefik has no such buffer limits). Traefik documents the remaining [behavioral differences](https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/ingress-nginx/).

#### Migrating an existing installation from ingress-nginx

Follow Traefik's [NGINX to Traefik migration guide](https://doc.traefik.io/traefik/migrate/nginx-to-traefik/); nothing in the chart changes:

1. Install Traefik next to ingress-nginx with the command above (add `--set providers.kubernetesIngressNGINX.publishService.enabled=false` while both run, so they don't fight over the Ingress status).
2. Verify through Traefik's own IP without touching DNS: `curl --connect-to your-domain.com:443:<traefik-ip>: https://your-domain.com/nomad-oasis/api/v1/info`. Existing TLS secrets are reused; cert-manager keeps working (use a DNS-01 solver, or keep nginx until Traefik is reachable, for HTTP-01 renewals during the overlap).
3. Shift traffic: re-point DNS or the external load balancer at Traefik.
4. Uninstall ingress-nginx, **keeping the `nginx` IngressClass** (`helm.sh/resource-policy: keep`, or re-create it as above), then remove the `publishService` override.

### Enabling TLS (cert-manager)

cert-manager is a cluster-level tool that provisions and renews TLS certificates automatically. It works with any ingress controller (nginx, Traefik, Contour, etc.) and is the recommended TLS solution for self-hosted deployments.

#### Step 1 — Install cert-manager (once per cluster)

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true

# Wait for cert-manager to be ready
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=90s
```

#### Step 2 — Apply a ClusterIssuer (once per cluster)

Two ready-to-use issuer files are provided in [`tls-issuer/`](tls-issuer/):

| File                                                       | When to use                                   |
| ---------------------------------------------------------- | --------------------------------------------- |
| [tls-issuer/letsencrypt.yaml](tls-issuer/letsencrypt.yaml) | Production — public domain required           |
| [tls-issuer/selfsigned.yaml](tls-issuer/selfsigned.yaml)   | Local dev / testing — no public domain needed |

```bash
# Production (public domain)
kubectl apply -f ./charts/default/custom-values/tls-issuer/letsencrypt.yaml

# OR local dev / testing
kubectl apply -f ./charts/default/custom-values/tls-issuer/selfsigned.yaml
```

> **Before applying `letsencrypt.yaml`**: edit the file and replace `your@email.com` with your email address and update `ingressClassName` to match your ingress controller.

#### Step 3 — Deploy NOMAD with TLS

```bash
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/kind.yaml \
  -f ./charts/default/custom-values/tls.yaml \
  --timeout 15m
```

> Update `nomad.ingress.certManager.issuerName` in `tls.yaml` to match the issuer you applied in Step 2 (`letsencrypt-prod` or `selfsigned-issuer`).

---

## Cloud-Hosted (AWS EKS)

Uses the AWS Load Balancer Controller to provision an Application Load Balancer (ALB) as the ingress. TLS is handled by AWS Certificate Manager (ACM) — **cert-manager is not required**.

### Prerequisites

Before using `aws.yaml`, the following infrastructure must be in place:

1. **EKS Cluster** with `kubectl` access configured

   ```bash
   aws eks update-kubeconfig --region <region> --name <cluster-name>
   ```

2. **AWS Load Balancer Controller** installed in the cluster

   ```bash
   helm repo add eks https://aws.github.io/eks-charts
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=<cluster-name> \
     --set serviceAccount.create=false \
     --set serviceAccount.name=aws-load-balancer-controller
   ```

   The controller's service account needs an IAM role with the [recommended IAM policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json).

3. **EFS filesystem** with the [EFS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html) installed

   ```bash
   helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
   helm install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver -n kube-system
   ```

   Then create a StorageClass pointing to your EFS filesystem:

   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: nomad-efs-sc
   provisioner: efs.csi.aws.com
   parameters:
     provisioningMode: efs-ap
     fileSystemId: fs-0123456789abcdef # <-- replace with your EFS ID
     directoryPerms: "777"
   ```

4. **EBS gp2 StorageClass** (available by default on EKS) for MongoDB, Elasticsearch, and PostgreSQL

5. **Security groups** allowing:
   - EFS: NFS traffic (port 2049) between EKS nodes and EFS mount targets
   - ALB: Inbound HTTP (80) and HTTPS (443) from the internet
   - EKS nodes: All traffic within the cluster security group

### Configuration

Copy `aws.yaml` and customize:

```bash
cp charts/default/custom-values/aws.yaml my-aws-values.yaml
```

Update the following fields:

- `nomad.config.services.api_host` — your domain name or ALB DNS name (available after first deploy)
- `mongodb.auth.rootPassword` — change to a secure password
- `alb.ingress.kubernetes.io/certificate-arn` — replace the placeholder ARN with your ACM certificate ARN (appears in both the NOMAD and JupyterHub ingress sections)

### Install

```bash
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f my-aws-values.yaml \
  --timeout 15m
```

After the ALB is provisioned, get its DNS name:

```bash
kubectl get ingress nomad-oasis -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Create a DNS CNAME record pointing your domain to this hostname, then update `api_host` and run `helm upgrade`:

```bash
helm upgrade nomad-oasis ./charts/default -f my-aws-values.yaml
```

### Enabling HTTPS

`aws.yaml` is pre-configured for HTTPS via ACM. To enable it:

1. Replace both `certificate-arn` placeholders (NOMAD and JupyterHub ingress sections) with your ACM certificate ARN.
2. Set `https: true` under `nomad.config.services`.
3. Update the JupyterHub OAuth callback URL scheme from `http://` to `https://`:

```yaml
nomad:
  config:
    services:
      https: true

jupyterhub:
  hub:
    config:
      GenericOAuthenticator:
        oauth_callback_url: https://your-domain.com/nomad-oasis/north/hub/oauth_callback
```

ACM handles certificate provisioning and renewal automatically — no cert-manager needed.

> **Note:** Both the NOMAD and JupyterHub ingresses share the same ALB via `group.name: "nomad-oasis"`, so one ACM certificate covers both. Use a wildcard cert (`*.your-domain.com`) or a cert with both hostnames as SANs if they are on different subdomains.

---

## Cloud-Hosted (Google GKE)

Uses the built-in **GCE ingress** (a Google Cloud HTTP Load Balancer) with a pre-reserved global static IP. Shared NOMAD data volumes are backed by **Filestore** (ReadWriteMany); databases use **Persistent Disk** (ReadWriteOnce). `gke.yaml` ships HTTP-only — see [Enabling HTTPS](#enabling-https-google-managed-certificate) to add a Google-managed certificate.

> The `public`, `staging`, and `tmp` volumes are mounted read-write by both the `app` and `worker` pods at the same time, so they **must** be ReadWriteMany. On GKE that means Filestore (`standard-rwx`) — the equivalent of EFS on AWS. `standard-rwo` Persistent Disk cannot be shared and will leave the second pod stuck `ContainerCreating`.

### Prerequisites

Before using `gke.yaml`, the following must be in place:

1. **GKE Autopilot cluster** with `kubectl` access configured

   ```bash
   gcloud container clusters get-credentials <cluster-name> --region <region>
   ```

2. **A global static IP** for the load balancer

   ```bash
   gcloud compute addresses create nomad-oasis-ip --global
   gcloud compute addresses describe nomad-oasis-ip --global --format='value(address)'
   ```

   The annotation `kubernetes.io/ingress.global-static-ip-name` in `gke.yaml` must match the **name** (`nomad-oasis-ip`), not the address.

3. **Cloud Filestore API enabled**, providing the `standard-rwx` StorageClass for the shared RWX volumes. The Filestore CSI *driver* ships with Autopilot, but the project-level API must be enabled explicitly — otherwise the `public`/`staging`/`tmp` PVCs stay `Pending` with `Error 403: ... SERVICE_DISABLED` and the `app`/`worker` pods never schedule.

   ```bash
   gcloud services enable file.googleapis.com
   kubectl get storageclass standard-rwx standard-rwo
   ```

4. **`standard-rwo` Persistent Disk StorageClass** (available by default on GKE) for MongoDB, Elasticsearch, and PostgreSQL.

> **Filestore cost note:** Filestore enforces a minimum provisioned capacity per instance, so the small RWX volumes are expensive when each is its own `standard-rwx` instance. For production, point `nomad.persistence.storageClass` at a Filestore **multishare** (Enterprise) StorageClass so all shared volumes pack into a single instance — see the [GKE Filestore multishare docs](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/filestore-multishares).

### Configuration

Copy `gke.yaml` and customize:

```bash
cp charts/default/custom-values/gke.yaml my-gke-values.yaml
```

Update the following fields:

- `nomad.config.services.api_host` — a **DNS name**, not a bare IP. A Kubernetes Ingress rejects an IP address in its host rule (`spec.rules[0].host: ... must be a DNS name, not an IP address`). Use a domain whose DNS A-record points to the static IP, or, to test without owning a domain, an [nip.io](https://nip.io) name that resolves to the IP — e.g. if the static IP is `34.120.0.1`, set `api_host: 34.120.0.1.nip.io`.
- `nomad.ingress.annotations."kubernetes.io/ingress.global-static-ip-name"` — the **name** of your reserved static IP (default `nomad-oasis-ip`)
- `mongodb.auth.rootPassword` — change to a secure password

> **Autopilot note:** `gke.yaml` disables the Elasticsearch `configure-sysctl` init container (`elasticsearch.sysctlInitContainer.enabled: false`) and sets `node.store.allow_mmap: false`, because Autopilot forbids the privileged container that would otherwise raise `vm.max_map_count`. Leave these in place on Autopilot.

### Install

```bash
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f my-gke-values.yaml \
  --timeout 15m
```

The Google Cloud Load Balancer takes a few minutes to provision. Once ready, its address equals the reserved static IP:

```bash
kubectl get ingress nomad-oasis -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Browse to `http://<api_host>/nomad-oasis/gui/` (the DNS name / nip.io host you set) to confirm NOMAD Oasis is up. If you used your own domain, create a DNS A-record pointing it at the static IP. Note that the Google Cloud Load Balancer can take 5–10 minutes after creation before it starts serving traffic.

### Enabling HTTPS (Google-managed certificate)

TODO

### Enabling North (JupyterHub)

North is disabled by default. To enable it, set `nomad.config.north.enabled: true` and `jupyterhub.enabled: true`, and set the JupyterHub OAuth callback URL to your external host (`http://<host>/nomad-oasis/north/hub/oauth_callback`, `https://` once TLS is on). The NOMAD proxy routes `/nomad-oasis/north/` internally, so **no extra ingress or second static IP is needed** — everything stays behind the single GCE load balancer.
