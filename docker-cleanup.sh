#!/bin/bash

# ==============================================================================
# Docker Automatic Cleanup
#
# Maintainer: Inova e-Business
# Created: 2026-08-20
# Version: 1.1
#
# Purpose:
#   Prevent excessive Docker disk consumption caused by CI/CD builds and
#   accumulated Docker images, containers and build cache.
#
# Supported platforms:
#   - Linux   : Docker Engine / Docker CE on any distribution
#   - macOS   : Docker Desktop
#   - Windows : Docker Desktop via Git Bash / MSYS2 / WSL
#
# Cleanup policy:
#   - Remove stopped containers
#   - Remove unused Docker networks
#   - Remove unused Docker images
#   - Remove Docker build cache
#   - NEVER remove Docker volumes automatically
#
# Notes:
#   - Uses a portable mkdir-based lock (works on Linux, macOS and Windows).
#   - Requires the Docker CLI in PATH. The daemon does not need to run under
#     root on macOS/Windows (Docker Desktop handles permissions).
#
# Managed by:
#   Inova e-Business
# ==============================================================================

set -uo pipefail

TAG="docker-cleanup"
VERSION="1.1"

OS_TYPE="$(uname -s 2>/dev/null || echo unknown)"
case "$OS_TYPE" in
    Darwin)
        OS_NAME="macOS"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        OS_NAME="Windows"
        ;;
    Linux)
        OS_NAME="Linux"
        ;;
    *)
        OS_NAME="$OS_TYPE"
        ;;
esac

log() {
    local line
    line="$(date +"%Y-%m-%dT%H:%M:%S%z") $1"
    if [ "$OS_NAME" != "Windows" ] && command -v logger >/dev/null 2>&1; then
        logger -t "$TAG" "$1" 2>/dev/null || true
    fi
    printf '%s\n' "$line"
}

TTY=0
[ -t 1 ] && TTY=1
SPIN_FRAMES=('|' '/' '-' '\')
if [[ "$(locale charmap 2>/dev/null)" == *"UTF"* ]]; then
    SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
fi

_spin() {
    local pid="$1" label="$2" i=0 n=${#SPIN_FRAMES[@]}
    [ "$TTY" = 1 ] || return
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  \033[1;36m%s\033[0m %s   ' "${SPIN_FRAMES[$i]}" "$label"
        i=$(( (i + 1) % n ))
        sleep 0.08
    done
    printf '\r\033[K'
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker CLI not found. Install Docker (Desktop) for your OS and retry."
    exit 1
fi

# Portable lock (mkdir is atomic on Linux, macOS and Windows/NTFS)
LOCK_DIR="${TMPDIR:-/tmp}/docker-cleanup.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$(date +"%Y-%m-%dT%H:%M:%S%z") Cleanup skipped: another cleanup process is already running."
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

log "============================================================"
log "Docker cleanup started. Version=$VERSION Maintainer=Inova e-Business"

if ! docker info >/dev/null 2>&1; then
    log "WARNING: Docker daemon does not appear to be running. Docker commands may fail."
fi

DISK_BEFORE=$(df -h / 2>/dev/null | tail -1)
log "Disk before cleanup: $DISK_BEFORE"

log "Docker disk usage before cleanup:"
docker system df 2>&1

log "Executing: docker system prune -af"
if [ "$TTY" = 1 ]; then
    docker system prune -af > "${TMPDIR:-/tmp}/docker-cleanup-prune.log" 2>&1 &
    PRUNE_PID=$!
    _spin "$PRUNE_PID" "Cleaning Docker resources ..."
    wait "$PRUNE_PID"
    cat "${TMPDIR:-/tmp}/docker-cleanup-prune.log"
    rm -f "${TMPDIR:-/tmp}/docker-cleanup-prune.log"
else
    docker system prune -af
fi
EXIT_CODE=$?

log "Docker disk usage after cleanup:"
docker system df 2>&1

DISK_AFTER=$(df -h / 2>/dev/null | tail -1)
log "Disk after cleanup: $DISK_AFTER"

if [ "$EXIT_CODE" -eq 0 ]; then
    log "Docker cleanup completed successfully."
else
    log "ERROR: Docker cleanup finished with exit code $EXIT_CODE."
fi

log "Docker volumes were intentionally preserved."
log "============================================================"

exit "$EXIT_CODE"