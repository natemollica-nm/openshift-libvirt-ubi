#!/usr/bin/env bash

./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name worker-4
./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name worker-5
./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name worker-6

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


cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-sc
provisioner: kubernetes.io/no-provisioner # indicates that this StorageClass does not support automatic provisioning
volumeBindingMode: WaitForFirstConsumer
EOF
