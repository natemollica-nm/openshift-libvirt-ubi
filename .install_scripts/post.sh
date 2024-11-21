#!/bin/bash

# Create the env file to store configuration details
create_env_file() {
    cat <<EOF > env
# OCP4 Automated Install Environment
# Repository: https://github.com/natemollica-nm/openshift-libvirt-ubi
# Script location: ${SDIR}
# Script invoked with: ${SINV}
# OpenShift version: ${OCP_NORMALIZED_VER}
# Red Hat CoreOS version: ${RHCOS_NORMALIZED_VER}
#
# Start time: $(date -d @"${START_TS}")
# End time:   $(date -d @"${END_TS}")
# Duration: ${TIME_TAKEN} minutes
#
# Environment Variables:

export SDIR="${SDIR}"
export SETUP_DIR="${SETUP_DIR}"
export DNS_DIR="${DNS_DIR}"
export VM_DIR="${VM_DIR}"
export KUBECONFIG="${SETUP_DIR}/install_dir/auth/kubeconfig"

export CLUSTER_NAME="${CLUSTER_NAME}"
export BASE_DOM="${BASE_DOM}"

export LBIP="${LBIP}"
export WS_PORT="${WS_PORT}"
export IMAGE="${IMAGE}"
export RHCOS_LIVE="${RHCOS_LIVE}"

export VIR_NET="${VIR_NET}"
export DNS_CMD="${DNS_CMD}"
export DNS_SVC="${DNS_SVC}"

EOF
}

# Function to copy post-scripts if they exist
copy_post_scripts() {
    local src_dir="${SDIR}/.post_scripts"
    local dest_dir="${SETUP_DIR}"

    if [[ -d "$src_dir" ]]; then
        cp "${src_dir}"/*.sh "$dest_dir" || {
            echo "Warning: Failed to copy post-scripts from ${src_dir} to ${dest_dir}."
            return 1
        }
        echo "Post-scripts copied from ${src_dir} to ${dest_dir}."
    else
        echo "Warning: No post-scripts directory found at ${src_dir}."
    fi
}

# Function to copy scripts if they exist
copy_directory() {
    local source_dir="$1"
    local dest_dir="${SETUP_DIR}"

    if [[ -d "${source_dir}" ]]; then
        [[ -d "${dest_dir}" ]] || mkdir -p "${dest_dir}"
        cp -a "${source_dir}"/. "${dest_dir}"/ || {
            echo "Warning: Failed to copy directory ${source_dir} to ${dest_dir}."
            return 1
        }
        echo "Directory copied from ${source_dir} to ${dest_dir}."
    else
        echo "Warning: No directory found at ${source_dir}."
    fi
}

# Execute the functions
create_env_file
copy_post_scripts
copy_directory "${SDIR}"/consul
