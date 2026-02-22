#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Load config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

MARKER_FILE="/var/log/azfiles_install_done"

if [ -f "${MARKER_FILE}" ]; then
    echo "Packages already installed (marker: ${MARKER_FILE}). Skipping."
    exit 0
fi

echo "Installing azfilesauth and dependencies ..."

sudo curl -sSL -O https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo rm -f packages-microsoft-prod.deb

sudo apt-get update -y
sudo apt-get install -y azfilesauth

# Configure azfilesauth
CONFIG_FILE="/etc/azfilesauth/config.yaml"
echo "Setting USER_UID to ${MOUNT_UID} in ${CONFIG_FILE}"
echo "USER_UID: ${MOUNT_UID}" | sudo tee "${CONFIG_FILE}"

# Install azure-identity in the conda env once
source /anaconda/etc/profile.d/conda.sh
conda activate "${CONDA_ENV}" >/dev/null 2>&1
pip install "azure-identity" >/dev/null 2>&1

sudo touch "${MARKER_FILE}"
echo "Installation complete."