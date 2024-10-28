#!/bin/bash

echo
echo "##################"
echo "#### DNS CHECK ###"
echo "##################"
echo

# Function to reload DNS and libvirt network services
reload_dns() {
    systemctl "$DNS_CMD" "$DNS_SVC" || err "Failed to reload $DNS_SVC"; echo -n "."
    sleep 5
    systemctl restart virtnetworkd || err "Failed to restart virtnetworkd"; echo -n "."
    sleep 5
}

# Function to clean up test files and reload DNS
cleanup() {
    rm -f "/etc/hosts.dnstest" "${DNS_DIR}/dnstest.conf" &> /dev/null || \
        echo "Failed to remove /etc/hosts.dnstest or ${DNS_DIR}/dnstest.conf"; echo -n "."
    reload_dns
}

# Function to handle DNS test failures with a cleanup message
fail() {
    echo -n "Failed! Cleaning up: "
    cleanup
    err "$@" \
    "DNS configuration using dnsmasq is not being picked up by the system/libvirt." \
    "Refer to https://github.com/kxr/ocp4_setup_upi_kvm/wiki/Setting-Up-DNS for details."
}

# Check if the first nameserver in /etc/resolv.conf points locally
echo -n "====> Checking if first entry in /etc/resolv.conf points locally: "
first_ns="$(grep -m1 "^nameserver " /etc/resolv.conf | awk '{print $2}')"
first_ns_oct=$(echo "${first_ns}" | cut -d '.' -f 1)
[[ "$first_ns_oct" == "127" ]] || err "First nameserver in /etc/resolv.conf is not pointing locally"
ok

# Create test files for dnsmasq configuration
echo -n "====> Creating test host file for dnsmasq: /etc/hosts.dnstest: "
echo "1.2.3.4 xxxtestxxx.${BASE_DOM}" > /etc/hosts.dnstest
ok

echo -n "====> Creating test dnsmasq config file: ${DNS_DIR}/dnstest.conf: "
cat <<EOF > "${DNS_DIR}/dnstest.conf"
local=/${CLUSTER_NAME}.${BASE_DOM}/
addn-hosts=/etc/hosts.dnstest
address=/test-wild-card.${CLUSTER_NAME}.${BASE_DOM}/5.6.7.8
EOF
ok

# Reload DNS services
echo -n "====> Reloading libvirt and dnsmasq: "
reload_dns; ok

# Function to perform DNS tests
run_dns_tests() {
    local dig_dest="$1" failed="no"

    echo -n "====> Testing forward DNS via ${dig_dest:-local resolver}: "
    fwd_dig=$(dig +short "xxxtestxxx.${BASE_DOM}" ${dig_dest} 2> /dev/null)
    if [[ "$fwd_dig" == "1.2.3.4" ]]; then ok; else failed="yes"; echo "failed"; fi

    echo -n "====> Testing reverse DNS via ${dig_dest:-local resolver}: "
    rev_dig=$(dig +short -x "1.2.3.4" ${dig_dest} 2> /dev/null)
    if [[ "$rev_dig" == "xxxtestxxx.${BASE_DOM}." ]]; then ok; else failed="yes"; echo "failed"; fi

    echo -n "====> Testing wildcard record via ${dig_dest:-local resolver}: "
    wc_dig=$(dig +short "blah.test-wild-card.${CLUSTER_NAME}.${BASE_DOM}" ${dig_dest} 2> /dev/null)
    if [[ "$wc_dig" == "5.6.7.8" ]]; then ok; else failed="yes"; echo "failed"; fi

    echo
    [[ "$failed" == "no" ]] || return 1
}

# Run DNS tests against the first nameserver, LIBVIRT_GWIP, and local resolver
test_failed=""
for dns_host in "$first_ns" "$LIBVIRT_GWIP" ""; do
    dig_dest=""
    [[ -n "$dns_host" ]] && dig_dest="@${dns_host}"
    run_dns_tests "$dig_dest" || test_failed="yes"
done

# Check if all tests passed or fail with a cleanup
if [[ -n "$test_failed" ]]; then
    fail "One or more DNS tests failed"
else
    echo -n "====> All DNS tests passed. Cleaning up: "
    cleanup
    ok
fi
