# Golden Image Strategy — Edge Devices

## Overview

We maintain a single **golden OS image** (Ubuntu 22.04 LTS) that is built once
and deployed identically to every edge device across all customer sites. The
image bakes in all OS-level dependencies, drivers, Docker, and the video-ingest
container image. Per-site configuration (SITE_ID, network settings, camera
IPs, VPN credentials) is injected at first boot via cloud-init or a
site-specific config package — never embedded in the image itself.

This approach gives us:
- **Reproducibility** — every site runs the same tested software stack.
- **Fast provisioning** — a new device is production-ready in ~20 minutes
  (image flash + first-boot config) rather than hours of manual `setup.sh` runs.
- **Auditability** — image version is a single version number that maps to an
  exact software bill of materials (SBOM).

---

## Base Image

### What goes INTO the golden image

| Layer | Contents |
|---|---|
| OS | Ubuntu 22.04 LTS, all security patches as of build date |
| Kernel | Locked to a tested LTS kernel version (`linux-image-5.15.0-x-generic`) |
| GPU drivers | NVIDIA driver 535 + nvidia-container-toolkit |
| Container runtime | Docker CE (specific version pinned) |
| System tools | chrony, logrotate, ufw, curl, jq, awscli, unattended-upgrades |
| Docker daemon config | `/etc/docker/daemon.json` (nvidia runtime, log rotation, overlay2) |
| Systemd units | `video-ingest.service` (disabled at image build; enabled at first boot) |
| Firewall baseline | UFW rules + `firewall_rules.sh` (applied at first boot) |
| Container image | `video-ingest:VERSION` pre-pulled and stored in Docker layer cache |

### What does NOT go into the golden image

| Item | Why excluded | Where it lives instead |
|---|---|---|
| `SITE_ID` | Unique per site | cloud-init `user-data` or `/etc/video-ingest/site.env` |
| VPN credentials | Secret; must not be in a shareable image | AWS Secrets Manager, pulled at first boot |
| Camera IPs / RTSP URLs | Site-specific | `/etc/video-ingest/cameras.json`, pushed by config management |
| Network config (IPs, VLAN) | Site-specific | Netplan config, applied by provisioning automation |
| AWS account IDs | Environment-specific | Injected via IAM instance profile / IRSA |

---

## Image Creation Process

Images are built in CI (GitHub Actions) on a schedule (weekly + on-demand)
and stored in S3. The pipeline is:

```
1. BASE BUILD
   - Start from official Ubuntu 22.04 cloud image (minimal, cloud-optimised)
   - Apply all OS security patches (apt-get upgrade)
   - Install and pin versions for: Docker CE, NVIDIA driver 535,
     nvidia-container-toolkit, chrony, logrotate, ufw, awscli
   - Write /etc/docker/daemon.json
   - Install video-ingest.service unit (disabled)
   - Pre-pull the video-ingest container image into Docker layer cache
   - Run CIS Ubuntu 22.04 benchmark hardening script
   - Install cloud-init for first-boot configuration

2. VALIDATION (automated in CI)
   - Boot the image in a VM (QEMU)
   - Run smoke tests:
       * Docker daemon starts cleanly
       * nvidia-smi reports the GPU (via pass-through or mock)
       * NTP sync completes within 60s
       * video-ingest container starts and passes /health/live
   - Run healthcheck.sh and assert exit 0

3. SIGN AND PUBLISH
   - Generate SHA-256 checksum of the image
   - Sign the checksum with GPG (release key)
   - Upload to S3: s3://vlt-edge-images/golden/YYYY-MM-DD-<git-sha>.img.gz
   - Tag the image with version metadata (build date, git SHA, package versions)
   - Update s3://vlt-edge-images/golden/latest.json to point to new image

4. PROMOTION
   - Deploy to 1 canary site first; monitor healthcheck.sh output for 24h
   - Promote to remaining sites in rolling batches of 10%
```

---

## Configuration Management

Per-site config is separated from the image to allow the same image to run at
any site without rebuilding.

**At first boot (cloud-init):**
```yaml
# /etc/cloud/cloud.d/site-config.yaml (injected by provisioning system)
write_files:
  - path: /etc/video-ingest/site.env
    content: |
      SITE_ID=SITE-2847
      IMAGE_TAG=v1.4.2
      NTP_SERVER=10.50.1.10
  - path: /etc/video-ingest/cameras.json
    content: |
      [{"id":"CAM-001","ip":"10.50.20.101","rtsp_path":"/axis-media/media.amp"}]

runcmd:
  - systemctl enable video-ingest
  - bash /usr/local/bin/firewall_rules.sh
  - systemctl start video-ingest
```

**Ongoing config changes** (without re-imaging):
- Config changes that don't require a new OS image (e.g. adding a camera,
  changing log level) are pushed via Ansible or AWS Systems Manager (SSM)
  Run Command to the target site's edge device.
- Changes that require a new binary (new container image version) are handled
  by updating `IMAGE_TAG` in `/etc/video-ingest/site.env` and restarting the
  systemd service — the `ExecStartPre` pull step in `video-ingest.service`
  fetches the new image from ECR.

---

## Patching and Updates

**OS security patches:**
`unattended-upgrades` (configured in `setup.sh`) applies security-only patches
automatically. Only the `*-security` pocket is enabled — no automatic
dist-upgrades that could change kernel or driver versions unexpectedly.

**Kernel and driver updates:**
Treated as a new golden image build. A kernel or driver update is integrated
into the image pipeline, validated against the smoke tests, and rolled out as
a full image update (see below).

**Container image updates (video-ingest):**
1. New container image is pushed to ECR and tagged (e.g. `v1.4.3`).
2. SSM Run Command updates `IMAGE_TAG` in `/etc/video-ingest/site.env`.
3. `systemctl restart video-ingest` pulls the new image and starts it.
4. `healthcheck.sh` is polled for 5 minutes; if it returns non-zero, the
   previous tag is restored automatically.

**Full OS image updates** (kernel, driver, major dependency):
Roll out via the canary promotion process described in Image Creation Process.
Devices are re-imaged using a PXE boot server or USB/BMC remote media —
the BIOS is pre-configured to boot from network on first POST if a new image
is signaled by the provisioning system.

---

## Rollback

| Scenario | Rollback method | Time to recover |
|---|---|---|
| Bad container image | Restore previous `IMAGE_TAG` in site.env + `systemctl restart video-ingest` | < 2 minutes |
| Bad config push | Re-push previous config via SSM; restart service | < 5 minutes |
| Bad OS image (caught in canary) | Stop rollout; canary site re-images from previous version in S3 | ~20 minutes |
| Bad OS image (caught post-rollout) | SSM Run Command triggers re-image from last known-good image in S3 | ~20 minutes per site |

**Key principle:** the previous golden image is always retained in S3 for a
minimum of 90 days. `latest.json` points to the current version; rolling back
means updating `latest.json` to point to the previous entry — the same
promotion pipeline runs in reverse.

Device state (video buffer, local DB) is separate from the OS image on a
dedicated data partition (`/data`). Re-imaging wipes only the OS partition;
locally buffered video chunks survive the rollback and are uploaded once the
device is healthy again.
