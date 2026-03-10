# Custom Values Files

Ready-to-use Helm values files for deploying NOMAD Oasis on different environments.

| File                           | Environment      | Ingress | Storage   | TLS               |
| ------------------------------ | ---------------- | ------- | --------- | ----------------- |
| [minikube.yaml](minikube.yaml) | Local (Minikube) | nginx   | hostPath  | No                |
| [kind.yaml](kind.yaml)         | Local (Kind)     | nginx   | hostPath  | No                |
| [aws.yaml](aws.yaml)           | AWS EKS          | ALB     | EFS + EBS | ACM (AWS-managed) |
| [tls.yaml](tls.yaml)           | Any (overlay)    | any     | —         | cert-manager      |

## TLS with cert-manager

The `tls.yaml` file is a Helm values **overlay** — it configures NOMAD to use cert-manager for TLS.
cert-manager itself is a separate cluster-level tool that must be set up before deploying NOMAD.

### Step 1 — Install cert-manager (once per cluster)

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

### Step 2 — Apply a ClusterIssuer (once per cluster)

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

### Step 3 — Deploy NOMAD with TLS

```bash
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/kind.yaml \
  -f ./charts/default/custom-values/tls.yaml \
  --timeout 15m
```

> Update `nomad.ingress.certManager.issuerName` in `tls.yaml` to match the issuer you applied in Step 2 (`letsencrypt-prod` or `selfsigned-issuer`).

## Local Development

For Minikube or Kind, use the automated setup scripts:

```bash
# Minikube
./helpers/minikube-setup.sh

# Kind
./helpers/kind-setup.sh
```

Or install manually:

```bash
helm dependency update ./charts/default
helm install nomad-oasis ./charts/default \
  -f ./charts/default/custom-values/minikube.yaml \
  --timeout 15m
```

## AWS EKS Deployment

### Prerequisites

Before using `aws.yaml`, you must have the following infrastructure in place:

1. **EKS Cluster** running with `kubectl` access configured

   ```bash
   aws eks update-kubeconfig --region <region> --name <cluster-name>
   ```

2. **AWS Load Balancer Controller** installed in the cluster (for ALB ingress)

   ```bash
   # Install via Helm
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
   # Install EFS CSI driver
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

4. **EBS gp2 StorageClass** (usually available by default on EKS) for MongoDB, Elasticsearch, and PostgreSQL block storage

5. **Security groups** allowing:
   - EFS: NFS traffic (port 2049) between EKS nodes and EFS mount targets
   - ALB: Inbound HTTP (80) and/or HTTPS (443) from the internet
   - EKS nodes: All traffic within the cluster security group

### Configuration

Copy `aws.yaml` and customize:

```bash
cp charts/default/custom-values/aws.yaml my-aws-values.yaml
```

Update the following fields:

- `nomad.config.services.api_host` -- Set to your ALB DNS name (available after first deploy) or a custom domain
- `mongodb.auth.rootPassword` -- Change to a secure password
- Uncomment the SSL annotations if you have an ACM certificate for HTTPS

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

Update `api_host` in your values file with this hostname and run `helm upgrade`:

```bash
helm upgrade nomad-oasis ./charts/default -f my-aws-values.yaml
```

### Enabling HTTPS

The `aws.yaml` file has HTTPS pre-configured using AWS ACM (the recommended approach for AWS). Update the `certificate-arn` annotation and set `https: true`:

```yaml
nomad:
  config:
    services:
      https: true
  ingress:
    annotations:
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80},{"HTTPS": 443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:<region>:<account>:certificate/<id>
```

ACM handles certificate provisioning and renewal automatically — no cert-manager needed on AWS.
