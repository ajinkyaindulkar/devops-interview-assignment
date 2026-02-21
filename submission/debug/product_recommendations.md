# Product & Engineering Recommendations

Based on the investigation of the SITE-2847 MTU misconfiguration incident (2025-11-12).

---

## Monitoring Improvements

### 1. Upload-path health check (highest priority)

The container's `HEALTHCHECK` probed `/health/live` — a small HTTP call that always
succeeded even when all S3 uploads were failing. This is a fundamental gap: the check
measured whether the process was alive, not whether the service was functional.

**Add a synthetic upload probe to `healthcheck.sh`:**
- Every 60 seconds, PUT a ~64 KB test object to a dedicated monitoring S3 bucket
  (`vlt-edge-healthcheck-prod/<site_id>/probe.bin`).
- If the PUT takes > 5 seconds or fails, set `edge_upload_reachable=0` in the
  textfile exporter and emit a WARN log line `upload_path_check: FAIL`.
- This would have fired within 30 seconds of 08:15, 14 minutes before the NOC alert
  from the disk threshold.

### 2. Log-based alert for MTU/fragmentation diagnosis

At 08:22:16, the application itself logged:
> `Possible MTU/fragmentation issue: large packets timing out, small health checks succeed`

No alert was configured for this pattern. A CloudWatch Logs Insights metric filter on
`"MTU/fragmentation"` at WARN level would have triggered within 30 seconds of that
log entry. **Rule of thumb: any structured log line that contains a human-readable
root-cause diagnosis should have a corresponding alert.**

### 3. ICMP "fragmentation needed" kernel log alert

The kernel emitted `ICMP: 10.50.1.1: fragmentation needed and DF set, mtu=1500`
three times in 2 seconds at 08:18:33. This is a deterministic signal that MTU is
misconfigured. A Prometheus textfile exporter scraping `/proc/net/snmp` for
`IcmpMsgInType3` (destination unreachable) spikes would catch this class of issue
without application-level instrumentation.

### 4. VPN throughput metric (not just tunnel UP/DOWN)

The `VPNTunnelStatus` metric in CloudWatch showed the tunnel as `UP` for most of the
incident — it was only `DOWN` during the 60-second rekey windows. A tunnel can be
"up" and nearly useless (1.8 Mbps vs 50 Mbps expected). Add `edge_vpn_throughput_mbps`
to the healthcheck.sh textfile exporter, sampled via a timed `iperf3` probe to a
fixed AWS endpoint inside the VPN. Alert if throughput drops below 10 Mbps.

---

## Automated Detection and Self-Healing

### 1. Post-change validation with automatic rollback (`netplan try`)

`netplan try` applies a configuration and automatically reverts it after a 30-second
timeout unless the operator explicitly confirms with `netplan apply`. This is the
correct tool for any network interface change on an edge device:

```bash
# In the change automation / SSM Run Command:
netplan try --timeout 30
# Operator (or automated test) confirms within 30s, otherwise auto-reverts
```

If automated, the confirmation step should be: VPN tunnel UP + test upload succeeds
within 30 seconds. If not confirmed, netplan reverts automatically — the same
safety net as a circuit breaker.

### 2. MTU consistency check in healthcheck.sh

Add a check to `healthcheck.sh`:

```bash
# Expected MTU per interface — single source of truth
declare -A EXPECTED_MTU=( ["eno1"]=1500 ["eno2"]=9000 )

for iface in "${!EXPECTED_MTU[@]}"; do
    actual=$(ip link show "$iface" | awk '/mtu/{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')
    if [[ "$actual" != "${EXPECTED_MTU[$iface]}" ]]; then
        mark_status 2   # CRITICAL
        add_check "mtu_${iface}" "critical" \
          "MTU is ${actual}, expected ${EXPECTED_MTU[$iface]} — possible misconfiguration"
    fi
done
```

This check runs every 60 seconds via the systemd timer. An MTU mismatch on eno1
would have been detected within 60 seconds of the 08:15 netplan apply — before
the first upload timeout at 08:17.

### 3. Inhibit camera/upload alerts when MTU is misconfigured

In Alertmanager, inhibit upload failure and tunnel flap alerts when the
`mtu_eno1_critical` alert is active for the same `site_id`. This prevents the NOC
from receiving 6 different alerts (upload failure, tunnel down x4, disk warning) and
helps them focus on the root cause: the MTU check. **The alert that names the cause
should suppress the alerts that describe the symptoms.**

---

## Platform Changes

### 1. Network interface change control — eno1 requires change board approval

`eno1` is not a camera-facing interface — it carries the VPN tunnel and all cloud
connectivity for the site. Any netplan change to `eno1` should require:
- A separate change ticket from changes to `eno2` (even when the intent is to modify
  both in one maintenance window)
- A second-engineer review of the netplan YAML before `netplan try` is executed
- An automated diff (`netplan generate > /tmp/new.yaml && diff /tmp/current.yaml /tmp/new.yaml`)
  as part of the change pre-check, showing exactly which interfaces are affected

### 2. Netplan change dry-run in CI/SSM automation

Any SSM Run Command document or Ansible playbook that applies netplan changes should
run `netplan generate --root-dir /tmp/netplan-test` first and parse the output to
confirm which interfaces will be reconfigured. If the diff shows `eno1` when only
`eno2` was intended, the automation aborts and creates an alert.

### 3. Structured change log with interface mapping

NET-4521 was titled "Enable jumbo frames for camera VLAN performance" — the title
implied `eno2` but the implementation targeted `eno1`. Change tickets for network
interface modifications should require the submitter to explicitly specify:
- Interface name (e.g. `eno2`)
- Current value (e.g. `mtu: 1500`)
- New value (e.g. `mtu: 9000`)
- Rollback procedure (e.g. `ip link set dev eno2 mtu 1500`)

Enforcing this schema at the JIRA ticket level makes the "wrong interface" class of
mistake visible before the change is executed.

---

## Edge Device Improvements

### 1. Per-interface MTU in the golden image configuration baseline

The golden image strategy stores per-site config in `/etc/video-ingest/site.env`
and `cameras.json`. Network interface MTU should be treated the same way:
add a canonical `interface_config.yaml` to the site config package, deployed
via cloud-init, that declares the authoritative MTU for each interface:

```yaml
# /etc/video-ingest/interface_config.yaml — source of truth for this site
interfaces:
  eno1:
    mtu: 1500   # WAN/management — must match site gateway 10.50.1.1
  eno2:
    mtu: 9000   # Camera VLAN — internal only, no gateway MTU constraint
```

`healthcheck.sh` reads this file and validates the live interface MTU against it.
Any deviation is a CRITICAL check failure. SSM Run Command can push an updated
`interface_config.yaml` when a legitimate MTU change is needed, making the change
visible in the site's config history.

### 2. Automated validation suite after any config push

After every SSM Run Command or Ansible playbook executes on an edge device, trigger
`healthcheck.sh` automatically and assert exit 0 before marking the change as
successful. If `healthcheck.sh` returns 1 or 2, trigger immediate automated rollback
via SSM (re-push the previous config package) and page the on-call engineer.

This converts every config push from a fire-and-forget operation into a
change-with-verification loop — the same principle as `deploy.py`'s `health_check()`
call after every Kubernetes rollout.

### 3. Local change audit log on the edge device

Currently, the only record of "who changed what, when" on an edge device is in
the upstream change management system (JIRA/SSM). Add a local append-only log
(`/var/log/edge-changes.log`) that records every config file modification with
a timestamp, the source (cloud-init / SSM / manual), and the before/after diff.
This log should be collected by the Prometheus textfile exporter and shipped to
CloudWatch Logs, so an engineer investigating an incident can immediately see
"what changed on this device in the last 2 hours" without consulting multiple
external systems.
