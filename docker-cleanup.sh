#!/bin/bash

# ==============================================================================
# Docker Automatic Cleanup
#
# Maintainer: Inova e-Business
# Created: 2026-08-20
# Version: 1.0
#
# Purpose:
#   Prevent excessive Docker disk consumption on this EC2 instance caused by
#   CI/CD builds and accumulated Docker images, containers and build cache.
#
# Background:
#   In August 2026, Docker storage reached a high utilization level, with
#   significant growth under /var/lib/docker/overlay2 and a large amount of
#   reclaimable build data. This condition was identified as a potential cause
#   of disk I/O degradation and instance instability.
#
# Cleanup policy:
#   - Remove stopped containers
#   - Remove unused Docker networks
#   - Remove unused Docker images
#   - Remove Docker build cache
#   - NEVER remove Docker volumes automatically
#
# Managed by:
#   Inova e-Business
# ==============================================================================

set -uo pipefail

TAG="docker-cleanup"
VERSION="1.0"

log() {
    logger -t "$TAG" "$1"
    echo "$(date -Is) $1"
}

exec 9>/run/docker-cleanup.lock

if ! flock -n 9; then
    log "Cleanup skipped: another cleanup process is already running."
    exit 0
fi

log "============================================================"
log "Docker cleanup started. Version=$VERSION Maintainer=Inova e-Business"

DISK_BEFORE=$(df -h / | tail -1)
log "Disk before cleanup: $DISK_BEFORE"

log "Docker disk usage before cleanup:"
docker system df 2>&1

log "Executing: docker system prune -af"
docker system prune -af
EXIT_CODE=$?

log "Docker disk usage after cleanup:"
docker system df 2>&1

DISK_AFTER=$(df -h / | tail -1)
log "Disk after cleanup: $DISK_AFTER"

if [ "$EXIT_CODE" -eq 0 ]; then
    log "Docker cleanup completed successfully."
else
    log "ERROR: Docker cleanup finished with exit code $EXIT_CODE."
fi

log "Docker volumes were intentionally preserved."
log "============================================================"

exit "$EXIT_CODE"
