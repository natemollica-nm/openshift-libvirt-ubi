#!/bin/bash

echo
echo "##########################################"
echo "### OPENSHIFT/RHCOS VERSION/URL CHECK  ###"
echo "##########################################"
echo

# Function to display and check URL availability
check_url() {
    local name="$1"
    local url="$2"
    local file="$3"

    echo "====> Checking if ${name} URL is downloadable: "
    download check "$file" "$url"
}

# Function to look up and validate the release files
lookup_release_file() {
    local description="$1"
    local url="$2"
    local pattern="$3"
    local file

    file=$(curl -N --fail -qs "$url" | grep -m1 "$pattern" | sed 's/.*href="\(.*\)">.*/\1/')
    test -n "$file" || err "No ${description} found at ${url}"
    echo "$file"
}

# Determine OpenShift release version
if [[ "$OCP_VERSION" == "latest" || "$OCP_VERSION" == "stable" ]]; then
    urldir="$OCP_VERSION"
else
    [[ "$(echo "$OCP_VERSION" | cut -d '.' -f1)" == "4" ]] || err "Invalid OpenShift version $OCP_VERSION"
    OCP_VER=$(echo "$OCP_VERSION" | cut -d '.' -f1-2)
    OCP_MINOR=$(echo "$OCP_VERSION" | cut -d '.' -f3- || echo "stable")
    urldir="${OCP_MINOR}-${OCP_VER}"
fi

# OpenShift client and installer download links
CLIENT="$(lookup_release_file "OCP4 client" "${OCP_MIRROR}/${urldir}/" "client-linux")"
CLIENT_URL="${OCP_MIRROR}/${urldir}/${CLIENT}"
check_url "Client" "$CLIENT_URL" "$CLIENT"

INSTALLER="$(lookup_release_file "OCP4 installer" "${OCP_MIRROR}/${urldir}/" "install-linux")"
INSTALLER_URL="${OCP_MIRROR}/${urldir}/${INSTALLER}"
check_url "Installer" "$INSTALLER_URL" "$INSTALLER"

OCP_NORMALIZED_VER=$(echo "${INSTALLER}" | sed 's/.*-\(4\..*\)\.tar.*/\1/')

# Determine RHCOS release version
if [[ -z "$RHCOS_VERSION" ]]; then
    RHCOS_VER="${OCP_VER}"
    RHCOS_MINOR="latest"
else
    RHCOS_VER=$(echo "$RHCOS_VERSION" | cut -d '.' -f1-2)
    RHCOS_MINOR=$(echo "$RHCOS_VERSION" | cut -d '.' -f3 || echo "latest")
fi
urldir="${RHCOS_VER}/${RHCOS_MINOR}"

# RHCOS kernel, initramfs, and image download links
KERNEL="$(lookup_release_file "RHCOS kernel" "${RHCOS_MIRROR}/${urldir}/" "installer-kernel\|live-kernel")"
KERNEL_URL="${RHCOS_MIRROR}/${urldir}/${KERNEL}"
check_url "Kernel" "$KERNEL_URL" "$KERNEL"

INITRAMFS="$(lookup_release_file "RHCOS initramfs" "${RHCOS_MIRROR}/${urldir}/" "installer-initramfs\|live-initramfs")"
INITRAMFS_URL="${RHCOS_MIRROR}/${urldir}/${INITRAMFS}"
check_url "Initramfs" "$INITRAMFS_URL" "$INITRAMFS"

# Detect RHCOS image type based on kernel/initramfs type
if [[ "$KERNEL" =~ "live" && "$INITRAMFS" =~ "live" ]]; then
    IMAGE="$(lookup_release_file "RHCOS live image" "${RHCOS_MIRROR}/${urldir}/" "live-rootfs")"
elif [[ "$KERNEL" =~ "installer" && "$INITRAMFS" =~ "installer" ]]; then
    IMAGE="$(lookup_release_file "RHCOS metal image" "${RHCOS_MIRROR}/${urldir}/" "metal")"
else
    err "Unhandled RHCOS configuration. Exiting."
fi
IMAGE_URL="${RHCOS_MIRROR}/${urldir}/${IMAGE}"
check_url "Image" "$IMAGE_URL" "$IMAGE"

RHCOS_NORMALIZED_VER="$(echo "${IMAGE}" | sed 's/.*-\(4\..*\)-x86.*/\1/')"

# CentOS cloud image check
LB_IMG="${LB_IMG_URL##*/}"
check_url "CentOS cloud image" "$LB_IMG_URL" "$LB_IMG"

# Display detected versions
echo
echo "      Red Hat OpenShift Version = $OCP_NORMALIZED_VER"
echo "                         Client = $CLIENT_URL"
echo "                      Installer = $INSTALLER_URL"
echo "                    RHCOS Image = $IMAGE_URL"
echo "      Red Hat CoreOS Version    = $RHCOS_NORMALIZED_VER"
echo

# Prompt user to continue
check_if_we_can_continue
