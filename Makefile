
SHELL = /usr/bin/env bash

#############
# Variables #
#############
# This is normally set by the caller but when building the agent windows installer it needs to be set to something
RELEASE_TAG ?= v0.0.0

# Docker image info
IMAGE_PREFIX ?= grafana
ifeq ($(RELEASE_TAG),v0.0.0)
IMAGE_TAG ?= $(shell ./tools/image-tag)
else
IMAGE_TAG ?= $(RELEASE_TAG)
endif
DRONE ?= false

$(info RELEASE_TAG $(RELEASE_TAG))
$(info IMAGE_TAG $(IMAGE_TAG))

# TARGETPLATFORM is specifically called from `docker buildx --platform`, this is mainly used when pushing docker image manifests, normal generally means NON DRONE builds
TARGETPLATFORM ?=normal

# This is used to set all the environment variables to pass to the go build/seego/docker commands
define SetBuildVarsConditional
$(if $(filter $(1),normal),export CGO_ENABLED=1, \
$(if $(filter $(1),linux/amd64),export CGO_ENABLED=1 GOOS=linux GOARCH=amd64, \
$(if $(filter $(1),linux/arm64),export CGO_ENABLED=1 GOOS=linux GOARCH=arm64, \
$(if $(filter $(1),linux/arm/v7),export CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=7, \
$(if $(filter $(1),linux/arm/v6),export CGO_ENABLED=1 GOOS=linux GOARCH=arm GOARM=6, \
$(if $(filter $(1),darwin/amd64),export CGO_ENABLED=1 GOOS=darwin  GOARCH=amd64, \
$(if $(filter $(1),darwin/arm64),export CGO_ENABLED=1 GOOS=darwin GOARCH=arm64, \
$(if $(filter $(1),windows),export CGO_ENABLED=1 GOOS=windows GOARCH=amd64, \
$(if $(filter $(1),mipls),export CGO_ENABLED=1 GOOS=linux GOARCH=mipsle, \
$(if $(filter $(1),freebsd),export CGO_ENABLED=1 GOOS=freebsd GOARCH=amd64, $(error invalid flag $(1))) \
)))))))))
endef

ALL_CGO_BUILD_FLAGS = $(call SetBuildVarsConditional,$(TARGETPLATFORM))



# Setting CROSS_BUILD=true enables cross-compiling `agent` and `agentctl` for
# different architectures. When true, docker buildx is used instead of docker,
# and seego is used for building binaries instead of go.
CROSS_BUILD ?= false

# Certain aspects of the build are done in containers for consistency.
# If you have the correct tools installed and want to speed up development,
# run make BUILD_IN_CONTAINER=false <target>, or you can set BUILD_IN_CONTAINER=true
# as an environment variable.
BUILD_IN_CONTAINER ?= true
BUILD_IMAGE_VERSION := 0.11.0
BUILD_IMAGE := $(IMAGE_PREFIX)/agent-build-image:$(BUILD_IMAGE_VERSION)

# Enables the binary to be built with optimizations (i.e., doesn't strip the image of
# symbols, etc.)
RELEASE_BUILD ?= false

# Version info for binaries
GIT_REVISION := $(shell git rev-parse --short HEAD)
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)

# When running find there's a set of directories we'll never care about; we
# define the list here to make scanning faster.
DONT_FIND := -name tools -prune -o -name vendor -prune -o -name .git -prune -o -name .cache -prune -o -name .pkg -prune -o

# Build flags
VPREFIX        := github.com/grafana/agent/pkg/build
GO_LDFLAGS     := -X $(VPREFIX).Branch=$(GIT_BRANCH) -X $(VPREFIX).Version=$(IMAGE_TAG) -X $(VPREFIX).Revision=$(GIT_REVISION) -X $(VPREFIX).BuildUser=$(shell whoami)@$(shell hostname) -X $(VPREFIX).BuildDate=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
GO_FLAGS       := -ldflags "-extldflags \"-static\" -s -w $(GO_LDFLAGS)" -tags "netgo static_build"
DEBUG_GO_FLAGS := -gcflags "all=-N -l" -ldflags "-extldflags \"-static\" $(GO_LDFLAGS)" -tags "netgo static_build"
DOCKER_BUILD_FLAGS = --build-arg RELEASE_BUILD=$(RELEASE_BUILD) --build-arg IMAGE_TAG=$(IMAGE_TAG) --build-arg DRONE=$(DRONE)

# We need a separate set of flags for CGO, where building with -static can
# cause problems with some C libraries.
CGO_FLAGS := -ldflags "-s -w $(GO_LDFLAGS)" -tags "netgo"
DEBUG_CGO_FLAGS := -gcflags "all=-N -l" -ldflags "-s -w $(GO_LDFLAGS)" -tags "netgo"
# If we're not building the release, use the debug flags instead.
ifeq ($(RELEASE_BUILD),false)
GO_FLAGS = $(DEBUG_GO_FLAGS)
endif

NETGO_CHECK = strings $@ | grep cgo_stub\\\.go >/dev/null || { \
       rm $@; \
       echo "\nYour go standard library was built without the 'netgo' build tag."; \
       echo "To fix that, run"; \
       echo "    sudo go clean -i net"; \
       echo "    sudo go install -tags netgo std"; \
       false; \
}

# Protobuf files
PROTO_DEFS := $(shell find . $(DONT_FIND) -type f -name '*.proto' -print)
PROTO_GOS := $(patsubst %.proto,%.pb.go,$(PROTO_DEFS))

# Packaging
PACKAGE_VERSION := $(patsubst v%,%,$(RELEASE_TAG))
# The number of times this version of the software was released, starting with 1 for the first release.
PACKAGE_RELEASE := 1

############
# Commands #
############

DOCKERFILE = Dockerfile

# If Go is installed locally mount the local module cache so seego builds
# aren't too slow.
ifeq (, $(shell which go))
MOD_MOUNT=""
else
MOD_MOUNT=-v "$(shell go env GOMODCACHE):/go/pkg/mod"
endif

# seego is used by default when running bare make commands such as `make dist` this uses an image that has all the necessary libraries to cross build
#	when using drone the docker in docker is more problematic so instead drone uses seego has the base image then calls make running "raw" commands
seego = docker run --rm -t $(MOD_MOUNT) -v "$(CURDIR):$(CURDIR)" -w "$(CURDIR)" -e "CGO_ENABLED=$$CGO_ENABLED" -e "GOOS=$$GOOS" -e "GOARCH=$$GOARCH" -e "GOARM=$$GOARM" -e "GOMIPS=$$GOMIPS"  grafana/agent/seego
docker-build = docker build $(DOCKER_BUILD_FLAGS)
ifeq ($(CROSS_BUILD),true)
DOCKERFILE = Dockerfile.buildx
docker-build = docker buildx build --push --platform linux/amd64,linux/arm64,linux/arm/v6,linux/arm/v7 $(DOCKER_BUILD_FLAGS)
endif

# we want to override the default seego behavior. Drone always builds locally inside seego and if build in container is false then use
ifeq ($(DRONE),true)
seego = "/go_wrapper.sh"
else ifeq ($(BUILD_IN_CONTAINER),false)
seego =  go
endif


########
# CRDs #
########

crds:
ifeq ($(BUILD_IN_CONTAINER),true)
	mkdir -p $(shell pwd)/.pkg
	mkdir -p $(shell pwd)/.cache
	docker run -i \
		-v $(shell pwd)/.cache:/go/cache \
		-v $(shell pwd)/.pkg:/go/pkg \
		-v $(shell pwd):/src/agent \
		-e SRC_PATH=/src/agent \
		$(BUILD_IMAGE) $@;
else
	bash ./tools/generate-crds.bash
endif

#############
# Protobufs #
#############

protos: $(PROTO_GOS)

# Use with care; this signals to make that the proto definitions don't need recompiling.
touch-protos:
	for proto in $(PROTO_GOS); do [ -f "./$${proto}" ] && touch "$${proto}" && echo "touched $${proto}"; done

%.pb.go: $(PROTO_DEFS)
ifeq ($(BUILD_IN_CONTAINER),true)
	mkdir -p $(shell pwd)/.pkg
	mkdir -p $(shell pwd)/.cache
	docker run -i \
		-v $(shell pwd)/.cache:/go/cache \
		-v $(shell pwd)/.pkg:/go/pkg \
		-v $(shell pwd):/src/agent \
		-e SRC_PATH=/src/agent \
		$(BUILD_IMAGE) $@;
else
	protoc -I .:./$(@D) --gogoslick_out=Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types,plugins=grpc,paths=source_relative:./ ./$(patsubst %.pb.go,%.proto,$@);
endif

###################
# Primary Targets #
###################
all: protos agent agentctl
agent: cmd/agent/agent
agentctl: cmd/agentctl/agentctl
agent-operator: cmd/agent-operator/agent-operator




# In general DRONE variable should overwrite any other options, if DRONE is not set then fallback to normal behavior

cmd/agent/agent: seego  cmd/agent/main.go
	$(ALL_CGO_BUILD_FLAGS) ; $(seego) build $(CGO_FLAGS) -o $@ ./$(@D)
	$(NETGO_CHECK)


cmd/agentctl/agentctl: seego cmd/agentctl/main.go
	$(ALL_CGO_BUILD_FLAGS) ; $(seego) build $(CGO_FLAGS) -o $@ ./$(@D)
	$(NETGO_CHECK)


cmd/agent-operator/agent-operator: cmd/agent-operator/main.go
	$(ALL_CGO_BUILD_FLAGS) ; $(seego) build $(CGO_FLAGS) -o $@ ./$(@D)
	$(NETGO_CHECK)


agent-image:
	$(docker-build)  -t $(IMAGE_PREFIX)/agent:latest -t $(IMAGE_PREFIX)/agent:$(IMAGE_TAG) -f cmd/agent/$(DOCKERFILE) .
agentctl-image:
	$(docker-build)  -t $(IMAGE_PREFIX)/agentctl:latest -t $(IMAGE_PREFIX)/agentctl:$(IMAGE_TAG) -f cmd/agentctl/$(DOCKERFILE) .
agent-operator-image:
	$(docker-build)  -t $(IMAGE_PREFIX)/agent-operator:latest -t $(IMAGE_PREFIX)/agent-operator:$(IMAGE_TAG) -f cmd/agent-operator/$(DOCKERFILE) .


install:
	CGO_ENABLED=1 go install $(CGO_FLAGS) ./cmd/agent
	CGO_ENABLED=0 go install $(GO_FLAGS) ./cmd/agentctl

#######################
# Development targets #
#######################

lint:
	GO111MODULE=on golangci-lint run -v --timeout=10m

# We have to run test twice: once for all packages with -race and then once more without -race
# for packages that have known race detection issues
# Run tests with -online flag set to true, to include tests requiring network connectivity in CI
test:
	CGO_ENABLED=1 go test $(CGO_FLAGS) -race -cover -coverprofile=cover.out -p=4 ./... -- -online
	CGO_ENABLED=1 go test $(CGO_FLAGS) -cover -coverprofile=cover-norace.out -p=4 ./pkg/integrations/node_exporter ./pkg/logs -- -online

clean:
	rm -rf cmd/agent/agent
	go clean ./...

example-kubernetes:
	cd production/kubernetes/build && bash build.sh

example-dashboards:
	cd example/docker-compose/grafana/dashboards && \
		jsonnet template.jsonnet -J ../../vendor -m .

#############
# Releasing #
#############

# dist builds the agent and agentctl for all different supported platforms.
# Most of these platforms need CGO_ENABLED=1, but to simplify things we'll
# use CGO_ENABLED for all of them. We define them all as separate targets
# to allow for parallelization with make -jX.
#
# We use rfratto/seego as a base for building these cross-platform images.
# seego provides a docker image with gcc toolchains for all of these platforms.
#
# A custom grafana/agent/seego image is built on top of the base image with
# specific overrides. grafana/agent/seego is not pushed to Docker Hub and
# can be built with "make seego".
#
# Note that dist/agent(ctl)-linux-mipsle targets are not included in dist target
# and are included as separate targets to make it easier for users to build them
# manually.
dist: dist-agent dist-agentctl dist-packages
	for i in dist/agent*; do zip -j -m $$i.zip $$i; done
	pushd dist && sha256sum * > SHA256SUMS && popd
.PHONY: dist

####################
# BEGIN AGENT DIST #
####################

dist-agent: seego dist/agent-linux-amd64 dist/agent-linux-arm64 dist/agent-linux-armv6 dist/agent-linux-armv7 dist/agent-darwin-amd64 dist/agent-darwin-arm64 dist/agent-windows-amd64.exe dist/agent-freebsd-amd64 dist/agent-windows-installer.exe
dist/agent-linux-amd64: seego
	$(call SetBuildVarsConditional,linux/amd64) ;      $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-linux-arm64: seego
	$(call SetBuildVarsConditional,linux/arm64) ;      $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-linux-armv6: seego
	$(call SetBuildVarsConditional,linux/arm/v6) ;     $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-linux-armv7: seego
	$(call SetBuildVarsConditional,linux/arm/v7) ;     $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-linux-mipsle: seego
	$(call SetBuildVarsConditional,linux/mipsle) ;     $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-darwin-amd64:  seego
	$(call SetBuildVarsConditional,darwin/amd64) ;     $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-darwin-arm64: seego
	$(call SetBuildVarsConditional,darwin/arm64) ;     $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-windows-amd64.exe: seego
	$(call SetBuildVarsConditional,windows) ;          $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent

dist/agent-windows-installer.exe: dist/agent-windows-amd64.exe
	cp ./dist/agent-windows-amd64.exe ./packaging/windows
	cp LICENSE ./packaging/windows
ifeq ($(BUILD_IN_CONTAINER),true)
	docker build -t windows_installer ./packaging/windows
	docker run --rm -t -v "${PWD}:/home" windows_installer
else

	makensis -V4 -DVERSION=${RELEASE_TAG} -DOUT="../../dist/grafana-agent-installer.exe" ./packaging/windows/install_script.nsis
endif

dist/agent-freebsd-amd64: seego
	$(call SetBuildVarsConditional,freebsd);  $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agent


#######################
# BEGIN AGENTCTL DIST #
#######################

dist-agentctl: seego dist/agentctl-linux-amd64 dist/agentctl-linux-arm64 dist/agentctl-linux-armv6 dist/agentctl-linux-armv7 dist/agentctl-darwin-amd64 dist/agentctl-darwin-arm64 dist/agentctl-windows-amd64.exe dist/agentctl-freebsd-amd64

dist/agentctl-linux-amd64: seego
	$(call SetBuildVarsConditional,linux/amd64);    $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-linux-arm64: seego
	$(call SetBuildVarsConditional,linux/arm64);    $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-linux-armv6: seego
	$(call SetBuildVarsConditional,linux/arm/v6);   $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-linux-armv7: seego
	$(call SetBuildVarsConditional,linux/arm/v7);   $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-linux-mipsle: seego
	$(call SetBuildVarsConditional,linux/mipsle);   $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-darwin-amd64: seego
	$(call SetBuildVarsConditional,darwin/amd64);   $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-darwin-arm64: seego
	$(call SetBuildVarsConditional,darwin/arm64);   $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-windows-amd64.exe: seego
	$(call SetBuildVarsConditional,windows);        $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

dist/agentctl-freebsd-amd64: seego
	$(call SetBuildVarsConditional,freebsd);        $(seego) build $(CGO_FLAGS) -o $@ ./cmd/agentctl

seego: tools/seego/Dockerfile
ifeq ($(DRONE),false)
ifeq ($(BUILD_IN_CONTAINER),true)
	docker build -t grafana/agent/seego tools/seego
endif
endif


build-image/.uptodate: build-image/Dockerfile
	docker pull $(BUILD_IMAGE) || docker build -t $(BUILD_IMAGE) $(@D)
	touch $@

build-image/.published: build-image/.uptodate
ifneq (,$(findstring WIP,$(IMAGE_TAG)))
	@echo "Cannot push a WIP image, commit changes first"; \
	false
endif
	docker push $(IMAGE_PREFIX)/agent-build-image:$(BUILD_IMAGE_VERSION)

packaging/debian-systemd/.uptodate: $(wildcard packaging/debian-systemd/*)
	docker pull $(IMAGE_PREFIX)/debian-systemd || docker build -t $(IMAGE_PREFIX)/debian-systemd $(@D)
	touch $@

packaging/centos-systemd/.uptodate: $(wildcard packaging/centos-systemd/*)
	docker pull $(IMAGE_PREFIX)/centos-systemd || docker build -t $(IMAGE_PREFIX)/centos-systemd $(@D)
	touch $@

#
# Define dist packages. BUILD_IN_CONTAINER=true will send requests to a docker
# container that has fpm installed.
#
.PHONY: dist-packages dist-packages-amd64 dist-packages-arm64 dist-packages-armv6 dist-packages-armv7
dist-packages: dist-packages-amd64 dist-packages-arm64 dist-packages-armv6 dist-packages-armv7

ifeq ($(BUILD_IN_CONTAINER), true)

container_make = docker run --rm \
	-v $(shell pwd):/src/agent:delegated \
	-e RELEASE_TAG=$(RELEASE_TAG) \
	-e SRC_PATH=/src/agent \
	-i $(BUILD_IMAGE)

dist-packages-amd64: enforce-release-tag dist/agent-linux-amd64 dist/agentctl-linux-amd64 build-image/.uptodate
	$(container_make) $@;
dist-packages-arm64: enforce-release-tag dist/agent-linux-arm64 dist/agentctl-linux-arm64 build-image/.uptodate
	$(container_make) $@;
dist-packages-armv6: enforce-release-tag dist/agent-linux-armv6 dist/agentctl-linux-armv6 build-image/.uptodate
	$(container_make) $@;
dist-packages-armv7: enforce-release-tag dist/agent-linux-armv7 dist/agentctl-linux-armv7 build-image/.uptodate
	$(container_make) $@;

else
package_base = ./dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE)
dist-packages-amd64: $(package_base).amd64.deb $(package_base).amd64.rpm
dist-packages-arm64: $(package_base).arm64.deb $(package_base).arm64.rpm
dist-packages-armv6: $(package_base).armv6.deb
dist-packages-armv7: $(package_base).armv7.deb $(package_base).armv7.rpm

ENVIRONMENT_FILE_rpm := /etc/sysconfig/grafana-agent
ENVIRONMENT_FILE_deb := /etc/default/grafana-agent

# generate_fpm(deb|rpm, package arch, agent arch, output file)
define generate_fpm =
	fpm -s dir -v $(PACKAGE_VERSION) -a $(2) \
		-n grafana-agent --iteration $(PACKAGE_RELEASE) -f \
		--log error \
		--license "Apache 2.0" \
		--vendor "Grafana Labs" \
		--url "https://github.com/grafana/agent" \
		-t $(1) \
		--after-install packaging/$(1)/control/postinst \
		--before-remove packaging/$(1)/control/prerm \
		--package $(4) \
			dist/agent-linux-$(3)=/usr/bin/grafana-agent \
			dist/agentctl-linux-$(3)=/usr/bin/grafana-agentctl \
			packaging/grafana-agent.yaml=/etc/grafana-agent.yaml \
			packaging/environment-file=$(ENVIRONMENT_FILE_$(1)) \
			packaging/$(1)/grafana-agent.service=/usr/lib/systemd/system/grafana-agent.service
endef

PACKAGE_PREFIX := dist/grafana-agent-$(PACKAGE_VERSION)-$(PACKAGE_RELEASE)
DEB_DEPS := $(wildcard packaging/deb/**/*) packaging/grafana-agent.yaml
RPM_DEPS := $(wildcard packaging/rpm/**/*) packaging/grafana-agent.yaml

# Build architectures for packaging based on the agent build:
#
# agent amd64, deb amd64, rpm x86_64
# agent arm64, deb arm64, rpm aarch64
# agent armv7, deb armhf, rpm armhfp
# agent armv6, deb armhf, (No RPM for armv6)
#
# These targets require the agent/agentctl binaries to have already been built
# with seego. Since this usually runs inside of a Docker Container, we can't
# build them here.
$(PACKAGE_PREFIX).amd64.deb: $(DEB_DEPS)
	$(call generate_fpm,deb,amd64,amd64,$@)
$(PACKAGE_PREFIX).arm64.deb: $(DEB_DEPS)
	$(call generate_fpm,deb,arm64,arm64,$@)
$(PACKAGE_PREFIX).armv7.deb: $(DEB_DEPS)
	$(call generate_fpm,deb,armhf,armv7,$@)
$(PACKAGE_PREFIX).armv6.deb: $(DEB_DEPS)
	$(call generate_fpm,deb,armhf,armv6,$@)

$(PACKAGE_PREFIX).amd64.rpm: $(RPM_DEPS)
	$(call generate_fpm,rpm,x86_64,amd64,$@)
$(PACKAGE_PREFIX).arm64.rpm: $(RPM_DEPS)
	$(call generate_fpm,rpm,aarch64,arm64,$@)
$(PACKAGE_PREFIX).armv7.rpm: $(RPM_DEPS)
	$(call generate_fpm,rpm,armhfp,armv7,$@)

endif

enforce-release-tag:
	sh -c '[ -n "${RELEASE_TAG}" ] || (echo \$$RELEASE_TAG environment variable not set; exit 1)'

test-packages: enforce-release-tag seego dist-packages-amd64 packaging/centos-systemd/.uptodate packaging/debian-systemd/.uptodate
	./tools/test-packages $(IMAGE_PREFIX) $(PACKAGE_VERSION) $(PACKAGE_RELEASE)
.PHONY: test-package

clean-dist:
	rm -rf dist
.PHONY: clean

publish: dist
	./tools/release

# Drone signs the yaml, you will need to specify DRONE_TOKEN, which can be found by logging into your profile in drone
.PHONY: drone
drone:
	drone lint .drone/drone.yml --trusted
	drone --server https://drone.grafana.net sign --save grafana/agent .drone/drone.yml
