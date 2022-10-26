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
	kubectl -n kube-system get pods -o wide

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

.PHONY: e2e
e2e:
	$(eval NODE_COUNT = $(shell kind get nodes --name kube-ovn | wc -l))
	$(eval NETWORK_BRIDGE = $(shell docker inspect -f '{{json .NetworkSettings.Networks.bridge}}' kube-ovn-control-plane))
	@if docker ps -a --format 'table {{.Names}}' | grep -q '^kube-ovn-e2e$$'; then \
		docker rm -f kube-ovn-e2e; \
	fi
	docker run -d --name kube-ovn-e2e --network kind --cap-add=NET_ADMIN $(REGISTRY)/kube-ovn:$(RELEASE_TAG) sleep infinity
	@if [ '$(NETWORK_BRIDGE)' = 'null' ]; then \
		kind get nodes --name kube-ovn | while read node; do \
		docker network connect bridge $$node; \
		done; \
	fi

	@if [ -n "$$VLAN_ID" ]; then \
		kind get nodes --name kube-ovn | while read node; do \
			docker cp test/kind-vlan.sh $$node:/kind-vlan.sh; \
			docker exec $$node sh -c "VLAN_ID=$$VLAN_ID sh /kind-vlan.sh"; \
		done; \
	fi

	@echo "{" > test/e2e/network.json
	@i=0; kind get nodes --name kube-ovn | while read node; do \
		i=$$((i+1)); \
		printf '"%s": ' "$$node" >> test/e2e/network.json; \
		docker inspect -f "{{json .NetworkSettings.Networks.bridge}}" "$$node" >> test/e2e/network.json; \
		if [ $$i -ne $(NODE_COUNT) ]; then echo "," >> test/e2e/network.json; fi; \
	done
	@echo "}" >> test/e2e/network.json

	@if [ ! -n "$$(docker images -q kubeovn/pause:3.2 2>/dev/null)" ]; then docker pull kubeovn/pause:3.2; fi
	kind load docker-image --name kube-ovn kubeovn/pause:3.2
	ginkgo -mod=mod -progress --always-emit-ginkgo-writer --slow-spec-threshold=60s test/e2e
