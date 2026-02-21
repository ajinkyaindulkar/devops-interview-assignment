# Root Cause Analysis — SITE-2847 Video Upload Failure

## Summary

At 08:15 UTC on 2025-11-12, a scheduled netplan configuration change (ticket NET-4521,
"Enable jumbo frames for camera VLAN performance") was applied to the wrong network interface
on the Denver edge device. The change set `eno1` (the management/WAN interface that carries
the IPSec VPN tunnel to AWS) to MTU 9000, instead of `eno2` (the camera VLAN interface that
the ticket intended). The site gateway (`10.50.1.1`) supports only MTU 1500 and cannot pass
jumbo frames. As a result, all large ESP-encapsulated S3 upload packets were rejected at the
gateway with ICMP "fragmentation needed" messages, degrading upload throughput from 41 Mbps
to ~1.8 Mbps and eventually causing total upload failure. Small packets (Docker health checks,
IKE keepalives) continued to pass because they fit within the 1500-byte gateway MTU — this
masked the failure from the container health check. The backlog grew for 45 minutes until a
NOC engineer manually reverted the MTU to 1500, immediately restoring uploads.

---

## Timeline

| Time (UTC) | Source | Event |
|------------|--------|-------|
| 08:00 | CloudWatch / app_logs.txt | All systems nominal. Upload success rate 100%, throughput 41–44 Mbps (`app_logs.txt:1-3`) |
| 08:15:03 | edge_syslog.txt:6 | `kernel: device eno1: MTU changed from 1500 to 9000 via netplan apply` — wrong NIC |
| 08:15:05 | vpn_status.log:8 | `WARNING: IKE SA keepalive: packet size 9000 exceeds path MTU 1500` — VPN immediately warns |
| 08:15 | cloudwatch_metrics.json | `VideoChunkUploadErrors` rises from 0 → 2 — first upload failures |
| 08:18:33 | edge_syslog.txt:12-14 | Three consecutive `ICMP: 10.50.1.1: fragmentation needed and DF set, mtu=1500` — gateway rejecting jumbo ESP packets |
| 08:18:30 | vpn_status.log:9-10 | `ESP packets being fragmented at gateway, excessive reassembly failures` / `IPSec throughput degraded: expected 50Mbps, actual 2.3Mbps` |
| 08:17–08:19 | app_logs.txt:6-13 | S3 multipart upload for `chunk-20251112-081200-cam001.ts` times out on part 1/5 across all 3 retry attempts — large chunks cannot pass the gateway |
| 08:20 | cloudwatch_metrics.json | Upload error count spikes: 0 → 18 per 5-min window |
| 08:20:15 | edge_syslog.txt:19 | Docker health check still passes — `/health/live` HTTP request fits in one 1500-byte packet |
| 08:20:58 | edge_syslog.txt:22-24 / vpn_status.log:11-12 | strongSwan DPD timeout — `peer 52.14.88.201 not responding` — IKE DPD probe itself is large enough to be blocked; tunnel tears down |
| 08:21:10 | edge_syslog.txt:28-29 | Tunnel re-established (IKE_SA[43]) — but MTU is still 9000, so uploads immediately fail again |
| 08:22:16 | app_logs.txt:20-21 | App self-diagnoses: `"Possible MTU/fragmentation issue: large packets timing out, small health checks succeed"` — correct diagnosis, but no automated alert triggered on this log line |
| 08:25–08:50 | vpn_status.log:16-24 | Three more DPD timeouts and tunnel flaps (08:25, 08:35, 08:50) — each flap lasts ~60s; `Sustained packet loss on ESP tunnel: 34%` at 08:36 |
| 08:30 | cloudwatch_metrics.json | Disk usage: 45% → 85%; upload backlog: 22 chunks; NOC alert fired |
| 08:30:01 | edge_syslog.txt:38 | `CRITICAL: Upload queue backlog exceeds threshold, alerting NOC` |
| 08:45 | timeline.md | NOC engineer begins investigation (15 min after alert received) |
| 08:45 | cloudwatch_metrics.json | Disk usage reaches 91% |
| 09:00:00 | vpn_status.log:27 | `Local interface eno1 MTU changed: 9000 -> 1500` — NOC reverts the change |
| 09:00:05 | vpn_status.log:28-29 | `ESP packet fragmentation stopped` / `Tunnel stable — DPD normal` |
| 09:00 | cloudwatch_metrics.json | Upload errors drop from 24 → 0; disk usage recovers from 91% → 65% as backlog drains |

**Total incident duration: 45 minutes** (08:15 – 09:00 UTC)

---

## Root Cause

**Misconfigured network interface MTU caused by applying a netplan change to the wrong NIC.**

Ticket NET-4521 intended to set `eno2` (camera VLAN, `10.50.20.0/24`) to MTU 9000 to improve
RTSP ingest throughput between cameras and the edge device. The netplan configuration was
instead applied to `eno1` (management VLAN + WAN uplink, `10.50.1.50`), which carries all
cloud-bound traffic through the IPSec VPN tunnel.

The failure mechanism is:

1. `eno1` MTU set to 9000. The edge device now attempts to send 9000-byte ESP packets out through the VPN tunnel.
2. The site gateway (`10.50.1.1`) has a physical MTU of 1500 and does not support jumbo frames.
3. ESP packets have the **DF (Don't Fragment) bit set** by default in strongSwan's IPSec implementation — they cannot be fragmented in transit.
4. The gateway drops the oversized packets and returns **ICMP Type 3 Code 4 ("fragmentation needed and DF set")** messages back to the edge device, specifying `mtu=1500`.
5. Path MTU Discovery (PMTUD) should have clamped the effective MTU, but strongSwan's PMTUD was not propagating the gateway's ICMP advisory back to the upload application's TCP socket in time — the upload was already in the process of timing out.
6. All S3 multipart upload parts (each several hundred MB) fail. Small packets — IKE keepalives, Docker health check HTTP requests, DNS queries — still pass because they are under 1500 bytes.
7. DPD (Dead Peer Detection) IKE probes are large enough to be blocked, causing repeated tunnel tears at 08:21, 08:25, 08:35, 08:50.

**Key evidence:**
- `edge_syslog.txt:6`: `kernel: device eno1: MTU changed from 1500 to 9000 via netplan apply` at 08:15:03 — exact time the failure begins.
- `vpn_status.log:8`: `IKE SA keepalive: packet size 9000 exceeds path MTU 1500` — VPN warned immediately.
- `edge_syslog.txt:12-14`: Three `ICMP: 10.50.1.1: fragmentation needed and DF set, mtu=1500` — confirms gateway is rejecting the packets.
- `app_logs.txt:20-21`: `Network throughput: 1.8 Mbps` / `Possible MTU/fragmentation issue` — the application correctly identified the symptom but no alert fired on this log line.
- `cloudwatch_metrics.json`: Upload errors spike exactly at 08:15, the same minute as the MTU change — zero errors for the prior 45 minutes.
- `vpn_status.log:27`: `eno1 MTU changed: 9000 -> 1500` at 09:00:00 — errors drop to 0 immediately (`cloudwatch_metrics.json` 09:00 datapoint).

---

## Contributing Factors

### 1. Change applied to wrong interface — no pre-change validation
The netplan config for NET-4521 targeted `eno1` instead of `eno2`. No automated check
verified which interface the configuration would modify before applying it. A simple
`netplan try` (which applies the config and reverts automatically after a timeout if
not confirmed) was not used.

### 2. Health check monitors liveness, not upload path
The Docker `HEALTHCHECK` (and `healthcheck.sh`) probes `/health/live` — a small HTTP
request that fits in a single TCP segment well under 1500 bytes. It does not test the
actual S3 upload path. As a result, the container reported `healthy` throughout the entire
45-minute incident (`edge_syslog.txt:9,20,36`). An upload-path health check (e.g. a
test PutObject to a monitoring bucket) would have caught this within 30 seconds.

### 3. "MTU/fragmentation issue" app log line had no associated alert
At 08:22:16, the application self-diagnosed the problem (`app_logs.txt:21`):
> `Possible MTU/fragmentation issue: large packets timing out, small health checks succeed`

This is a structured log line at WARN level — but no Alertmanager or CloudWatch Logs
Insights rule was configured to trigger on it. The diagnosis sat in the log stream
unnoticed for 23 minutes until the NOC acted.

### 4. NOC response latency — 15 minutes from alert to investigation
The NOC alert fired at 08:30 (`edge_syslog.txt:38`). The NOC engineer began
investigating at 08:45 (`timeline.md`). During this 15-minute gap, disk usage rose
from 85% to 91% — close to the threshold where the container would begin dropping
new chunks rather than queuing them.

### 5. No change rollback automation
NET-4521 had no automated rollback on failure. When the netplan change caused an
immediate degradation (VPN warning at 08:15:05, upload errors at 08:15), the system
had no mechanism to revert the change and alert the change author. Resolution required
manual NOC intervention 45 minutes later.
