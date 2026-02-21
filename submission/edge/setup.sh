#!/usr/bin/env bash
#
# setup.sh — Edge device provisioning script
#
# Provisions a fresh Ubuntu 22.04 edge device (Dell PowerEdge XR4000 + NVIDIA T4)
# for SITE-2847 (Acme Distribution, Denver CO).
# Reference: data/site_spec.json
#
# Usage:
#   SITE_ID=SITE-2847 IMAGE_TAG=v1.4.2 sudo bash setup.sh
#
# Environment variables:
#   SITE_ID    — customer site identifier (default: SITE-UNKNOWN)
#   IMAGE_TAG  — video-ingest container image tag to run (default: v1.0.0)

set -euo pipefail

SITE_ID="${SITE_ID:-SITE-UNKNOWN}"
IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"
LOG_FILE="/var/log/edge-setup-${SITE_ID}.log"

# NTP server from data/site_spec.json
NTP_SERVER="10.50.1.10"

# Video buffer directory — mounted into the container for local chunk staging
VIDEO_BUFFER_DIR="/data/video-buffer"

# ECR image (tag comes from IMAGE_TAG env var so it's never hardcoded)
ECR_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/video-ingest:${IMAGE_TAG}"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Cleanup trap
# If any command fails, log the error and remove partial state so a re-run
# starts cleanly. apt-get errors leave the package database locked; the
# cleanup resets that. Use '|| true' on cleanup steps so the trap itself
# never causes a secondary failure that obscures the original error.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR: setup failed at line ${BASH_LINENO[0]} with exit code $exit_code"
        log "Cleaning up partial state..."
        apt-get autoremove -y 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "Starting edge device setup for site: $SITE_ID (image: $IMAGE_TAG)"

# ============================================================================
# SECTION 1: System Updates and Base Packages
#
# Update the package index and upgrade all packages before adding third-party
# repos. This ensures a consistent, patched baseline. DEBIAN_FRONTEND=noninteractive
# prevents apt from prompting for input (e.g. timezone, kernel options) which
# would hang an unattended provisioning run.
# ============================================================================
log "Section 1: System updates and base packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get upgrade -y
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    chrony \
    logrotate \
    ufw \
    jq \
    awscli

log "Base packages installed"

# ============================================================================
# SECTION 2: Docker Installation
#
# Install Docker CE from Docker's official apt repository (not the Ubuntu snap
# or the older docker.io package). The snap version lacks daemon configuration
# support; docker.io lags behind upstream releases.
#
# Daemon config:
#   json-file log driver with rotation — prevents Docker logs from filling disk
#   overlay2 storage driver  — best performance on ext4/xfs (the NVMe SSD)
#   default-runtime: nvidia  — set after toolkit is installed (Section 3)
# ============================================================================
log "Section 2: Docker CE installation"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin

# Create a dedicated non-root service user for running the ingest container.
# Never run production workloads as root — limits blast radius if the container
# is compromised. The user is added to the docker group so it can manage containers
# without sudo.
useradd --system --shell /usr/sbin/nologin --create-home video-ingest || true
usermod -aG docker video-ingest

# Docker daemon configuration — written before starting Docker so it takes
# effect on first start. The nvidia runtime entry is added here and remains
# inactive until Section 3 installs the toolkit.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

systemctl enable docker
systemctl start docker
log "Docker CE installed and started"

# ============================================================================
# SECTION 3: NVIDIA GPU Drivers and Container Toolkit
#
# Install the NVIDIA driver for the T4 GPU (driver 525 is the minimum for T4
# on Ubuntu 22.04; 535 is the current LTS production driver as of 2025).
# nvidia-container-toolkit allows Docker to pass the GPU into containers via
# --gpus all. The daemon.json in Section 2 already sets default-runtime to
# nvidia, so containers that need GPU access get it automatically.
# ============================================================================
log "Section 3: NVIDIA GPU drivers and container toolkit"

# Add NVIDIA container toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -y
apt-get install -y nvidia-container-toolkit

# Install NVIDIA driver (535 = current LTS production driver for T4 on Ubuntu 22.04)
apt-get install -y nvidia-driver-535

# Configure the container toolkit runtime and restart Docker to pick it up
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

log "NVIDIA drivers and container toolkit installed"

# ============================================================================
# SECTION 4: NTP Configuration
#
# Accurate time is critical for:
#   - Video chunk timestamps (used for ordering in S3 and Kafka)
#   - IPSec VPN authentication (certificates have narrow time windows)
#   - CloudWatch metric alignment
#
# Use the site's NTP server (10.50.1.10 from site_spec.json) as primary.
# pool.ntp.org is listed as fallback in case the site server is unreachable
# (e.g. during initial provisioning before the VPN is up).
# ============================================================================
log "Section 4: NTP configuration"

cat > /etc/chrony/chrony.conf << EOF
# Site NTP server (data/site_spec.json: ntp_server)
server ${NTP_SERVER} iburst prefer

# Public pool as fallback
pool pool.ntp.org iburst

# Allow NTP client access from camera VLAN (cameras sync to edge device)
allow 10.50.20.0/24

driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
makestep 1.0 3
rtcsync
EOF

systemctl enable chrony
systemctl restart chrony

# Verify synchronisation — log the current offset
chronyc tracking | tee -a "$LOG_FILE" || true
log "NTP configured to use ${NTP_SERVER}"

# ============================================================================
# SECTION 5: Log Rotation
#
# Two logrotate configs:
#   video-ingest — rotates application logs daily, keeps 7 days, compresses
#   docker       — Docker's json-file driver handles its own rotation (set in
#                  daemon.json), but we also rotate /var/log/docker/*.log for
#                  any daemon-level logs written outside of containers.
# ============================================================================
log "Section 5: Log rotation"

mkdir -p /var/log/video-ingest

cat > /etc/logrotate.d/video-ingest << 'EOF'
/var/log/video-ingest/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 video-ingest adm
    sharedscripts
    postrotate
        # Signal the container to reopen log files after rotation
        docker kill --signal=USR1 video-ingest 2>/dev/null || true
    endscript
}
EOF

cat > /etc/logrotate.d/docker-daemon << 'EOF'
/var/log/docker*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

log "Log rotation configured"

# ============================================================================
# SECTION 6: Systemd Service
#
# The video-ingest container is managed by systemd rather than Docker's own
# restart policy. Systemd provides:
#   - Integration with journald for centralized log collection
#   - Dependency ordering (After=docker.service ensures Docker is up first)
#   - Restart backoff (RestartSec=15) to avoid tight crash loops
#   - Clean shutdown via ExecStop
#
# GPU access: --gpus all passes the T4 through to the container.
# Video buffer: /data/video-buffer is mounted for local chunk staging —
#               allows the container to buffer up to 24h of video on disk
#               (per site_spec.json: video_retention_local_hours: 24).
# Network: --network host avoids NAT overhead for RTSP ingest and S3 uploads.
# ============================================================================
log "Section 6: Systemd service"

mkdir -p "$VIDEO_BUFFER_DIR"
chown video-ingest:video-ingest "$VIDEO_BUFFER_DIR"

# Write the systemd unit file
cat > /etc/systemd/system/video-ingest.service << EOF
[Unit]
Description=Video Ingest Container — SITE-2847
Documentation=https://docs.internal/edge/video-ingest
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
User=video-ingest
Group=video-ingest
Restart=always
RestartSec=15
TimeoutStartSec=120
TimeoutStopSec=30

# Remove any stale container from a previous run before starting
ExecStartPre=-/usr/bin/docker stop video-ingest
ExecStartPre=-/usr/bin/docker rm   video-ingest

# Pull the latest image before each start so restarts pick up updated images
ExecStartPre=/usr/bin/docker pull ${ECR_IMAGE}

ExecStart=/usr/bin/docker run \
    --name          video-ingest \
    --gpus          all \
    --network       host \
    --env           SITE_ID=${SITE_ID} \
    --env           LOG_LEVEL=INFO \
    --volume        ${VIDEO_BUFFER_DIR}:/var/video-buffer \
    --volume        /etc/video-ingest:/etc/video-ingest:ro \
    --log-driver    json-file \
    --log-opt       max-size=100m \
    --log-opt       max-file=3 \
    --restart       no \
    ${ECR_IMAGE}

ExecStop=/usr/bin/docker stop --time 20 video-ingest

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable video-ingest
log "Systemd service video-ingest.service installed and enabled"

# ============================================================================
# SECTION 7: Security Hardening
#
# Minimum hardening for an internet-connected edge device:
#   1. Disable root SSH login — root access must go through sudo from a named user
#   2. UFW firewall — allows SSH only from management VLAN (10.50.1.0/24)
#      Note: full iptables rules are applied by firewall_rules.sh; UFW here
#      provides a persistent baseline that survives reboots before firewall_rules.sh
#      is applied by the configuration management system.
#   3. Automatic security updates — critical patches applied without manual
#      intervention; reduces exposure window for known CVEs.
#   4. Disable unused services — reduce attack surface.
# ============================================================================
log "Section 7: Security hardening"

# Disable root SSH login
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# UFW — allow SSH only from management VLAN, deny everything else
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from 10.50.1.0/24 to any port 22 proto tcp comment "SSH from management VLAN only"
ufw --force enable
log "UFW enabled: SSH restricted to management VLAN (10.50.1.0/24)"

# Unattended security upgrades
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable unattended-upgrades
log "Automatic security updates enabled"

# Disable services not needed on an edge device
systemctl disable --now apport 2>/dev/null || true   # crash reporter — not needed in production
systemctl disable --now avahi-daemon 2>/dev/null || true  # mDNS — cameras use ONVIF/RTSP, not mDNS

log "Edge device setup complete for site: $SITE_ID"
