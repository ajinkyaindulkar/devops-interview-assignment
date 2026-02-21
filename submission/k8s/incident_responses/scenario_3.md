# Incident Response: Scenario 3

## What is happening?

The `chunk-processor` deployment rollout to `v3.0.0-rc1` is stuck. Only 1 of
3 new replicas has been created, and it has been in `ImagePullBackOff` for
15 minutes. The 3 old pods (`v2.x`) remain Running and continue serving traffic
(rolling update strategy preserves them until new pods are healthy), but the
rollout will never complete without intervention.

## Root Cause

The new pod cannot pull its image from ECR because the node's ECR credentials
have expired. The root cause is a **missing IRSA annotation** on the
`chunk-processor` ServiceAccount — without it, nodes cannot obtain fresh ECR
tokens.

**Evidence from `rollout_status.txt`:**

```
Failed to pull image "...chunk-processor:v3.0.0-rc1":
rpc error: code = Unknown desc = Error response from daemon:
denied: Your authorization token has expired.
Reauthenticate and try again.
```

The error is not "image not found" — the image exists. The node's ECR auth
token (valid for 12 hours) has expired and cannot be automatically renewed.

**Root cause from the ServiceAccount:**

```yaml
# kubectl get sa chunk-processor -n video-analytics -o yaml
metadata:
  annotations:
    # NOTE: IAM role annotation is missing — should be:
    # eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/chunk-processor-ecr-role
```

EKS uses **IRSA (IAM Roles for Service Accounts)** to grant pods AWS
permissions without static credentials. The `eks.amazonaws.com/role-arn`
annotation tells the EKS Pod Identity webhook to inject a short-lived
token into the pod, which the AWS SDK and `kubelet` image puller use to
authenticate with ECR. Without the annotation, no token is injected,
the node falls back to its instance profile credentials, and when those
expire the kubelet cannot renew them for ECR pulls.

## Immediate Remediation

**Step 1 — Add the missing IRSA annotation to the ServiceAccount:**

```bash
kubectl annotate serviceaccount chunk-processor \
  --namespace video-analytics \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/chunk-processor-ecr-role \
  --overwrite
```

**Step 2 — Restart the stuck pod to force a fresh pull attempt:**

The existing `ImagePullBackOff` pod will not retry with the new credentials
automatically in a reasonable timeframe. Delete it so the deployment
controller creates a fresh pod that picks up the annotation:

```bash
kubectl delete pod chunk-processor-7c8d9e0f1-new01 -n video-analytics
```

**Step 3 — Confirm the rollout completes:**

```bash
kubectl rollout status deployment/chunk-processor -n video-analytics
# Expected: "deployment successfully rolled out"

kubectl get pods -n video-analytics -l app=chunk-processor
# All 3 new pods should reach Running/Ready
```

**Rollback option** — if the annotation cannot be immediately confirmed or the
IAM role does not exist yet, roll back to the previous working version to
restore full capacity while the fix is prepared:

```bash
kubectl rollout undo deployment/chunk-processor -n video-analytics
```

## Long-term Fix

1. **Commit the annotation to the ServiceAccount manifest in source control:**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: chunk-processor
  namespace: video-analytics
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/chunk-processor-ecr-role
```

2. **Ensure the IAM role (`chunk-processor-ecr-role`) has the correct trust
   policy** scoped to the specific ServiceAccount (not the entire namespace):

```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/CLUSTER_ID:sub":
        "system:serviceaccount:video-analytics:chunk-processor"
    }
  }
}
```

3. **Add ECR pull permissions to the role** — at minimum
   `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`,
   `ecr:GetAuthorizationToken`.

## Prevention

1. **Validate IRSA annotation in CI** — add a policy check (Kyverno or OPA
   Gatekeeper) that requires every ServiceAccount in `video-analytics` to
   carry the `eks.amazonaws.com/role-arn` annotation. Block deployments that
   reference a ServiceAccount without it.

2. **Test ECR pull in staging before production rollout** — the CI pipeline
   should do a dry-run pod deployment in staging and verify `ImagePullPolicy`
   succeeds before promoting to production. An `ImagePullBackOff` in staging
   catches this class of error before it reaches prod.

3. **Alert on `ImagePullBackOff`** — add a Prometheus alert on
   `kube_pod_container_status_waiting_reason{reason="ImagePullBackOff"} > 0`.
   15 minutes of silent `ImagePullBackOff` before anyone noticed indicates
   there was no alert — this should page immediately.

4. **Treat ServiceAccounts as code** — manage ServiceAccount manifests
   (including annotations) in the same Helm chart or Kustomize overlay as the
   Deployment. A Deployment and its ServiceAccount must be deployed atomically
   so annotation gaps cannot slip through independently.
