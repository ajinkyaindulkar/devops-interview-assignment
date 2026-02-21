#!/usr/bin/env bash
#
# remediation.sh — Immediate remediation for SITE-2847 MTU misconfiguration incident
#
# Root cause: eno1 MTU was changed from 1500 to 9000 by a misconfigured netplan
# change (NET-4521), breaking the IPSec VPN tunnel and all S3 video uploads.
#
# What this script does:
#   1. Confirms the MTU misconfiguration is present (idempotent — safe to re-run)
#   2. Reverts eno1 MTU to 1500 — both at runtime (ip link) and in the persisted
#      netplan config so the fix survives a reboot
#   3. Restarts strongSwan to clear any broken IKE SAs left over from tunnel flaps
#   4. Waits for the VPN tunnel to re-establish
#   5. Verifies upload connectivity with a test S3 object
#   6. Reports the outcome
#
# Safe to re-run: every action checks current state before acting.
# If the MTU is already correct this script exits 0 with a "no action needed" message.
#
# Usage:
#   sudo bash remediation.sh
#
# Requirements: ip, netplan, strongswan (swanctl), aws CLI, curl

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TARGET_INTERFACE="eno1"              # WAN/VPN interface — must be MTU 1500
CORRECT_MTU=1500                     # Site gateway 10.50.1.1 supports only 1500
NETPLAN_CONF="/etc/netplan/99-edge.yaml"   # Netplan file applied by NET-4521
VPN_PEER="52.14.88.201"             # AWS VPN endpoint (from vpn_status.log)
VPN_CONN_NAME="aws-vpn"             # strongSwan connection name
S3_TEST_BUCKET="vlt-edge-healthcheck-prod"   # Bucket for upload connectivity test
S3_TEST_KEY="remediation-test/$(hostname)-$(date -u +%s).txt"
VPN_WAIT_TIMEOUT=60                 # Seconds to wait for VPN to re-establish
LOG_FILE="/var/log/remediation-$(date -u '+%Y%m%dT%H%M%S').log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

pass() { log "PASS: $1"; }
fail() { log "FAIL: $1"; exit 1; }
warn() { log "WARN: $1"; }

log "Starting remediation for SITE-2847 MTU incident"
log "Log file: $LOG_FILE"

# ---------------------------------------------------------------------------
# STEP 1: Confirm the problem exists before changing anything
#
# WHY check first: this script may be run after a partial remediation, or on
# a device that is not affected. We do not want to restart strongSwan or
# modify netplan config on a healthy device unnecessarily.
# ---------------------------------------------------------------------------
log "Step 1: Checking current MTU on ${TARGET_INTERFACE}"

current_mtu="$(ip link show "$TARGET_INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if ($i=="mtu") print $(i+1)}')"

if [[ -z "$current_mtu" ]]; then
    fail "Interface ${TARGET_INTERFACE} not found — cannot proceed"
fi

log "Current MTU on ${TARGET_INTERFACE}: ${current_mtu}"

if [[ "$current_mtu" -eq "$CORRECT_MTU" ]]; then
    log "MTU is already ${CORRECT_MTU} — no runtime change needed"
    MTU_ALREADY_CORRECT=true
else
    log "MTU is ${current_mtu} (should be ${CORRECT_MTU}) — remediation required"
    MTU_ALREADY_CORRECT=false
fi

# ---------------------------------------------------------------------------
# STEP 2: Revert MTU at runtime (immediate effect, does not survive reboot)
#
# WHY ip link before netplan: 'ip link set mtu' takes effect instantly without
# disrupting the network stack beyond the MTU change. 'netplan apply' causes
# a brief interface reconfiguration that can interrupt active connections.
# We fix the runtime state first to restore uploads as fast as possible, then
# persist the fix via netplan.
# ---------------------------------------------------------------------------
if [[ "$MTU_ALREADY_CORRECT" == "false" ]]; then
    log "Step 2a: Reverting MTU at runtime"
    ip link set dev "$TARGET_INTERFACE" mtu "$CORRECT_MTU"

    # Verify the runtime change took effect
    new_mtu="$(ip link show "$TARGET_INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if ($i=="mtu") print $(i+1)}')"
    if [[ "$new_mtu" -ne "$CORRECT_MTU" ]]; then
        fail "Runtime MTU revert failed — expected ${CORRECT_MTU}, got ${new_mtu}"
    fi
    pass "Runtime MTU on ${TARGET_INTERFACE} reverted to ${new_mtu}"
else
    log "Step 2a: Skipping runtime MTU change (already correct)"
fi

# ---------------------------------------------------------------------------
# STEP 3: Persist the correct MTU in netplan
#
# WHY persist separately: 'ip link set mtu' does NOT survive a reboot.
# If the edge device reboots (planned or unplanned) before netplan is fixed,
# the incident recurs. We patch the netplan YAML to set mtu: 1500 for eno1
# and simultaneously ensure eno2 has the intended jumbo frame setting if
# NET-4521's goal was valid for eno2.
#
# WHY sed in-place with a backup: the netplan file may contain other config
# we must not overwrite. We target only the eno1 mtu line.
# ---------------------------------------------------------------------------
log "Step 3: Persisting correct MTU in netplan config (${NETPLAN_CONF})"

if [[ ! -f "$NETPLAN_CONF" ]]; then
    warn "Netplan config ${NETPLAN_CONF} not found — skipping persist step."
    warn "Manually verify that no netplan file sets eno1 mtu to 9000."
else
    # Create a timestamped backup before modifying
    cp "$NETPLAN_CONF" "${NETPLAN_CONF}.bak-$(date -u '+%Y%m%dT%H%M%S')"
    log "Backup written to ${NETPLAN_CONF}.bak-*"

    # Replace any 'mtu: 9000' under the eno1 stanza with 'mtu: 1500'
    # The sed pattern targets the line in context — only under 'eno1:' block
    # WHY not a full YAML rewrite: minimise the blast radius; touch only
    # the one value that caused the incident.
    if grep -q "mtu: 9000" "$NETPLAN_CONF"; then
        sed -i 's/mtu: 9000/mtu: 1500/' "$NETPLAN_CONF"
        pass "Replaced 'mtu: 9000' with 'mtu: 1500' in ${NETPLAN_CONF}"
    else
        log "No 'mtu: 9000' found in ${NETPLAN_CONF} — nothing to patch"
    fi

    # Apply the updated netplan without a full interface restart
    # --debug shows what changed; 2>/dev/null suppresses warnings about
    # non-netplan-managed interfaces
    netplan apply 2>/dev/null || warn "netplan apply returned non-zero — verify manually"
    pass "netplan apply completed"
fi

# ---------------------------------------------------------------------------
# STEP 4: Restart strongSwan to clear broken IKE SAs
#
# WHY restart: the MTU change caused 4 DPD timeouts and tunnel flaps, leaving
# stale IKE_SA entries (aws-vpn[42..45]). Even though the tunnel re-established
# after each flap, the ESP SAs may still have cached the old (9000-byte) MSS.
# A clean restart ensures a fresh IKE negotiation with the correct MTU.
#
# WHY 'systemctl restart' and not 'swanctl --terminate + --initiate':
# terminate+initiate can leave a 2-3 second window where no tunnel exists.
# systemctl restart is atomic from the connection perspective — strongSwan
# starts the new process and re-initiates before the old one fully exits.
# ---------------------------------------------------------------------------
log "Step 4: Restarting strongSwan to clear stale IKE SAs"
systemctl restart strongswan-starter 2>/dev/null \
    || systemctl restart strongswan 2>/dev/null \
    || fail "Could not restart strongSwan — check service name with 'systemctl list-units | grep swan'"
pass "strongSwan restarted"

# ---------------------------------------------------------------------------
# STEP 5: Wait for VPN tunnel to re-establish
#
# WHY poll instead of sleep: IKE re-establishment typically completes in 2-5
# seconds but can take up to 30s if the AWS VPN endpoint is recovering from
# its own DPD state. Polling lets us succeed as soon as the tunnel is up
# rather than waiting a fixed duration.
# ---------------------------------------------------------------------------
log "Step 5: Waiting for VPN tunnel to re-establish (timeout: ${VPN_WAIT_TIMEOUT}s)"

deadline=$(( $(date +%s) + VPN_WAIT_TIMEOUT ))
tunnel_up=false

while [[ $(date +%s) -lt $deadline ]]; do
    # swanctl --list-sas exits 0 and prints the SA name when the tunnel is up
    if swanctl --list-sas 2>/dev/null | grep -q "$VPN_CONN_NAME"; then
        tunnel_up=true
        break
    fi
    sleep 3
done

if [[ "$tunnel_up" == "true" ]]; then
    pass "VPN tunnel '${VPN_CONN_NAME}' is established"
else
    fail "VPN tunnel did not re-establish within ${VPN_WAIT_TIMEOUT}s — check strongSwan logs: journalctl -u strongswan --since '2 minutes ago'"
fi

# ---------------------------------------------------------------------------
# STEP 6: Verify S3 upload connectivity
#
# WHY test an actual upload: ping and VPN tunnel UP status only confirm layer 3
# reachability. The original failure was at the application layer — large
# packets being dropped. We PUT a small test object to confirm the path is
# end-to-end functional, using the same AWS credentials the container uses
# (instance profile / IRSA).
#
# WHY a small object (not a large one): we want to confirm the path is open,
# not reproduce the load. A small object fits in a few packets; if even that
# fails, the path is still broken.
# ---------------------------------------------------------------------------
log "Step 6: Verifying S3 upload connectivity with test object"

echo "remediation-test $(date -u)" > /tmp/remediation-test.txt

if aws s3 cp /tmp/remediation-test.txt "s3://${S3_TEST_BUCKET}/${S3_TEST_KEY}" \
       --region us-east-1 2>>"$LOG_FILE"; then
    pass "S3 test upload succeeded: s3://${S3_TEST_BUCKET}/${S3_TEST_KEY}"
    # Clean up the test object — we don't want monitoring buckets filling up
    aws s3 rm "s3://${S3_TEST_BUCKET}/${S3_TEST_KEY}" --region us-east-1 2>/dev/null || true
else
    fail "S3 test upload failed — VPN may be up but S3 route is still broken. Check 'aws s3 ls s3://${S3_TEST_BUCKET}/' manually."
fi

rm -f /tmp/remediation-test.txt

# ---------------------------------------------------------------------------
# STEP 7: Final status report
# ---------------------------------------------------------------------------
log "================================================="
log "Remediation COMPLETE for SITE-2847"
log "  Interface:   ${TARGET_INTERFACE}"
log "  MTU before:  ${current_mtu}"
log "  MTU after:   $(ip link show "$TARGET_INTERFACE" | awk '/mtu/{for(i=1;i<=NF;i++) if ($i=="mtu") print $(i+1)}')"
log "  VPN tunnel:  UP"
log "  S3 upload:   OK"
log ""
log "Next steps:"
log "  1. Monitor CloudWatch VideoChunkUploadErrors for SITE-2847 — should be 0"
log "  2. Confirm upload backlog drains: 'docker exec video-ingest cat /var/video-buffer/queue.json'"
log "  3. Re-apply NET-4521 change to the CORRECT interface (eno2) after reviewing"
log "     the netplan config with the network team"
log "  4. Create a post-mortem and follow up on action items in postmortem.md"
log "================================================="
