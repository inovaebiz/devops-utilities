#!/bin/bash

# ==============================================================================
# System Update Checker & Safe Updater
#
# Maintainer: Inova e-Business
# Version: 1.1
#
# Purpose:
#   Analyze which resources of a system need to be updated (packages, kernel,
#   security patches, services), present an intelligible summary and, upon
#   acceptance, apply the updates safely.
#
# Behavior:
#   - Without flags: list everything, then confirm item by item.
#   - With -y / --yes: list everything, then apply all without asking.
#   - With -c / --check-only: only analyze and print, never change anything.
#
# Supported platforms:
#   - Linux : apt / apt-get (Debian, Ubuntu), dnf / yum (RHEL, CentOS, Fedora, Amazon Linux)
#   - macOS : Homebrew (brew) and system updates (softwareupdate)
#   - Windows : winget, chocolatey (choco), scoop — via Git Bash / WSL / MSYS
#
# ==============================================================================

set -uo pipefail

VERSION="1.1"
TAG="sys-update"

ASSUME_YES=0
CHECK_ONLY=0

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

# -----------------------------------------------------------------------------
# Platform detection
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Package manager detection
# -----------------------------------------------------------------------------
PKG_MANAGER=""

detect_package_manager() {
    case "$OS_TYPE" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                PKG_MANAGER="brew"
            else
                err "Homebrew not found. Install it from https://brew.sh"
                return 1
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            if command -v winget >/dev/null 2>&1; then
                PKG_MANAGER="winget"
            elif command -v choco >/dev/null 2>&1; then
                PKG_MANAGER="choco"
            elif command -v scoop >/dev/null 2>&1; then
                PKG_MANAGER="scoop"
            else
                err "No supported Windows package manager found (winget, choco or scoop)."
                return 1
            fi
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                PKG_MANAGER="apt"
            elif command -v dnf >/dev/null 2>&1; then
                PKG_MANAGER="dnf"
            elif command -v yum >/dev/null 2>&1; then
                PKG_MANAGER="yum"
            else
                err "No supported package manager found (apt-get, dnf or yum)."
                return 1
            fi
            ;;
        *)
            err "Unsupported platform: $OS_TYPE"
            return 1
            ;;
    esac
    return 0
}

detect_package_manager || exit 1

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
ask() {
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
OS_PRETTY="$(uname -srm 2>/dev/null)"
HOSTNAME="$(hostname 2>/dev/null || uname -n)"
KERNEL_RUNNING="$(uname -r)"
UPTIME="$(uptime 2>/dev/null | sed 's/^ *//' || echo n/a)"

printf '\n'
printf '  %s\n' '============================================================'
printf '  %s\n' '  SYSTEM UPDATE CHECKER'
printf '  %s\n' '  Maintainer: Inova e-Business'
printf '  %s\n' "  Version: $VERSION"
printf '  %s\n' '============================================================'
printf '\n'
log "  Platform        : $OS_NAME ($OS_PRETTY)"
log "  Hostname        : $HOSTNAME"
log "  Package manager : $PKG_MANAGER"
log "  Running kernel  : $KERNEL_RUNNING"
log "  Uptime          : $UPTIME"
printf '\n'

# -----------------------------------------------------------------------------
# Collect update data (per platform)
# -----------------------------------------------------------------------------
UPGRADABLE_COUNT=0
SECURITY_COUNT=0
UPGRADABLE_LIST=""

collect_updates() {
    case "$PKG_MANAGER" in
        apt)
            run_spinner "Refreshing package metadata ..." apt-get update -qq >/dev/null
            UPGRADABLE_LIST="$(apt list --upgradable 2>/dev/null | grep 'upgradable' || true)"
            UPGRADABLE_COUNT="$(printf '%s\n' "$UPGRADABLE_LIST" | grep -c 'upgradable' || true)"
            SECURITY_COUNT="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst.*[Ss]ecurity' || true)"
            ;;
        dnf|yum)
            UPGRADABLE_LIST="$($PKG_MANAGER -q check-update 2>/dev/null | grep '\.' || true)"
            UPGRADABLE_COUNT="$(printf '%s\n' "$UPGRADABLE_LIST" | grep -c '\.' || true)"
            SECURITY_COUNT="$($PKG_MANAGER -q updateinfo list security 2>/dev/null | grep -c '\.' || true)"
            ;;
        brew)
            run_spinner "Updating Homebrew ..." brew update >/dev/null
            UPGRADABLE_LIST="$(brew outdated 2>/dev/null || true)"
            UPGRADABLE_COUNT="$(printf '%s\n' "$UPGRADABLE_LIST" | grep -c . || true)"
            SECURITY_COUNT=0
            ;;
        winget)
            UPGRADABLE_LIST="$(winget upgrade 2>/dev/null | tail -n +3 || true)"
            UPGRADABLE_COUNT="$(printf '%s\n' "$UPGRADABLE_LIST" | grep -c . || true)"
            SECURITY_COUNT=0
            ;;
        choco)
            UPGRADABLE_LIST="$(choco outdated 2>/dev/null | tail -n +2 || true)"
            UPGRADABLE_COUNT="$(printf '%s\n' "$UPGRADABLE_LIST" | grep -c '|' || true)"
            SECURITY_COUNT=0
            ;;
        scoop)
            run_spinner "Checking Scoop ..." scoop update >/dev/null
            UPGRADABLE_LIST="$(scoop status 2>/dev/null || true)"
            UPGRADABLE_COUNT="$(printf '%s\n' "$UPGRADABLE_LIST" | grep -c '^[a-zA-Z]' || true)"
            SECURITY_COUNT=0
            ;;
    esac
}

collect_updates

# macOS system updates (separate from Homebrew)
MACOS_SYS_UPDATES=""
if [ "$PKG_MANAGER" = "brew" ] && command -v softwareupdate >/dev/null 2>&1; then
    MACOS_SYS_UPDATES="$(softwareupdate -l 2>/dev/null | grep -E '^\s*\*' || true)"
fi

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

TOTAL_PENDING="$UPGRADABLE_COUNT"
if [ -n "$MACOS_SYS_UPDATES" ]; then
    MACOS_SYS_COUNT="$(printf '%s\n' "$MACOS_SYS_UPDATES" | grep -c . || true)"
    TOTAL_PENDING=$(( TOTAL_PENDING + MACOS_SYS_COUNT ))
fi

if [ "$TOTAL_PENDING" -gt 0 ]; then
    warn "$TOTAL_PENDING resource(s) with updates available."
    if [ "$SECURITY_COUNT" -gt 0 ]; then
        warn "$SECURITY_COUNT of them are security-related."
    fi
    printf '\n'
    if [ "$UPGRADABLE_COUNT" -gt 0 ]; then
        info "Packages to be updated:"
        printf '%s\n' "$UPGRADABLE_LIST" | sed 's/^/    /'
    fi
    if [ -n "$MACOS_SYS_UPDATES" ]; then
        printf '\n'
        info "macOS system updates available:"
        printf '%s\n' "$MACOS_SYS_UPDATES" | sed 's/^/    /'
    fi
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

if [ "$TOTAL_PENDING" -eq 0 ]; then
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

apply_updates() {
    case "$PKG_MANAGER" in
        apt)
            if [ "$ASSUME_YES" -eq 1 ]; then
                run_spinner "Upgrading packages ..." apt-get -y upgrade >/dev/null
                run_spinner "Removing unused packages ..." apt-get -y autoremove >/dev/null
            else
                echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    pkg="$(echo "$line" | awk -F/ '{print $1}')"
                    if ask "Update package '$pkg'?"; then
                        run_spinner "Updating $pkg ..." apt-get -y install --only-upgrade "$pkg" >/dev/null || warn "Failed to update $pkg"
                    else
                        info "Skipped $pkg"
                    fi
                done
                run_spinner "Removing unused packages ..." apt-get -y autoremove >/dev/null
            fi
            ;;
        dnf|yum)
            if [ "$ASSUME_YES" -eq 1 ]; then
                run_spinner "Upgrading packages ..." $PKG_MANAGER -y upgrade >/dev/null
                run_spinner "Removing unused packages ..." $PKG_MANAGER -y autoremove >/dev/null
            else
                echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    pkg="$(echo "$line" | awk '{print $1}' | sed 's/\..*//')"
                    if ask "Update package '$pkg'?"; then
                        run_spinner "Updating $pkg ..." $PKG_MANAGER -y upgrade "$pkg" >/dev/null || warn "Failed to update $pkg"
                    else
                        info "Skipped $pkg"
                    fi
                done
                run_spinner "Removing unused packages ..." $PKG_MANAGER -y autoremove >/dev/null
            fi
            ;;
        brew)
            if [ "$ASSUME_YES" -eq 1 ]; then
                run_spinner "Upgrading Homebrew packages ..." brew upgrade >/dev/null
                run_spinner "Cleaning up ..." brew cleanup >/dev/null
            else
                echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                    [ -z "$line" ] || continue
                    pkg="$(echo "$line" | awk '{print $1}')"
                    if ask "Update package '$pkg'?"; then
                        run_spinner "Updating $pkg ..." brew upgrade "$pkg" >/dev/null || warn "Failed to update $pkg"
                    else
                        info "Skipped $pkg"
                    fi
                done
                run_spinner "Cleaning up ..." brew cleanup >/dev/null
            fi
            ;;
        winget)
            if [ "$ASSUME_YES" -eq 1 ]; then
                run_spinner "Upgrading packages ..." winget upgrade --all >/dev/null
            else
                echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                    [ -z "$line" ] || continue
                    pkg="$(echo "$line" | awk '{print $2}')"
                    [ -n "$pkg" ] || continue
                    if ask "Update package '$pkg'?"; then
                        run_spinner "Updating $pkg ..." winget upgrade --id "$pkg" >/dev/null || warn "Failed to update $pkg"
                    else
                        info "Skipped $pkg"
                    fi
                done
            fi
            ;;
        choco)
            if [ "$ASSUME_YES" -eq 1 ]; then
                run_spinner "Upgrading packages ..." choco upgrade all -y >/dev/null
            else
                echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                    [ -z "$line" ] || continue
                    pkg="$(echo "$line" | awk -F'|' '{print $1}')"
                    [ -n "$pkg" ] || continue
                    if ask "Update package '$pkg'?"; then
                        run_spinner "Updating $pkg ..." choco upgrade "$pkg" -y >/dev/null || warn "Failed to update $pkg"
                    else
                        info "Skipped $pkg"
                    fi
                done
            fi
            ;;
        scoop)
            if [ "$ASSUME_YES" -eq 1 ]; then
                run_spinner "Upgrading packages ..." scoop update '*' >/dev/null
            else
                echo "$UPGRADABLE_LIST" | while IFS= read -r line; do
                    [ -z "$line" ] || continue
                    pkg="$(echo "$line" | awk '{print $1}')"
                    if ask "Update package '$pkg'?"; then
                        run_spinner "Updating $pkg ..." scoop update "$pkg" >/dev/null || warn "Failed to update $pkg"
                    else
                        info "Skipped $pkg"
                    fi
                done
            fi
            ;;
    esac
}

apply_updates

# macOS system updates
if [ -n "$MACOS_SYS_UPDATES" ]; then
    printf '\n'
    if [ "$ASSUME_YES" -eq 1 ]; then
        info "Applying macOS system updates..."
        softwareupdate -i -a
    else
        if ask "Apply macOS system updates?"; then
            softwareupdate -i -a
        else
            info "Skipped macOS system updates."
        fi
    fi
fi

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
