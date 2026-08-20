#!/bin/bash

# ==============================================================================
# System Update Checker & Safe Updater
#
# Maintainer: Inova e-Business
# Version: 1.0
#
# Purpose:
#   Analyze which resources of a Linux system need to be updated (packages,
#   kernel, security patches, services), present an intelligible summary and,
#   upon acceptance, apply the updates safely.
#
# Behavior:
#   - Without flags: list everything, then confirm item by item.
#   - With -y / --yes: list everything, then apply all without asking.
#   - With -c / --check-only: only analyze and print, never change anything.
#
# Supports:
#   - apt / apt-get (Debian, Ubuntu)
#   - dnf / yum   (RHEL, CentOS, Fedora, Amazon Linux)
#
# ==============================================================================

set -uo pipefail

VERSION="1.0"
TAG="sys-update"

ASSUME_YES=0
CHECK_ONLY=0

log()  { printf '%s\n' "$*"; }
info() { printf '  \033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '  \033[1;31m[ERR]\033[0m  %s\n' "$*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -y, --yes          Apply all updates without asking for confirmation.
  -c, --check-only   Only analyze and print the summary (no changes).
  -h, --help         Show this help.

Examples:
  $0                 Analyze and confirm item by item.
  $0 --yes           Analyze and apply everything automatically.
  $0 --check-only    Just list what needs to be updated.
EOF
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes)        ASSUME_YES=1 ;;
        -c|--check-only) CHECK_ONLY=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) err "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    err "This script requires root privileges."
    err "Re-run with: sudo $0 $*"
    exit 1
fi

# -----------------------------------------------------------------------------
# Package manager detection
# -----------------------------------------------------------------------------
PKG_MANAGER=""
if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
else
    err "No supported package manager found (apt-get, dnf or yum)."
    exit 1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
ask() {
    # ask "question" -> returns 0 for yes, 1 for no
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    local answer
    printf '  \033[1;36m[?]\033[0m %s [y/N] ' "$1"
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Collect system information
# -----------------------------------------------------------------------------
OS_PRETTY="$(grep -E '^(NAME|VERSION)=' /etc/os-release 2>/dev/null | tr '\n' ' ' | sed 's/NAME=//; s/VERSION=//; s/"//g')"
KERNEL_RUNNING="$(uname -r)"
UPTIME="$(uptime -p 2>/dev/null || uptime)"

printf '\n'
printf '  %s\n' '============================================================'
printf '  %s\n' '  SYSTEM UPDATE CHECKER'
printf '  %s\n' '  Maintainer: Inova e-Business'
printf '  %s\n' "  Version: $VERSION"
printf '  %s\n' '============================================================'
printf '\n'
log "  System          : $OS_PRETTY"
log "  Package manager : $PKG_MANAGER"
log "  Running kernel  : $KERNEL_RUNNING"
log "  Uptime          : $UPTIME"
printf '\n'

# -----------------------------------------------------------------------------
# Collect update data
# -----------------------------------------------------------------------------
info "Refreshing package metadata (this may take a moment)..."

case "$PKG_MANAGER" in
    apt)
        apt-get update -qq
        UPGRADABLE_COUNT="$(apt list --upgradable 2>/dev/null | grep -c 'upgradable' || true)"
        SECURITY_COUNT="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst.*[Ss]ecurity' || true)"
        UPGRADABLE_LIST="$(apt list --upgradable 2>/dev/null | grep 'upgradable' || true)"
        ;;
    dnf|yum)
        UPGRADABLE_COUNT="$($PKG_MANAGER -q check-update 2>/dev/null | grep -c '\.' || true)"
        SECURITY_COUNT="$($PKG_MANAGER -q updateinfo list security 2>/dev/null | grep -c '\.' || true)"
        UPGRADABLE_LIST="$($PKG_MANAGER -q check-update 2>/dev/null | grep '\.' || true)"
        ;;
esac

# Reboot / service restart detection
REBOOT_REQUIRED=0
if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=1
elif command -v needs-restarting >/dev/null 2>&1 && needs-restarting -r >/dev/null 2>&1; then
    REBOOT_REQUIRED=1
fi

SERVICES_NEED_RESTART=""
if command -v needs-restarting >/dev/null 2>&1; then
    SERVICES_NEED_RESTART="$(needs-restarting -s 2>/dev/null || true)"
elif [ -d /var/run/systemd ] && [ "$PKG_MANAGER" = "apt" ] && [ -f /var/run/reboot-required ]; then
    SERVICES_NEED_RESTART="(see /var/run/reboot-required.pkgs)"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
printf '  %s\n' '------------------------------------------------------------'
printf '  %s\n' '  SUMMARY'
printf '  %s\n' '------------------------------------------------------------'
printf '\n'

if [ "$UPGRADABLE_COUNT" -gt 0 ]; then
    warn "$UPGRADABLE_COUNT package(s) with updates available."
    if [ "$SECURITY_COUNT" -gt 0 ]; then
        warn "$SECURITY_COUNT of them are security-related."
    fi
    printf '\n'
    info "Packages to be updated:"
    printf '%s\n' "$UPGRADABLE_LIST" | sed 's/^/    /'
else
    ok "All packages are up to date."
fi

printf '\n'
if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    warn "A system reboot is recommended after updating."
else
    ok "No reboot required."
fi

if [ -n "$SERVICES_NEED_RESTART" ]; then
    printf '\n'
    info "Services that should be restarted after updating:"
    printf '%s\n' "$SERVICES_NEED_RESTART" | sed 's/^/    /'
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

if [ "$UPGRADABLE_COUNT" -eq 0 ]; then
    printf '\n'
    ok "Nothing to update. Exiting."
    exit 0
fi

# -----------------------------------------------------------------------------
# Acceptance and safe update
# -----------------------------------------------------------------------------
printf '\n'
if [ "$ASSUME_YES" -eq 1 ]; then
    info "Running in --yes mode. Applying all updates..."
else
    if ask "Proceed with the update? (item-by-item confirmation)"; then
        info "Proceeding."
    else
        warn "Update cancelled by user."
        exit 0
    fi
fi

case "$PKG_MANAGER" in
    apt)
        if [ "$ASSUME_YES" -eq 1 ]; then
            apt-get -y upgrade
            apt-get -y autoremove
        else
            # Interactive: list each package and ask
            echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                pkg="$(echo "$line" | awk -F/ '{print $1}')"
                if ask "Update package '$pkg'?"; then
                    apt-get -y install --only-upgrade "$pkg" || warn "Failed to update $pkg"
                else
                    info "Skipped $pkg"
                fi
            done
            apt-get -y autoremove
        fi
        ;;
    dnf|yum)
        if [ "$ASSUME_YES" -eq 1 ]; then
            $PKG_MANAGER -y upgrade
            $PKG_MANAGER -y autoremove
        else
            echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                [ -z "$line" ] && continue
                pkg="$(echo "$line" | awk '{print $1}' | sed 's/\..*//')"
                if ask "Update package '$pkg'?"; then
                    $PKG_MANAGER -y upgrade "$pkg" || warn "Failed to update $pkg"
                else
                    info "Skipped $pkg"
                fi
            done
            $PKG_MANAGER -y autoremove
        fi
        ;;
esac

printf '\n'
ok "Update process finished."

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    printf '\n'
    warn "A reboot is recommended to apply kernel/security updates."
    if ask "Reboot the system now?"; then
        warn "Rebooting now..."
        reboot
    else
        info "Reboot postponed. Remember to reboot later."
    fi
fi

printf '\n'
log "System update checker completed. Maintainer: Inova e-Business"
