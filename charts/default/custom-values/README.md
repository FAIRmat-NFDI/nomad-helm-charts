# Custom Values Files

Ready-to-use Helm values files for deploying NOMAD Oasis on different environments.

| File                           | Environment      | Ingress | Storage   | TLS               |
| ------------------------------ | ---------------- | ------- | --------- | ----------------- |
| [minikube.yaml](minikube.yaml) | Local (Minikube) | nginx   | hostPath  | cert-manager      |
| [kind.yaml](kind.yaml)         | Local (Kind)     | nginx   | hostPath  | cert-manager      |
| [aws.yaml](aws.yaml)           | AWS EKS          | ALB     | EFS + EBS | ACM (AWS-managed) |
| [tls.yaml](tls.yaml)           | Self-hosted overlay | any  | —         | cert-manager      |

---

## Self-Hosted

Covers local development (Kind, Minikube) and on-premises Kubernetes clusters. Uses an nginx ingress controller. TLS is handled by cert-manager — no cloud account required.

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
