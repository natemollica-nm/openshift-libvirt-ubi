#!/usr/bin/env bash

oc --context dc1 annotate namespace consul k8s.ovn.org/multicast-enabled-
oc --context dc2 annotate namespace consul k8s.ovn.org/multicast-enabled-


oc --context dc1 annotate namespace consul k8s.ovn.org/multicast-enabled=true
oc --context dc2 annotate namespace consul k8s.ovn.org/multicast-enabled=true