#!/usr/bin/env bash

#./add_node.sh --cpu 8 --memory 16000 --add-disk 50 --add-disk 100 --name worker-4
#./add_node.sh --cpu 8 --memory 16000 --add-disk 50 --add-disk 100 --name worker-5
#./add_node.sh --cpu 8 --memory 16000 --add-disk 50 --add-disk 100 --name worker-6

add_node() {
    local name="$1"

    echo -n "====> Adding OCP node ${name} to ${CLUSTER_NAME}: "
    if grep -q "${name}.${CLUSTER_NAME}.${BASE_DOM}" < <(oc get nodes); then
        ok "${name}.${CLUSTER_NAME}.${BASE_DOM} already present"
    else
        ./add_node.sh --cpu 8 --memory 16000 --add-disk 50 --add-disk 100 --name "${name}"
    fi
    return 0
}

for node in 4 5 6; do
  add_node worker-"${node}"
done

#################################################
#### Persistent storage using local volumes #####
#################################################
#### https://docs.openshift.com/container-platform/4.17/storage/persistent_storage/persistent_storage_local/persistent-storage-local.html
oc adm new-project openshift-local-storage
oc annotate namespace openshift-local-storage openshift.io/node-selector=''
oc annotate namespace openshift-local-storage workload.openshift.io/allowed='management'

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-operator-group
  namespace: openshift-local-storage
spec:
  targetNamespaces:
    - openshift-local-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: stable
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo -n "====> Waiting for local-storage-operator pod to become ready: "
oc wait \
    --for=condition=ready pod \
    --namespace openshift-local-storage \
    --selector=name=local-storage-operator \
    --timeout=90s >/dev/null 2>&1 || err "Failed to deploy local-storage-operator pod, exiting..."
ok

# ClusterServiceVersion
echo -n "====> Waiting for ClusterServiceVersion: "
csvs_name=
while [ -z "${csvs_name}" ]; do
    csvs_name="$(oc get ClusterServiceVersion -n openshift-local-storage --output=name)"
    [ -z "${csvs_name}" ] && echo -n "." && sleep 1
done; ok


####################################################################################################
#############  Provisioning local volumes by using the Local Storage Operator  #####################
####################################################################################################
# Setting forceWipeDevicesAndDestroyAllData to "true" can be useful in
# scenarios where previous data can remain on disks that need to be re-used.
# In these scenarios, setting this field to true eliminates the need for
# administrators to erase the disks manually. Such cases can include single-node
# OpenShift (SNO) cluster environments where a node can be redeployed multiple times
cat <<EOF | oc apply -f -
apiVersion: "local.storage.openshift.io/v1"
kind: "LocalVolume"
metadata:
  name: local-disks-fs
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - worker-4.${CLUSTER_NAME}.${BASE_DOM}
          - worker-5.${CLUSTER_NAME}.${BASE_DOM}
          - worker-6.${CLUSTER_NAME}.${BASE_DOM}
  storageClassDevices:
    - storageClassName: "local-sc"
      forceWipeDevicesAndDestroyAllData: true
      volumeMode: Filesystem
      devicePaths:
        - /dev/vdb
EOF