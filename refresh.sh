#!/bin/bash
set -e

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ── Kill any previous refresh loop ──────────────────────────────────────────
if [ -f "${PID_FILE}" ]; then
    OLD_PID=$(cat "${PID_FILE}" 2>/dev/null || true)
    if [ -n "${OLD_PID}" ] && kill -0 "${OLD_PID}" 2>/dev/null; then
        echo "Stopping previous token-refresh process (PID ${OLD_PID})"
        kill "${OLD_PID}" 2>/dev/null || true
    fi
    sudo rm -f "${PID_FILE}"
fi

sudo touch "${REFRESH_LOG}" "${PID_FILE}"
sudo chmod 666 "${REFRESH_LOG}" "${PID_FILE}"

# ── Write the daemon to a standalone script ─────────────────────────────────
DAEMON_SCRIPT="${INSTALL_DIR}/token_refresh_daemon.sh"

cat << DAEMON_EOF | sudo tee "${DAEMON_SCRIPT}" > /dev/null
#!/bin/bash

# Baked-in values from config.env at generation time
CONDA_ENV="${CONDA_ENV}"
REFRESH_INTERVAL=${REFRESH_INTERVAL}
PID_FILE="${PID_FILE}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT}"
REFRESH_LOG="${REFRESH_LOG}"

echo \$\$ > "\${PID_FILE}"

get_token() {
    source /anaconda/etc/profile.d/conda.sh
    conda activate "\${CONDA_ENV}" >/dev/null 2>&1
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
" 2>/dev/null
}

while true; do
    sleep "\${REFRESH_INTERVAL}"

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Refreshing managed-identity token"

    NEW_TOKEN=\$(get_token)

    if [ -n "\${NEW_TOKEN}" ]; then
        sudo azfilesauthmanager set \\
            "https://\${STORAGE_ACCOUNT}.file.core.windows.net" "\${NEW_TOKEN}"
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Token refreshed (\${#NEW_TOKEN} chars)."
    else
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Token refresh failed."
    fi
done
DAEMON_EOF

sudo chmod +x "${DAEMON_SCRIPT}"

echo "Starting background token-refresh loop (every ${REFRESH_INTERVAL}s)"
nohup bash "${DAEMON_SCRIPT}" >> "${REFRESH_LOG}" 2>&1 &
disown

echo "Token-refresh daemon running (PID $!, interval ${REFRESH_INTERVAL}s)."
echo "Logs: ${REFRESH_LOG}"