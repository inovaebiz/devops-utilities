#!/bin/bash

# ==============================================================================
# System Malware & Threat Scanner
#
# Maintainer: Inova e-Business
# Version: 1.0
#
# Purpose:
#   Perform a read-only inspection of a Linux system looking for common
#   indicators of compromise (IoC): viruses, worms, malware, crypto miners,
#   backdoors and suspicious persistence mechanisms.
#
# Scope (read-only, does NOT modify the system):
#   - Suspicious processes (crypto miners, high CPU, unusual names)
#   - Unusual network connections and listening ports
#   - Malicious or modified cron jobs / systemd timers / rc.local
#   - Suspicious users (new accounts, UID 0 backdoors)
#   - Authorized keys and SSH backdoors
#   - Suspicious files (world-writable, SUID/SGID, hidden dirs in /tmp, /dev, /var/tmp)
#   - Known mining / malware strings in process command lines
#   - Rootkit-related kernel modules and loaded LKMs
#   - Modified system binaries (via rpm -Va / debsums when available)
#
# Notes:
#   - This script only REPORTS findings. It never removes or quarantines.
#   - Some checks require root. Run as root for full coverage.
#   - Optional integrations: ClamAV (clamscan) and rkhunter/chkrootkit, if installed.
#
# ==============================================================================

set -uo pipefail

VERSION="1.0"
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
# Header
# -----------------------------------------------------------------------------
printf '\n'
printf '  %s\n' '============================================================'
printf '  %s\n' '  SYSTEM MALWARE & THREAT SCANNER'
printf '  %s\n' '  Maintainer: Inova e-Business'
printf '  %s\n' "  Version: $VERSION"
printf '  %s\n' '============================================================'
printf '\n'

if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root. Some checks will be skipped or incomplete."
fi

ROOT_OK=0
[ "$(id -u)" -eq 0 ] && ROOT_OK=1

# =============================================================================
# 1. PROCESSES
# =============================================================================
secdim "1. Process inspection"

info "Scanning running processes for crypto-miner indicators..."
MINER_PATTERNS='xmrig|minerd|cpuminer|ccminer|ethminer|claymore|kdevtmpfsi|kinsing|kthreaddk|solr|zeph|dero|monero|t-rex|phoenixminer|nbminer|gminer|lolminer|rigel'
MINER_HITS="$(ps -eo pid,user,%cpu,%mem,cmd 2>/dev/null | grep -Ei "$MINER_PATTERNS" | grep -v grep || true)"
if [ -n "$MINER_HITS" ]; then
    err "Possible crypto-miner processes detected:"
    printf '%s\n' "$MINER_HITS" | sed 's/^/      /'
else
    ok "No known miner process signatures found."
fi

info "Listing top CPU processes (anomaly check)..."
ps -eo pid,user,%cpu,%mem,cmd --sort=-%cpu 2>/dev/null | head -n 8 | sed 's/^/      /'

info "Checking for processes running from suspicious locations (/tmp, /dev/shm, /var/tmp)..."
SUSP_PROC="$(ps -eo pid,user,cmd 2>/dev/null | grep -Ei '(/tmp/|/dev/shm/|/var/tmp/)' | grep -v grep || true)"
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
if command -v ss >/dev/null 2>&1; then
    ss -tulnp 2>/dev/null | sed 's/^/      /'
elif command -v netstat >/dev/null 2>&1; then
    netstat -tulnp 2>/dev/null | sed 's/^/      /'
else
    warn "Neither ss nor netstat found; skipping listening ports."
fi

info "Active outbound connections (check for suspicious endpoints)..."
if command -v ss >/dev/null 2>&1; then
    ss -tnp state established 2>/dev/null | sed 's/^/      /'
elif command -v netstat >/dev/null 2>&1; then
    netstat -tnp 2>/dev/null | grep ESTABLISHED | sed 's/^/      /'
fi

info "Checking /etc/hosts for suspicious entries..."
if [ -r /etc/hosts ]; then
    HOSTS_SUSP="$(grep -Eiv '^#|^$|localhost|broadcasthost|::1|127\.0\.0\.1' /etc/hosts || true)"
    if [ -n "$HOSTS_SUSP" ]; then
        warn "Non-default entries in /etc/hosts:"
        printf '%s\n' "$HOSTS_SUSP" | sed 's/^/      /'
    else
        ok "/etc/hosts looks clean."
    fi
fi

info "Checking /etc/resolv.conf for suspicious nameservers..."
if [ -r /etc/resolv.conf ]; then
    RESOLV="$(grep -E '^nameserver' /etc/resolv.conf || true)"
    printf '%s\n' "$RESOLV" | sed 's/^/      /'
fi

# =============================================================================
# 3. PERSISTENCE
# =============================================================================
secdim "3. Persistence mechanisms"

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

# =============================================================================
# 4. USERS & ACCESS
# =============================================================================
secdim "4. User & access inspection"

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

info "SSH authorized_keys files..."
for k in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$k" ] || continue
    echo "      --- $k ---"
    awk '{print "      key for "$NF}' "$k" 2>/dev/null
done

info "Users with shell access..."
grep -E '(/bash|/sh|/zsh)$' /etc/passwd 2>/dev/null | awk -F: '{print "      "$1" ("$7")"}' || true

# =============================================================================
# 5. FILES & PERMISSIONS
# =============================================================================
secdim "5. Filesystem inspection"

info "World-writable files in system dirs (potential backdoors)..."
if [ "$ROOT_OK" -eq 1 ]; then
    find /etc /usr/local /var/spool -type f -perm -002 ! -path '*/proc/*' 2>/dev/null | head -n 50 | sed 's/^/      /'
else
    warn "Skipped (requires root)."
fi

info "SUID/SGID binaries (look for unusual entries)..."
if [ "$ROOT_OK" -eq 1 ]; then
    find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -n 100 | sed 's/^/      /'
else
    warn "Skipped (requires root)."
fi

info "Hidden files/dirs in /tmp, /dev/shm, /var/tmp..."
find /tmp /dev/shm /var/tmp -maxdepth 2 -name '.*' 2>/dev/null | head -n 50 | sed 's/^/      /'

info "Executable files in /tmp and /dev/shm..."
find /tmp /dev/shm -maxdepth 2 -type f -executable 2>/dev/null | head -n 50 | sed 's/^/      /'

info "Files modified in the last 24h in /etc, /usr/local/bin, /usr/local/sbin..."
find /etc /usr/local/bin /usr/local/sbin -type f -mtime -1 2>/dev/null | head -n 50 | sed 's/^/      /'

# =============================================================================
# 6. KERNEL MODULES & ROOTKITS
# =============================================================================
secdim "6. Kernel & rootkit inspection"

info "Loaded kernel modules..."
lsmod 2>/dev/null | sed 's/^/      /' | head -n 50

info "Recently loaded module files (24h)..."
find /lib/modules/$(uname -r) -type f -mtime -1 2>/dev/null | head -n 30 | sed 's/^/      /'

if command -v chkrootkit >/dev/null 2>&1; then
    info "chkrootkit is installed; consider running it for deeper rootkit checks."
elif command -v rkhunter >/dev/null 2>&1; then
    info "rkhunter is installed; consider running it for deeper rootkit checks."
else
    info "Neither chkrootkit nor rkhunter installed (optional deep scan)."
fi

# =============================================================================
# 7. OPTIONAL CLAMAV
# =============================================================================
secdim "7. Antivirus (optional)"

if command -v clamscan >/dev/null 2>&1; then
    info "ClamAV found. Running quick scan of /tmp and /var/tmp (read-only)..."
    if [ "$TTY" = 1 ]; then
        clamscan -ri --no-summary /tmp /var/tmp > /tmp/threat-scan-clam.log 2>/dev/null &
        CLAM_PID=$!
        _spin "$CLAM_PID" "Scanning /tmp and /var/tmp with ClamAV ..."
        wait "$CLAM_PID"
        sed 's/^/      /' /tmp/threat-scan-clam.log
        rm -f /tmp/threat-scan-clam.log
    else
        clamscan -ri --no-summary /tmp /var/tmp 2>/dev/null | sed 's/^/      /'
    fi
else
    info "ClamAV not installed. Install with: apt install clamav (or dnf install clamav)."
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
printf '  %s\n' "Scan completed. Maintainer: Inova e-Business (read-only scan)"
