# Custom Values Files

Ready-to-use Helm values files for deploying NOMAD Oasis on different environments.

| File | Environment | Ingress | Storage |
|------|-------------|---------|---------|
| [minikube.yaml](minikube.yaml) | Local (Minikube) | nginx | hostPath |
| [kind.yaml](kind.yaml) | Local (Kind) | nginx | hostPath |
| [aws.yaml](aws.yaml) | AWS EKS | ALB | EFS + EBS |

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
     fileSystemId: fs-0123456789abcdef   # <-- replace with your EFS ID
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

To enable HTTPS with an ACM certificate, uncomment and configure these annotations in your values file:

```yaml
nomad:
  config:
    services:
      https: true
  ingress:
    annotations:
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
      alb.ingress.kubernetes.io/ssl-redirect: "443"
      alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:<region>:<account>:certificate/<id>
```
