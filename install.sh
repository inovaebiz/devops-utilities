#!/bin/bash

# ==============================================================================
# DevOps Utilities - Installer & Manager
#
# Maintainer: Inova e-Business
# Version: 2.2
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
#   - The interactive menu uses arrow-key navigation. If `gum` is installed it
#     is used automatically for a nicer experience.
# ==============================================================================

set -uo pipefail

VERSION="2.3"

REPO="inovaebiz/devops-utilities"
BRANCH="main"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
API_URL="https://api.github.com/repos/${REPO}/contents"
SELF="install.sh"
DEFAULT_INSTALL_DIR="/usr/local/sbin"
PERMISSIONS="750"

STATE_DIR="${HOME}/.inova-devops"
MANIFEST="${STATE_DIR}/manifest"
LOG_FILE="${STATE_DIR}/manager.log"

# Script data (populated by load_scripts)
SCRIPTS_ARR=()
ARR_LOCAL=()
ARR_REMOTE=()
ARR_INSTALLED=()
ARR_DESC=()
SCRIPT_COUNT=0

# -----------------------------------------------------------------------------
# Colors / unicode detection (only when stdout is a terminal)
# -----------------------------------------------------------------------------
TTY=0
[ -t 1 ] && TTY=1

if [ "$TTY" = 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
    C_REV=$'\033[7m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
    C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN="" C_REV=""
fi

UTF8=0
if [[ "$(locale charmap 2>/dev/null)" == *"UTF"* ]]; then UTF8=1; fi

if [ "$UTF8" = 1 ]; then
    B_TL="╭"; B_TR="╮"; B_BL="╰"; B_BR="╯"; B_H="─"; B_V="│"
    SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    TICK="✓"; ARROW="▸"; CROSS="✗"
else
    B_TL="+"; B_TR="+"; B_BL="+"; B_BR="+"; B_H="-"; B_V="|"
    SPIN_FRAMES=('|' '/' '-' '\')
    TICK="*"; ARROW=">"; CROSS="x"
fi

GUM=0
command -v gum >/dev/null 2>&1 && GUM=1

info()  { printf '  %s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '  %s%s%s %s\n' "$C_GREEN" "$TICK" "$C_RESET" "$*"; }
warn()  { printf '  %s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()   { printf '  %s[!]%s %s\n' "$C_RED" "$C_RESET" "$*"; }

log_event() {
    manifest_init
    printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

rep() { local c="$1" n="$2" i s=""; for ((i=0;i<n;i++)); do s+="$c"; done; printf '%s' "$s"; }

center_pad() {
    local t w len pad
    t="$1"
    w="$2"
    len=${#t}
    pad=$(( (w - len) / 2 ))
    printf '%*s%s%*s' "$pad" '' "$t" "$(( w - len - pad ))" ''
}

# -----------------------------------------------------------------------------
# Spinner
# -----------------------------------------------------------------------------
_spin() {
    local pid="$1" label="$2" i=0 n=${#SPIN_FRAMES[@]}
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$C_CYAN" "${SPIN_FRAMES[$i]}" "$C_RESET" "$label"
        i=$(( (i + 1) % n ))
        sleep 0.08
    done
    printf '\r\033[K'
}

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
    local tmpf json
    tmpf="$(mktemp)"
    if [ "$TTY" = 1 ]; then
        curl -fsSL "$API_URL" -o "$tmpf" 2>/dev/null &
        _spin $! "Fetching script list ..."
        wait $! || { rm -f "$tmpf"; return 1; }
    else
        curl -fsSL "$API_URL" -o "$tmpf" 2>/dev/null || { rm -f "$tmpf"; return 1; }
    fi
    json="$(cat "$tmpf")"; rm -f "$tmpf"
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

extract_description() {
    awk '/^# Purpose:/{p=1; next} p && /^#/{if ($0 ~ /^#   /){sub(/^#   /,""); print} else exit}' "$1" \
        | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

remote_info() {
    local tmp ver desc
    tmp="$(mktemp)"
    if curl -fsSL "${RAW_URL}/${1}" -o "$tmp" 2>/dev/null; then
        ver="$(extract_version "$tmp")"
        desc="$(extract_description "$tmp")"
    else
        ver="unknown"
        desc=""
    fi
    rm -f "$tmp"
    echo "${ver}|${desc}"
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
    printf '%s\n' "${SCRIPTS_ARR[$(( $1 - 1 ))]}"
}

# -----------------------------------------------------------------------------
# Install / remove / update
# -----------------------------------------------------------------------------
do_install() {
    local name="$1" dir="${2:-$DEFAULT_INSTALL_DIR}" url dest tmp ver
    url="${RAW_URL}/${name}"
    dest="${dir}/${name}"

    tmp="$(mktemp)"
    if [ "$TTY" = 1 ]; then
        curl -fsSL "$url" -o "$tmp" 2>/dev/null &
        _spin $! "Downloading ${name} ..."
        wait $! || { err "Failed to download ${name}."; rm -f "$tmp"; return 1; }
    else
        curl -fsSL "$url" -o "$tmp" 2>/dev/null || { err "Failed to download ${name}."; rm -f "$tmp"; return 1; }
    fi

    if ! head -n1 "$tmp" | grep -q '^#!/'; then
        err "'${name}' does not look like an executable script."
        rm -f "$tmp"
        return 1
    fi

    info "Installing to ${C_CYAN}${dest}${C_RESET} (${PERMISSIONS}) ..."
    if mkdir -p "$(dirname "$dest")" 2>/dev/null && [ -w "$(dirname "$dest")" ]; then
        cp "$tmp" "$dest" && chmod "$PERMISSIONS" "$dest" || { err "Install failed."; rm -f "$tmp"; return 1; }
    else
        sudo mkdir -p "$(dirname "$dest")"
        sudo cp "$tmp" "$dest" && sudo chmod "$PERMISSIONS" "$dest" || { err "Install failed (sudo may need your password)."; rm -f "$tmp"; return 1; }
    fi

    ver="$(extract_version "$tmp")"
    [ -n "$ver" ] || ver="unknown"
    manifest_set "$name" "$ver" "$dir"
    rm -f "$tmp"
    log_event "Installed ${name} v${ver} -> ${dest} (client: ${CLIENT_NAME:-n/a})"
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
    log_event "Removed ${name} (client: ${CLIENT_NAME:-n/a})"
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
        "$dest" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
    else
        sudo "$dest" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
    fi
    printf '\n'
    if [ "$rc" -eq 0 ]; then
        ok "Finished ${name}."
    else
        warn "${name} exited with code ${rc}."
    fi
    log_event "Ran ${name} (exit ${rc}, client: ${CLIENT_NAME:-n/a})"
}

# -----------------------------------------------------------------------------
# Self-update
# -----------------------------------------------------------------------------
version_gt() {
    local a="$1" b="$2" first
    [ "$a" = "$b" ] && return 1
    first="$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)"
    [ "$first" = "$b" ] && return 0
    return 1
}

ask() {
    local ans
    if [ "$GUM" = 1 ] && [ "$TTY" = 1 ]; then
        gum confirm "$1" && return 0 || return 1
    fi
    printf '  %s' "${C_BOLD}$1 [y/N]${C_RESET} "
    read -r ans
    case "$ans" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

self_changelog() {
    local json tmpf
    tmpf="$(mktemp)"
    if [ "$TTY" = 1 ]; then
        curl -fsSL "https://api.github.com/repos/${REPO}/commits?path=${SELF}&per_page=10" -o "$tmpf" 2>/dev/null &
        _spin $! "Fetching changelog ..."
        wait $! || { rm -f "$tmpf"; return 1; }
        json="$(cat "$tmpf")"; rm -f "$tmpf"
    else
        json="$(curl -fsSL "https://api.github.com/repos/${REPO}/commits?path=${SELF}&per_page=10" 2>/dev/null)" || return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r '.[].commit.message' | sed 's/^/    • /'
    else
        echo "$json" | grep -oE '"message": *"[^"]*"' \
            | sed 's/"message": *"//; s/"$//' \
            | sed 's/^/    • /'
    fi
}

self_update() {
    local me="${BASH_SOURCE[0]:-$0}" tmp
    if [ ! -f "$me" ] || [ "$me" = "bash" ] || [ "$me" = "-bash" ]; then
        warn "Running via pipe; cannot self-update in place."
        info "Re-run the bootstrap command to get the latest version."
        return 1
    fi

    tmp="$(mktemp)"
    if [ "$TTY" = 1 ]; then
        curl -fsSL "${RAW_URL}/${SELF}" -o "$tmp" 2>/dev/null &
        _spin $! "Downloading latest ${SELF} ..."
        wait $! || { err "Download failed."; rm -f "$tmp"; return 1; }
    else
        curl -fsSL "${RAW_URL}/${SELF}" -o "$tmp" 2>/dev/null || { err "Download failed."; rm -f "$tmp"; return 1; }
    fi

    if [ "$(id -u)" -eq 0 ] || [ -w "$(dirname "$me")" ]; then
        cp "$tmp" "$me" && chmod 750 "$me" || { err "Update failed."; rm -f "$tmp"; return 1; }
    else
        sudo cp "$tmp" "$me" && sudo chmod 750 "$me" || { err "Update failed (sudo may need your password)."; rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
    ok "Manager updated to the latest version."
    info "Restart the manager to apply changes."
}

self_update_check() {
    local remote_ver cl
    remote_ver="$(remote_version "$SELF")"
    [ -n "$remote_ver" ] || return 0
    [ "$remote_ver" = "unknown" ] && return 0

    if version_gt "$remote_ver" "$VERSION"; then
        printf '\n'
        printf '  %s\n' "${C_YELLOW}A new version of the manager is available!${C_RESET}"
        printf '  %s\n' "    Current : v${VERSION}"
        printf '  %s\n' "    Latest  : v${remote_ver}"
        printf '\n'
        cl="$(self_changelog 2>/dev/null || true)"
        if [ -n "$cl" ]; then
            printf '  %s\n' "${C_DIM}  Recent changes:${C_RESET}"
            printf '%s\n' "$cl"
            printf '\n'
        fi
        if ask "Update the manager now?"; then
            self_update
        else
            warn "Keeping current version v${VERSION}."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Rendering
# -----------------------------------------------------------------------------
print_header() {
    local w=58
    printf '\n'
    printf '  %s%s%s%s%s\n' "$C_MAGENTA" "$B_TL" "$(rep "$B_H" "$w")" "$B_TR" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_MAGENTA" "$B_V" "$(center_pad "Inova e-Business · DevOps Utilities" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_MAGENTA" "$B_V" "$(center_pad "Manager v${VERSION} · ${REPO} (${BRANCH})" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_MAGENTA" "$B_BL" "$(rep "$B_H" "$w")" "$B_BR" "$C_RESET"
    printf '\n'
}

system_header() {
    local os host kernel user w=58
    os="$(uname -s 2>/dev/null || echo unknown)"
    host="$(hostname 2>/dev/null || echo unknown)"
    kernel="$(uname -r 2>/dev/null || echo unknown)"
    user="$(id -un 2>/dev/null || echo unknown)"

    printf '\n'
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_TL" "$(rep "$B_H" "$w")" "$B_TR" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$(center_pad "System" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$(center_pad "Host   : ${host}" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$(center_pad "OS     : ${os}" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$(center_pad "Kernel : ${kernel}" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_V" "$(center_pad "User   : ${user}" "$w")" "$B_V" "$C_RESET"
    printf '  %s%s%s%s%s\n' "$C_CYAN" "$B_BL" "$(rep "$B_H" "$w")" "$B_BR" "$C_RESET"
    printf '\n'
}

client_gate() {
    # Ask for the client name to justify elevated (sudo) usage.
    # Empty / cancelled -> exit; filled -> proceed.
    local client
    printf '\n'
    printf '  %s\n' "${C_YELLOW}Some actions require elevated privileges (sudo).${C_RESET}"
    printf '  %s\n' "${C_DIM}Please identify the client this session is for.${C_RESET}"
    printf '  %s' "${C_BOLD}Client:${C_RESET} "
    read -r client || { printf '\n'; return 1; }
    client="$(printf '%s' "$client" | tr -d '[:space:]')"
    if [ -z "$client" ]; then
        printf '\n'
        warn "No client provided. Exiting."
        return 1
    fi
    CLIENT_NAME="$client"
    log_event "Session started for client: ${client}"
    ok "Welcome, ${C_BOLD}${client}${C_RESET}."
    printf '\n'
    return 0
}

status_of() {
    local installed="$1" lv="$2" rv="$3"
    if [ "$installed" = 0 ]; then
        printf '%s' "not installed"
    elif [ "$rv" != "unknown" ] && [ -n "$rv" ] && [ "$lv" != "$rv" ]; then
        printf '%s' "update available"
    else
        printf '%s' "up to date"
    fi
}

status_color() {
    case "$1" in
        "not installed")     printf '%s' "$C_DIM" ;;
        "update available")  printf '%s' "$C_YELLOW" ;;
        *)                   printf '%s' "$C_GREEN" ;;
    esac
}

load_scripts() {
    local names tmpf name lv rv info desc installed
    names="$(fetch_script_list)" || { err "Could not reach the repository."; return 1; }
    [ -n "$names" ] || { warn "No scripts found in the repository."; SCRIPT_COUNT=0; return 0; }

    tmpf="$(mktemp)"
    (
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            lv="$(local_version "$name")"
            if is_installed "$name"; then installed=1; else installed=0; fi
            info="$(remote_info "$name")"
            rv="${info%%|*}"; desc="${info#*|}"
            printf '%s|%s|%s|%s|%s\n' "$name" "$lv" "$rv" "$installed" "$desc"
        done <<< "$names"
    ) > "$tmpf" &
    local pid=$!
    if [ "$TTY" = 1 ]; then _spin "$pid" "Loading scripts ..."; fi
    wait "$pid"

    SCRIPTS_ARR=(); ARR_LOCAL=(); ARR_REMOTE=(); ARR_INSTALLED=(); ARR_DESC=()
    while IFS='|' read -r name lv rv installed desc; do
        [ -n "$name" ] || continue
        SCRIPTS_ARR+=("$name")
        ARR_LOCAL+=("$lv")
        ARR_REMOTE+=("$rv")
        ARR_INSTALLED+=("$installed")
        ARR_DESC+=("$desc")
    done < "$tmpf"
    rm -f "$tmpf"

    SCRIPT_COUNT=${#SCRIPTS_ARR[@]}
}

print_table() {
    local sel="${1:-0}" i lv rv installed desc st stc
    local W_NUM=4 W_NAME=24 W_LOCAL=8 W_REMOTE=8 W_STATUS=16 W_DESC=72

    printf '  %*s %-*s %-*s %-*s %-*s\n' \
        "$W_NUM" "#" "$W_NAME" "SCRIPT" "$W_LOCAL" "LOCAL" "$W_REMOTE" "REMOTE" "$W_STATUS" "STATUS"
    printf '  %*s %-*s %-*s %-*s %-*s\n' \
        "$W_NUM" "---" "$W_NAME" "------------------------" "$W_LOCAL" "--------" "$W_REMOTE" "--------" "$W_STATUS" "----------------"

    for ((i=1; i<=SCRIPT_COUNT; i++)); do
        lv="${ARR_LOCAL[$i-1]}"
        rv="${ARR_REMOTE[$i-1]}"
        installed="${ARR_INSTALLED[$i-1]}"
        desc="${ARR_DESC[$i-1]}"
        st="$(status_of "$installed" "$lv" "$rv")"
        stc="$(status_color "$st")"

        # Cursor (1 char) + space + right-aligned number (2 chars) => fixed 4 chars, ASCII only
        local cur numtxt numcol
        if [ "$sel" = "$i" ]; then
            cur=">"; numcol="$C_CYAN"
        else
            cur=" "; numcol="$C_DIM"
        fi
        numtxt="$(printf '%2d' "$i")"

        printf '  %s%s %s%s%s %s%-*s%s %-*s %-*s %s%-*s%s\n' \
            "$numcol" "$cur" "$numcol" "$numtxt" "$C_RESET" \
            "$C_BOLD" "$W_NAME" "${SCRIPTS_ARR[$i-1]}" "$C_RESET" \
            "$W_LOCAL" "${lv:--}" \
            "$W_REMOTE" "${rv:--}" \
            "$stc" "$W_STATUS" "$st" "$C_RESET"

        if [ -n "$desc" ]; then
            printf '%s\n' "$desc" | fold -s -w "$W_DESC" | sed 's/^/         /'
        fi
    done
}

# -----------------------------------------------------------------------------
# Interactive menu
# -----------------------------------------------------------------------------
read_key() {
    local k k2
    IFS= read -rsn1 k 2>/dev/null || { echo "ESC"; return; }
    if [ "$k" = $'\033' ]; then
        IFS= read -rsn2 k2 2>/dev/null || true
        case "$k2" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            '') echo "ESC" ;;
            *) echo "$k$k2" ;;
        esac
        return
    fi
    if [ "$k" = "" ]; then echo "ENTER"; else echo "$k"; fi
}

render_menu() {
    local sel="${1:-1}"
    printf '\033[2J\033[H'
    print_header
    print_table "$sel"
    printf '\n'
    printf '  %s%s%s\n' "$C_CYAN" "↑/↓ navigate   Enter run   a update all   r remove   l reload   q quit" "$C_RESET"
    printf '  %s' "${C_BOLD}>${C_RESET} "
}

# After running an action, wait for the user to go back to the menu without
# immediately re-rendering the header/table (keeps the action output on screen).
back_to_menu() {
    printf '\n'
    printf '  %s\n' "${C_DIM}────────────────────────────────────────────────────────${C_RESET}"
    printf '  %s' "${C_BOLD}Press Enter to return to the menu${C_RESET} "
    read -r _
}

arrow_menu() {
    local sel=1 key
    while true; do
        render_menu "$sel"
        key="$(read_key)"
        case "$key" in
            UP)   sel=$(( sel > 1 ? sel - 1 : SCRIPT_COUNT )) ;;
            DOWN) sel=$(( sel < SCRIPT_COUNT ? sel + 1 : 1 )) ;;
            ENTER)
                printf '\n'
                run_script "$(script_at "$sel")"
                load_scripts
                sel=1
                back_to_menu
                ;;
            a|A) printf '\n'; menu_update_all; load_scripts; back_to_menu ;;
            r|R) printf '\n'; do_remove "$(script_at "$sel")"; load_scripts; back_to_menu ;;
            l|L) load_scripts ;;
            q|Q|ESC) return 1 ;;
        esac
    done
}

gum_menu() {
    local choice opts=() opt
    for opt in "${SCRIPTS_ARR[@]}"; do opts+=("$opt"); done
    opts+=("Update all installed" "Remove a script" "Quit")

    while true; do
        choice="$(printf '%s\n' "${opts[@]}" | gum choose --height 15 --header "DevOps Utilities · select a script to run")"
        case "$choice" in
            "") return 1 ;;
            "Update all installed") menu_update_all; load_scripts; back_to_menu ;;
            "Remove a script") menu_remove_gum ;;
            "Quit") return 1 ;;
            *) printf '\n'; run_script "$choice"; load_scripts; back_to_menu ;;
        esac
    done
}

menu_update_all() {
    local name
    for name in "${SCRIPTS_ARR[@]}"; do
        is_installed "$name" && do_update "$name"
    done
    ok "Update pass completed."
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

menu_remove_gum() {
    local choice
    choice="$(printf '%s\n' "${SCRIPTS_ARR[@]}" | gum choose --height 15 --header "Select a script to remove")"
    [ -n "$choice" ] && do_remove "$choice"
}

interactive_menu() {
    system_header
    client_gate || return 1
    print_header
    self_update_check
    load_scripts || return 1
    [ "$SCRIPT_COUNT" -gt 0 ] || return 1

    if [ "$GUM" = 1 ] && [ "$TTY" = 1 ]; then
        gum_menu
    else
        arrow_menu
    fi
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
  install.sh self-update              update the manager itself
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
    list|status)   print_header; self_update_check; load_scripts; print_table ;;
    self-update)   self_update ;;
    install)       do_install "${2:-}" "${3:-}" ;;
    update)
        if [ -n "${2:-}" ]; then
            do_update "$2"
        else
            load_scripts
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
