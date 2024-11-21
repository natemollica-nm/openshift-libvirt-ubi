#!/usr/bin/env bash


set -e

SOURCE_SVC="${1}"
SOURCE_NAMESPACE="${2}"

DST_SVC="${3}"
DST_NAMESPACE="${4}"

DST_PORT="${5:-80}"
PROTOCOL="-${6:-tcp}"
LOG_LEVEL="${7:-0}"

if [ -z "$SOURCE_SVC" ] || [ -z "$SOURCE_NAMESPACE" ] || [ -z "$DST_SVC" ] || [ -z "$DST_NAMESPACE" ] || [ -z "$DST_PORT" ]; then
  echo "Usage: $(basename $0) <source_service> <src_svc_namespace> <destination_service> <dst_svc_namespace> [destination_port] [protocol] [log_level]"
  echo "    Parameters:"
  echo "        source_service:      Source service application name (label)."
  echo "        src_svc_namespace:   Source service application namespace."
  echo "        destination_service: Destination service application name (label)."
  echo "        dst_svc_namespace:   Destination service application namespace"
  echo "    Options:"
  echo "        destination_port:    Trace test tcp/udp port to test (Default: 80)"
  echo "        protocol:            Trace test protocol to use      (Options: tcp, udp) (Default: tcp)"
  echo "        log_level:           Trace test logging level        (Options: 0-5, 0 being lowest and 5 most verbose) (Default: 0)"
  exit 2
fi

download_ovnkube() {
  local pod

  pod=$(oc get pods -n openshift-ovn-kubernetes -l app=ovnkube-control-plane -o name | head -1 | awk -F '/' '{print $NF}')
  echo "Retrieving 'ovnkube-trace' from $pod:/usr/bin/ovnkube-trace"
  oc cp -n openshift-ovn-kubernetes "$pod":/usr/bin/ovnkube-trace -c ovnkube-cluster-manager ovnkube-trace
  ! test -f /usr/local/bin/ovnkube-trace || {
      echo "Removing previously downloaded ovnkube-trace..."
      sudo rm /usr/local/bin/ovnkube-trace
  }
  sudo cp ovnkube-trace /usr/local/bin/ovnkube-trace
  sudo chmod a+x /usr/local/bin/ovnkube-trace
}

SRC_POD=$(oc get pods -n "$SOURCE_NAMESPACE" -l app="$SOURCE_SVC" -o name | head -1 | awk -F '/' '{print $NF}')
DST_POD=$(oc get pods -n "$DST_NAMESPACE" -l app="$DST_SVC" -o name | head -1 | awk -F '/' '{print $NF}')

if ! command -v ovnkube-trace >/dev/null 2>&1; then
    download_ovnkube
fi

echo "Running ovnkube-trace | source: $SOURCE_SVC ($SOURCE_NAMESPACE) | destination: $DST_SVC:$DST_PORT ($DST_NAMESPACE) | Protocol: $PROTOCOL"
ovnkube-trace \
    -src-namespace consul \
    -src "$SRC_POD" \
    -dst-namespace consul \
    -dst "$DST_POD" \
    "${PROTOCOL}" \
    -dst-port "${DST_PORT}" \
    -loglevel "${LOG_LEVEL}"
echo "done!"