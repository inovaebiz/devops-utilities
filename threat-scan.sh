#!/bin/bash

# ==============================================================================
# System Malware & Threat Scanner
#
# Maintainer: Inova e-Business
# Version: 1.1
#
# Purpose:
#   Perform a read-only inspection of a system looking for common indicators
#   of compromise (IoC): viruses, worms, malware, crypto miners, backdoors and
#   suspicious persistence mechanisms.
#
# Supported platforms:
#   - Linux   : systemd, cron, /etc/passwd, ss/netstat, lsmod, ClamAV
#   - macOS   : launchd/Library, dscl, lsof/netstat, kextstat, ClamAV
#   - Windows : schtasks, net user/localgroup, netstat, driverquery, ClamAV
#               (via Git Bash / MSYS2 / WSL)
#
# Scope (read-only, does NOT modify the system):
#   - Suspicious processes (crypto miners, high CPU, unusual names)
#   - Unusual network connections and listening ports
#   - Malicious or modified cron / launchd / scheduled tasks
#   - Suspicious users (new or privileged accounts)
#   - Authorized keys and SSH backdoors
#   - Suspicious files (world-writable, SUID/SGID, hidden dirs in temp paths)
#   - Known mining / malware strings in process command lines
#   - Kernel modules / drivers (rootkits)
#
# Notes:
#   - This script only REPORTS findings. It never removes or quarantines.
#   - Some checks require elevation. Run elevated for full coverage.
#   - Optional integrations: ClamAV (clamscan) and rkhunter/chkrootkit, if installed.
#
# ==============================================================================

set -uo pipefail

VERSION="1.1"
TAG="threat-scan"

FOUND_ANY=0

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
secdim() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
sec()    { printf '\033[1;35m[%s]\033[0m\n' "$*"; }
ok()     { printf '  \033[1;32m[OK]\033[0m     %s\n' "$*"; }
info()   { printf '  \033[1;34m[INFO]\033[0m   %s\n' "$*"; }
warn()   { printf '  \033[1;33m[SUSPECT]\033[0m %s\n' "$*"; FOUND_ANY=1; }
err()    { printf '  \033[1;31m[ALERT]\033[0m  %s\n' "$*"; FOUND_ANY=1; }

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
# Header
# -----------------------------------------------------------------------------
printf '\n'
printf '  %s\n' '============================================================'
printf '  %s\n' '  SYSTEM MALWARE & THREAT SCANNER'
printf '  %s\n' '  Maintainer: Inova e-Business'
printf '  %s\n' "  Version: $VERSION"
printf '  %s\n' "  Platform: $OS_NAME"
printf '  %s\n' '============================================================'
printf '\n'

# -----------------------------------------------------------------------------
# Process listing helpers (per platform)
# -----------------------------------------------------------------------------
case "$OS_NAME" in
    Linux|Windows)
        PS_ALL="ps -eo pid,user,%cpu,%mem,cmd"
        PS_TOP="ps -eo pid,user,%cpu,%mem,cmd --sort=-%cpu"
        ;;
    macOS)
        PS_ALL="ps -axo pid,user,%cpu,%mem,command"
        PS_TOP="ps -axo pid,user,%cpu,%mem,command -r"
        ;;
esac

# Listing ports
list_listening() {
    case "$OS_NAME" in
        Linux)
            if command -v ss >/dev/null 2>&1; then
                ss -tulnp 2>/dev/null | sed 's/^/      /'
            elif command -v netstat >/dev/null 2>&1; then
                netstat -tulnp 2>/dev/null | sed 's/^/      /'
            else
                warn "Neither ss nor netstat found; skipping listening ports."
            fi
            ;;
        macOS)
            if command -v lsof >/dev/null 2>&1; then
                lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | sed 's/^/      /'
                lsof -nP -iUDP 2>/dev/null | sed 's/^/      /'
            elif command -v netstat >/dev/null 2>&1; then
                netstat -anv -p tcp 2>/dev/null | grep -i LISTEN | sed 's/^/      /'
            else
                warn "Neither lsof nor netstat found; skipping listening ports."
            fi
            ;;
        Windows)
            netstat -ano 2>/dev/null | grep -Ei 'LISTENING' | sed 's/^/      /' \
                || warn "netstat not available; skipping listening ports."
            ;;
    esac
}

list_established() {
    case "$OS_NAME" in
        Linux)
            if command -v ss >/dev/null 2>&1; then
                ss -tnp state established 2>/dev/null | sed 's/^/      /'
            elif command -v netstat >/dev/null 2>&1; then
                netstat -tnp 2>/dev/null | grep ESTABLISHED | sed 's/^/      /'
            fi
            ;;
        macOS)
            if command -v lsof >/dev/null 2>&1; then
                lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null | sed 's/^/      /'
            elif command -v netstat >/dev/null 2>&1; then
                netstat -anv -p tcp 2>/dev/null | grep -i ESTABLISHED | sed 's/^/      /'
            fi
            ;;
        Windows)
            netstat -ano 2>/dev/null | grep -Ei 'ESTABLISHED' | sed 's/^/      /' || true
            ;;
    esac
}

find_hosts_file() {
    local f
    for f in /etc/hosts "/c/Windows/System32/drivers/etc/hosts" "$SYSTEMROOT/System32/drivers/etc/hosts"; do
        if [ -r "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

# =============================================================================
# 1. PROCESSES
# =============================================================================
secdim "1. Process inspection"

info "Scanning running processes for crypto-miner indicators..."
MINER_PATTERNS='xmrig|minerd|cpuminer|ccminer|ethminer|claymore|kdevtmpfsi|kinsing|kthreaddk|solr|zeph|dero|monero|t-rex|phoenixminer|nbminer|gminer|lolminer|rigel'
MINER_HITS="$($PS_ALL 2>/dev/null | grep -Ei "$MINER_PATTERNS" | grep -v grep || true)"
if [ -n "$MINER_HITS" ]; then
    err "Possible crypto-miner processes detected:"
    printf '%s\n' "$MINER_HITS" | sed 's/^/      /'
else
    ok "No known miner process signatures found."
fi

info "Listing top CPU processes (anomaly check)..."
$PS_TOP 2>/dev/null | head -n 8 | sed 's/^/      /'

info "Checking for processes running from suspicious locations (/tmp, /dev/shm, /var/tmp)..."
SUSP_PROC="$($PS_ALL 2>/dev/null | grep -Ei '(/tmp/|/dev/shm/|/var/tmp/|/var/tmp/)' | grep -v grep || true)"
if [ -n "$SUSP_PROC" ]; then
    warn "Processes executing from world-writable dirs:"
    printf '%s\n' "$SUSP_PROC" | sed 's/^/      /'
else
    ok "No processes running from /tmp, /dev/shm or /var/tmp."
fi

# =============================================================================
# 2. NETWORK
# =============================================================================
secdim "2. Network inspection"

info "Listening ports (TCP/UDP)..."
list_listening

info "Active outbound connections (check for suspicious endpoints)..."
list_established

info "Checking hosts file for suspicious entries..."
if HOSTS_FILE="$(find_hosts_file)"; then
    HOSTS_SUSP="$(grep -Eiv '^#|^$|localhost|broadcasthost|::1|127\.0\.0\.1' "$HOSTS_FILE" || true)"
    if [ -n "$HOSTS_SUSP" ]; then
        warn "Non-default entries in $HOSTS_FILE:"
        printf '%s\n' "$HOSTS_SUSP" | sed 's/^/      /'
    else
        ok "$HOSTS_FILE looks clean."
    fi
fi

if [ "$OS_NAME" != "Windows" ] && [ -r /etc/resolv.conf ]; then
    info "Checking /etc/resolv.conf for suspicious nameservers..."
    grep -E '^nameserver' /etc/resolv.conf | sed 's/^/      /' || true
fi

# =============================================================================
# 3. PERSISTENCE
# =============================================================================
secdim "3. Persistence mechanisms"

case "$OS_NAME" in
    Linux)
        info "User crontabs..."
        for u in /var/spool/cron/crontabs/* /var/spool/cron/*; do
            [ -f "$u" ] || continue
            echo "      --- $u ---"
            sed 's/^/      /' "$u" 2>/dev/null
        done

        info "System crontab entries (/etc/crontab, /etc/cron.d/*)..."
        [ -f /etc/crontab ] && grep -Ev '^#|^$' /etc/crontab | sed 's/^/      /'
        for f in /etc/cron.d/*; do
            [ -f "$f" ] || continue
            echo "      --- $f ---"
            grep -Ev '^#|^$' "$f" 2>/dev/null | sed 's/^/      /'
        done

        info "Cron daily/hourly/weekly/monthly scripts..."
        for d in /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
            [ -d "$d" ] && find "$d" -maxdepth 1 -type f -exec echo "      {}" \;
        done

        info "rc.local content..."
        [ -r /etc/rc.local ] && grep -Ev '^#|^$|^exit 0' /etc/rc.local | sed 's/^/      /' || ok "No /etc/rc.local."

        info "Systemd timers (enabled)..."
        systemctl list-timers --all --no-pager 2>/dev/null | sed 's/^/      /' || warn "systemd not available."
        ;;
    macOS)
        info "User crontabs..."
        for u in /usr/lib/cron/tabs/* /etc/crontab; do
            [ -f "$u" ] || continue
            echo "      --- $u ---"
            grep -Ev '^#|^$' "$u" 2>/dev/null | sed 's/^/      /'
        done

        info "LaunchAgents / LaunchDaemons (suspicious persistence)..."
        LAUNCHD_SUSP="$(find /Library/LaunchAgents /Library/LaunchDaemons "$HOME/Library/LaunchAgents" -maxdepth 1 -name '*.plist' -type f 2>/dev/null | grep -Ei '\.(sh|curl|wget|base64|minerd|xmrig)' || true)"
        find /Library/LaunchAgents /Library/LaunchDaemons "$HOME/Library/LaunchAgents" -maxdepth 1 -name '*.plist' -type f 2>/dev/null | sed 's/^/      /'
        if [ -n "$LAUNCHD_SUSP" ]; then
            warn "Suspicious launchd plists:"
            printf '%s\n' "$LAUNCHD_SUSP" | sed 's/^/      /'
        else
            ok "No obviously suspicious launchd jobs found."
        fi

        info "Loaded launchd jobs (top-level)..."
        launchctl list 2>/dev/null | head -n 20 | sed 's/^/      /'
        ;;
    Windows)
        info "Scheduled tasks (schtasks)..."
        if command -v schtasks >/dev/null 2>&1; then
            schtasks /query /fo csv 2>/dev/null | sed 's/^/      /' | head -n 40
        else
            schtasks.exe /query /fo csv 2>/dev/null | sed 's/^/      /' | head -n 40 || warn "schtasks not available."
        fi
        ;;
esac

# =============================================================================
# 4. USERS & ACCESS
# =============================================================================
secdim "4. User & access inspection"

case "$OS_NAME" in
    Linux)
        info "Users with UID 0 (only root should be 0)..."
        UID0="$(awk -F: '($3==0){print $1}' /etc/passwd)"
        if [ "$(echo "$UID0" | grep -v '^root$' | grep -c . || true)" -gt 0 ]; then
            err "Accounts with UID 0 besides root:"
            printf '%s\n' "$UID0" | sed 's/^/      /'
        else
            ok "Only 'root' has UID 0."
        fi

        info "Users with empty password (passwordless login risk)..."
        EMPTY_PW="$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)"
        if [ -n "$EMPTY_PW" ]; then
            err "Accounts with empty passwords:"
            printf '%s\n' "$EMPTY_PW" | sed 's/^/      /'
        else
            ok "No empty-password accounts."
        fi
        ;;
    macOS)
        info "Users with UID 0 (only root should be 0)..."
        if command -v dscl >/dev/null 2>&1; then
            UID0="$(dscl . -search /Users UniqueID 0 2>/dev/null | awk '{print $1}')"
            nonroot="$(echo "$UID0" | grep -v '^root$' | grep -c . || true)"
            if [ "$nonroot" -gt 0 ]; then
                err "Accounts with UID 0 besides root:"
                printf '%s\n' "$UID0" | sed 's/^/      /'
            else
                ok "Only 'root' has UID 0."
            fi
        else
            warn "dscl not available."
        fi
        ;;
    Windows)
        info "Local Administrators group:"
        (net localgroup Administrators 2>/dev/null || net.exe localgroup Administrators 2>/dev/null) | sed 's/^/      /'
        ;;
esac

info "SSH authorized_keys files (backdoor check)..."
AUTHKEYS_SUSP=""
for k in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys "$HOME/.ssh/authorized_keys"; do
    [ -f "$k" ] || continue
    echo "      --- $k ---"
    awk '{print "      key for "$NF}' "$k" 2>/dev/null
    if grep -Ei 'command=.*(curl|wget|/tmp/)|no-user-rc.*command' "$k" >/dev/null 2>&1; then
        AUTHKEYS_SUSP="$AUTHKEYS_SUSP $k"
    fi
done
if [ -n "$AUTHKEYS_SUSP" ]; then
    warn "Possibly restricted/backdoor authorized_keys:"
    printf '      %s\n' $AUTHKEYS_SUSP
fi

case "$OS_NAME" in
    Linux)
        info "Users with shell access..."
        grep -E '(/bash|/sh|/zsh)$' /etc/passwd 2>/dev/null | awk -F: '{print "      "$1" ("$7")"}' || true
        ;;
    macOS)
        info "Users with a login shell..."
        if command -v dscl >/dev/null 2>&1; then
            dscl . -list /Users UserShell 2>/dev/null \
                | grep -E '(/bin/bash|/bin/zsh|/bin/csh|/usr/bin/zsh)$' \
                | sed 's/^/      /' || true
        fi
        ;;
esac

# =============================================================================
# 5. FILES & PERMISSIONS
# =============================================================================
secdim "5. Filesystem inspection"

case "$OS_NAME" in
    Windows)
        ok "NTFS ACL checks skipped (run a Windows-native scanner for full coverage)."
        ;;
    *)
        info "World-writable files in system dirs (potential backdoors)..."
        if [ "$(id -u)" -eq 0 ]; then
            find /etc /usr/local /var/spool "${TMPDIR:-/tmp}" -type f -perm -002 ! -path '*/proc/*' 2>/dev/null | head -n 50 | sed 's/^/      /'
        else
            info "Skipped (requires root)."
        fi

        info "SUID/SGID binaries (look for unusual entries)..."
        if [ "$(id -u)" -eq 0 ]; then
            find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -n 100 | sed 's/^/      /'
        else
            info "Skipped (requires root)."
        fi

        info "Hidden files/dirs in /tmp, /dev/shm, /var/tmp..."
        find /tmp /dev/shm /var/tmp -maxdepth 2 -name '.*' 2>/dev/null | head -n 50 | sed 's/^/      /'

        info "Executable files in /tmp and /dev/shm..."
        if [ "$OS_NAME" = "macOS" ]; then
            find /tmp /dev/shm -maxdepth 2 -type f -perm -0111 2>/dev/null | head -n 50 | sed 's/^/      /'
        else
            find /tmp /dev/shm -maxdepth 2 -type f -executable 2>/dev/null | head -n 50 | sed 's/^/      /'
        fi

        info "Files modified in the last 24h in /etc, /usr/local/bin, /usr/local/sbin..."
        find /etc /usr/local/bin /usr/local/sbin -type f -mtime -1 2>/dev/null | head -n 50 | sed 's/^/      /'
        ;;
esac

# =============================================================================
# 6. KERNEL MODULES & ROOTKITS
# =============================================================================
secdim "6. Kernel & rootkit inspection"

case "$OS_NAME" in
    Linux)
        info "Loaded kernel modules..."
        lsmod 2>/dev/null | sed 's/^/      /' | head -n 50

        info "Recently loaded module files (24h)..."
        find /lib/modules/$(uname -r) -type f -mtime -1 2>/dev/null | head -n 30 | sed 's/^/      /'
        ;;
    macOS)
        info "Loaded kernel extensions (kextstat)..."
        kextstat 2>/dev/null | sed 's/^/      /' | head -n 50
        ;;
    Windows)
        info "Loaded kernel drivers (driverquery)..."
        (driverquery /v 2>/dev/null || driverquery.exe /v 2>/dev/null) | sed 's/^/      /' | head -n 40
        ;;
esac

if [ "$OS_NAME" = "Linux" ]; then
    if command -v chkrootkit >/dev/null 2>&1; then
        info "chkrootkit is installed; consider running it for deeper rootkit checks."
    elif command -v rkhunter >/dev/null 2>&1; then
        info "rkhunter is installed; consider running it for deeper rootkit checks."
    else
        info "Neither chkrootkit nor rkhunter installed (optional deep scan)."
    fi
fi

# =============================================================================
# 7. OPTIONAL CLAMAV
# =============================================================================
secdim "7. Antivirus (optional)"

case "$OS_NAME" in
    Linux)
        CLAM_DIRS="/tmp /var/tmp"
        CLAM_HINT="apt install clamav (Ubuntu/Debian) or dnf install clamav (RHEL/Fedora)"
        ;;
    macOS)
        CLAM_DIRS="/tmp /var/tmp"
        CLAM_HINT="brew install clamav"
        ;;
    Windows)
        CLAM_DIRS="${TMP:-$TEMP}"
        CLAM_HINT="install ClamAV from https://www.clamav.net/downloads"
        ;;
esac

if command -v clamscan >/dev/null 2>&1; then
    info "ClamAV found. Running quick scan (read-only) of: $CLAM_DIRS"
    if [ "$TTY" = 1 ]; then
        # shellcheck disable=SC2086
        clamscan -ri --no-summary $CLAM_DIRS > "${TMPDIR:-/tmp}/threat-scan-clam.log" 2>/dev/null &
        CLAM_PID=$!
        _spin "$CLAM_PID" "Scanning with ClamAV ..."
        wait "$CLAM_PID"
        sed 's/^/      /' "${TMPDIR:-/tmp}/threat-scan-clam.log"
        rm -f "${TMPDIR:-/tmp}/threat-scan-clam.log"
    else
        # shellcheck disable=SC2086
        clamscan -ri --no-summary $CLAM_DIRS 2>/dev/null | sed 's/^/      /'
    fi
else
    info "ClamAV not installed. Install with: $CLAM_HINT"
fi

# =============================================================================
# SUMMARY
# =============================================================================
printf '\n'
printf '  %s\n' '============================================================'
if [ "$FOUND_ANY" -eq 1 ]; then
    err "Review the items marked [SUSPECT] or [ALERT] above."
else
    ok "No obvious indicators of compromise detected."
fi
printf '  %s\n' '============================================================'
printf '\n'
printf '  %s\n' "Scan completed. Platform: $OS_NAME. Maintainer: Inova e-Business (read-only scan)"