# Site Network Plan — SITE-2847 (Acme Distribution, Denver CO)

Reference: `data/site_spec.json`

## VLAN Design

| VLAN ID | Name | Subnet | Purpose |
|---------|------|--------|---------|
| 1 | management | 10.50.1.0/24 | IT management, SSH access, DNS, NTP, VPN uplink — existing |
| 10 | corporate | 10.50.10.0/24 | Office workstations — existing, no changes |
| 20 | cameras | 10.50.20.0/24 | IP cameras only — new, fully isolated from all other VLANs |

**Why a dedicated camera VLAN?**
IP cameras are embedded devices with limited firmware update cycles and a wide
vulnerability surface. Placing them on a dedicated VLAN with no routing to
management or corporate networks limits the blast radius of a compromised
camera to the camera VLAN only — it cannot pivot to reach the edge device's
management interface, corporate workstations, or the VPN.

---

## IP Addressing Scheme

### VLAN 1 — Management (10.50.1.0/24)

| Device | IP | Notes |
|---|---|---|
| Site gateway / L3 switch | 10.50.1.1 | Default gateway for management VLAN |
| DNS server (primary) | 10.50.1.10 | Also serves as NTP server per site_spec.json |
| DNS server (secondary) | 10.50.1.11 | |
| Edge device — eno1 | 10.50.1.50 | Static; management interface + WAN/VPN uplink |
| DHCP range | 10.50.1.100–10.50.1.200 | IT devices, laptops |

### VLAN 20 — Cameras (10.50.20.0/24)

| Device | IP | Notes |
|---|---|---|
| Edge device — eno2 | 10.50.20.1 | Static; acts as L3 gateway for camera VLAN |
| CAM-001 (Axis P3265-LVE, Loading Dock A) | 10.50.20.101 | DHCP reservation by MAC |
| CAM-002 (Axis P3265-LVE, Loading Dock B) | 10.50.20.102 | DHCP reservation by MAC |
| CAM-003 (Axis P3265-LVE, Warehouse Entrance) | 10.50.20.103 | DHCP reservation by MAC |
| CAM-004 (Axis Q6135-LE, Parking Lot North) | 10.50.20.104 | DHCP reservation by MAC |
| CAM-005 (Axis Q6135-LE, Parking Lot South) | 10.50.20.105 | DHCP reservation by MAC |
| CAM-006 (Axis P3265-LVE, Receiving Area) | 10.50.20.106 | DHCP reservation by MAC |
| CAM-007 (Axis P3265-LVE, Shipping Area) | 10.50.20.107 | DHCP reservation by MAC |
| CAM-008 (Axis P3265-LVE, Main Hallway) | 10.50.20.108 | DHCP reservation by MAC |
| Dynamic DHCP pool | 10.50.20.150–10.50.20.200 | Spare for future cameras |

DHCP for VLAN 20 is served by the edge device itself (dnsmasq on eno2) so no
DHCP traffic crosses the switch trunk to the management VLAN. MAC reservations
ensure cameras always receive the same IP, making RTSP stream URLs stable.

---

## Camera Network Isolation

Cameras are isolated through three complementary layers:

**1. VLAN segmentation at the switch**
VLAN 20 is an access VLAN on the switch ports where cameras connect. Trunk
ports carry tagged VLANs 1 and 20; cameras see only their untagged access
port — they have no visibility of VLAN 1 or 10 traffic at the Ethernet layer.

**2. No inter-VLAN routing**
The L3 switch (or router) has no route between VLAN 20 and VLANs 1 or 10.
Cameras are given a default gateway of `10.50.20.1` (edge device eno2) —
the edge device is the only gateway, and `firewall_rules.sh` explicitly
blocks forwarding from the camera VLAN to the management and corporate subnets.

**3. Host-based firewall on the edge device**
`firewall_rules.sh` applies iptables FORWARD chain rules that drop any packet
sourced from `10.50.20.0/24` destined for `10.50.1.0/24` (management) or
`10.50.10.0/24` (corporate). Even if the switch were misconfigured, the edge
device firewall provides a second enforcement point.

---

## Edge Device Network Configuration

The Dell PowerEdge XR4000 has two NICs serving two distinct roles:

| NIC | VLAN | IP | Role |
|---|---|---|---|
| eno1 | 1 (management) | 10.50.1.50/24 | Management access (SSH), WAN uplink, IPSec VPN tunnel to AWS |
| eno2 | 20 (cameras) | 10.50.20.1/24 | Camera VLAN gateway; RTSP ingest from all 8 cameras |

**Routing table on the edge device:**

```
Destination       Gateway       Interface   Notes
0.0.0.0/0         10.50.1.1     eno1        Default route — all cloud traffic via WAN
10.50.1.0/24      —             eno1        Management VLAN (directly connected)
10.50.20.0/24     —             eno2        Camera VLAN (directly connected)
<AWS VPC CIDR>    VPN tunnel    ipsec0      IPSec tunnel — video uploads, S3, SQS
```

The VPN tunnel (`ipsec0`) carries all cloud-bound traffic over eno1.
DNS for the edge device points to `10.50.1.10` and `10.50.1.11` (site DNS).
NTP is synchronised to `10.50.1.10` (configured in `edge/setup.sh`).

---

## Traffic Flow

```
IP Camera (10.50.20.x)
    │  RTSP stream (TCP 554) over VLAN 20
    ▼
Edge device — eno2 (10.50.20.1)
    │  Video ingest container captures RTSP, runs local AI inference (NVIDIA T4)
    │  Chunks processed video frames + inference metadata
    ▼
Edge device — eno1 (10.50.1.50)
    │  HTTPS (TCP 443) traffic enters IPSec tunnel (strongSwan)
    ▼
IPSec VPN tunnel → AWS VPC
    │  S3 PutObject  → vlt-video-chunks-prod (video frames)
    │  SQS SendMessage → inference results queue
    ▼
AWS Cloud (EKS — Kafka Streams processor, inference API, dashboards)
```

Key constraints:
- Cameras **never** initiate connections; the edge device pulls RTSP streams.
- Camera traffic **never** leaves VLAN 20 — it is consumed entirely on eno2.
- All cloud-bound traffic traverses eno1 inside the IPSec tunnel; no video
  data crosses the internet unencrypted.
- Upload bandwidth is capped at 50 Mbps per `site_spec.json` requirements,
  enforced by traffic shaping on eno1.
