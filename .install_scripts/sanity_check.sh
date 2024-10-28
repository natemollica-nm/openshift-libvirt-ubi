#!/bin/bash

echo
echo "####################################"
echo "### DEPENDENCIES & SANITY CHECKS ###"
echo "####################################"
echo

# Dependency mapping hashtable (command => install method)
declare -A dependencies=(
    [virsh]="dnf install -y libvirt"
    [virt-install]="dnf install -y libvirt"
    [virt-customize]="yum install -y libguestfs-tools-c"
    [systemctl]="dnf install -y systemd"
    [dig]="dnf install -y bind-utils"
    [wget]="dnf install -y wget"
)

# Function to attempt installation of missing dependencies
install_dependency() {
    local cmd="$1"
    local install_cmd="${dependencies[$cmd]}"

    echo "Attempting to install missing dependency: $cmd"
    if ! $install_cmd; then
        err "Failed to install $cmd using command: $install_cmd. Please install it manually."
    else
        ok "$cmd installed successfully."
    fi
}

# Function to check for required executables
check_dependencies() {
    echo "====> Checking dependencies: "
    for cmd in "${!dependencies[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Dependency $cmd not found."
            install_dependency "$cmd"
        else
            ok "$cmd found."
        fi
    done

    # Verify libvirt_driver_network.so existence
    if ! find /usr -type f -name libvirt_driver_network.so >/dev/null 2>&1; then
        err "libvirt_driver_network.so not found. Please install the libvirt package."
    else
        ok "libvirt_driver_network.so found."
    fi
}

# Function to check if setup directory already exists
check_setup_directory() {
    echo -n "====> Checking if the setup directory exists: "
    if [[ -d "${SETUP_DIR}" ]]; then
        err "Directory ${SETUP_DIR} already exists" \
            "" \
            "You can use --destroy to remove your existing installation" \
            "You can also use --setup-dir to specify a different directory for this installation"
    fi
    ok
}

# Function to check for pull secret
check_pull_secret() {
    echo -n "====> Checking for pull-secret (${PULL_SEC_F}): "
    if [[ -f "${PULL_SEC_F}" ]]; then
        export PULL_SEC=$(<"${PULL_SEC_F}")
    else
        err "Pull secret not found." "Please specify the pull secret file using -p or --pull-secret"
    fi
    ok
}

# Function to enable/start libvirt modular daemons
start_libvirt_services() {
    local service
    for service in qemu interface network nodedev nwfilter secret storage; do
        echo -n "====> Unmasking virt${service} socket: "
        systemctl unmask virt${service}d.service; systemctl unmask virt${service}d{,-ro,-admin}.socket || \
            err "virt${service}d is not running nor enabled"
        ok
        echo -n "====> Enabling virt${service} socket: "
        systemctl enable virt${service}d.service; systemctl enable virt${service}d{,-ro,-admin}.socket || \
            err "virt${service}d is not running nor enabled"
        ok
        echo -n "====> Starting virt${service} socket: "
        systemctl start virt${service}d{,-ro,-admin}.socket || \
            err "virt${service}d is not running nor enabled"
        ok
    done
}

# Function to check and restart libvirt services
check_libvirt_services() {
    local service

    for service in qemu interface network nodedev nwfilter secret storage; do
        echo -n "====> Checking if virt${service}d is running or enabled: "
        systemctl -q is-active "virt${service}d" || systemctl -q is-enabled "virt${service}d" || \
            err "virt${service}d is not running nor enabled"
        ok

        echo -n "====> Testing virt${service}d restart: "
        systemctl restart "virt${service}d" || err "Failed to restart virt${service}d"
        ok
    done
}

# Function to check for existing VMs
check_existing_vms() {
    echo -n "====> Checking for any existing leftover VMs: "
    existing_vm=$(virsh list --all --name | grep -m1 "${CLUSTER_NAME}-lb\|${CLUSTER_NAME}-master-\|${CLUSTER_NAME}-worker-\|${CLUSTER_NAME}-bootstrap") || true
    test -z "$existing_vm" || err "Found existing VM: $existing_vm"
    ok
}

# Function to check DNS service and configuration
check_dns_service() {
    echo -n "====> Checking if DNS service (dnsmasq or NetworkManager) is active: "
    if [[ -d "/etc/NetworkManager/dnsmasq.d" ]]; then
        DNS_DIR="/etc/NetworkManager/dnsmasq.d"
        DNS_SVC="NetworkManager"
        DNS_CMD="reload"
    elif [[ -d "/etc/dnsmasq.d" ]]; then
        DNS_DIR="/etc/dnsmasq.d"
        DNS_SVC="dnsmasq"
        DNS_CMD="restart"
    else
        err "No dnsmasq found; set DNS_DIR to either /etc/dnsmasq.d or /etc/NetworkManager/dnsmasq.d"
    fi

    systemctl -q is-active "${DNS_SVC}" || err "DNS_DIR points to $DNS_DIR but $DNS_SVC is not active"
    ok "${DNS_SVC}"

    if [[ "${DNS_SVC}" == "NetworkManager" ]]; then
        echo -n "====> Checking if dnsmasq is enabled in NetworkManager: "
        grep -qr dnsmasq /etc/NetworkManager/conf.d/*.conf || err "dnsmasq not enabled in NetworkManager" \
            "See: https://github.com/kxr/ocp4_setup_upi_kvm/wiki/Setting-Up-DNS"
        ok
    fi

    echo -n "====> Testing dnsmasq reload: "
    systemctl "${DNS_CMD}" "${DNS_SVC}" || err "Failed to ${DNS_CMD} ${DNS_SVC}"
    ok
}

# Function to check for leftover DNS and host files
check_dns_and_hosts() {
    echo -n "====> Checking for leftover dnsmasq config: "
    test -f "${DNS_DIR}/${CLUSTER_NAME}.conf" && err "Existing dnsmasq config file found: ${DNS_DIR}/${CLUSTER_NAME}.conf"
    ok

    echo -n "====> Checking for leftover hosts file: "
    test -f "/etc/hosts.${CLUSTER_NAME}" && err "Existing hosts file found: /etc/hosts.${CLUSTER_NAME}"
    ok

    echo -n "====> Checking for leftover/conflicting DNS records: "
    for host in api api-int bootstrap master-1 master-2 master-3 etcd-0 etcd-1 etcd-2 worker-1 worker-2 test.apps; do
        res=$(dig +short "${host}.${CLUSTER_NAME}.${BASE_DOM}" @127.0.0.1) || err "Failed dig @127.0.0.1"
        test -z "$res" || err "Found existing DNS record for ${host}.${CLUSTER_NAME}.${BASE_DOM}: ${res}"
    done

    existing_hosts=$(grep -v "^#" /etc/hosts | grep -w -m1 "${CLUSTER_NAME}\.${BASE_DOM}") || true
    test -z "$existing_hosts" || err "Found existing /etc/hosts records" "$existing_hosts"
    ok
}

# Run all checks
check_dependencies
check_setup_directory
check_pull_secret
start_libvirt_services
check_libvirt_services
check_existing_vms
check_dns_service
check_dns_and_hosts
