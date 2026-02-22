#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

# ── If running from a mounted path, copy everything and re-launch locally ───
if [ "${SCRIPT_DIR}" != "${INSTALL_DIR}" ]; then
    echo "=== Copying scripts to ${INSTALL_DIR} ==="
    sudo mkdir -p "${INSTALL_DIR}"
    sudo cp -f "${SCRIPT_DIR}/config.env"  "${INSTALL_DIR}/config.env"
    sudo cp -f "${SCRIPT_DIR}/install.sh"  "${INSTALL_DIR}/install.sh"
    sudo cp -f "${SCRIPT_DIR}/mount.sh"    "${INSTALL_DIR}/mount.sh"
    sudo cp -f "${SCRIPT_DIR}/refresh.sh"  "${INSTALL_DIR}/refresh.sh"
    sudo cp -f "${SCRIPT_DIR}/setup.sh"    "${INSTALL_DIR}/setup.sh"
    sudo chmod +x "${INSTALL_DIR}"/*.sh

    echo "=== Re-launching setup from ${INSTALL_DIR} ==="
    exec bash "${INSTALL_DIR}/setup.sh"
fi

# ── From here, we are running from /opt/azfiles/ ────────────────────────────

echo "=== Phase 1: Install packages (one-time) ==="
bash "${INSTALL_DIR}/install.sh"

echo "=== Phase 2: Register systemd service ==="

sudo tee /etc/systemd/system/azfiles-mount.service > /dev/null << 'UNIT_EOF'
[Unit]
Description=Azure Files Kerberos mount and token refresh
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=azureuser
Group=azureuser
EnvironmentFile=/etc/default/azfiles
ExecStartPre=/bin/sleep 15
ExecStart=/opt/azfiles/mount.sh
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