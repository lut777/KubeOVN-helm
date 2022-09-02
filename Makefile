GO_VERSION = 1.18
SHELL=/bin/bash

REGISTRY = kubeovn
DEV_TAG = dev
RELEASE_TAG = $(shell cat VERSION)
COMMIT = git-$(shell git rev-parse --short HEAD)
DATE = $(shell date +"%Y-%m-%d_%H:%M:%S")
GOLDFLAGS = "-w -s -extldflags '-z now' -X github.com/kubeovn/kube-ovn/versions.COMMIT=$(COMMIT) -X github.com/kubeovn/kube-ovn/versions.VERSION=$(RELEASE_TAG) -X github.com/kubeovn/kube-ovn/versions.BUILDDATE=$(DATE)"

CONTROL_PLANE_TAINTS = node-role.kubernetes.io/master node-role.kubernetes.io/control-plane

MULTUS_IMAGE = ghcr.io/k8snetworkplumbingwg/multus-cni:stable
MULTUS_YAML = https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

CILIUM_VERSION = 1.11.6
CILIUM_IMAGE_REPO = quay.io/cilium/cilium

VPC_NAT_GW_IMG = $(REGISTRY)/vpc-nat-gateway:$(RELEASE_TAG)
MASTERS = ""

join-with = $(subst $(space),$1,$(strip $2))

.PHONY: kind-init
kind-init: kind-clean
	kube_proxy_mode=ipvs ip_family=ipv4 ha=false single=false j2 yamls/kind.yaml.j2 -o yamls/kind.yaml
	kind create cluster --config yamls/kind.yaml --name kube-ovn
	kubectl describe no

.PHONY: kind-install
kind-install: kind-load-image kind-untaint-control-plane
	$(eval NODESNUMBER = $(shell docker exec -i kube-ovn-control-plane kubectl get nodes --no-headers=true | wc -l))
	$(eval MASTERNODES = $(shell docker exec -i kube-ovn-control-plane kubectl get nodes -l node-role.kubernetes.io/control-plane=""  -o jsonpath='{.items[*].status.addresses[].address}'))
	$(eval EMPTY := )
	$(eval SPACE := $(EMPTY))
	$(eval MASTERS = $(subst SPACE,,,$(strip $$(MASTERNODES))))
	cd .. && sudo helm install kubeovn ./KubeOVN-helm --set cni_conf.MASTER_NODES=$(MASTERNODES) --set nodes=$(NODESNUMBER)
	kubectl describe no

.PHONY: kind-clean
kind-clean:
	kind delete cluster --name=kube-ovn
	docker ps -a -f name=kube-ovn-e2e --format "{{.ID}}" | while read c; do docker rm -f $$c; done

.PHONY: kind-load-image
kind-load-image:
	kind load docker-image --name kube-ovn $(REGISTRY)/kube-ovn:$(RELEASE_TAG)

.PHONY: kind-untaint-control-plane
kind-untaint-control-plane:
	@for node in $$(kubectl get no -o jsonpath='{.items[*].metadata.name}'); do \
		for key in $(CONTROL_PLANE_TAINTS); do \
			taint=$$(kubectl get no $$node -o jsonpath="{.spec.taints[?(@.key==\"$$key\")]}"); \
			if [ -n "$$taint" ]; then \
				kubectl taint node $$node $$key:NoSchedule-; \
			fi; \
		done; \
	done

.PHONY: tar-kube-ovn
tar-kube-ovn:
	docker save $(REGISTRY)/kube-ovn:$(RELEASE_TAG) -o kube-ovn.tar
