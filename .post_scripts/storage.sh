#!/usr/bin/env bash

echo -n "====> Labeling ${NODE}.${CLUSTER_NAME}.${BASE_DOM} node with cluster.ocs.openshift.io/openshift-storage='' "
oc label node "${NODE}"."${CLUSTER_NAME}"."${BASE_DOM}" cluster.ocs.openshift.io/openshift-storage='' || err "failed labeling ${NODE}.${CLUSTER_NAME}.${BASE_DOM}"
ok

./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name storage-1
./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name storage-2
./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name storage-3

#################################################
#### Persistent storage using local volumes #####
#################################################
#### https://docs.openshift.com/container-platform/4.17/storage/persistent_storage/persistent_storage_local/persistent-storage-local.html
oc adm new-project openshift-local-storage
oc annotate namespace openshift-local-storage openshift.io/node-selector=''


cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-operator-group
  namespace: openshift-local-storage
spec:
  targetNamespaces:
    - openshift-local-storage
    - consul
    - default
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

oc get pods -n openshift-local-storage

# ClusterServiceVersion
oc get csvs -n openshift-local-storage

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
          - storage-1.ocp-01.local
          - storage-2.ocp-01.local
          - storage-3.ocp-01.local
  storageClassDevices:
    - storageClassName: "local-sc"
      forceWipeDevicesAndDestroyAllData: true
      volumeMode: Filesystem
      devicePaths:
        - /dev/vdb
EOF


cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner # indicates that this StorageClass does not support automatic provisioning
volumeBindingMode: WaitForFirstConsumer
EOF
