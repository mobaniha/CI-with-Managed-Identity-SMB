#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ── Validate configuration ──────────────────────────────────────────────────
if [ -z "${STORAGE_ACCOUNT}" ]; then
    echo "ERROR: STORAGE_ACCOUNT is not set in config.env." >&2
    exit 1
fi

if [ "${INSTANCE_TYPE}" = "AFH" ]; then
    if [ -z "${SHARE_NAMES}" ]; then
        echo "ERROR: SHARE_NAMES must be set in config.env for AFH mode." >&2
        exit 1
    fi
    echo "Config OK — AFH mode with shares: ${SHARE_NAMES}"
else
    if [ -z "${SHARE_NAME}" ]; then
        echo "ERROR: SHARE_NAME must be set in config.env for AML mode." >&2
        exit 1
    fi
    echo "Config OK — AML mode with share: ${SHARE_NAME}"
fi

# ── If running from a mounted path, copy everything and re-launch locally ───
if [ "${SCRIPT_DIR}" != "${INSTALL_DIR}" ]; then
    echo "=== Copying scripts to ${INSTALL_DIR} ==="
    sudo mkdir -p "${INSTALL_DIR}"
    sudo cp -f "${SCRIPT_DIR}/config.env"   "${INSTALL_DIR}/config.env"
    sudo cp -f "${SCRIPT_DIR}/install.sh"   "${INSTALL_DIR}/install.sh"
    sudo cp -f "${SCRIPT_DIR}/mount.sh"     "${INSTALL_DIR}/mount.sh"
    sudo cp -f "${SCRIPT_DIR}/mount-afh.sh" "${INSTALL_DIR}/mount-afh.sh"
    sudo cp -f "${SCRIPT_DIR}/refresh.sh"   "${INSTALL_DIR}/refresh.sh"
    sudo cp -f "${SCRIPT_DIR}/setup.sh"     "${INSTALL_DIR}/setup.sh"
    sudo chmod +x "${INSTALL_DIR}"/*.sh

    echo "=== Re-launching setup from ${INSTALL_DIR} ==="
    exec bash "${INSTALL_DIR}/setup.sh"
fi

# ── From here, we are running from /opt/azfiles/ ────────────────────────────

echo "=== Phase 1: Install packages (one-time) ==="
bash "${INSTALL_DIR}/install.sh"

echo "=== Phase 2: Register systemd service ==="

# Select the mount script based on instance type
if [ "${INSTANCE_TYPE}" = "AFH" ]; then
    MOUNT_SCRIPT="${INSTALL_DIR}/mount-afh.sh"
else
    MOUNT_SCRIPT="${INSTALL_DIR}/mount.sh"
fi
echo "Using mount script: ${MOUNT_SCRIPT}"

sudo tee /etc/systemd/system/azfiles-mount.service > /dev/null << UNIT_EOF
[Unit]
Description=Azure Files Kerberos mount and token refresh
After=multi-user.target
Wants=multi-user.target

[Service]
Type=forking
User=azureuser
Group=azureuser
EnvironmentFile=/etc/default/azfiles
ExecStartPre=/bin/sleep 75
ExecStart=${MOUNT_SCRIPT}
TimeoutStartSec=300
Restart=on-failure
RestartSec=60
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Persist identity-related environment variables for systemd
{
    echo "DEFAULT_IDENTITY_CLIENT_ID=${DEFAULT_IDENTITY_CLIENT_ID}"
    echo "MSI_ENDPOINT=${MSI_ENDPOINT}"
    echo "MSI_SECRET=${MSI_SECRET}"
    echo "OBO_ENDPOINT=${OBO_ENDPOINT}"
    echo "HOME=/home/azureuser"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/anaconda/bin:/anaconda/condabin"
} | sudo tee /etc/default/azfiles > /dev/null

echo "=== Saved environment ==="
cat /etc/default/azfiles

# Allow azureuser to run privileged commands without password
sudo tee /etc/sudoers.d/azfiles > /dev/null << 'SUDOERS_EOF'
azureuser ALL=(ALL) NOPASSWD: /usr/bin/mount, /usr/bin/umount, /usr/bin/azfilesauthmanager, /usr/bin/mkdir, /usr/bin/tee, /usr/bin/touch, /usr/bin/chmod, /usr/bin/rm
SUDOERS_EOF
sudo chmod 440 /etc/sudoers.d/azfiles

sudo systemctl daemon-reload
sudo systemctl enable azfiles-mount.service

echo "=== Phase 3: Start the service now ==="
sudo systemctl stop azfiles-mount.service 2>/dev/null || true
sudo systemctl start azfiles-mount.service

echo "=== Setup complete ==="
echo "The service will auto-start on every boot."
echo "Check status:  sudo systemctl status azfiles-mount.service"
echo "Check logs:    sudo journalctl -u azfiles-mount.service"
echo "Refresh logs:  cat ${REFRESH_LOG}"
