# Sources .env for targets
SHELL=$(PWD)/shell

SINGLE_CLUSTER=true

# OpenShift Specific
PULL_SECRET=/root/pull-secret.txt

# Consul Image Versioning
CONSUL_RELEASE_VERSION=1.20.0
CONSUL_K8s_RELEASE_VER=1.5.0
CONSUL_DP_RELEASE_VER=1.5.0

DOCKERHUB_REGISTRY=natemollica
OCP_REDHAT_REGISTRY=registry.connect.redhat.com/hashicorp
HASHICORP_PREVIEW_REGISTRY=hashicorppreview

CONSUL_REGISTRY="$(OCP_REDHAT_REGISTRY)"
CONSUL_K8s_REGISTRY="$(OCP_REDHAT_REGISTRY)"
CONSUL_DATAPLANE_REGISTRY="$(OCP_REDHAT_REGISTRY)"

# Enable/disable local helm chart usage
USE_LOCAL_HELM_CHARTS=0
ifeq ($(USE_LOCAL_HELM_CHARTS), 1)
    CHART_DIR=~/HashiCorp/consul-k8s/charts/consul
else
    CHART_DIR=hashicorp/consul
endif

# Swap aws vs local context
OC="$$SETUP_DIR/oc"

# Check dependencies are install for repo Make targets
.PHONY: verify
verify:
	@scripts/verify-deps.sh

# ////////////////////////////////////////////////////////////////////////// #
# //////////////////////////// OpenShift /////////////////////////////////// #
##@ Openshift
.PHONY: kubeconfig
kubeconfig: ## Update context naming
	@scripts/kubeconfig.sh

.PHONY: ingress-op-patch
ingress-op-patch: ##   Apply openshift-ingress-operator patch to allow cross-namespace communication
	@$(OC) -n openshift-ingress-operator patch ingresscontroller/default --patch '{"spec":{"routeAdmission":{"namespaceOwnership":"InterNamespaceAllowed"}}}' --type=merge

# //////////////////////////////////////////////////////////////////////////////////// #
# ///////////////////////////// Consul Install  ////////////////////////////////////// #
##@ Consul
.PHONY: version
version: ## Update Consul version for installation/deployment/upgrade
	@scripts/consul-version-set.sh $(CONSUL_RELEASE_VERSION) $(CONSUL_K8s_RELEASE_VER) $(CONSUL_DP_RELEASE_VER) $(CONSUL_REGISTRY) $(CONSUL_K8s_REGISTRY) $(CONSUL_DATAPLANE_REGISTRY)

.PHONY: version-show
version-show: ## Print currently set Consul versioning scheme
	@cat .k8sImages.env

.PHONY: install-consul
install-consul: ##  Run consul helm installation | Set proxy-defaults | Configure consul-cni network attachment and SCC
	@scripts/install-consul.sh $(CHART_DIR) $(CONSUL_RELEASE_VERSION) $(CONSUL_K8s_RELEASE_VER)

.PHONY: upgrade-consul
upgrade-consul: version ##  Run helm upgrade on consul with updates from values-ent.yaml
	@scripts/install-consul.sh $(CHART_DIR) $(CONSUL_RELEASE_VERSION) $(CONSUL_K8s_RELEASE_VER) true

.PHONY: uninstall-consul
uninstall-consul: ## Run consul-k8s or helm uninstall on consul project
	@scripts/uninstall-consul.sh "$$CLUSTER_NAME" || { scripts/uninstall-consul.sh dc1 true; }

.PHONY: edge-proxy-concurrency
edge-proxy-concurrency: ## Configure mesh-gw and tgw Envoy concurrency to higher value
	@scripts/set-envoy-concurrency.sh $(SINGLE_CLUSTER) 4

.PHONY: consul-core-dns
consul-core-dns: consul-core-dns-dc1 consul-core-dns-dc2

.PHONY: consul-core-dns-dc1
consul-core-dns-dc1: ##  (DC1) Retrieve consul-dns service clusterIP information to update openshift dns.operator for DNS forwarding
	@printf '\n%s' "dc1: consul-dns-cluster-ip: "
	@$(OC) --context "$$CLUSTER1_CONTEXT" get svc consul-dns --namespace "$$CONSUL_NS" --output jsonpath='{.spec.clusterIP}'
	@printf '\n%s' "    => $(OC) --context $$CLUSTER1_CONTEXT edit dns.operator/default"

.PHONY: bootstrap-token
bootstrap-token: ##  Retrieve and print consul bootstrap-token secretID
	@echo "dc1: $$(oc get secret --context "$$CLUSTER1_CONTEXT" --namespace consul consul-bootstrap-acl-token -o yaml | yq -r '.data.token' | base64 -d)"

# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# ////////////////////////////////////// Prom Stack Testing //////////////////////////////////////// #
##@ Prometheus + Grafana
.PHONY: prom-graf-stack
prom-graf-stack: prometheus grafana loki ## Deploy prometheus grafana loki stack

.PHONY: prometheus
prometheus: ## Deploy prometheus stack
	@observability/prometheus.sh $(SINGLE_CLUSTER)

.PHONY: grafana
grafana: ## Deploy grafana stack
	@observability/grafana.sh $(SINGLE_CLUSTER)

.PHONY: loki
loki: ## Deploy loki + promtail stack
	@observability/loki.sh $(SINGLE_CLUSTER)

.PHONY: teardown-prometheus
teardown-prometheus: ## Destroy prometheus stack
	@observability/prometheus.sh $(SINGLE_CLUSTER) true

.PHONY: teardown-grafana
teardown-grafana: ## Destroy grafana stack
	@observability/grafana.sh $(SINGLE_CLUSTER) true

.PHONY: teardown-loki
teardown-loki: ## Deploy loki + promtail stack
	@observability/loki.sh $(SINGLE_CLUSTER) true

.PHONY: teardown-prom-graf
teardown-prom-graf: teardown-grafana teardown-prometheus teardown-loki ## Destroy prometheus + grafana stack
	@oc --context dc1 delete namespaces observability >/dev/null 2>&1 || true
	@oc --context dc2 delete namespaces observability >/dev/null 2>&1 || true

# /////////////////////////////////////////////////////////////////////////// #
# ///////////////////////////// Envoy  ////////////////////////////////////// #
##@ Envoy
.PHONY: envoy-dump
envoy-dump: ## Run envoy sidecar or gateway admin/ API endpoint scrape (i.e. 'make envoy-dump -- --service <my-service> --namespace <my-namespace>')
	@scripts/envoy/envoy.sh $(filter-out $@,$(MAKECMDGOALS))

# ////////////////////////////////////// Consul Load Testing /////////////////////////////////////////// #
# //////////////////////////////////////////////////////////////////////////////////////////////////// #
##@ Consul Load Testing
CONSUL_LOAD_TEST_DIR=~/HashiCorp/consul-load-test
.PHONY: consul-load-test-img
consul-load-test-img: ## Customer internal consul-load-test binary tool for dynamically load testing
	@consul-load-test/consul-load-test-build.sh $(CONSUL_LOAD_TEST_DIR) $(DOCKERHUB_REGISTRY)

.PHONY: consul-load-test
consul-load-test:
	@consul-load-test/consul-load-test.sh $(SINGLE_CLUSTER)

.PHONY: rm-consul-load-test
rm-consul-load-test:
	@consul-load-test/consul-load-test.sh $(SINGLE_CLUSTER) true

.PHONY: consul-load-generator
consul-load-generator: ## Deploy k6 loadimpact generator to load test Consul's KV, Service Catalog, and ACL API endpoints.
	@load-generator/consul-load-generator.sh apply

.PHONY: delete-consul-load-generator
delete-consul-load-generator: ## Destroy k6 loadimpact generator in consul namespace
	@load-generator/consul-load-generator.sh delete
# /////////////////////////////////////////////////////////////////////////////////////// #
# ///////////////////////////// Test Applications  ////////////////////////////////////// #
##@ Test Apps
.PHONY: static-services
static-services: ##    Deploy static-server and static-client apps to openshift
	@scripts/static-services.sh

.PHONY: rm-static-services
rm-static-services: ## Delete static-server and static-client apps from openshift
	@scripts/static-services.sh delete

.PHONY: fake-services
fake-services: ##    Deploy fake-service frontend + backend apps to openshift   | Configure consul intentions, service-defaults, service-resolver for services
	@scripts/fake-services.sh apply $(SINGLE_CLUSTER)

.PHONY: delete-fake-services
delete-fake-services: ##   Delete fake-service frontend + backend apps from openshift | Deletes consul intentions, service-defaults, service-resolver for services
	@scripts/fake-services.sh delete $(SINGLE_CLUSTER)

# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# //////////////////////////////////// Ingress Gateway Testing ///////////////////////////////////////// #
##@ Ingress Gateway
.PHONY: ingress-gw-demo
ingress-gw-demo: fake-services ingress-gateway ##   Deploy Ingress gateway demo using frontend => backend test apps

.PHONY: ingress-gateway
ingress-gateway: ##    Apply ingress-gateway/igw.yaml resource
	@ingress-gateway/ingress-gateway.sh default

.PHONY: delete-ingress-gw
delete-ingress-gw: ## Delete api-gateway demo resources
	@scripts/fake-services.sh delete
	@ingress-gateway/ingress-gateway.sh default delete
# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# //////////////////////////////////// API Gateway Testing ///////////////////////////////////////// #
##@ API Gateway
.PHONY: api-gateway-demo
api-gateway-demo: fake-services api-gateway ##   Deploy API gateway demo using frontend => backend test apps

.PHONY: api-gateway
api-gateway: ##    Apply api-gateway/api-gateway.yaml resource
	@api-gateway/api-gateway-demo.sh default

.PHONY: api-gw-ip
api-gw-ip: ##    Print demo api-gateway loadBalancer IP
	@$(OC) get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

.PHONY: delete-api-gw-demo
delete-api-gw-demo: ## Delete api-gateway demo resources
	@scripts/fake-services.sh delete
	@api-gateway/api-gateway-demo.sh default delete

# //////////////////////////////////////////////////////////////////////////////////////////////////////// #
# //////////////////////////////////// Spring Boot SMTP + TGW Testing //////////////////////////////////// #
##@ Springboot + SMTP Testing
.PHONY: smtp-demo
smtp-demo: smtp-service smtp-terminating-gateway smtp-tgw-policy ## Deploy SMTP TGW and Adjust TGW service ACL permissions

.PHONY: smtp-service
smtp-service: ## Create spring-boot-smtp-client namespace and deploy service
	@smtp/smtp-service.sh apply smtp

.PHONY: delete-smtp-service
delete-smtp-service: ## Delete spring-boot-smtp-client namespace and deploy service
	@smtp/smtp-service.sh delete smtp

.PHONY: smtp-terminating-gateway
smtp-terminating-gateway: ## Configure smtp-terminating-gateway with mail-app service + destinations + intentions
	@smtp/smtp-service.sh apply tgw

.PHONY: delete-smtp-tgw
delete-smtp-tgw: ## Configure smtp-terminating-gateway with mail-app service + destinations + intentions
	@smtp/smtp-service.sh delete tgw

.PHONY: smtp-tgw-policy
smtp-tgw-policy: ## Update smtp-terminating-gateway acl policy to allow mail-app communication from spring-boot client
	@smtp/acl/tgw.sh "$$CLUSTER1_CONTEXT"

.PHONY: delete-smtp-demo
delete-smtp-demo: ## Delete resources for smtp-terminating-gateway + mail-app service + destinations + intentions
	@smtp/smtp-service.sh delete tgw
	@smtp/smtp-service.sh delete smtp

# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# //////////////////////////////////// Spring Boot Mesh Testing //////////////////////////////////// #
##@ Java Springboot
.PHONY: springboot-demo
springboot-demo: ##    Deploy Springboot admin and client apps and configure API Gateway Ingress
	@api-gateway/api-gateway-demo.sh springboot apply dc1

.PHONY: delete-springboot-demo
delete-springboot-demo: ## Delete Springboot + API Gateway Ingress resources
	@api-gateway/api-gateway-demo.sh springboot delete dc1

# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# //////////////////////////////////// Counting Sample Testing //////////////////////////////////// #
##@ Counting + Dashboard
.PHONY: count-dash-demo
count-dash-demo: ##    Deploy counting and dashboard services in consul-sample-test namespace
	@api-gateway/api-gateway-demo.sh counting-sample

.PHONY: delete-count-dash-demo
delete-count-dash-demo: ## Destroy count-dash-demo deployment
	@api-gateway/api-gateway-demo.sh counting-sample delete

# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# ////////////////////////////////////// Terminating GW Testing //////////////////////////////////// #
##@ Terminating Gateway
# TGW Specific Deployment Targets
.PHONY: tgw
tgw: terminating-gateway tgw-acl-policy ## Deploy terminating-gateway and update acl policy

.PHONY: tgw-acl-policy
tgw-acl-policy: ## Update terminating-gateway ACL policy with external service node, service, and intention policies
	@tgw/acl-policy-update.sh "" default $(SINGLE_CLUSTER)

.PHONY: terminating-gateway
terminating-gateway: ## Apply terminating-gateway resources, and test services
	@tgw/terminating-gateway.sh create $(SINGLE_CLUSTER)

.PHONY: delete-terminating-gateway
delete-terminating-gateway: ## Destroy terminating-gateway resources
	@tgw/terminating-gateway.sh delete $(SINGLE_CLUSTER)

TGW_IMPLEMENTATION=destination # Options: destination|explicit
.PHONY: backend-db
backend-db: ## Deploy external backend-db (non-connect-injected) service (Registration Options: destination/explicit)
	@tgw/backend-db.sh create $(SINGLE_CLUSTER) $(TGW_IMPLEMENTATION) $(CONSUL_K8s_RELEASE_VER) $(OSS)

.PHONY: rm-backend-db
rm-backend-db: ## Destroy backend-db (non-connect-injected) service
	@tgw/backend-db.sh delete $(SINGLE_CLUSTER) $(TGW_IMPLEMENTATION) $(CONSUL_K8s_RELEASE_VER) $(OSS)
# ////////////////////////////////////// Datadog Testing /////////////////////////////////////////// #
# ////////////////////////////////////////////////////////////////////////////////////////////////// #
##@ Datadog
# Datadog Versioning Scheme
DD_OPERATOR_IMAGE_VERSION=1.6.0
DD_AGENT_IMAGE_VERSION=7.54.0
DD_CLUSTER_AGENT_IMAGE_VERSION=7.54.0
.PHONY: install-datadog
install-datadog: version-datadog ##      Install datadog operator and apply datadog/datadog-agent.yaml resources
	@datadog/install-datadog.sh $(DD_OPERATOR_IMAGE_VERSION)

.PHONY: helm-upgrade-datadog
helm-upgrade-datadog: ## Run helm upgrade on datadog
	@datadog/helm-upgrade-dd.sh $(DD_OPERATOR_IMAGE_VERSION)

.PHONY: uninstall-datadog
uninstall-datadog: ##    Run helm uninstall of datadog-operator and delete datadog-agent resources
	@datadog/uninstall-datadog.sh

.PHONY: version-datadog
version-datadog: ##      Verify and set .ddImages.env datadog image versions
	@datadog/datadog-version-set.sh $(DD_OPERATOR_IMAGE_VERSION) $(DD_AGENT_IMAGE_VERSION) $(DD_CLUSTER_AGENT_IMAGE_VERSION)

# ////////////////////////////////////// Dynatrace Testing /////////////////////////////////////////// #
# //////////////////////////////////////////////////////////////////////////////////////////////////// #
##@ Dynatrace
.PHONY: dynatrace-fullstack
dynatrace-fullstack: dynatrace-operator dynakube

.PHONY: dynatrace-operator
dynatrace-operator: ## Deploy Dynatrace Operator to dynatrace namespace
	@dynatrace/dynatrace.sh operator apply

.PHONY: dynakube
dynakube: ## Deploy Classic Full-stack Dynakube
	@dynatrace/dynatrace.sh dynakube apply

.PHONY: uninstall-dynatrace
uninstall-dynatrace: ## Teardown Dynatrace resources from OpenShift
	@dynatrace/dynatrace.sh operator delete
	@dynatrace/dynatrace.sh dynakube delete


# ////////////////////////////////////////////////////////////////////////////////////////////////// #
# ////////////////////////////////////// Teardown ////////////////////////////////////////////////// #
##@ Teardown
.PHONY: pre-uninstall
pre-uninstall: delete-test-apps rm-peering uninstall-consul ## Uninstall demo application scenarios + uninstall Consul
	@scripts/repo-helper.sh clean dc1
	@scripts/repo-helper.sh clean dc2

.PHONY: delete-test-apps
delete-test-apps: delete-api-gw-demo delete-ingress-gw delete-springboot-demo delete-count-dash-demo delete-smtp-demo uninstall-datadog uninstall-dynatrace ## Uninstall demo applications from cluster

.PHONY: run-force-uninstall
run-force-uninstall:
	@scripts/uninstall-consul.sh "$$CLUSTER1_CONTEXT" true
	@scripts/uninstall-consul.sh "$$CLUSTER2_CONTEXT" true

.PHONY: clean
clean: destroy delete-kube-contexts cleanup-openshift-tools clean-aws-credentials ## Destroy aws resources | Cleanup kube contexts | Cleanup openshift/ directory

.PHONY: destroy
destroy: ## Run terraform destroy on aws resources
	@terraform destroy \
		-var local_public_cidr="$(PUBLIC_IP)/32" \
		-auto-approve

.PHONY: clean-aws-credentials
clean-aws-credentials:
	@scripts/doormat-update-creds.sh true

.PHONY: delete-kube-contexts
delete-kube-contexts: ## remove openshift contexts from the kubeconfig file
	@scripts/delete-kube-contexts.sh "$$CLUSTER1_CONTEXT"

.PHONY: cleanup-openshift-tools
cleanup-openshift-tools: ## Cleanup kubeconfig and openshift tooling from openshift/ dir
	@scripts/repo-helper.sh clean-oc-tools dc1
	@scripts/repo-helper.sh clean-oc-tools dc2

.PHONY: destroy-bastion-dc1
destroy-bastion-dc1: ## Target destroy bastion host only from aws
	@terraform destroy \
		-var local_public_cidr="$(PUBLIC_IP)/32" \
		-target=module.bootstrap_primary \
		-auto-approve

.PHONY: destroy-bastion-dc2
destroy-bastion-dc2: ## Target destroy bastion host only from aws
	@terraform destroy \
		-var local_public_cidr="$(PUBLIC_IP)/32" \
		-target=module.bootstrap_secondary \
		-auto-approve

.DEFAULT_GOAL := help
##@ Help

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php
.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

%:
	@: