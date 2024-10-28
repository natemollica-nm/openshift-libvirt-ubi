#!/usr/bin/env bash

echo -n "====> Labeling ${NODE}.${CLUSTER_NAME}.${BASE_DOM} node with cluster.ocs.openshift.io/openshift-storage='' "
oc label node "${NODE}"."${CLUSTER_NAME}"."${BASE_DOM}" cluster.ocs.openshift.io/openshift-storage='' || err "failed labeling ${NODE}.${CLUSTER_NAME}.${BASE_DOM}"; ok


./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name storage-1
./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name storage-2
./add_node.sh --cpu 4 --memory 16000 --add-disk 50 --add-disk 100 --name storage-3

oc adm new-project openshift-local-storage
oc annotate namespace openshift-local-storage openshift.io/node-selector=''
# oc annotate namespace openshift-local-storage workload.openshift.io/allowed='management'

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
          - worker-1.ocp-01.local
          - worker-2.ocp-01.local
          - storage-1.ocp-01.local
          - storage-2.ocp-01.local
          - storage-3.ocp-01.local
  storageClassDevices:
    - storageClassName: "local-sc"
      forceWipeDevicesAndDestroyAllData: false
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