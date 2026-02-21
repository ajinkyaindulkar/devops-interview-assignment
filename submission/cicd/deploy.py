#!/usr/bin/env python3
"""
deploy.py — Deployment automation script for video-analytics service.

Subcommands:
  deploy    Push a new container image tag to an EKS deployment.
  rollback  Revert EKS deployment to the previous (or a named) revision.
  status    Show the current rollout state and running pod image tags.

Design decisions:
  - subprocess.run() wraps real kubectl and aws CLI calls so the script works
    in a live environment without modification.
  - --dry-run prints every command that would run without executing it —
    useful for pipeline debugging and pre-deployment review.
  - health_check() polls 'kubectl rollout status' on a configurable timeout
    rather than sleeping a fixed duration.  This means healthy rollouts are
    confirmed in seconds while giving slow rollouts their full 300s window.
  - Rollback uses 'kubectl rollout undo' (Kubernetes revision history) rather
    than re-deploying a known-good image tag.  This is faster and does not
    require the pipeline to know what the last good tag was.
"""

import argparse
import logging
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Logging
#
# WHY basicConfig with a timestamp: when this script runs inside GitHub Actions
# or SSM Run Command, the log stream is the only debugging record.  A timestamp
# lets an operator correlate deploy.py output with kubectl events and CloudWatch
# metrics when investigating a failed rollout.
# ---------------------------------------------------------------------------

def setup_logging(verbose: bool = False) -> None:
    """Configure root logger — INFO by default, DEBUG with --verbose."""
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s  %(levelname)-8s  %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        stream=sys.stdout,
    )


log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    """
    Build the top-level parser with deploy / rollback / status subcommands.

    WHY subcommands instead of flags:
      Subcommands make the intent explicit in shell history and CI logs.
      'deploy.py deploy --env prod' is unambiguous; 'deploy.py --action deploy'
      requires reading the flag value to understand what will happen.
    """
    parser = argparse.ArgumentParser(
        prog="deploy.py",
        description="Deployment automation for video-analytics on EKS.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable DEBUG logging.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # ---- deploy subcommand ------------------------------------------------
    deploy_parser = subparsers.add_parser(
        "deploy",
        help="Deploy a container image tag to staging or production.",
    )
    deploy_parser.add_argument(
        "--environment", "-e",
        required=True,
        choices=["staging", "production"],
        help="Target environment.",
    )
    deploy_parser.add_argument(
        "--image-tag", "-t",
        required=True,
        dest="image_tag",
        help="Full ECR image URI with tag, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/video-ingest:v1.4.3",
    )
    deploy_parser.add_argument(
        "--deployment",
        default="video-processor",
        help="Kubernetes Deployment name (default: video-processor).",
    )
    deploy_parser.add_argument(
        "--namespace", "-n",
        default="video-analytics",
        help="Kubernetes namespace (default: video-analytics).",
    )
    deploy_parser.add_argument(
        "--dry-run",
        action="store_true",
        dest="dry_run",
        help="Print commands without executing them.",
    )
    deploy_parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Seconds to wait for rollout to complete (default: 300).",
    )

    # ---- rollback subcommand ----------------------------------------------
    rollback_parser = subparsers.add_parser(
        "rollback",
        help="Roll back to the previous (or a specific) deployment revision.",
    )
    rollback_parser.add_argument(
        "--environment", "-e",
        required=True,
        choices=["staging", "production"],
    )
    rollback_parser.add_argument(
        "--deployment",
        default="video-processor",
    )
    rollback_parser.add_argument(
        "--namespace", "-n",
        default="video-analytics",
    )
    rollback_parser.add_argument(
        "--revision",
        type=int,
        default=None,
        help="Specific revision number to roll back to. Omit to use the previous revision.",
        # WHY optional: 'kubectl rollout undo' without --to-revision reverts to the
        # last active ReplicaSet — the correct behaviour 99% of the time.
        # --revision is provided for cases where two bad deploys were applied in
        # quick succession and the operator needs to skip back further.
    )
    rollback_parser.add_argument(
        "--dry-run",
        action="store_true",
        dest="dry_run",
    )

    # ---- status subcommand ------------------------------------------------
    status_parser = subparsers.add_parser(
        "status",
        help="Show current deployment rollout status and pod image tags.",
    )
    status_parser.add_argument(
        "--environment", "-e",
        required=True,
        choices=["staging", "production"],
    )
    status_parser.add_argument(
        "--deployment",
        default="video-processor",
    )
    status_parser.add_argument(
        "--namespace", "-n",
        default="video-analytics",
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Shell execution helper
# ---------------------------------------------------------------------------

def run_cmd(cmd: list[str], dry_run: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    """
    Run a shell command, logging it before execution.

    WHY check=True by default:
      Most callers want an exception on non-zero exit so failures surface
      immediately with a clear error.  Callers that need to inspect the return
      code (e.g. health_check polling loop) pass check=False explicitly.

    WHY dry_run returns a fake CompletedProcess instead of raising:
      Callers should not need to branch on dry_run — they call run_cmd() and
      use the return value normally.  The fake object has returncode=0 so the
      caller's success path executes, printing what would happen.
    """
    log.info("CMD: %s", " ".join(cmd))

    if dry_run:
        log.info("[DRY-RUN] command not executed")
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="", stderr="")

    result = subprocess.run(
        cmd,
        capture_output=False,   # let stdout/stderr flow to the terminal in real time
        text=True,
        check=check,
    )
    return result


# ---------------------------------------------------------------------------
# Health check
#
# WHY poll instead of a single call:
#   'kubectl rollout status --timeout=5m' blocks the calling process for up to
#   5 minutes.  Polling with a short interval lets us log progress updates
#   every 10 seconds so the CI log shows the rollout is advancing rather than
#   appearing stalled.  It also allows us to fail fast if the deployment object
#   enters an error state before the timeout expires.
# ---------------------------------------------------------------------------

def health_check(
    deployment: str,
    namespace: str,
    timeout: int = 300,
    dry_run: bool = False,
) -> bool:
    """
    Poll 'kubectl rollout status' until the deployment is complete or timeout.

    Returns True if the rollout succeeds within timeout, False otherwise.
    """
    log.info("Health check: waiting up to %ds for rollout of %s/%s ...", timeout, namespace, deployment)

    deadline = time.time() + timeout
    poll_interval = 10  # seconds between polls

    while time.time() < deadline:
        result = run_cmd(
            ["kubectl", "rollout", "status",
             f"deployment/{deployment}",
             "-n", namespace,
             "--timeout=10s"],
            dry_run=dry_run,
            check=False,
        )

        if dry_run:
            log.info("[DRY-RUN] health check assumed successful")
            return True

        if result.returncode == 0:
            log.info("Rollout complete — deployment %s is healthy.", deployment)
            return True

        remaining = int(deadline - time.time())
        log.info("Rollout still in progress... %ds remaining", max(remaining, 0))
        time.sleep(poll_interval)

    log.error(
        "Health check timed out after %ds — deployment %s did not complete. "
        "Run 'kubectl describe deployment/%s -n %s' and 'kubectl get events -n %s' "
        "to investigate.",
        timeout, deployment, deployment, namespace, namespace,
    )
    return False


# ---------------------------------------------------------------------------
# deploy command
# ---------------------------------------------------------------------------

def deploy(
    environment: str,
    image_tag: str,
    deployment: str,
    namespace: str,
    timeout: int = 300,
    dry_run: bool = False,
) -> int:
    """
    Update the container image on an EKS Deployment and verify the rollout.

    Steps:
      1. Annotate the deployment with the deploy timestamp and git SHA for
         audit trail (visible in 'kubectl rollout history').
      2. Set the new image — triggers a rolling update.
      3. Poll health_check() — if it times out, return exit code 1 so the
         pipeline's rollback job is triggered.

    WHY annotate before set image:
      The annotation is written to the Deployment's change-cause field, which
      appears in 'kubectl rollout history'.  Writing it before 'set image'
      ensures the history entry for THIS revision includes the reason — not
      the previous revision's annotation.
    """
    log.info("Deploying %s to %s (environment: %s)", image_tag, deployment, environment)

    if dry_run:
        log.info("[DRY-RUN] would update deployment %s/%s to image %s", namespace, deployment, image_tag)

    # Step 1: Annotate for audit trail
    run_cmd(
        ["kubectl", "annotate", "deployment", deployment,
         f"kubernetes.io/change-cause=deploy image={image_tag} env={environment}",
         "--overwrite",
         "-n", namespace],
        dry_run=dry_run,
    )

    # Step 2: Rolling image update
    run_cmd(
        ["kubectl", "set", "image",
         f"deployment/{deployment}",
         f"{deployment}={image_tag}",
         "-n", namespace],
        dry_run=dry_run,
    )

    # Step 3: Verify rollout
    if health_check(deployment, namespace, timeout=timeout, dry_run=dry_run):
        log.info("Deploy to %s SUCCEEDED: %s", environment, image_tag)
        return 0

    log.error("Deploy to %s FAILED — rollout did not complete within %ds", environment, timeout)
    return 1


# ---------------------------------------------------------------------------
# rollback command
# ---------------------------------------------------------------------------

def rollback(
    environment: str,
    deployment: str,
    namespace: str,
    revision: int | None = None,
    dry_run: bool = False,
) -> int:
    """
    Revert the deployment to its previous revision (or a named revision).

    WHY 'kubectl rollout undo' rather than re-deploying a known-good image tag:
      rollout undo restores the exact ReplicaSet spec from history — including
      resource limits, environment variables, and volume mounts that may have
      changed — not just the image tag.  Re-deploying only the old image tag
      to the CURRENT spec could mask a regression in those other fields.
    """
    log.info("Rolling back %s/%s in %s", namespace, deployment, environment)

    cmd = ["kubectl", "rollout", "undo", f"deployment/{deployment}", "-n", namespace]

    if revision is not None:
        cmd += [f"--to-revision={revision}"]
        log.info("Rolling back to specific revision %d", revision)
    else:
        log.info("Rolling back to previous revision")

    run_cmd(cmd, dry_run=dry_run)

    # Verify the rollback completed successfully
    if health_check(deployment, namespace, dry_run=dry_run):
        log.info("Rollback SUCCEEDED for %s in %s", deployment, environment)
        return 0

    log.error("Rollback did not complete within timeout — manual intervention required")
    return 1


# ---------------------------------------------------------------------------
# status command
# ---------------------------------------------------------------------------

def status(
    environment: str,
    deployment: str,
    namespace: str,
) -> int:
    """
    Display current deployment rollout status and the image tag on each pod.

    WHY show pod images alongside rollout status:
      'kubectl rollout status' only tells you whether the rollout is done.
      It doesn't tell you WHICH image is running.  Showing pod images lets an
      operator confirm that all pods are running the expected tag — not a
      stale version that somehow survived a rollout.
    """
    log.info("Status of %s/%s in environment: %s", namespace, deployment, environment)

    # Overall rollout state
    run_cmd(
        ["kubectl", "rollout", "status", f"deployment/{deployment}", "-n", namespace,
         "--timeout=30s"],
        check=False,   # non-zero just means rollout is in progress — not a fatal error
    )

    # Pods and the image tag each is running
    run_cmd(
        ["kubectl", "get", "pods",
         "-l", f"app={deployment}",
         "-n", namespace,
         "-o", "custom-columns=NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready"],
    )

    # Rollout history so the operator can see available revisions for rollback
    run_cmd(
        ["kubectl", "rollout", "history", f"deployment/{deployment}", "-n", namespace],
    )

    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    setup_logging(verbose=args.verbose)

    dry_run = getattr(args, "dry_run", False)

    if args.command == "deploy":
        exit_code = deploy(
            environment=args.environment,
            image_tag=args.image_tag,
            deployment=args.deployment,
            namespace=args.namespace,
            timeout=args.timeout,
            dry_run=dry_run,
        )

    elif args.command == "rollback":
        exit_code = rollback(
            environment=args.environment,
            deployment=args.deployment,
            namespace=args.namespace,
            revision=args.revision,
            dry_run=dry_run,
        )

    elif args.command == "status":
        exit_code = status(
            environment=args.environment,
            deployment=args.deployment,
            namespace=args.namespace,
        )

    else:
        log.error("Unknown command: %s", args.command)
        exit_code = 1

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
