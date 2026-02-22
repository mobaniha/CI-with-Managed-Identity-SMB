#!/bin/bash
set -e

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

HOSTNAME=$(hostname)
MOUNT_PATH="/mnt/batch/tasks/shared/LS_root/mounts/clusters/${HOSTNAME}/code"

# ── Helper: acquire managed-identity token ──────────────────────────────────
get_token() {
    export HOME="${HOME:-/home/azureuser}"
    if [ -f /anaconda/etc/profile.d/conda.sh ]; then
        source /anaconda/etc/profile.d/conda.sh
    else
        echo "ERROR: conda.sh not found" >&2
        return 1
    fi
    conda activate "${CONDA_ENV}" >/dev/null 2>&1

    python3 -c "
from azure.identity import ManagedIdentityCredential
import os, sys
cid = os.environ.get('DEFAULT_IDENTITY_CLIENT_ID', '')
if not cid:
    print('ERROR: DEFAULT_IDENTITY_CLIENT_ID not set', file=sys.stderr)
    sys.exit(1)
c = ManagedIdentityCredential(client_id=cid)
t = c.get_token('https://storage.azure.com/.default')
sys.stdout.write(t.token)
"
}

# ── Acquire token ───────────────────────────────────────────────────────────
echo "Acquiring managed-identity token ..."
TOKEN=$(get_token)
if [ -z "${TOKEN}" ]; then
    echo "ERROR: Failed to acquire token." >&2
    exit 1
fi
echo "Token acquired (${#TOKEN} chars)."

# ── Set token with azfilesauthmanager ───────────────────────────────────────
echo "Setting token via azfilesauthmanager"
sudo azfilesauthmanager set \
    "https://${STORAGE_ACCOUNT}.file.core.windows.net" "${TOKEN}"

# ── Unmount ALL layers on the path ──────────────────────────────────────────
echo "Checking for existing mounts on ${MOUNT_PATH} ..."
UNMOUNT_ATTEMPTS=0
while mountpoint -q "${MOUNT_PATH}" 2>/dev/null; do
    UNMOUNT_ATTEMPTS=$((UNMOUNT_ATTEMPTS + 1))
    if [ "${UNMOUNT_ATTEMPTS}" -gt 5 ]; then
        echo "ERROR: Could not fully unmount ${MOUNT_PATH} after 5 attempts." >&2
        break
    fi
    echo "Unmounting ${MOUNT_PATH} (attempt ${UNMOUNT_ATTEMPTS}) ..."
    sudo umount -fl "${MOUNT_PATH}" || true
    sleep 2
done

if mountpoint -q "${MOUNT_PATH}" 2>/dev/null; then
    echo "WARN: Path still mounted — proceeding anyway."
else
    echo "Path fully unmounted."
fi

sleep 10

# ── Remount via CIFS with Kerberos auth ─────────────────────────────────────
echo "Mounting //${STORAGE_ACCOUNT}.file.core.windows.net/${SHARE_NAME} → ${MOUNT_PATH}"
sudo mkdir -p "${MOUNT_PATH}"
sudo mount -t cifs \
    "//${STORAGE_ACCOUNT}.file.core.windows.net/${SHARE_NAME}" \
    "${MOUNT_PATH}" \
    -o sec=krb5,cruid=${MOUNT_UID},dir_mode=${DIR_MODE},file_mode=${FILE_MODE},serverino,nosharesock,mfsymlinks,actimeo=30,uid=${MOUNT_UID}

echo "Mount successful."

# ── Start background token-refresh daemon ───────────────────────────────────
bash "${INSTALL_DIR}/refresh.sh"