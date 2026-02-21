# Incident Response: Scenario 1

## What is happening?

Pod `video-processor-7d4f8b6c9-x2k4m` in namespace `video-analytics` is in
`CrashLoopBackOff` after 7 restarts. The container is not ready
(`containerStatuses[].ready: false`) and the deployment cannot serve traffic.
Each restart attempt terminates within approximately 2.5 minutes of starting.

## Root Cause

The container is being killed by the Linux OOM killer on every boot — not
crashing due to an application bug.

**Evidence from `pod_description.yaml`:**

- `lastState.terminated.exitCode: 137` — exit code 137 = SIGKILL from the
  kernel OOM killer (128 + signal 9). The process did not exit voluntarily.
- `lastState.terminated.reason: OOMKilled` — Kubernetes confirms the cause.
- `resources.limits.memory: "512Mi"` — hard cgroup ceiling for this container.
- `env.JAVA_OPTS: "-Xmx384m -Xms256m"` — JVM heap is capped at 384Mi.
- `env.PROCESSING_THREADS: "8"` — 8 concurrent processing threads.

**Why 512Mi is insufficient:**

The JVM consumes heap *and* significant off-heap memory. Total footprint:

| Component | Approximate size |
|---|---|
| Heap (`-Xmx`) | 384Mi (configured) |
| Metaspace (class metadata) | ~80–120Mi |
| Thread stacks (8 threads × ~1Mi) | ~8Mi |
| GC buffers, JIT code cache, native | ~50–80Mi |
| **Total** | **~522–612Mi** |

The off-heap alone pushes total consumption past the 512Mi limit before the
heap fills. The OOMKill happens during JVM startup — class loading and thread
initialisation — which matches the observed 2.5-minute pod lifetime.

## Immediate Remediation

Patch the deployment's memory limit and reduce `PROCESSING_THREADS` to restore
service now. The rolling update will replace the crashing pod automatically.

```bash
# Raise the memory limit to give the JVM safe operating headroom
kubectl set resources deployment/video-processor \
  --namespace video-analytics \
  --containers=video-processor \
  --requests=memory=1Gi \
  --limits=memory=2Gi

# Fix JAVA_OPTS to match the new limit (-Xmx = 75% of 2Gi = 1536m)
# and reduce threads from 8 to 4 to halve per-thread stack overhead
kubectl set env deployment/video-processor \
  --namespace video-analytics \
  PROCESSING_THREADS=4 \
  JAVA_OPTS="-Xmx1536m -Xms512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# Confirm the rollout succeeds and no further OOMKills occur
kubectl rollout status deployment/video-processor -n video-analytics
kubectl describe pod -n video-analytics -l app=video-processor | grep -A5 "Last State"
```

## Long-term Fix

Commit corrected values to `deployment.yaml` in source control so the fix
survives the next deploy (already applied in this submission):

```yaml
resources:
  requests:
    memory: "1Gi"
  limits:
    memory: "2Gi"
env:
- name: JAVA_OPTS
  value: "-Xmx1536m -Xms512m -XX:+UseG1GC"
- name: PROCESSING_THREADS
  value: "4"
```

**Rule of thumb for JVM containers:** set `-Xmx` to ~75% of the memory limit,
leaving 25% for off-heap. For a 2Gi limit: 2048Mi × 0.75 = 1536Mi. Never set
requests == limits without measuring total JVM footprint — `-Xmx` does not
account for metaspace, thread stacks, or native memory.

## Prevention

1. **Alert on OOMKill immediately** — add a Prometheus/CloudWatch alert on
   `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0`.
   This fires on the *first* kill, before 7 restarts accumulate and the
   deployment degrades to zero healthy pods.

2. **Memory saturation alert** — alert at 85% of the container memory limit
   (`container_memory_working_set_bytes / container_spec_memory_limit_bytes`).
   This fires while the pod is still alive, giving time to act before OOMKill.

3. **Load test before release** — run a representative video workload in
   staging with realistic `PROCESSING_THREADS` and `BATCH_SIZE` values.
   Observe actual JVM peak usage under `kubectl top pod` and set limits
   based on observed data, not estimates.

4. **VPA in recommendation mode** — install Vertical Pod Autoscaler and use
   it to surface right-sizing suggestions without automatically mutating
   limits. A human reviews each recommendation before it reaches production.
