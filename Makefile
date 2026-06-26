# Makefile — convenience entrypoints for the Coriolis Windows worker builder.
# Thin wrappers around the scripts in build/ and the manifests in harvester/.
# Every variable below can be overridden, e.g.  make build-harvester NS=labs
#
# There are TWO ways to build the same coriolis-windows-worker.qcow2 — pick ONE,
# you do NOT need both:
#   make build-local      # build here with local KVM/libvirt
#   make build-harvester  # build on a throwaway Harvester build-host VM
#
# Quick start:
#   make config           # create build/config.env from the template, then edit it
#   make build-local      # ...or build-harvester (then `make logs` to follow it)
# (build-local / build-harvester each download their own assets; `make assets`
#  just pre-caches them here and is optional.)

SHELL := /bin/bash

# --- Harvester / kubectl targets -------------------------------------------
# (keep comments off the assignment lines — trailing text becomes part of the value)
NS              ?= default
SECRET          ?= coriolis-builder-cloudinit
BUILD_VM        ?= coriolis-worker-builder
BUILD_PVC       ?= coriolis-builder-root
TEST_NS         ?= coriolis-worker-test
TEST_VM         ?= coriolis-windows-worker
# virtctl is only needed to reach a VM console (make logs / smoke-test). Match
# your cluster: kubectl get kubevirt -A -o jsonpath='{.items[0].status.observedKubeVirtVersion}'
KUBEVIRT_VERSION ?= v1.7.0

# --- Paths -----------------------------------------------------------------
USER_DATA       := cloud-init/user-data.yaml
CONFIG          := build/config.env
CONFIG_EXAMPLE  := build/config.env.example
SECRET_ENV      := build/config.secret.env
SECRET_EXAMPLE  := build/config.secret.env.example

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@echo "Coriolis Windows worker builder — make targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Two build paths produce the same image — pick ONE:"
	@echo "  build-local      build here with local KVM/libvirt"
	@echo "  build-harvester  build on a throwaway Harvester build-host VM"

# --- local config ----------------------------------------------------------
.PHONY: config
config: ## Create build/config.env + config.secret.env from the examples (won't clobber existing ones)
	@if [ -f $(CONFIG) ]; then \
	  echo "$(CONFIG) already exists — leaving it untouched."; \
	else \
	  cp $(CONFIG_EXAMPLE) $(CONFIG); \
	  echo "Created $(CONFIG) — edit tunables (HARVESTER_SERVER, UPLOAD_TO_HARVESTER, *_SHA256, ...)."; \
	fi
	@if [ -f $(SECRET_ENV) ]; then \
	  echo "$(SECRET_ENV) already exists — leaving it untouched."; \
	else \
	  cp $(SECRET_EXAMPLE) $(SECRET_ENV); chmod 600 $(SECRET_ENV); \
	  echo "Created $(SECRET_ENV) (mode 600) — put your HARVESTER_TOKEN / BUILD_ADMIN_PASSWORD here."; \
	fi

# --- cloud-init ------------------------------------------------------------
.PHONY: cloud-init
cloud-init: ## (Re)generate cloud-init/user-data.yaml from build/ + windows/
	./generate-cloud-init.sh

# --- Harvester build -------------------------------------------------------
.PHONY: build-harvester
build-harvester: cloud-init ## Build the worker qcow2 on a Harvester build-host VM (generate cloud-init + secret + apply)
	kubectl -n $(NS) create secret generic $(SECRET) \
	  --from-file=userdata=$(USER_DATA) \
	  --from-literal=networkdata='' \
	  --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f harvester/leap-image.yaml
	./harvester/apply-with-storageclass.sh $(NS) opensuse-leap-16-cloud harvester/leap-build-host.yaml
	@echo "Build host applied. Follow progress with: make logs"

.PHONY: logs
logs: ## Open the build-host VM console to follow the build log (needs virtctl)
	@command -v virtctl >/dev/null 2>&1 || { \
	  echo "virtctl not found — it's how you reach the build VM (the log lives *inside* it,"; \
	  echo "not on this machine). Install it, matching your cluster's KubeVirt $(KUBEVIRT_VERSION):"; \
	  echo "    curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/virtctl-$(KUBEVIRT_VERSION)-linux-amd64"; \
	  echo "    chmod +x virtctl && sudo mv virtctl /usr/local/bin/"; \
	  echo "  (or grab it from the Harvester UI: Support > Download virtctl), then rerun 'make logs'."; \
	  exit 1; \
	}
	@echo "Opening the $(BUILD_VM) console. Log in as builder/builder, then run:"
	@echo "    tail -f ~builder/coriolis-worker-build/coriolis-build.log"
	@echo "Leave the console with Ctrl-] . Falling back to VNC: virtctl vnc -n $(NS) $(BUILD_VM)"
	virtctl console -n $(NS) $(BUILD_VM)

.PHONY: destroy
destroy: ## Delete the Harvester build-host VM, its root PVC and cloud-init secret
	# Delete the VM first and wait for the VMI to terminate — otherwise the volume
	# is still attached and Harvester's webhook refuses to delete the PVC.
	-kubectl -n $(NS) delete vm $(BUILD_VM) --ignore-not-found
	-kubectl -n $(NS) wait --for=delete vmi/$(BUILD_VM) --timeout=120s
	-kubectl -n $(NS) delete pvc $(BUILD_PVC) --ignore-not-found
	-kubectl -n $(NS) delete secret $(SECRET) --ignore-not-found

# --- smoke test ------------------------------------------------------------
.PHONY: smoke-test
smoke-test: ## Boot the built image in an isolated test namespace (does it come up on virtio?)
	kubectl create namespace $(TEST_NS) --dry-run=client -o yaml | kubectl apply -f -
	./harvester/apply-with-storageclass.sh $(TEST_NS) $(TEST_VM) harvester/worker-vm.yaml
	@echo "Watch:   kubectl -n $(TEST_NS) get vmi $(TEST_VM) -w"
	@echo "Console: virtctl vnc -n $(TEST_NS) $(TEST_VM)"
	@command -v virtctl >/dev/null 2>&1 || echo "         (no virtctl? install it: https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/virtctl-$(KUBEVIRT_VERSION)-linux-amd64 — or see 'make logs')"

.PHONY: smoke-clean
smoke-clean: ## Tear down the smoke-test namespace
	-kubectl delete ns $(TEST_NS)

# --- local (libvirt) build -------------------------------------------------
.PHONY: assets
assets: ## Download the Windows ISO, VMDP ISO and cloudbase-init MSI
	./build/download-assets.sh

.PHONY: build-local
build-local: ## Build the worker qcow2 here with local KVM/libvirt (no Harvester)
	./build/build-worker.sh

# --- housekeeping ----------------------------------------------------------
.PHONY: clean
clean: ## Remove the generated cloud-init (does not touch downloaded assets)
	rm -f $(USER_DATA)
