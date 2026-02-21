# Post-Incident Report — SITE-2847 Video Upload Failure

## Incident Summary

| Field | Value |
|-------|-------|
| Date | 2025-11-12 |
| Duration | 45 minutes (08:15 – 09:00 UTC) |
| Severity | P1 — Critical (complete video upload failure for one site) |
| Services Affected | S3 video upload pipeline, IPSec VPN tunnel, SITE-2847 (Denver Distribution Center) |
| Customer Impact | 45 minutes of video data delayed; ~22 video chunks queued locally; no permanent data loss (local buffer preserved all chunks) |

---

## What Happened

During a scheduled maintenance window, a netplan configuration change intended to
enable jumbo frames on `eno2` (camera VLAN interface) was mistakenly applied to
`eno1` (management/WAN interface) on the Denver edge device. This changed `eno1`'s
MTU from 1500 to 9000. The site gateway (`10.50.1.1`) only supports MTU 1500 and
cannot pass jumbo frames. The IPSec VPN tunnel runs over `eno1`, and all S3 uploads
traverse that tunnel. Large video chunk uploads (several hundred MB each) were
immediately rejected by the gateway with ICMP "fragmentation needed" messages,
while small packets (health checks, DNS queries) continued to pass unaffected.

The container's health check continued to report "healthy" throughout the incident
because it makes a small HTTP request that fits in a single 1500-byte packet. This
masked the failure from automated detection. The application correctly self-diagnosed
the issue in its logs at 08:22 — but no alert was configured for that log message.

The upload queue grew for 45 minutes, disk usage rose from 45% to 91%, and the VPN
tunnel flapped four times due to DPD probe failures. The NOC was alerted at 08:30
and an engineer reverted the MTU at 09:00, immediately restoring uploads. All
queued chunks were successfully uploaded from the local buffer after recovery.

---

## Timeline

| Time (UTC) | Source | Event |
|------------|--------|-------|
| 08:00 | CloudWatch | All systems normal — upload success rate 100%, throughput 41–44 Mbps |
| 08:15:03 | edge_syslog | `kernel: device eno1: MTU changed from 1500 to 9000 via netplan apply` |
| 08:15:05 | vpn_status.log | `WARNING: IKE SA keepalive: packet size 9000 exceeds path MTU 1500` |
| 08:15 | CloudWatch | First 2 upload errors appear |
| 08:18 | edge_syslog / vpn_status | ICMP "fragmentation needed" from 10.50.1.1; ESP reassembly failures; throughput drops to 2.3 Mbps |
| 08:19:07 | app_logs | First chunk (`cam001.ts`) fails all 3 upload retry attempts |
| 08:20 | CloudWatch | Upload errors: 18 per 5-min window |
| 08:20:58 | strongSwan | First DPD timeout — tunnel DOWN |
| 08:21:10 | strongSwan | Tunnel re-established — uploads still fail (MTU unchanged) |
| 08:22:16 | app_logs | Application logs: "Possible MTU/fragmentation issue" — unmonitored log line |
| 08:25 | strongSwan | Second tunnel flap; 14 chunks in backlog |
| 08:30 | CloudWatch | Disk at 85%; 22-chunk backlog; NOC alert fires |
| 08:35 | strongSwan | Third tunnel flap |
| 08:45 | NOC | Engineer begins investigation (15 min after alert) |
| 08:45 | CloudWatch | Disk at 91% |
| 08:50 | strongSwan | Fourth tunnel flap; 34% sustained packet loss |
| 09:00:00 | NOC / edge_syslog | `eno1 MTU changed: 9000 -> 1500` — NOC reverts change |
| 09:00:05 | vpn_status.log | `ESP packet fragmentation stopped / Tunnel stable` |
| 09:00 | CloudWatch | Upload errors: 24 → 0; disk usage recovers 91% → 65% |

---

## Root Cause

A netplan configuration change was applied to the wrong network interface. `eno1`
(the WAN/VPN interface) was given MTU 9000 instead of `eno2` (the camera VLAN
interface, where jumbo frames were intended). The site gateway (`10.50.1.1`) only
supports MTU 1500 and dropped all oversized ESP-encapsulated upload packets, which
have the DF (Don't Fragment) bit set and cannot be fragmented mid-path.

---

## Resolution

NOC engineer manually reverted `eno1` MTU from 9000 to 1500 at 09:00 UTC using
`ip link set dev eno1 mtu 1500` and re-applied netplan. The VPN tunnel stabilised
immediately, uploads resumed, and the 22-chunk backlog drained from local disk
buffer within ~10 minutes.

---

## Impact

| Metric | Value |
|---|---|
| Total incident duration | 45 minutes |
| Video upload failure window | 08:15 – 09:00 UTC (45 min) |
| Chunks delayed (not lost) | ~22 chunks queued locally; all uploaded after recovery |
| Permanent data loss | None — local buffer retained all chunks during the outage |
| VPN tunnel flaps | 4 (each ~60 seconds) |
| Peak disk usage | 91% (threshold: 90% critical) |
| Sites affected | 1 (SITE-2847, Denver Distribution Center) |
| Other sites affected | None |

No permanent video data was lost because the local buffer on the edge device's
`/data/video-buffer` partition retained all queued chunks. The data partition is
on a separate logical volume from the OS and survived the incident intact.

The customer (Acme Distribution) experienced a 45-minute delay in their video
analytics dashboard for the Denver site. Customer success proactively notified
the account team at 08:35.

---

## Action Items

| Action | Owner | Priority | Due Date |
|--------|-------|----------|----------|
| Add upload-path health check (test S3 PutObject to monitoring bucket) to healthcheck.sh | Edge Platform | P1 | 2025-11-19 |
| Add Alertmanager rule to fire on log line "MTU/fragmentation issue" from app_logs | Observability | P1 | 2025-11-19 |
| Add pre-change validation to netplan CI: `netplan generate --root-dir <tmpdir>` + verify interface assignments | Network Ops | P1 | 2025-11-19 |
| Add post-change automated rollback: apply netplan with `netplan try` (30s auto-revert if not confirmed) | Network Ops | P1 | 2025-11-26 |
| Reduce NOC alert → investigation SLA from 15 min to 5 min for P1 edge upload failures | Operations | P2 | 2025-11-26 |
| Add `edge_upload_success_rate` metric to healthcheck.sh output | Edge Platform | P2 | 2025-11-26 |
| Add change freeze on eno1 during business hours — netplan changes to WAN interface require change board approval | Change Management | P2 | 2025-12-03 |
| Apply NET-4521 (jumbo frames) to the correct interface (eno2) after network team review | Network Ops | P3 | 2025-12-10 |

---

## Lessons Learned

### What went well

- **Local video buffer worked as designed.** No data was permanently lost. The `/data/video-buffer` partition on a dedicated LVM volume survived the incident and all 22 chunks were uploaded after recovery. This was one of the key design decisions in the golden image strategy and it paid off.
- **Application self-diagnosed correctly.** The uploader logged "Possible MTU/fragmentation issue" at 08:22 — the right diagnosis 37 minutes before resolution. The application's instrumentation was good; the alerting pipeline around it was not.
- **CloudWatch metrics gave an accurate signal.** The `VideoChunkUploadErrors` counter went from 0 to 18 in the 5-minute window immediately after the MTU change. If this had been configured as a P1 alert trigger, the NOC could have been engaged 10 minutes earlier.

### What could be improved

- **The health check does not test the upload path.** A container that reports "healthy" while being completely unable to upload is a false negative. The `/health/live` endpoint must be augmented with a periodic S3 connectivity probe.
- **No automated rollback on change failure.** `netplan try` exists specifically to auto-revert a failed network change after a configurable timeout. Not using it was a missed safety net. Any netplan change applied manually or via automation should use `netplan try` rather than `netplan apply`.
- **The application's own diagnosis never became an alert.** Log-based alerting for structured warning messages is low-cost to implement and would have cut the detection gap from 15 minutes to under 2 minutes.
- **15 minutes from alert to investigation is too long for a P1 edge failure.** A site that cannot upload video is completely dark from the customer's perspective. The P1 SLA should be 5 minutes, not 15.
