#!/bin/bash
# OpenShift UPI installation script
# https://github.com/kxr/ocp4_setup_upi_kvm

# Force the script to run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root. Restarting with sudo..."
  exec sudo "$0" "$@"
fi

set -e

export START_TS=$(date +%s)
export SINV="${0} ${@}"
export SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
export COLS="$(stty size | awk '{print $2}')"

# 'source' integrates scripts as part of the main environment without
#  needing separate processes or subshells, providing an effective
#  structure for complex workflows like the OpenShift UPI installation.

# Utility function err,ok,download etc.
source ${SDIR}/.install_scripts/utils.sh

# Checking if we are root
test "$(whoami)" = root || err "Not running as root"

# Process Arguments
source ${SDIR}/.defaults.sh
source ${SDIR}/.install_scripts/process_args.sh "${@}"

# Destroy
if [ "${DESTROY}" == "yes" ]; then
    source ${SDIR}/.install_scripts/destroy.sh
    exit 0
fi

## https://www.libguestfs.org/guestfs.3.html#backend
#export LIBGUESTFS_BACKEND=direct

# Dependencies & Sanity checks
source ${SDIR}/.install_scripts/sanity_check.sh

# Libvirt Network
source ${SDIR}/.install_scripts/libvirt_network.sh

# DNS Check
source ${SDIR}/.install_scripts/dns_check.sh

# Version check
source ${SDIR}/.install_scripts/version_check.sh

# Download & Prepare
source ${SDIR}/.install_scripts/download_prepare.sh

# Create LB VM
source ${SDIR}/.install_scripts/create_lb.sh

# Create Cluster Nodes
source ${SDIR}/.install_scripts/create_nodes.sh

# OpenShift Bootstrapping
source ${SDIR}/.install_scripts/bootstrap.sh

# OpenShift ClusterVersion
source ${SDIR}/.install_scripts/clusterversion.sh

# Generate env file and copy post scripts
source ${SDIR}/.install_scripts/post.sh

