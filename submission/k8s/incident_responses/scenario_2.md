# Incident Response: Scenario 2

## What is happening?

The `inference-api` service is unreachable. Callers receive connection refused
or timeouts. The deployment shows 3 running pods, so the application itself
has not crashed — but no traffic is reaching them. Additionally, `web-frontend`
pods cannot reach `inference-api` even when the service does route correctly.

## Root Cause

There are **two independent bugs**, both of which must be fixed for full
service restoration.

---

### Bug 1 — Label mismatch: Service selector does not match pod labels

**Evidence from `deployment.yaml` and `service.yaml`:**

`service.yaml` selector requires **both** labels to be present on a pod:
```yaml
selector:
  app: inference-api
  tier: backend
```

`deployment.yaml` pod template only carries **one** label:
```yaml
labels:
  app: inference-api
  # tier: backend is missing
```

Kubernetes Services use AND logic on selectors — a pod must satisfy every
label in the selector to be included in the Endpoints object. Because no pod
carries `tier: backend`, the Service's Endpoints list is permanently empty.
Traffic sent to the Service IP is immediately dropped — there is nowhere to
forward it.

This explains why 3 pods are Running yet the service appears completely down.

---

### Bug 2 — NetworkPolicy: web-frontend is not an allowed ingress source

**Evidence from `networkpolicy.yaml`:**

```yaml
ingress:
- from:
  - podSelector:
      matchLabels:
        app: api-gateway
```

Only pods labelled `app: api-gateway` are permitted to reach `inference-api`
on port 8080. The `web-frontend` pods (labelled `app: web-frontend`) are not
listed, so their traffic is silently dropped at the network layer — they
receive no error, just a timeout.

---

## Immediate Remediation

Fix both bugs independently — either one alone leaves the service partially
broken.

**Fix Bug 1 — add the missing label to the deployment:**

```bash
kubectl patch deployment inference-api \
  --namespace video-analytics \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/tier","value":"backend"}]'

# Verify Endpoints are now populated (should show pod IPs, not "<none>")
kubectl get endpoints inference-api -n video-analytics
```

**Fix Bug 2 — extend the NetworkPolicy to allow web-frontend:**

```bash
kubectl patch networkpolicy inference-api-netpol \
  --namespace video-analytics \
  --type=json \
  -p='[{"op":"add","path":"/spec/ingress/0/from/-","value":{"podSelector":{"matchLabels":{"app":"web-frontend"}}}}]'
```

Or apply a corrected NetworkPolicy manifest directly:

```yaml
ingress:
- from:
  - podSelector:
      matchLabels:
        app: api-gateway
  - podSelector:
      matchLabels:
        app: web-frontend
  ports:
  - protocol: TCP
    port: 8080
```

## Long-term Fix

1. **Deployment:** add `tier: backend` to the pod template labels in source
   control and ensure it matches the Service selector exactly.

2. **NetworkPolicy:** maintain an explicit list of permitted callers in the
   policy. When a new consumer (`web-frontend`) is introduced, the NetworkPolicy
   must be updated as part of the same PR — not as an afterthought when the
   service appears broken in production.

3. **Integration test in CI:** add a test that deploys the manifests into a
   local cluster (e.g. `kind`) and verifies the Service Endpoints object is
   non-empty after deployment. A zero-endpoint Service is always a bug and is
   trivially detectable in CI.

## Prevention

1. **Alert on zero-endpoint Services** — add a Prometheus alert on
   `kube_endpoint_address_available{endpoint="inference-api"} == 0`.
   An empty Endpoints object is never intentional in a running deployment.

2. **Alert on Service with no ready pods** —
   `kube_deployment_status_replicas_ready{deployment="inference-api"} == 0`
   while `kube_deployment_spec_replicas > 0` flags the selector mismatch
   pattern specifically.

3. **Validate label consistency in CI** — use `kubeval`, `kyverno`, or a
   custom script to assert that every Service selector key exists in the
   pod template labels of its target Deployment before merging.

4. **Document allowed callers** — keep a comment in each NetworkPolicy listing
   the services permitted to call this one and why. Makes it obvious when a
   new caller is missing from the allowlist during code review.
