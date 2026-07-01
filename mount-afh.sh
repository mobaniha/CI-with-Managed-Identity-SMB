#!/bin/bash
set -e

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

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

# ── Function: remount a single path with managed-identity auth ──────────────
# Usage: do_mount <mount_path> <share_name>
do_mount() {
    local MOUNT_PATH="$1"
    local MNT_SHARE="$2"

    echo ""
    echo "=========================================="
    echo "Processing mount path: ${MOUNT_PATH}"
    echo "  Share: ${MNT_SHARE}"
    echo "  Storage account: ${STORAGE_ACCOUNT}"
    echo "=========================================="

    # ── Set token with azfilesauthmanager ────────────────────────────────
    echo "Setting token via azfilesauthmanager"
    sudo azfilesauthmanager set \
        "https://${STORAGE_ACCOUNT}.file.core.windows.net" "${TOKEN}"

    # ── Unmount ALL layers on the path ──────────────────────────────────
    echo "Checking for existing mounts on ${MOUNT_PATH} ..."

    # Handle stale fuse mounts ("Transport endpoint is not connected"):
    # mountpoint -q returns false for these, but the path is still in the
    # mount table and any access fails with ENOTCONN.
    if ! stat "${MOUNT_PATH}" >/dev/null 2>&1 && findmnt "${MOUNT_PATH}" >/dev/null 2>&1; then
        echo "Detected stale mount at ${MOUNT_PATH}, force unmounting ..."
        sudo umount -fl "${MOUNT_PATH}" 2>/dev/null || true
        sleep 2
    fi

    local UNMOUNT_ATTEMPTS=0
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

    # ── Remount via CIFS with Kerberos auth ─────────────────────────────
    echo "Mounting //${STORAGE_ACCOUNT}.file.core.windows.net/${MNT_SHARE} → ${MOUNT_PATH}"
    sudo mkdir -p "${MOUNT_PATH}"
    sudo mount -t cifs \
        "//${STORAGE_ACCOUNT}.file.core.windows.net/${MNT_SHARE}" \
        "${MOUNT_PATH}" \
        -o sec=krb5,cruid=${MOUNT_UID},dir_mode=${DIR_MODE},file_mode=${FILE_MODE},serverino,nosharesock,mfsymlinks,actimeo=30,uid=${MOUNT_UID}

    echo "Mount successful for ${MOUNT_PATH}."
}

# ── Acquire token ───────────────────────────────────────────────────────────
echo "Acquiring managed-identity token ..."
TOKEN=$(get_token)
if [ -z "${TOKEN}" ]; then
    echo "ERROR: Failed to acquire token." >&2
    exit 1
fi
echo "Token acquired (${#TOKEN} chars)."

# ── Route based on INSTANCE_TYPE ────────────────────────────────────────────
if [ "${INSTANCE_TYPE}" = "AFH" ]; then
    echo "Instance type: AI Foundry (AFH)"

    if [ -z "${SHARE_NAMES}" ]; then
        echo "ERROR: SHARE_NAMES is not set in config.env. Required for AFH mode." >&2
        exit 1
    fi

    # ── Validate against /afh/projects (double-check) ───────────────────
    AFH_PROJECTS_DIR="/afh/projects"
    if [ -d "${AFH_PROJECTS_DIR}" ]; then
        echo "Validating SHARE_NAMES against ${AFH_PROJECTS_DIR} ..."
        DISCOVERED_IDS=()
        for dir in "${AFH_PROJECTS_DIR}"/*/; do
            [ -d "${dir}" ] || continue
            DISCOVERED_IDS+=("$(basename "${dir}")")
        done

        for CURRENT_SHARE in ${SHARE_NAMES}; do
            WORKSPACE_ID="${CURRENT_SHARE%-code}"
            FOUND=false
            for did in "${DISCOVERED_IDS[@]}"; do
                if [[ "${did}" == *"${WORKSPACE_ID}"* ]]; then
                    FOUND=true
                    break
                fi
            done
            if [ "${FOUND}" = true ]; then
                echo "  ✓ Share '${CURRENT_SHARE}' matches project folder."
            else
                echo "  WARN: Share '${CURRENT_SHARE}' (workspace ID '${WORKSPACE_ID}') not found under ${AFH_PROJECTS_DIR}."
            fi
        done
    else
        echo "WARN: ${AFH_PROJECTS_DIR} not found — skipping discovery validation."
    fi

    # ── Process each share ──────────────────────────────────────────────
    for CURRENT_SHARE in ${SHARE_NAMES}; do
        echo ""
        echo "--- Processing share: ${CURRENT_SHARE} ---"

        # Extract workspace ID by stripping the trailing "-code" suffix
        WORKSPACE_ID="${CURRENT_SHARE%-code}"

        if [ "${WORKSPACE_ID}" = "${CURRENT_SHARE}" ]; then
            echo "WARN: Share '${CURRENT_SHARE}' does not end with '-code'. Using full name as search key."
        fi

        # Find all fuse mount paths that contain this workspace ID
        MOUNT_PATHS=()
        while IFS= read -r line; do
            MPATH=$(echo "${line}" | awk '{print $1}')
            [ -n "${MPATH}" ] && MOUNT_PATHS+=("${MPATH}")
        done < <(findmnt --raw --noheadings | grep fuse | grep "${WORKSPACE_ID}" || true)

        if [ ${#MOUNT_PATHS[@]} -eq 0 ]; then
            echo "WARN: No fuse mounts found for workspace ID '${WORKSPACE_ID}'. Skipping."
            continue
        fi

        echo "Found ${#MOUNT_PATHS[@]} mount path(s) for share '${CURRENT_SHARE}':"
        printf '  %s\n' "${MOUNT_PATHS[@]}"

        for mp in "${MOUNT_PATHS[@]}"; do
            do_mount "${mp}" "${CURRENT_SHARE}"
        done
    done
else
    echo "Instance type: AML"

    if [ -z "${SHARE_NAME}" ]; then
        echo "ERROR: SHARE_NAME is not set in config.env. Required for AML mode." >&2
        exit 1
    fi

    HOSTNAME=$(hostname)
    MOUNT_PATH="/mnt/batch/tasks/shared/LS_root/mounts/clusters/${HOSTNAME}/code"

    do_mount "${MOUNT_PATH}" "${SHARE_NAME}"
fi

# ── Restart Jupyter so it drops the stale mount handle ──────────────────────
# The remount(s) above replace the filesystem under Jupyter's working directory.
# A long-running Jupyter process keeps a stale CIFS handle and then fails with
# "OSError: [Errno 107] Transport endpoint is not connected" on kernel start,
# nbconvert, etc. Restarting it forces a fresh handle on the new mount.
if systemctl list-unit-files | grep -q '^jupyter\.service'; then
    echo "Restarting jupyter.service to pick up the fresh mount ..."
    sudo systemctl restart jupyter.service || echo "WARN: jupyter restart failed."
else
    echo "jupyter.service not found — skipping restart."
fi

# ── Start background token-refresh daemon ───────────────────────────────────
bash "${INSTALL_DIR}/refresh.sh"