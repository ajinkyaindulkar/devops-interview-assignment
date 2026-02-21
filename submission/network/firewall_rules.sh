#!/usr/bin/env bash
#
# firewall_rules.sh — Edge device firewall configuration
#
# Implements iptables rules for SITE-2847 edge device.
# Network layout from site_plan.md and data/site_spec.json:
#   eno1 — management VLAN (10.50.1.0/24) + WAN/VPN uplink
#   eno2 — camera VLAN    (10.50.20.0/24)
#
# Security posture: default-deny on INPUT and FORWARD.
# Only explicitly permitted traffic is allowed in.
# The edge device's own outbound traffic (OUTPUT) is allowed by default —
# it needs to reach S3, MSK, and the VPN endpoint without restriction.

set -euo pipefail

# ---------------------------------------------------------------------------
# Network definitions — single source of truth, referenced throughout
# ---------------------------------------------------------------------------
MGMT_VLAN="10.50.1.0/24"       # Management VLAN (site_spec.json: existing VLAN 1)
CORPORATE_VLAN="10.50.10.0/24" # Corporate VLAN  (site_spec.json: existing VLAN 10)
CAMERA_VLAN="10.50.20.0/24"    # Camera VLAN     (site_plan.md: new VLAN 20)
WAN_IF="eno1"                  # Management + WAN uplink
CAM_IF="eno2"                  # Camera VLAN interface

# ---------------------------------------------------------------------------
# Flush existing rules
# Flush all chains before applying new rules to ensure we start from a clean
# state. Avoids duplicate rules if this script is run more than once.
# ---------------------------------------------------------------------------
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# ---------------------------------------------------------------------------
# Default policies
# INPUT DROP  — no unsolicited inbound traffic reaches the edge device
# FORWARD DROP — the edge device does not forward packets between VLANs unless
#               explicitly allowed (camera → cloud upload goes via OUTPUT, not FORWARD)
# OUTPUT ACCEPT — the edge device itself can initiate outbound connections:
#                S3 uploads (443), VPN (500/4500/ESP), DNS (53), NTP (123)
# ---------------------------------------------------------------------------
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT

# ---------------------------------------------------------------------------
# Loopback
# Processes communicating via localhost (Docker, Prometheus, health checks)
# must not be blocked. Without this, any service binding to 127.0.0.1 fails.
# ---------------------------------------------------------------------------
iptables -A INPUT -i lo -j ACCEPT

# ---------------------------------------------------------------------------
# Established / Related connections
# Allows return traffic for connections the edge device initiated (S3 uploads,
# VPN handshakes, DNS lookups) and for RTSP streams the ingest container pulled.
# Must come before any DROP rules so existing sessions are not interrupted.
# ---------------------------------------------------------------------------
iptables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ---------------------------------------------------------------------------
# SSH — management VLAN only
# SSH is restricted to packets arriving on eno1 from the management subnet.
# Binding the rule to the interface (eno1) prevents a camera-VLAN device from
# spoofing a management-VLAN source IP and reaching the SSH daemon.
# ---------------------------------------------------------------------------
iptables -A INPUT \
  -i "$WAN_IF" \
  -s "$MGMT_VLAN" \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

# ---------------------------------------------------------------------------
# RTSP — camera VLAN only (TCP and UDP, port 554)
# Cameras may push RTSP announce or respond to RTSP OPTIONS on this port.
# Bound to eno2 so a spoofed source on any other interface is rejected.
# TCP is used for RTSP control; UDP is used for RTP media data in some modes.
# ---------------------------------------------------------------------------
iptables -A INPUT \
  -i "$CAM_IF" \
  -s "$CAMERA_VLAN" \
  -p tcp --dport 554 \
  -m conntrack --ctstate NEW \
  -j ACCEPT

iptables -A INPUT \
  -i "$CAM_IF" \
  -s "$CAMERA_VLAN" \
  -p udp --dport 554 \
  -j ACCEPT

# ---------------------------------------------------------------------------
# HTTPS outbound (OUTPUT chain — edge device to cloud)
# The edge device uploads video chunks to S3 and calls AWS APIs over HTTPS.
# OUTPUT is already ACCEPT so this rule is explicit documentation of intent;
# it also makes the rule visible if OUTPUT policy is tightened in the future.
# ---------------------------------------------------------------------------
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# ---------------------------------------------------------------------------
# Camera VLAN isolation — block camera → management and camera → corporate
# Cameras are assigned 10.50.20.1 (eno2) as their default gateway, so any
# camera attempting to reach management or corporate subnets forwards through
# this device. These rules drop such packets in the FORWARD chain before they
# can reach their destination.
#
# Order matters: these DROP rules must appear before any broader FORWARD ACCEPTs
# to ensure camera traffic is blocked regardless of other rules.
# ---------------------------------------------------------------------------
iptables -A FORWARD \
  -i "$CAM_IF" \
  -s "$CAMERA_VLAN" \
  -d "$MGMT_VLAN" \
  -j DROP

iptables -A FORWARD \
  -i "$CAM_IF" \
  -s "$CAMERA_VLAN" \
  -d "$CORPORATE_VLAN" \
  -j DROP

# Block cameras from forwarding to any other destination as well.
# Cameras have no legitimate reason to reach the internet or any subnet
# other than the edge device itself (which is INPUT, not FORWARD).
iptables -A FORWARD \
  -i "$CAM_IF" \
  -s "$CAMERA_VLAN" \
  -j DROP

# ---------------------------------------------------------------------------
# ICMP — allow for diagnostics
# Ping is essential for network troubleshooting (verifying camera reachability,
# confirming VPN tunnel is up). Allow echo-request inbound and all ICMP types
# for established sessions. Unrestricted ICMP flood is not a realistic threat
# on a site-local management network.
# ---------------------------------------------------------------------------
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p icmp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# ---------------------------------------------------------------------------
# Logging — dropped INPUT and FORWARD packets
# Log before the implicit default-deny so dropped packets are visible in
# /var/log/syslog with a recognisable prefix. Rate-limited to 5/min to prevent
# log flooding if a camera misbehaves or a port scan occurs.
# ---------------------------------------------------------------------------
iptables -A INPUT \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "[FW-DROP-INPUT] " --log-level 4

iptables -A FORWARD \
  -m limit --limit 5/min --limit-burst 10 \
  -j LOG --log-prefix "[FW-DROP-FORWARD] " --log-level 4

echo "Firewall rules applied successfully"
