#!/bin/bash

# ==============================================================================
# DevOps Utilities - Installer & Manager
#
# Maintainer: Inova e-Business
# Version: 2.1
#
# Purpose:
#   Install, run, track, update and remove the DevOps Utilities scripts from
#   this repository. It knows which scripts are installed locally, their
#   versions, and whether they need to be updated relative to the repository.
#
# Usage:
#   # Interactive menu
#   install.sh
#
#   # Non-interactive commands
#   install.sh list                      # list all scripts and their status
#   install.sh status                    # alias for "list"
#   install.sh install <script>          # install a specific script
#   install.sh update                    # update all installed scripts
#   install.sh update <script>           # update a specific script
#   install.sh remove <script>           # remove an installed script
#   install.sh <script>                  # shortcut: install <script>
#
# Bootstrap (download the manager itself):
#   curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh -o install.sh
#   bash install.sh
#
# Notes:
#   - The download happens as the current user; only the final install step is
#     run with sudo (which may prompt for your password).
#   - Installed scripts and their versions are tracked in a local manifest.
# ==============================================================================

set -uo pipefail

VERSION="2.1"

REPO="inovaebiz/devops-utilities"
BRANCH="main"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
API_URL="https://api.github.com/repos/${REPO}/contents"
SELF="install.sh"
DEFAULT_INSTALL_DIR="/usr/local/sbin"
PERMISSIONS="750"

STATE_DIR="${HOME}/.inova-devops"
MANIFEST="${STATE_DIR}/manifest"

# Script list cache (populated by render_list / fetch)
SCRIPTS_ARR=()
SCRIPT_COUNT=0

# -----------------------------------------------------------------------------
# Colors (only when stdout is a terminal)
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
    C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
fi

info()  { printf '  %s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '  %s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '  %s[ERR]%s  %s\n' "$C_RED" "$C_RESET" "$*"; }

# -----------------------------------------------------------------------------
# State / manifest helpers
# -----------------------------------------------------------------------------
manifest_init() {
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
    [ -f "$MANIFEST" ] || : > "$MANIFEST"
}

manifest_get() {
    grep -E "^${1}\|" "$MANIFEST" 2>/dev/null | head -n1 | cut -d'|' -f2-
}

manifest_set() {
    manifest_init
    local tmp
    tmp="$(mktemp)"
    grep -Ev "^${1}\|" "$MANIFEST" 2>/dev/null > "$tmp" || true
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$tmp"
    mv "$tmp" "$MANIFEST"
}

manifest_del() {
    manifest_init
    local tmp
    tmp="$(mktemp)"
    grep -Ev "^${1}\|" "$MANIFEST" 2>/dev/null > "$tmp" || true
    mv "$tmp" "$MANIFEST"
}

# -----------------------------------------------------------------------------
# Repository / version helpers
# -----------------------------------------------------------------------------
fetch_script_list() {
    local json
    json="$(curl -fsSL "$API_URL" 2>/dev/null)" || return 1
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r '.[].name' | grep '\.sh$' | grep -v "^${SELF}$"
    else
        echo "$json" | grep -oE '"name": *"[^"]+\.sh"' \
            | sed 's/.*"name": *"//; s/"$//' \
            | grep -v "^${SELF}$"
    fi
}

extract_version() {
    grep -m1 -E '^VERSION=' "$1" 2>/dev/null \
        | sed -E 's/^VERSION="?([^"]*)"?.*/\1/' \
        | tr -d '[:space:]'
}

remote_version() {
    local tmp
    tmp="$(mktemp)"
    if curl -fsSL "${RAW_URL}/${1}" -o "$tmp" 2>/dev/null; then
        extract_version "$tmp"
    else
        echo "unknown"
    fi
    rm -f "$tmp"
}

local_version() {
    local rec ver
    rec="$(manifest_get "$1")"
    if [ -n "$rec" ]; then
        echo "$rec" | cut -d'|' -f1
        return
    fi
    ver="$(extract_version "${DEFAULT_INSTALL_DIR}/${1}")"
    echo "$ver"
}

is_installed() {
    manifest_get "$1" >/dev/null 2>&1
}

script_at() {
    # script_at <n> -> prints the nth script name (1-based)
    printf '%s\n' "${SCRIPTS_ARR[$(( $1 - 1 ))]}"
}

# -----------------------------------------------------------------------------
# Install / remove / update
# -----------------------------------------------------------------------------
do_install() {
    local name="$1" dir="${2:-$DEFAULT_INSTALL_DIR}" url dest tmp ver
    url="${RAW_URL}/${name}"
    dest="${dir}/${name}"

    info "Downloading ${C_CYAN}${name}${C_RESET} ..."
    tmp="$(mktemp)"
    curl -fsSL "$url" -o "$tmp" || { err "Failed to download ${name}."; rm -f "$tmp"; return 1; }

    if ! head -n1 "$tmp" | grep -q '^#!/'; then
        err "'${name}' does not look like an executable script."
        rm -f "$tmp"
        return 1
    fi

    info "Installing to ${C_CYAN}${dest}${C_RESET} (${PERMISSIONS}) ..."
    if [ "$(id -u)" -eq 0 ]; then
        install -m "$PERMISSIONS" "$tmp" "$dest" || { err "Install failed."; rm -f "$tmp"; return 1; }
    else
        sudo install -m "$PERMISSIONS" "$tmp" "$dest" || { err "Install failed (sudo may need your password)."; rm -f "$tmp"; return 1; }
    fi

    ver="$(extract_version "$tmp")"
    [ -n "$ver" ] || ver="unknown"
    manifest_set "$name" "$ver" "$dir"
    rm -f "$tmp"
    ok "Installed ${C_BOLD}${name}${C_RESET} v${ver} -> ${dest}"
    return 0
}

do_remove() {
    local name="$1" rec dir dest
    rec="$(manifest_get "$name")"
    if [ -z "$rec" ]; then
        warn "${name} is not tracked. Nothing to remove."
        return 0
    fi
    dir="$(echo "$rec" | cut -d'|' -f2)"
    dest="${dir}/${name}"

    info "Removing ${C_CYAN}${dest}${C_RESET} ..."
    if [ "$(id -u)" -eq 0 ]; then
        rm -f "$dest"
    else
        sudo rm -f "$dest"
    fi
    manifest_del "$name"
    ok "Removed ${C_BOLD}${name}${C_RESET}."
}

do_update() {
    local name="$1"
    if is_installed "$name"; then
        info "Updating ${C_CYAN}${name}${C_RESET} ..."
    else
        info "Installing ${C_CYAN}${name}${C_RESET} ..."
    fi
    do_install "$name"
}

run_script() {
    local name="$1" rec dir dest rc
    if ! is_installed "$name"; then
        info "${C_BOLD}${name}${C_RESET} is not installed. Installing first ..."
        do_install "$name" || return 1
    fi
    rec="$(manifest_get "$name")"
    dir="$(echo "$rec" | cut -d'|' -f2)"
    [ -n "$dir" ] || dir="$DEFAULT_INSTALL_DIR"
    dest="${dir}/${name}"

    info "Running ${C_BOLD}${dest}${C_RESET} ..."
    printf '\n'
    if [ "$(id -u)" -eq 0 ]; then
        "$dest"
    else
        sudo "$dest"
    fi
    rc=$?
    printf '\n'
    if [ "$rc" -eq 0 ]; then
        ok "Finished ${name}."
    else
        warn "${name} exited with code ${rc}."
    fi
}

# -----------------------------------------------------------------------------
# Rendering
# -----------------------------------------------------------------------------
print_header() {
    printf '\n  %s\n' "${C_BOLD}${C_MAGENTA}============================================================${C_RESET}"
    printf '  %s\n' "${C_BOLD}  Inova e-Business · DevOps Utilities Manager${C_RESET}"
    printf '  %s\n' "${C_DIM}  Version ${VERSION} · ${REPO} (${BRANCH})${C_RESET}"
    printf '  %s\n' "${C_BOLD}${C_MAGENTA}============================================================${C_RESET}"
    printf '\n'
}

render_list() {
    local name ver_local ver_remote status status_color i
    info "Fetching script list from repository ..."

    local raw
    raw="$(fetch_script_list)" || { err "Could not reach the repository."; return 1; }
    [ -n "$raw" ] || { warn "No scripts found in the repository."; return 0; }

    local W_NUM=4 W_NAME=24 W_LOCAL=8 W_REMOTE=8 W_STATUS=16

    printf '\n'
    printf '  %-*s %-*s %-*s %-*s %-*s\n' \
        "$W_NUM" "#" "$W_NAME" "SCRIPT" "$W_LOCAL" "LOCAL" "$W_REMOTE" "REMOTE" "$W_STATUS" "STATUS"
    printf '  %-*s %-*s %-*s %-*s %-*s\n' \
        "$W_NUM" "---" "$W_NAME" "------------------------" "$W_LOCAL" "--------" "$W_REMOTE" "--------" "$W_STATUS" "----------------"

    SCRIPTS_ARR=()
    i=1
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        SCRIPTS_ARR+=("$name")
        ver_local="$(local_version "$name")"
        ver_remote="$(remote_version "$name")"

        if is_installed "$name"; then
            if [ "$ver_remote" != "unknown" ] && [ "$ver_local" != "$ver_remote" ]; then
                status="update available"; status_color="$C_YELLOW"
            else
                status="up to date";      status_color="$C_GREEN"
            fi
        else
            status="not installed";       status_color="$C_DIM"
        fi

        printf '  %-*s %-*s %-*s %-*s %s%-*s%s\n' \
            "$W_NUM"   "${C_DIM}${i}${C_RESET}" \
            "$W_NAME"  "${C_BOLD}${name}${C_RESET}" \
            "$W_LOCAL" "${ver_local:-—}" \
            "$W_REMOTE" "${ver_remote:-—}" \
            "$status_color" "$W_STATUS" "$status" "$C_RESET"
        i=$((i + 1))
    done <<< "$raw"

    SCRIPT_COUNT=$((i - 1))
    printf '\n'
}

# -----------------------------------------------------------------------------
# Interactive menu
# -----------------------------------------------------------------------------
menu_prompt() {
    printf '\n'
    printf '  %s\n' "${C_CYAN}Pick a number to run (auto-installs if needed), or a command:${C_RESET}"
    printf '  %s\n' "  [1-${SCRIPT_COUNT}] run     [a] update all     [r] remove     [l] refresh     [q] quit"
    printf '  %s' "${C_BOLD}>${C_RESET} "
    read -r choice
    case "$choice" in
        q|Q|quit|exit|"") return 1 ;;
        a|A) menu_update_all ;;
        r|R) menu_remove ;;
        l|L) render_list ;;
        [0-9]*)
            if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$SCRIPT_COUNT" ] 2>/dev/null; then
                run_script "$(script_at "$choice")"
            else
                warn "Invalid number: ${choice}"
            fi
            ;;
        *) warn "Unknown command. Use a number, a, r, l or q." ;;
    esac
    return 0
}

menu_update_all() {
    local name
    for name in "${SCRIPTS_ARR[@]}"; do
        is_installed "$name" && do_update "$name"
    done
    ok "Update pass completed."
    render_list
}

menu_remove() {
    local n
    printf '  %s' "${C_BOLD}Script number to remove:${C_RESET} "
    read -r n
    if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "$SCRIPT_COUNT" ] 2>/dev/null; then
        do_remove "$(script_at "$n")"
    else
        warn "Invalid number: ${n}"
    fi
}

interactive_menu() {
    print_header
    render_list || return 1
    local keep=0
    while [ "$keep" -eq 0 ]; do
        menu_prompt || keep=1
    done
    printf '\n'
    ok "Bye!"
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Inova e-Business · DevOps Utilities Manager (v${VERSION})

Usage:
  install.sh                          interactive menu
  install.sh list                     list scripts and their status
  install.sh status                   alias for "list"
  install.sh install <script>         install a script
  install.sh update                   update all installed scripts
  install.sh update <script>          update a specific script
  install.sh remove <script>          remove an installed script
  install.sh <script>                 shortcut: install <script>

Options:
  -h, --help                          show this help
EOF
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
manifest_init

CMD="${1:-}"

case "$CMD" in
    ""|menu)       interactive_menu ;;
    list|status)   print_header; render_list ;;
    install)       do_install "${2:-}" ;;
    update)
        if [ -n "${2:-}" ]; then
            do_update "$2"
        else
            render_list
            for name in "${SCRIPTS_ARR[@]}"; do
                is_installed "$name" && do_update "$name"
            done
            ok "Update pass completed."
        fi
        ;;
    remove|rm|uninstall)
        do_remove "${2:-}"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        if [ -n "$CMD" ]; then
            do_install "$CMD"
        else
            usage
        fi
        ;;
esac
