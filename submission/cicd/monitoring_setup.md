# Monitoring and Observability Setup — Video Analytics Platform

## Metrics

We collect metrics at three layers: **edge device**, **cloud infrastructure**, and **business/application**.
Each layer has different collection mechanisms and different failure modes — a gap in one layer should
not hide problems in another.

### Application-level metrics (Prometheus → Grafana)

Collected from the `video-processor` pods via `/metrics` (scraped by Prometheus every 15s):

| Metric | Type | Why we track it |
|---|---|---|
| `video_chunk_processing_latency_seconds` (P50/P95/P99) | Histogram | Direct measure of end-to-end processing SLO — P99 > 10s triggers an alert |
| `video_chunk_upload_total` (labelled `status=success\|failure`) | Counter | Upload success rate; a drop below 99% means video data is being lost |
| `kafka_consumer_lag` (per topic partition) | Gauge | High lag means the processor is falling behind ingest rate — precursor to buffer overflow |
| `rtsp_stream_reconnects_total` (per camera) | Counter | Frequent reconnects indicate a camera or network fault before it becomes a full outage |
| `inference_frames_per_second` | Gauge | GPU throughput; a sudden drop (without load change) indicates GPU fault or thermal throttle |
| `http_request_duration_seconds` (P99, per endpoint) | Histogram | API latency for downstream dashboard consumers |
| `jvm_memory_used_bytes` / `jvm_memory_max_bytes` | Gauge | Ratio triggers OOM alert before the container is killed — learned from Scenario 1 |

### Infrastructure metrics (CloudWatch + Node Exporter)

| Metric | Source | Threshold |
|---|---|---|
| Node CPU utilisation | CloudWatch / kube-state-metrics | Alert > 85% sustained 10 min |
| Node memory utilisation | Node Exporter | Alert > 90% |
| GPU utilisation (`DCGM_FI_DEV_GPU_UTIL`) | DCGM Exporter on GPU nodes | Alert < 10% during business hours (GPU idle = inference not running) |
| EKS pod restart count | kube-state-metrics | Alert if any pod restarts > 3 times in 5 min |
| ECR pull errors | CloudWatch Container Insights | Alert on any `ImagePullBackOff` event |
| S3 upload latency (`PutObject` P99) | CloudWatch S3 metrics | Alert > 5s (slow bucket = upload queue backup) |

### Edge device metrics (Prometheus textfile collector via healthcheck.sh)

The edge `healthcheck.sh` runs every 60s via systemd timer and writes structured output.
A lightweight Prometheus textfile exporter on each device exposes these as gauges for
centralised collection over the VPN tunnel.

| Metric | Values | Why |
|---|---|---|
| `edge_docker_daemon_up` | 0/1 | Primary workload prerequisite |
| `edge_container_running` | 0/1 | Direct ingest health signal |
| `edge_gpu_accessible` | 0/1 | Inference capability |
| `edge_disk_used_percent` (per mount) | 0–100 | Video buffer fill rate |
| `edge_ntp_offset_ms` | float | Timestamp accuracy for S3 object ordering |
| `edge_vpn_tunnel_up` | 0/1 | Cloud connectivity |
| `edge_camera_reachable` (per camera IP) | 0/1 | Per-camera fault isolation |

### Business metrics (custom instrumentation → CloudWatch)

| Metric | Why it matters |
|---|---|
| `video_chunks_processed_per_site_per_hour` | Confirms each site is contributing data — a site at zero means total loss |
| `inference_detections_per_hour` (per site) | Sudden drop without a camera fault = model regression |
| `s3_bytes_uploaded_per_hour` | Budget tracking; unexpected spike = runaway retention bug |
| `sites_healthy_count` / `sites_degraded_count` / `sites_critical_count` | Fleet-wide health summary for operations dashboard |

---

## SLOs (Service Level Objectives)

SLOs are defined per customer contract tier. The defaults below apply to all sites.

| SLO | Target | Measurement window | Error budget (30d) |
|---|---|---|---|
| Video upload success rate | ≥ 99.5% of chunks reach S3 | Rolling 30 days | 3.6 hours of total failure time |
| Cloud processing latency (P99) | < 10 seconds from chunk arrival to inference result in SQS | Rolling 7 days | — |
| Edge device uptime | ≥ 99.9% per site per month | Calendar month | 43 minutes |
| API availability (dashboard / query API) | ≥ 99.5% | Rolling 30 days | 3.6 hours |
| Data freshness | Video data visible in dashboard within 60 seconds of capture | Per-event spot check | < 0.1% of events exceed 120s |

**SLO vs SLA:** These are internal SLOs. Customer SLAs are set 5% lower (e.g. 99.0% upload
success in the contract) so we have a buffer to detect SLO breaches and respond before
violating the customer-facing commitment.

---

## Alerting

### Alert severity tiers

| Tier | Who gets paged | Response expectation | Example conditions |
|---|---|---|---|
| **P1 — Critical (page immediately)** | On-call engineer (PagerDuty, 24/7) | Acknowledge within 5 min, resolve within 30 min | VPN tunnel down, video-ingest container stopped, disk > 90%, GPU inaccessible, Kafka consumer lag > 10 min |
| **P2 — High (page business hours)** | On-call engineer (PagerDuty, business hours only) | Acknowledge within 30 min | NTP offset > 1s, upload success rate < 99.5% (1h window), pod restart > 3x/5min |
| **P3 — Warning (ticket)** | Team Slack channel `#ops-alerts` → JIRA ticket | Reviewed next business day | Disk > 80%, P99 latency 8–10s, camera reconnects > 10/hour, Kafka lag growing but < 5 min |
| **P4 — Info (dashboard only)** | None — visible on Grafana only | Reviewed in weekly ops review | Spot instance reclamation events, unattended-upgrades patch applied, image pull cache miss |

### Alert fatigue prevention

- **Alertmanager grouping**: alerts for the same root cause are grouped into a single notification.
  E.g. if 5 cameras on the same site go offline simultaneously, one alert fires for the site —
  not 5 individual camera alerts. This is implemented with `group_by: [site_id]` in Alertmanager config.
- **Inhibition rules**: if `edge_vpn_tunnel_up=0` fires for a site, camera and upload alerts for
  that same site are inhibited — the VPN being down is the root cause; the downstream failures are noise.
- **Minimum duration**: no alert fires unless the condition persists for at least 5 minutes (configurable).
  Transient blips (a single missed health check, a momentary NTP sync gap) do not page.
- **Weekly review**: P3 alert volume is reviewed in the Monday ops standup. Any alert that fires
  more than 3 times per week without a corresponding P1/P2 incident is either tuned or automated.

### Key Alertmanager rules (representative sample)

```yaml
groups:
  - name: edge.critical
    rules:
      - alert: EdgeVPNDown
        expr: edge_vpn_tunnel_up == 0
        for: 5m
        labels: { severity: critical }
        annotations:
          summary: "VPN tunnel down on {{ $labels.site_id }}"
          description: >
            Video uploads and SSM connectivity lost. All cloud-bound traffic
            is blocked. Check strongSwan on the edge device.

      - alert: EdgeContainerStopped
        expr: edge_container_running == 0
        for: 2m
        labels: { severity: critical }
        annotations:
          summary: "video-ingest container stopped on {{ $labels.site_id }}"

      - alert: UploadSuccessRateLow
        expr: |
          rate(video_chunk_upload_total{status="success"}[1h])
          / rate(video_chunk_upload_total[1h]) < 0.995
        for: 10m
        labels: { severity: high }
        annotations:
          summary: "Upload success rate below 99.5% for {{ $labels.site_id }}"
```

---

## Escalation

| Level | Who | Trigger | Actions |
|---|---|---|---|
| **L0 — Automated remediation** | Systemd / Kubernetes | Container exit, pod crash | `Restart=always` restarts the container; Kubernetes replaces unhealthy pods. No human involvement needed for transient faults. |
| **L1 — On-call engineer** | Rotating on-call (PagerDuty) | P1/P2 alert not auto-resolved within 5 min | Diagnose via Grafana dashboard + SSM Session Manager. Execute runbook (linked from alert annotation). Most edge faults are resolved here: restart service, re-push config, re-image from last known-good. |
| **L2 — Senior infrastructure engineer** | Named escalation contact | L1 cannot resolve within 30 min, or outage affects > 5 sites | Has access to production infrastructure controls, can authorise emergency deploys outside the normal approval gate, can coordinate with AWS Support. |
| **L3 — Engineering lead + customer success** | Engineering leadership | SLA at risk (> 1h of data loss for a customer), security incident, or data integrity concern | Decision authority for customer communication. Customer success notifies the customer proactively — customers should hear about a major outage from us, not discover it themselves. |

**Runbook links** are embedded in every alert's `annotations.runbook_url` field so the on-call
engineer does not need to search for documentation under pressure.

---

## Dashboards

### Dashboard 1: Edge Fleet Overview

**Audience**: Operations team, on-call engineer
**Refresh**: 30s

Panels:
- **Site health heatmap** — one cell per site, colour-coded by `overall` status from healthcheck.sh (green/yellow/red). Instantly shows which sites are degraded without scrolling.
- **VPN tunnel status** (per site) — `edge_vpn_tunnel_up` time series, last 24h
- **Container uptime** (per site) — `edge_container_running`, last 24h
- **Disk usage** (per site) — `edge_disk_used_percent{mount="/data"}`, gauge panels with 80%/90% threshold lines
- **NTP offset** (per site) — `edge_ntp_offset_ms`, table sorted by worst offset
- **Camera reachability** — count of unreachable cameras per site

### Dashboard 2: Cloud Processing Health

**Audience**: Engineering team, on-call engineer
**Refresh**: 15s

Panels:
- **Chunk processing latency** — P50/P95/P99 histogram over time; SLO threshold line at 10s
- **Upload success rate** — `rate(video_chunk_upload_total{status="success"})` vs total; SLO line at 99.5%
- **Kafka consumer lag** — per partition, last 1h; alert threshold overlay at 5 min lag
- **Pod status** — kube-state-metrics replica counts (desired vs available vs ready)
- **JVM heap usage** — `jvm_memory_used_bytes / jvm_memory_max_bytes` per pod; 80% threshold line
- **GPU utilisation** — `DCGM_FI_DEV_GPU_UTIL` per node

### Dashboard 3: Business KPIs

**Audience**: Product, customer success, leadership
**Refresh**: 5 min

Panels:
- **Chunks processed per site per hour** — table of all sites, current hour vs 7-day average
- **Sites healthy / degraded / critical** — three stat panels with colour thresholds
- **Inference detections per hour** — trend line across all sites; anomaly detection overlay
- **S3 storage cost trend** — bytes uploaded per day, 30-day view; budget threshold line
- **SLO burn rate** — error budget consumed this month (upload success + API availability)

### Dashboard 4: Deployment Tracking

**Audience**: Engineering team
**Refresh**: 1 min (live during deploys, otherwise low frequency)

Panels:
- **Current image tag per environment** — which version is running in staging vs production
- **Rollout progress** — pod-by-pod image update status during a rolling deploy
- **Recent deployments** — table of last 10 deploy events (image tag, deployer, timestamp, result)
- **Rollback history** — any rollback events in the last 30 days
