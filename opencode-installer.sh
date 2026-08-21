#!/bin/bash

# ==============================================================================
# OpenCode Installer
#
# Maintainer: Inova e-Business
# Version: 1.0
#
# Purpose:
#   Download and install OpenCode (AI coding agent) using the best available
#   method for the current platform, following the same UX patterns as the
#   other DevOps Utilities scripts.
#
# Supported platforms:
#   - Linux   : install script (curl | bash), npm, Homebrew, pacman
#   - macOS   : Homebrew (anomalyco/tap), install script, npm
#   - Windows : Chocolatey, Scoop, npm, install script via Git Bash / WSL / MSYS
#
# Behavior:
#   - Without flags: check if opencode is installed, show available methods,
#     then ask for confirmation before installing/updating.
#   - With -y / --yes: install/update without asking.
#   - With -c / --check-only: only check and print status (no changes).
#   - With --method <name>: force a specific method (script|npm|brew|choco|scoop|pacman).
#
# Notes:
#   - This script only installs OpenCode; it does not configure providers.
#     Run `opencode` and `/connect` after install to set up your LLM keys.
#   - Some methods require elevation (brew/choco/pacman). The script will
#     use sudo when needed and available.
#
# ==============================================================================

set -uo pipefail

VERSION="1.0"
TAG="opencode-installer"

ASSUME_YES=0
CHECK_ONLY=0
METHOD="auto"

log()  { printf '%s\n' "$*"; }
info() { printf '  \033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '  \033[1;31m[ERR]\033[0m  %s\n' "$*"; }

TTY=0
[ -t 1 ] && TTY=1

if [ "$TTY" = 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

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
    local out rc
    if [ "$TTY" = 1 ]; then
        out="$("$@" 2>&1)" &
        local pid=$!
        _spin "$pid" "$label"
        wait "$pid"; rc=$?
    else
        out="$("$@" 2>&1)"; rc=$?
    fi
    printf '%s\n' "$out"
    return $rc
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -y, --yes              Install/update without asking for confirmation.
  -c, --check-only       Only check status (no changes).
      --method NAME      Force install method: script|npm|brew|choco|scoop|pacman|auto
  -h, --help             Show this help.

Methods:
  script  curl -fsSL https://opencode.ai/install | bash  (recommended, all platforms)
  npm     npm install -g opencode-ai
  brew    brew install anomalyco/tap/opencode  (macOS/Linux)
  choco   choco install opencode               (Windows)
  scoop   scoop install opencode               (Windows)
  pacman  sudo pacman -S opencode              (Arch Linux)

Examples:
  $0                     Check and prompt before installing.
  $0 --yes               Install/update without prompts.
  $0 --check-only        Just show if opencode is installed.
  $0 --method brew       Force Homebrew method.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)            ASSUME_YES=1; shift ;;
        -c|--check-only)     CHECK_ONLY=1; shift ;;
        --method)            METHOD="${2:-auto}"; shift 2 ;;
        --method=*)          METHOD="${1#*=}"; shift ;;
        -h|--help)           usage; exit 0 ;;
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
    printf '  \033[1;36m[?]\033[0m %s [y/N] ' "$1" > /dev/tty
    if [ -r /dev/tty ]; then
        read -r answer < /dev/tty
    else
        read -r answer
    fi
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
OS_PRETTY="$(uname -srm 2>/dev/null)"
HOSTNAME="$(hostname 2>/dev/null || uname -n)"
printf '\n'
printf '  %s\n' '============================================================'
printf '  %s\n' '  OPENCODE INSTALLER'
printf '  %s\n' '  Maintainer: Inova e-Business'
printf '  %s\n' "  Version: $VERSION"
printf '  %s\n' '============================================================'
printf '\n'
log "  Platform : $OS_NAME ($OS_PRETTY)"
log "  Hostname : $HOSTNAME"
log "  Mode     : $([ "$CHECK_ONLY" = 1 ] && echo "check-only" || ([ "$ASSUME_YES" = 1 ] && echo "auto (yes)" || echo "interactive"))"
log "  Method   : $METHOD"
printf '\n'

# -----------------------------------------------------------------------------
# Detect current installation
# -----------------------------------------------------------------------------
INSTALLED=0
INSTALLED_VERSION=""
INSTALLED_PATH=""

if command -v opencode >/dev/null 2>&1; then
    INSTALLED=1
    INSTALLED_PATH="$(command -v opencode 2>/dev/null || true)"
    INSTALLED_VERSION="$(opencode --version 2>/dev/null | head -n1 || true)"
    # Fallback: try opencode --help if --version not supported in older builds
    [ -z "$INSTALLED_VERSION" ] && INSTALLED_VERSION="$(opencode --help 2>/dev/null | head -n1 || echo "unknown")"
fi

# -----------------------------------------------------------------------------
# Available methods per platform
# -----------------------------------------------------------------------------
HR_SEP="------------------------------------------------------------"

print_section() {
    printf '\n  %s\n' "$HR_SEP"
    printf '  %s\n' "  $1"
    printf '  %s\n' "$HR_SEP"
    printf '\n'
}

have_method() {
    case "$1" in
        script) command -v curl >/dev/null 2>&1 ;;
        npm)    command -v npm >/dev/null 2>&1 ;;
        brew)   command -v brew >/dev/null 2>&1 ;;
        choco)  command -v choco >/dev/null 2>&1 || command -v choco.exe >/dev/null 2>&1 ;;
        scoop)  command -v scoop >/dev/null 2>&1 ;;
        pacman) command -v pacman >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

describe_method() {
    case "$1" in
        script) echo "curl -fsSL https://opencode.ai/install | bash  (recommended)" ;;
        npm)    echo "npm install -g opencode-ai" ;;
        brew)   echo "brew install anomalyco/tap/opencode" ;;
        choco)  echo "choco install opencode" ;;
        scoop)  echo "scoop install opencode" ;;
        pacman) echo "sudo pacman -S opencode" ;;
    esac
}

detect_best_method() {
    if [ "$METHOD" != "auto" ]; then
        printf '%s\n' "$METHOD"
        return 0
    fi
    case "$OS_NAME" in
        macOS)
            have_method brew   && { echo "brew"; return 0; }
            have_method script && { echo "script"; return 0; }
            have_method npm    && { echo "npm"; return 0; }
            ;;
        Windows)
            have_method choco  && { echo "choco"; return 0; }
            have_method scoop  && { echo "scoop"; return 0; }
            have_method npm    && { echo "npm"; return 0; }
            have_method script && { echo "script"; return 0; }
            ;;
        Linux)
            # Prefer script (works everywhere), then package managers
            have_method script && { echo "script"; return 0; }
            have_method pacman && { echo "pacman"; return 0; }
            have_method brew   && { echo "brew"; return 0; }
            have_method npm    && { echo "npm"; return 0; }
            ;;
    esac
    # Fallback: first available
    for m in script npm brew choco scoop pacman; do
        have_method "$m" && { echo "$m"; return 0; }
    done
    echo "script"
}

print_section "Status"

if [ "$INSTALLED" -eq 1 ]; then
    ok "OpenCode is installed."
    info "Path: $INSTALLED_PATH"
    info "Version: ${INSTALLED_VERSION:-unknown}"
else
    warn "OpenCode is not installed."
fi

printf '\n'
info "Available install methods on this system:"
for m in script npm brew choco scoop pacman; do
    if have_method "$m"; then
        ok "$m — $(describe_method "$m")"
    else
        printf '  \033[2m[ -- ]   %s — not available\033[0m\n' "$m"
    fi
done

BEST_METHOD="$(detect_best_method)"
printf '\n'
info "Selected method: ${C_BOLD}${BEST_METHOD}${C_RESET} — $(describe_method "$BEST_METHOD")"
if ! have_method "$BEST_METHOD" && [ "$BEST_METHOD" = "script" ]; then
    # script only needs curl, which we already checked via have_method
    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required for the 'script' method but was not found."
        err "Install curl or choose another method via --method."
        exit 1
    fi
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '\n'
    ok "Check-only mode. No changes were made."
    if [ "$INSTALLED" -eq 0 ]; then
        info "Run without --check-only to install via: $BEST_METHOD"
    fi
    exit 0
fi

# If already installed, confirm update/reinstall
if [ "$INSTALLED" -eq 1 ]; then
    printf '\n'
    if ! ask "OpenCode is already installed (${INSTALLED_VERSION:-unknown}). Reinstall/update via ${BEST_METHOD}?"; then
        warn "Install cancelled by user."
        exit 0
    fi
else
    printf '\n'
    if ! ask "Install OpenCode via ${BEST_METHOD}?"; then
        warn "Install cancelled by user."
        exit 0
    fi
fi

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
install_via_script() {
    info "Installing via install script (curl | bash)..."
    if [ "$TTY" = 1 ]; then
        curl -fsSL https://opencode.ai/install | bash 2>&1 | sed 's/^/    /'
        return ${PIPESTATUS[0]:-${PIPESTATUS[1]:-0}}
    else
        curl -fsSL https://opencode.ai/install | bash 2>&1 | sed 's/^/    /'
    fi
}

install_via_npm() {
    info "Installing via npm..."
    run_spinner "Installing opencode-ai via npm ..." npm install -g opencode-ai
}

install_via_brew() {
    info "Installing via Homebrew..."
    run_spinner "Installing opencode via brew ..." brew install anomalyco/tap/opencode
}

install_via_choco() {
    info "Installing via Chocolatey..."
    if command -v choco >/dev/null 2>&1; then
        run_spinner "Installing opencode via choco ..." choco install opencode -y
    else
        run_spinner "Installing opencode via choco ..." choco.exe install opencode -y
    fi
}

install_via_scoop() {
    info "Installing via Scoop..."
    run_spinner "Installing opencode via scoop ..." scoop install opencode
}

install_via_pacman() {
    info "Installing via pacman..."
    run_spinner "Installing opencode via pacman ..." sudo pacman -S --noconfirm opencode
}

printf '\n'
case "$BEST_METHOD" in
    script) install_via_script ;;
    npm)    install_via_npm ;;
    brew)   install_via_brew ;;
    choco)  install_via_choco ;;
    scoop)  install_via_scoop ;;
    pacman) install_via_pacman ;;
    *) err "Unknown method: $BEST_METHOD"; exit 1 ;;
esac
RC=$?

if [ $RC -ne 0 ]; then
    err "Install via $BEST_METHOD failed with exit code $RC."
    info "Try another method: $0 --method <name>"
    info "Available: script, npm, brew, choco, scoop, pacman"
    exit $RC
fi

printf '\n'
# Verify
if command -v opencode >/dev/null 2>&1; then
    NEW_VER="$(opencode --version 2>/dev/null | head -n1 || true)"
    ok "OpenCode installed successfully."
    info "Path: $(command -v opencode)"
    [ -n "$NEW_VER" ] && info "Version: $NEW_VER"
    printf '\n'
    info "Next steps:"
    printf '    %s\n' "1. Run: opencode"
    printf '    %s\n' "2. Inside the TUI, run /connect to configure your LLM provider"
    printf '    %s\n' "   or set API keys per https://opencode.ai/docs/providers"
    printf '    %s\n' "3. In your project, run /init to create AGENTS.md"
else
    warn "Install finished but 'opencode' not found on PATH."
    info "Try opening a new shell or adding the install dir to PATH."
    info "Check: https://opencode.ai/docs#install"
fi

printf '\n'
log "OpenCode installer completed. Maintainer: Inova e-Business"
