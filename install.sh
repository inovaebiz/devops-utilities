#!/bin/bash

# ==============================================================================
# DevOps Utilities - Generic Installer
#
# Maintainer: Inova e-Business
# Version: 1.0
#
# Purpose:
#   Download and install any script from the Inova e-Business DevOps Utilities
#   repository with the appropriate permissions, so it can be run from the
#   command line.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh | bash -s -- <script> [install_dir]
#
# Examples:
#   # Install docker-cleanup.sh into /usr/local/sbin
#   curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh | bash -s -- docker-cleanup.sh
#
#   # Install into a custom directory
#   curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh | bash -s -- docker-cleanup.sh /opt/scripts
#
# Notes:
#   - Requires root privileges to write into system directories.
#   - The script name must exist in the repository (a *.sh file).
# ==============================================================================

set -euo pipefail

REPO="inovaebiz/devops-utilities"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
DEFAULT_INSTALL_DIR="/usr/local/sbin"
PERMISSIONS="750"

SCRIPT_NAME="${1:-}"
INSTALL_DIR="${2:-$DEFAULT_INSTALL_DIR}"

if [ -z "$SCRIPT_NAME" ]; then
    echo "Usage: install.sh <script> [install_dir]" >&2
    echo "Example: install.sh docker-cleanup.sh" >&2
    exit 1
fi

SCRIPT_URL="${BASE_URL}/${SCRIPT_NAME}"
DEST="${INSTALL_DIR}/${SCRIPT_NAME}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this installer needs root privileges." >&2
    echo "Re-run with sudo." >&2
    exit 1
fi

echo "Downloading ${SCRIPT_URL} ..."
TMP_FILE="$(mktemp)"
curl -fsSL "${SCRIPT_URL}" -o "${TMP_FILE}"

if head -n 1 "${TMP_FILE}" | grep -q '^#!/'; then
    :
else
    echo "Error: '${SCRIPT_NAME}' does not look like an executable script." >&2
    rm -f "${TMP_FILE}"
    exit 1
fi

echo "Installing to ${DEST} (permissions ${PERMISSIONS}) ..."
install -m "${PERMISSIONS}" "${TMP_FILE}" "${DEST}"
rm -f "${TMP_FILE}"

echo "Done: ${DEST}"
