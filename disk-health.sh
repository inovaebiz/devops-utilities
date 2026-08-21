#!/bin/bash

# ==============================================================================
# Disk Health & Log Cleanup
#
# Maintainer: Inova e-Business
# Version: 1.0
#
# Purpose:
#   Diagnose disk pressure, inode exhaustion and log growth, then offer
#   safe, reversible cleanups for journal, system logs and temporary files.
#
# Supported platforms:
#   - Linux   : df, du, find, journalctl, /var/log, /tmp, /var/tmp, Docker
#   - macOS   : df, du, find, /var/log, /private/tmp (/tmp), Docker Desktop
#   - Windows : df, du, find via Git Bash / MSYS2 / WSL; %TEMP% and /tmp
#
# Behavior:
#   - Without flags: diagnose, summarize, then confirm each cleanup.
#   - With -y / --yes: diagnose, then apply all safe cleanups without asking.
#   - With -c / --check-only: only diagnose and print, never change anything.
#
# Safe cleanups (only with confirmation or --yes):
#   - Vacuum systemd journal to a cap (default 500M, Linux only)
#   - Remove compressed/rotated logs older than 30 days in /var/log
#   - Truncate oversized active logs (>100M) after backup
#   - Remove files in temp dirs older than 10 days
#   - Report Docker disk usage (delegates heavy cleanup to docker-cleanup.sh)
#
# Notes:
#   - Never deletes Docker volumes, databases or user data.
#   - All destructive actions are logged and ask for confirmation.
#   - Run elevated for full visibility (some dirs require root).
#
# ==============================================================================

set -uo pipefail

VERSION="1.0"
TAG="disk-health"

ASSUME_YES=0
CHECK_ONLY=0
JOURNAL_CAP="500M"
TMP_DAYS=10

log()  { printf '%s\n' "$*"; }
info() { printf '  \033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '  \033[1;31m[ERR]\033[0m  %s\n' "$*"; }

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

run_spinner() {
    local label="$1"; shift
    local out
    if [ "$TTY" = 1 ]; then
        out="$("$@" 2>&1)" &
        local pid=$!
        _spin "$pid" "$label"
        wait "$pid"
    else
        out="$("$@" 2>&1)"
    fi
    printf '%s\n' "$out"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -y, --yes              Apply all safe cleanups without asking.
  -c, --check-only       Only diagnose and print (no changes).
      --journal-cap SIZE Cap for journal vacuum (default: 500M, e.g. 1G).
      --tmp-days N       Age in days for temp files to remove (default: 10).
  -h, --help             Show this help.

Examples:
  $0                     Diagnose and confirm each cleanup.
  $0 --yes               Diagnose and apply everything automatically.
  $0 --check-only        Just show disk health.
  $0 --journal-cap 1G    Vacuum journal to 1G.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)           ASSUME_YES=1; shift ;;
        -c|--check-only)    CHECK_ONLY=1; shift ;;
        --journal-cap)      JOURNAL_CAP="${2:-500M}"; shift 2 ;;
        --journal-cap=*)    JOURNAL_CAP="${1#*=}"; shift ;;
        --tmp-days)         TMP_DAYS="${2:-10}"; shift 2 ;;
        --tmp-days=*)       TMP_DAYS="${1#*=}"; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Platform detection
# -----------------------------------------------------------------------------
OS_TYPE="$(uname -s 2>/dev/null || echo unknown)"
case "$OS_TYPE" in
    Darwin)       OS_NAME="macOS" ;;
    MINGW*|MSYS*|CYGWIN*) OS_NAME="Windows" ;;
    Linux)        OS_NAME="Linux" ;;
    *)            OS_NAME="$OS_TYPE" ;;
esac

ask() {
    if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
    local answer
    printf '  \033[1;36m[?]\033[0m %s [y/N] ' "$1"
    read -r answer
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
OS_PRETTY="$(uname -srm 2>/dev/null)"
HOSTNAME="$(hostname 2>/dev/null || uname -n)"
printf '\n'
printf '  %s\n' '============================================================'
printf '  %s\n' '  DISK HEALTH & LOG CLEANUP'
printf '  %s\n' '  Maintainer: Inova e-Business'
printf '  %s\n' "  Version: $VERSION"
printf '  %s\n' '============================================================'
printf '\n'
log "  Platform : $OS_NAME ($OS_PRETTY)"
log "  Hostname : $HOSTNAME"
log "  Mode     : $([ "$CHECK_ONLY" = 1 ] && echo "check-only" || ([ "$ASSUME_YES" = 1 ] && echo "auto (yes)" || echo "interactive"))"
printf '\n'

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
HR_SEP="------------------------------------------------------------"

print_section() {
    printf '\n  %s\n' "$HR_SEP"
    printf '  %s\n' "  $1"
    printf '  %s\n' "$HR_SEP"
    printf '\n'
}

have_journalctl=0
command -v journalctl >/dev/null 2>&1 && have_journalctl=1

have_docker=0
command -v docker >/dev/null 2>&1 && have_docker=1

# Temp dirs per platform
case "$OS_NAME" in
    Windows)
        # Git Bash: $TMP / $TEMP is Windows temp; also /tmp exists as mount
        TMP_DIRS=()
        [ -n "${TMP:-}" ] && [ -d "$TMP" ] && TMP_DIRS+=("$TMP")
        [ -n "${TEMP:-}" ] && [ -d "$TEMP" ] && [ "$TEMP" != "$TMP" ] && TMP_DIRS+=("$TEMP")
        [ -d "/tmp" ] && TMP_DIRS+=("/tmp")
        [ ${#TMP_DIRS[@]} -eq 0 ] && TMP_DIRS=("/tmp")
        ;;
    *)
        TMP_DIRS=("/tmp" "/var/tmp")
        ;;
esac

# Log dirs per platform
case "$OS_NAME" in
    Windows)
        LOG_DIRS=()
        [ -d "/var/log" ] && LOG_DIRS+=("/var/log")
        ;;
    *)
        LOG_DIRS=("/var/log")
        ;;
esac

PENDING_COUNT=0
PENDING_DESCS=()

add_pending() {
    PENDING_COUNT=$(( PENDING_COUNT + 1 ))
    PENDING_DESCS+=("$1")
}

# =============================================================================
# 1. DISK OVERVIEW
# =============================================================================
print_section "1. Disk overview"

info "Filesystem usage (df -h):"
df -h 2>/dev/null | sed 's/^/    /'
printf '\n'

if df -i / >/dev/null 2>&1; then
    info "Inode usage (df -i):"
    df -i 2>/dev/null | sed 's/^/    /'
    printf '\n'
    # Check inode pressure (>80%)
    INODE_WARN="$(df -i / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print ($5+0>=80)}')"
    if [ "$INODE_WARN" = "1" ]; then
        warn "Inode usage >= 80% on / — check many small files."
        add_pending "Inode pressure on /"
    else
        ok "Inode usage looks healthy."
    fi
    printf '\n'
fi

# Warn on any FS >80%
HIGH_FS="$(df -h 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); if ($5+0>=80) print $0}')"
if [ -n "$HIGH_FS" ]; then
    warn "Filesystems above 80% usage:"
    printf '%s\n' "$HIGH_FS" | sed 's/^/    /'
    add_pending "Filesystem(s) above 80%"
else
    ok "No filesystem above 80% usage."
fi

# =============================================================================
# 2. LARGEST DIRECTORIES & FILES
# =============================================================================
print_section "2. Largest directories & files"

info "Top directories by size (du -sh, up to 8):"
# Pick sensible roots per platform
case "$OS_NAME" in
    Windows)
        DU_ROOTS=()
        for d in "${TMP_DIRS[@]}" "/var/log" "/c/Windows/Temp"; do
            [ -d "$d" ] && DU_ROOTS+=("$d")
        done
        ;;
    macOS)
        DU_ROOTS=("/var/log" "/private/tmp" "/usr/local")
        ;;
    *)
        DU_ROOTS=("/var/log" "/var/tmp" "/tmp" "/var/lib/docker")
        ;;
esac
for d in "${DU_ROOTS[@]}"; do
    [ -d "$d" ] || continue
    du -sh "$d" 2>/dev/null | sed 's/^/    /'
done
printf '\n'

info "Largest files (>100M) — top 15 (scanned: ${DU_ROOTS[*]}):"
# For the heavy scan, exclude $HOME (too large/slow) — use log/tmp/docker roots only
LARGE_FIND_ROOTS=()
for d in "${DU_ROOTS[@]}"; do
    [ "$d" = "$HOME" ] && continue
    [ -d "$d" ] && LARGE_FIND_ROOTS+=("$d")
done
[ ${#LARGE_FIND_ROOTS[@]} -eq 0 ] && LARGE_FIND_ROOTS=("${DU_ROOTS[@]}")
if [ ${#LARGE_FIND_ROOTS[@]} -gt 0 ]; then
    find "${LARGE_FIND_ROOTS[@]}" -type f -size +100M 2>/dev/null | head -n 15 | while IFS= read -r f; do ls -lh "$f" 2>/dev/null | sed 's/^/    /'; done
fi
if ! find "${LARGE_FIND_ROOTS[@]}" -type f -size +100M 2>/dev/null | head -n1 | grep -q . 2>/dev/null; then
    ok "No files >100M found in scanned roots."
fi

# =============================================================================
# 3. SYSTEMD JOURNAL (Linux)
# =============================================================================
print_section "3. System journal"

if [ "$have_journalctl" -eq 1 ]; then
    info "Journal disk usage:"
    journalctl --disk-usage 2>/dev/null | sed 's/^/    /'
    JOURNAL_SIZE="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]')"
    # Parse size roughly: if > JOURNAL_CAP we have pending
    # Simple heuristic: if journal reports >500M (when cap is 500M), suggest vacuum
    if journalctl --disk-usage 2>/dev/null | grep -qE '[0-9]+G|[0-9]{3,}M'; then
        warn "Journal is large — vacuum to ${JOURNAL_CAP} can reclaim space."
        add_pending "Journal vacuum to ${JOURNAL_CAP} (journalctl --vacuum-size=${JOURNAL_CAP})"
    else
        ok "Journal size looks contained."
    fi
else
    case "$OS_NAME" in
        macOS)   info "No journalctl on macOS (uses unified log). Skipped." ;;
        Windows) info "No journalctl on Windows. Skipped." ;;
        *)       info "journalctl not found. Skipped." ;;
    esac
fi

# =============================================================================
# 4. SYSTEM LOGS
# =============================================================================
print_section "4. System logs"

LOG_FOUND=0
for ld in "${LOG_DIRS[@]}"; do
    [ -d "$ld" ] || continue
    info "Logs in ${ld} (top 10 by size):"
    find "$ld" -type f -exec ls -lh {} \; 2>/dev/null | awk '{print $5, $9}' | sort -hr | head -n 10 | sed 's/^/    /'
    info "Rotated/compressed logs older than 30 days in ${ld}:"
    OLD_LOGS="$(find "$ld" -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -mtime +30 2>/dev/null | head -n 20 || true)"
    if [ -n "$OLD_LOGS" ]; then
        printf '%s\n' "$OLD_LOGS" | sed 's/^/    /'
        ROTATED_COUNT="$(printf '%s\n' "$OLD_LOGS" | grep -c . || true)"
        warn "$ROTATED_COUNT rotated log(s) older than 30 days can be removed."
        add_pending "Remove ${ROTATED_COUNT} rotated log(s) older than 30 days in ${ld}"
    else
        ok "No rotated logs older than 30 days in ${ld}."
    fi
    # Oversized active logs (>100M)
    LARGE_LOGS="$(find "$ld" -type f -size +100M 2>/dev/null | head -n 10 || true)"
    if [ -n "$LARGE_LOGS" ]; then
        warn "Active log(s) >100M in ${ld} (consider truncation/rotation):"
        printf '%s\n' "$LARGE_LOGS" | while IFS= read -r f; do ls -lh "$f" 2>/dev/null | sed 's/^/    /'; done
        add_pending "Oversized log(s) >100M in ${ld} — truncate after backup"
    fi
    LOG_FOUND=1
done
[ "$LOG_FOUND" -eq 0 ] && info "No standard log dir found on this platform."

# =============================================================================
# 5. TEMPORARY FILES
# =============================================================================
print_section "5. Temporary files"

for td in "${TMP_DIRS[@]}"; do
    [ -d "$td" ] || continue
    info "Temp dir: ${td}"
    if [ -r "$td" ]; then
        TOTAL_TMP="$(find "$td" -type f 2>/dev/null | wc -l | tr -d ' ')"
        OLD_TMP="$(find "$td" -type f -mtime +"$TMP_DAYS" 2>/dev/null | wc -l | tr -d ' ')"
        SIZE_TMP="$(du -sh "$td" 2>/dev/null | awk '{print $1}')"
        printf '    %s files, %s older than %s days, size %s\n' "$TOTAL_TMP" "$OLD_TMP" "$TMP_DAYS" "${SIZE_TMP:-n/a}"
        if [ "${OLD_TMP:-0}" -gt 0 ] 2>/dev/null; then
            warn "$OLD_TMP file(s) older than ${TMP_DAYS} days in ${td} can be removed."
            add_pending "Remove ${OLD_TMP} file(s) older than ${TMP_DAYS} days in ${td}"
            find "$td" -type f -mtime +"$TMP_DAYS" 2>/dev/null | head -n 10 | sed 's/^/    /'
            [ "$OLD_TMP" -gt 10 ] && printf '    ... and %d more\n' $(( OLD_TMP - 10 ))
        else
            ok "No temp file older than ${TMP_DAYS} days in ${td}."
        fi
    else
        warn "Cannot read ${td}."
    fi
done

# =============================================================================
# 6. DOCKER (if present)
# =============================================================================
print_section "6. Docker"

if [ "$have_docker" -eq 1 ]; then
    if docker info >/dev/null 2>&1; then
        info "Docker disk usage (docker system df):"
        docker system df 2>&1 | sed 's/^/    /'
        RECLAIMABLE="$(docker system df 2>/dev/null | grep -i reclaimable | head -n1 || true)"
        if printf '%s\n' "$RECLAIMABLE" | grep -qE '[1-9][0-9]*\.?[0-9]*[KMGT]B.*reclaimable'; then
            warn "Docker has reclaimable space — run docker-cleanup.sh for a safe prune (volumes preserved)."
            add_pending "Docker reclaimable space — run docker-cleanup.sh"
        fi
    else
        warn "Docker CLI found but daemon not running — skipping docker df."
    fi
else
    info "Docker not installed — skipping."
fi

# =============================================================================
# SUMMARY
# =============================================================================
printf '\n'
printf '  %s\n' '------------------------------------------------------------'
printf '  %s\n' '  SUMMARY'
printf '  %s\n' '------------------------------------------------------------'
printf '\n'

if [ "$PENDING_COUNT" -gt 0 ]; then
    warn "$PENDING_COUNT cleanup action(s) available:"
    for d in "${PENDING_DESCS[@]}"; do
        printf '    • %s\n' "$d"
    done
else
    ok "Disk health looks good — no cleanup needed."
fi

printf '\n'
printf '  %s\n' '------------------------------------------------------------'

# -----------------------------------------------------------------------------
# Check-only mode
# -----------------------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '\n'
    ok "Check-only mode. No changes were made."
    exit 0
fi

if [ "$PENDING_COUNT" -eq 0 ]; then
    printf '\n'
    ok "Nothing to clean. Exiting."
    exit 0
fi

# -----------------------------------------------------------------------------
# Acceptance
# -----------------------------------------------------------------------------
printf '\n'
if [ "$ASSUME_YES" -eq 1 ]; then
    info "Running in --yes mode. Applying all safe cleanups..."
else
    if ask "Proceed with the safe cleanups? (each step will confirm again)"; then
        info "Proceeding."
    else
        warn "Cleanup cancelled by user."
        exit 0
    fi
fi

# =============================================================================
# APPLY CLEANUPS
# =============================================================================

# 3. Journal vacuum
if [ "$have_journalctl" -eq 1 ]; then
    if journalctl --disk-usage 2>/dev/null | grep -qE '[0-9]+G|[0-9]{3,}M'; then
        printf '\n'
        if ask "Vacuum journal to ${JOURNAL_CAP}? (journalctl --vacuum-size=${JOURNAL_CAP})"; then
            run_spinner "Vacuuming journal to ${JOURNAL_CAP} ..." journalctl --vacuum-size="$JOURNAL_CAP" 2>&1 | sed 's/^/    /'
            ok "Journal vacuumed."
        else
            info "Skipped journal vacuum."
        fi
    fi
fi

# 4. Rotated logs older than 30 days
for ld in "${LOG_DIRS[@]}"; do
    [ -d "$ld" ] || continue
    OLD_LOGS="$(find "$ld" -type f \( -name '*.gz' -o -name '*.1' -o -name '*.old' \) -mtime +30 2>/dev/null || true)"
    [ -z "$OLD_LOGS" ] && continue
    COUNT="$(printf '%s\n' "$OLD_LOGS" | grep -c . || true)"
    [ "$COUNT" -eq 0 ] && continue
    printf '\n'
    if ask "Remove ${COUNT} rotated log(s) older than 30 days in ${ld}?"; then
        # shellcheck disable=SC2086
        printf '%s\n' "$OLD_LOGS" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ -w "$f" ] || [ "$(id -u)" -eq 0 ]; then
                rm -f "$f" 2>/dev/null && printf '    removed %s\n' "$f" || warn "Failed to remove $f"
            else
                sudo rm -f "$f" 2>/dev/null && printf '    removed %s\n' "$f" || warn "Failed to remove $f (try elevated)"
            fi
        done
        ok "Rotated logs cleaned in ${ld}."
    else
        info "Skipped rotated logs in ${ld}."
    fi
done

# 4b. Oversized active logs (>100M) — offer to truncate after backup
for ld in "${LOG_DIRS[@]}"; do
    [ -d "$ld" ] || continue
    LARGE_LOGS="$(find "$ld" -type f -size +100M 2>/dev/null || true)"
    [ -z "$LARGE_LOGS" ] && continue
    printf '%s\n' "$LARGE_LOGS" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '\n'
        warn "Active log $f is >100M ($(du -h "$f" 2>/dev/null | awk '{print $1}'))."
        if ask "Truncate $f after creating ${f}.bak?"; then
            if cp "$f" "${f}.bak" 2>/dev/null || sudo cp "$f" "${f}.bak" 2>/dev/null; then
                : > "$f" 2>/dev/null || sudo truncate -s 0 "$f" 2>/dev/null || true
                ok "Truncated $f (backup at ${f}.bak)."
            else
                warn "Failed to backup $f — skipped truncation."
            fi
        else
            info "Skipped $f."
        fi
    done
done

# 5. Temp files older than TMP_DAYS
for td in "${TMP_DIRS[@]}"; do
    [ -d "$td" ] || continue
    OLD_FILES="$(find "$td" -type f -mtime +"$TMP_DAYS" 2>/dev/null || true)"
    [ -z "$OLD_FILES" ] && continue
    COUNT="$(printf '%s\n' "$OLD_FILES" | grep -c . || true)"
    [ "$COUNT" -eq 0 ] && continue
    printf '\n'
    if ask "Remove ${COUNT} file(s) older than ${TMP_DAYS} days in ${td}?"; then
        printf '%s\n' "$OLD_FILES" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            rm -f "$f" 2>/dev/null || sudo rm -f "$f" 2>/dev/null || warn "Failed to remove $f"
        done
        ok "Temp files cleaned in ${td}."
    else
        info "Skipped temp files in ${td}."
    fi
done

printf '\n'
ok "Disk health cleanup finished."

if df -h 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); if ($5+0>=80) exit 1}' ; then
    :
else
    printf '\n'
    warn "Some filesystems are still above 80%. Consider manual review of large files above."
fi

printf '\n'
log "Disk health check completed. Maintainer: Inova e-Business"
