#!/bin/bash

echo
echo "#####################################################"
echo "### DOWNLOAD AND PREPARE OPENSHIFT 4 INSTALLATION ###"
echo "#####################################################"
echo

# Function to create and navigate to the setup directory
setup_directory() {
    echo -n "====> Setting up directory ${SETUP_DIR}: "
    mkdir -p "${SETUP_DIR}" && cd "${SETUP_DIR}" || err "Failed to use ${SETUP_DIR}"
    ok
}

# Function to create necessary config files for the cluster
create_config_files() {
    echo -n "====> Creating hosts file for the cluster (/etc/hosts.${CLUSTER_NAME}): "
    touch "/etc/hosts.${CLUSTER_NAME}" || err "Failed to create /etc/hosts.${CLUSTER_NAME}"
    ok

    echo -n "====> Creating dnsmasq config file (${DNS_DIR}/${CLUSTER_NAME}.conf): "
    echo "addn-hosts=/etc/hosts.${CLUSTER_NAME}" > "${DNS_DIR}/${CLUSTER_NAME}.conf" || err "Failed to create ${DNS_DIR}/${CLUSTER_NAME}.conf"
    ok
}

# Function to handle SSH key generation or selection
setup_ssh_key() {
    echo -n "====> Setting up SSH key for VM access: "
    if [[ -z "${SSH_PUB_KEY_FILE}" ]]; then
        ssh-keygen -f sshkey -q -N "" || err "SSH key generation failed"
        export SSH_PUB_KEY_FILE="sshkey.pub"
        ok "Generated new SSH key"
    elif [[ -f "${SSH_PUB_KEY_FILE}" ]]; then
        ok "Using existing SSH key: ${SSH_PUB_KEY_FILE}"
    else
        err "SSH public key not found!"
    fi
}

# Function to download necessary OpenShift files
download_files() {
    echo -n "====> Copying OpenShift Installer (installed previously...): "
    mv /tmp/openshift-install ./openshift-install || err "Failed to copy openshift-install, exiting..."
    ok
    echo -n "====> Downloading OpenShift Client: "; download get "$CLIENT" "$CLIENT_URL"
    tar -xf "${CACHE_DIR}/${CLIENT}" && rm -f README.md
    echo -n "====> Downloading RHCOS Image: "; download get "$IMAGE" "$IMAGE_URL"
    echo -n "====> Downloading RHCOS Kernel: "; download get "$KERNEL" "$KERNEL_URL"
    echo -n "====> Downloading RHCOS Initramfs: "; download get "$INITRAMFS" "$INITRAMFS_URL"
}

# Function to prepare RHCOS installation files
prepare_rhcos_files() {
    mkdir -p rhcos-install
    cp "${CACHE_DIR}/${KERNEL}" "rhcos-install/vmlinuz"
    cp "${CACHE_DIR}/${INITRAMFS}" "rhcos-install/initramfs.img"
    cat <<EOF > rhcos-install/.treeinfo
[general]
arch = x86_64
family = Red Hat CoreOS
platforms = x86_64
version = ${OCP_VER}
[images-x86_64]
initrd = initramfs.img
kernel = vmlinuz
EOF
}

# Function to create install config YAML
create_install_config() {
    mkdir -p install_dir
    cat <<EOF > install_dir/install-config.yaml
apiVersion: v1
baseDomain: ${BASE_DOM}
compute:
- hyperthreading: Disabled
  name: worker
  replicas: 0
controlPlane:
  hyperthreading: Disabled
  name: master
  replicas: ${N_MAST}
metadata:
  name: ${CLUSTER_NAME}
networking:
  clusterNetworks:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
pullSecret: '${PULL_SEC}'
sshKey: '$(< "${SSH_PUB_KEY_FILE}")'
EOF
}

# Function to generate ignition configs
generate_ignition_configs() {
    echo "====> Generating ignition configs: "
    ./openshift-install create ignition-configs --dir=./install_dir || err "Failed to create ignition configs"
}

# Function to create the HTTP server service file for image serving
create_http_service() {
    cat <<EOF > tmpws.service
[Unit]
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt
ExecStart=/usr/bin/python3 -m http.server ${WS_PORT}
[Install]
WantedBy=default.target
EOF
}

# Function to create HAProxy config file
create_haproxy_config() {
    echo "global
  log 127.0.0.1 local2
  chroot /var/lib/haproxy
  pidfile /var/run/haproxy.pid
  maxconn 4000
  user haproxy
  group haproxy
  daemon
  stats socket /var/lib/haproxy/stats

defaults
  mode tcp
  log global
  option tcplog
  option dontlognull
  option redispatch
  retries 3
  timeout queue 1m
  timeout connect 10s
  timeout client 1m
  timeout server 1m
  timeout check 10s
  maxconn 3000

# 6443 points to control plane
frontend ${CLUSTER_NAME}-api
  bind *:6443
  default_backend master-api
backend master-api
  balance source
  server bootstrap bootstrap.${CLUSTER_NAME}.${BASE_DOM}:6443 check" > haproxy.cfg
    local i
    for i in $(seq 1 "${N_MAST}"); do
        echo "  server master-${i} master-${i}.${CLUSTER_NAME}.${BASE_DOM}:6443 check" >> haproxy.cfg
    done

    echo "
# 22623 points to control plane
frontend ${CLUSTER_NAME}-mapi
  bind *:22623
  default_backend master-mapi
backend master-mapi
  balance source
  server bootstrap bootstrap.${CLUSTER_NAME}.${BASE_DOM}:22623 check" >> haproxy.cfg

    for i in $(seq 1 "${N_MAST}"); do
        echo "  server master-${i} master-${i}.${CLUSTER_NAME}.${BASE_DOM}:22623 check" >> haproxy.cfg
    done

    echo "
# 80 points to master nodes
frontend ${CLUSTER_NAME}-http
  bind *:80
  default_backend ingress-http
backend ingress-http
  balance source" >> haproxy.cfg

    for i in $(seq 1 "${N_MAST}"); do
        echo "  server master-${i} master-${i}.${CLUSTER_NAME}.${BASE_DOM}:80 check" >> haproxy.cfg
    done

    echo "
# 443 points to master nodes
frontend ${CLUSTER_NAME}-https
  bind *:443
  default_backend infra-https
backend infra-https
  balance source" >> haproxy.cfg

    for i in $(seq 1 "${N_MAST}"); do
        echo "  server master-${i} master-${i}.${CLUSTER_NAME}.${BASE_DOM}:443 check" >> haproxy.cfg
    done
}

# Execute the functions in sequence
setup_directory
create_config_files
setup_ssh_key
download_files
prepare_rhcos_files
create_install_config
generate_ignition_configs
create_http_service
create_haproxy_config
