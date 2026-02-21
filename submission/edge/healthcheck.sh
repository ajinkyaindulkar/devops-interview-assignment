#!/usr/bin/env bash
#
# healthcheck.sh — Edge device health check script
#
# Checks each critical subsystem on the edge device, collects results, and
# outputs a single JSON document to stdout.  The exit code signals the
# worst-case severity so callers (systemd, Nagios, SSM) can act without
# parsing JSON:
#
#   0 — all checks passed (healthy)
#   1 — at least one check is DEGRADED (service is up but impaired)
#   2 — at least one check is CRITICAL (service is down or unusable)
#
# Design: set -euo pipefail is intentionally NOT used here.
# A failing check command (e.g. nvidia-smi absent) must NOT kill the script —
# every subsystem must be evaluated independently so the JSON report is always
# complete.  Each check captures its own exit status explicitly.
#
# Usage:
#   sudo bash healthcheck.sh
#   sudo bash healthcheck.sh | jq .           # pretty-print results
#
# Typical callers:
#   - golden_image.md CI smoke tests (assert exit 0 after first boot)
#   - Cron / systemd timer every 60s for continuous monitoring
#   - SSM Run Command for on-demand remote health snapshot

# ---------------------------------------------------------------------------
# Thresholds — adjust per site_spec.json
# ---------------------------------------------------------------------------
DISK_WARN_PCT=80          # DEGRADED  if any filesystem exceeds this
DISK_CRIT_PCT=90          # CRITICAL  if any filesystem exceeds this
NTP_WARN_MS=100           # DEGRADED  if NTP offset exceeds this many milliseconds
NTP_CRIT_MS=1000          # CRITICAL  if NTP offset exceeds this
VPN_INTERFACE="ipsec0"    # IPSec tunnel interface (strongSwan / ip link)
CAMERA_GATEWAY="10.50.20.1"  # Edge device eno2 — if its own address is unreachable
                              # the camera VLAN NIC is down
CAMERA_SAMPLE_IP="10.50.20.101"  # Ping one representative camera (CAM-001);
                                 # success means the VLAN and switch are healthy

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
OVERALL=0    # 0=healthy, 1=degraded, 2=critical — raised by mark_status()
declare -a CHECKS=()   # accumulates JSON check objects

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# mark_status SEVERITY
# Raises OVERALL to SEVERITY only if SEVERITY is worse than current value.
# Severity order: 0 (healthy) < 1 (degraded) < 2 (critical)
mark_status() {
    local sev=$1
    if [[ $sev -gt $OVERALL ]]; then
        OVERALL=$sev
    fi
}

# add_check NAME STATUS MESSAGE
# Appends a JSON check object to the CHECKS array.
# STATUS must be one of: "ok", "degraded", "critical"
add_check() {
    local name="$1"
    local status="$2"
    local message="$3"
    # Escape any double-quotes in the message to keep JSON valid
    message="${message//\"/\\\"}"
    CHECKS+=("{\"check\":\"${name}\",\"status\":\"${status}\",\"message\":\"${message}\"}")
}

# ============================================================================
# CHECK 1: Docker daemon
#
# WHY THIS IS CRITICAL: the video-ingest container cannot run without Docker.
# We use 'systemctl is-active' rather than 'docker info' because docker info
# opens a socket and can hang for 30 s if the daemon is deadlocked.
# ============================================================================
check_docker() {
    if systemctl is-active --quiet docker; then
        add_check "docker_daemon" "ok" "Docker daemon is active"
    else
        add_check "docker_daemon" "critical" \
            "Docker daemon is NOT active — video-ingest container cannot run"
        mark_status 2
    fi
}

# ============================================================================
# CHECK 2: video-ingest container
#
# WHY THIS IS CRITICAL: this is the primary workload.  A stopped or unhealthy
# container means no video is being ingested or uploaded to S3.
#
# Docker inspect exits 1 if the container does not exist (never started or
# was removed after a crash).  The .State.Health.Status field is present only
# if the image declares a HEALTHCHECK; we fall back to .State.Status otherwise.
# ============================================================================
check_container() {
    local status
    status="$(docker inspect --format '{{.State.Status}}' video-ingest 2>/dev/null)" || {
        add_check "video_ingest_container" "critical" \
            "Container 'video-ingest' does not exist — service has not been started or crashed and was removed"
        mark_status 2
        return
    }

    local health
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' video-ingest 2>/dev/null)"

    case "$status" in
        running)
            if [[ "$health" == "unhealthy" ]]; then
                add_check "video_ingest_container" "degraded" \
                    "Container is running but its HEALTHCHECK reports 'unhealthy' — check 'docker logs video-ingest'"
                mark_status 1
            else
                add_check "video_ingest_container" "ok" \
                    "Container is running (health: ${health})"
            fi
            ;;
        restarting)
            # Systemd Restart=always will restart it, but being in a restart loop
            # means no video is being processed right now — report as degraded
            add_check "video_ingest_container" "degraded" \
                "Container is in a restart loop — check 'journalctl -u video-ingest' for errors"
            mark_status 1
            ;;
        exited|dead)
            add_check "video_ingest_container" "critical" \
                "Container is ${status} — video ingest has stopped"
            mark_status 2
            ;;
        *)
            add_check "video_ingest_container" "degraded" \
                "Container is in unexpected state: ${status}"
            mark_status 1
            ;;
    esac
}

# ============================================================================
# CHECK 3: GPU accessibility
#
# WHY THIS IS CRITICAL: the NVIDIA T4 runs all real-time AI inference.
# Without GPU access the container will either fail to start (if it requires
# --gpus all) or fall back to CPU-only processing, exceeding frame latency SLOs.
#
# nvidia-smi exit code 0 means at least one GPU is visible and responsive.
# We capture the driver/CUDA versions for the JSON report to aid debugging.
# ============================================================================
check_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then
        add_check "gpu" "critical" \
            "nvidia-smi not found — NVIDIA driver may not be installed"
        mark_status 2
        return
    fi

    local smi_out
    if smi_out="$(nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total \
                             --format=csv,noheader,nounits 2>&1)"; then
        # nvidia-smi succeeded — extract first GPU's info for the message
        local first_gpu
        first_gpu="$(echo "$smi_out" | head -1 | tr -s ' ')"
        add_check "gpu" "ok" "GPU accessible: ${first_gpu}"
    else
        add_check "gpu" "critical" \
            "nvidia-smi failed — GPU may be unavailable or driver crashed: ${smi_out}"
        mark_status 2
    fi
}

# ============================================================================
# CHECK 4: Disk usage
#
# WHY THIS MATTERS: the /data/video-buffer directory holds up to 24h of
# buffered video chunks (site_spec.json: video_retention_local_hours=24).
# If the disk fills up, the ingest container can no longer write new chunks,
# causing dropped frames and eventual container crash.
#
# We check ALL mounted filesystems and report the worst offender.
# The root filesystem and /data are both important here.
# ============================================================================
check_disk() {
    local worst_pct=0
    local worst_fs=""
    local all_info=""

    while IFS= read -r line; do
        # df --output=pcent,target produces lines like "  42% /data"
        local pct fs
        pct="$(echo "$line" | awk '{print $1}' | tr -d '%')"
        fs="$(echo  "$line" | awk '{print $2}')"
        all_info="${all_info}${fs}:${pct}% "
        if [[ "$pct" -gt "$worst_pct" ]]; then
            worst_pct=$pct
            worst_fs=$fs
        fi
    done < <(df --output=pcent,target --exclude-type=tmpfs \
                --exclude-type=devtmpfs 2>/dev/null | tail -n +2)

    if [[ $worst_pct -ge $DISK_CRIT_PCT ]]; then
        add_check "disk" "critical" \
            "Disk ${worst_fs} is ${worst_pct}% full (>= ${DISK_CRIT_PCT}% threshold) — video buffer may be exhausted. All: ${all_info}"
        mark_status 2
    elif [[ $worst_pct -ge $DISK_WARN_PCT ]]; then
        add_check "disk" "degraded" \
            "Disk ${worst_fs} is ${worst_pct}% full (>= ${DISK_WARN_PCT}% warning threshold). All: ${all_info}"
        mark_status 1
    else
        add_check "disk" "ok" \
            "All filesystems below ${DISK_WARN_PCT}% — highest is ${worst_fs} at ${worst_pct}%. All: ${all_info}"
    fi
}

# ============================================================================
# CHECK 5: NTP synchronisation
#
# WHY THIS MATTERS: video chunk timestamps must be accurate for:
#   - S3 object ordering (consumers sort by time)
#   - IPSec certificate validity windows (±30s tolerance)
#   - CloudWatch metric alignment
#
# chronyc tracking outputs "System time: X.XXXXXXXXX seconds slow/fast of NTP time".
# We parse the offset and compare against thresholds.
# ============================================================================
check_ntp() {
    if ! command -v chronyc &>/dev/null; then
        add_check "ntp" "degraded" \
            "chronyc not found — cannot verify NTP synchronisation"
        mark_status 1
        return
    fi

    local tracking
    tracking="$(chronyc tracking 2>&1)" || {
        add_check "ntp" "degraded" \
            "chronyc tracking failed — chrony may not be running: ${tracking}"
        mark_status 1
        return
    }

    # Extract "System time" line: "System time     : 0.000012345 seconds slow of NTP time"
    local offset_sec
    offset_sec="$(echo "$tracking" | awk '/^System time/{print $4}')"

    if [[ -z "$offset_sec" ]]; then
        add_check "ntp" "degraded" \
            "Could not parse NTP offset from chronyc output"
        mark_status 1
        return
    fi

    # Convert seconds to milliseconds for threshold comparison (awk for float arithmetic)
    local offset_ms
    offset_ms="$(awk -v s="$offset_sec" 'BEGIN{printf "%d", s*1000}')"
    # Use absolute value — offset can be negative (fast) or positive (slow)
    offset_ms="${offset_ms#-}"

    if [[ $offset_ms -ge $NTP_CRIT_MS ]]; then
        add_check "ntp" "critical" \
            "NTP offset is ${offset_ms}ms (>= ${NTP_CRIT_MS}ms threshold) — IPSec auth may fail and timestamps will be inaccurate"
        mark_status 2
    elif [[ $offset_ms -ge $NTP_WARN_MS ]]; then
        add_check "ntp" "degraded" \
            "NTP offset is ${offset_ms}ms (>= ${NTP_WARN_MS}ms warning threshold)"
        mark_status 1
    else
        add_check "ntp" "ok" "NTP offset is ${offset_ms}ms — within threshold"
    fi
}

# ============================================================================
# CHECK 6: VPN tunnel
#
# WHY THIS IS CRITICAL: all video uploads to S3 and SQS messages travel over
# the IPSec tunnel (ipsec0).  If the tunnel is down, no data reaches the cloud
# even though the container is running — silently causing a data gap.
#
# We check 'ip link show' for the interface and its operational state.
# A UP+LOWER_UP interface means the tunnel is established.
# ============================================================================
check_vpn() {
    local link_state
    link_state="$(ip link show "$VPN_INTERFACE" 2>&1)" || {
        add_check "vpn_tunnel" "critical" \
            "VPN interface '${VPN_INTERFACE}' does not exist — IPSec tunnel is down. Video uploads will queue locally until reconnected."
        mark_status 2
        return
    }

    if echo "$link_state" | grep -q "state UP"; then
        add_check "vpn_tunnel" "ok" "VPN interface ${VPN_INTERFACE} is UP"
    else
        # Interface exists but is not UP — strongSwan may be re-keying or down
        add_check "vpn_tunnel" "degraded" \
            "VPN interface ${VPN_INTERFACE} exists but is not UP — tunnel may be re-keying: ${link_state}"
        mark_status 1
    fi
}

# ============================================================================
# CHECK 7: Camera connectivity
#
# WHY THIS MATTERS: the edge device cannot pull RTSP streams from cameras it
# cannot reach.  A failed ping to the camera gateway (eno2's own IP) means
# the camera-facing NIC is down.  A failed ping to a specific camera means
# that camera is offline or the switch port is down.
#
# We ping the gateway first (our own interface — should always succeed if NIC
# is up), then a representative camera.  Treating the gateway as CRITICAL and
# the individual camera as DEGRADED reflects the blast radius: a dead NIC
# affects all cameras; a single dead camera is isolated.
# ============================================================================
check_cameras() {
    # Ping our own eno2 address first — if this fails the NIC/VLAN is down
    if ! ping -c 1 -W 2 "$CAMERA_GATEWAY" &>/dev/null; then
        add_check "camera_vlan" "critical" \
            "Cannot ping camera VLAN gateway ${CAMERA_GATEWAY} (eno2) — NIC or VLAN 20 is down; ALL cameras unreachable"
        mark_status 2
        return
    fi

    # Now ping a representative camera
    if ping -c 1 -W 2 "$CAMERA_SAMPLE_IP" &>/dev/null; then
        add_check "camera_vlan" "ok" \
            "Camera VLAN reachable: gateway ${CAMERA_GATEWAY} OK, sample camera ${CAMERA_SAMPLE_IP} OK"
    else
        # Gateway is up but the camera isn't responding — camera-specific fault
        add_check "camera_vlan" "degraded" \
            "Camera VLAN gateway OK but sample camera ${CAMERA_SAMPLE_IP} did not respond — that camera may be offline"
        mark_status 1
    fi
}

# ============================================================================
# Run all checks — order does not affect scoring but mirrors operator triage
# priority: Docker → container → GPU → disk → NTP → VPN → cameras
# ============================================================================
check_docker
check_container
check_gpu
check_disk
check_ntp
check_vpn
check_cameras

# ============================================================================
# Emit JSON report
#
# WHY JSON: downstream consumers (monitoring agents, SSM automation, dashboards)
# can parse structured output without fragile string matching.  A human operator
# can pipe through 'jq .' for readable output.
#
# Structure:
#   {
#     "timestamp": "...",
#     "overall": "healthy|degraded|critical",
#     "checks": [ { "check": "...", "status": "...", "message": "..." }, ... ]
#   }
# ============================================================================
case $OVERALL in
    0) overall_str="healthy"  ;;
    1) overall_str="degraded" ;;
    2) overall_str="critical" ;;
    *) overall_str="unknown"  ;;
esac

# Build the checks JSON array by joining accumulated objects with commas
checks_json="$(printf '%s,' "${CHECKS[@]}")"
checks_json="[${checks_json%,}]"   # strip trailing comma, wrap in array

cat <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "overall": "${overall_str}",
  "checks": ${checks_json}
}
EOF

exit $OVERALL
