# Requirements
# docker or podman installed and running
# git installed
# .git_token file exists with current Token (or injected as the GIT_TOKEN env var)
# Linux OS

ifndef WORKFLOW_ID
$(error WORKFLOW_ID variable is not defined. Please provide the required value)
endif

ifndef APPLICATION_ID
APPLICATION_ID = UNDEFINED
endif

ifndef LOCAL_TEST
LOCAL_TEST = false
endif

ifeq ($(APPLICATION_ID), UNDEFINED)
IS_WORKFLOW = true
IS_APPLICATION = false
else
IS_WORKFLOW = false
IS_APPLICATION = true
endif

CONTAINER_ENGINE ?= $(shell which podman >/dev/null 2>&1 && echo podman || echo docker)
ifneq (,$(wildcard $(CURDIR)/.docker))
	DOCKER_CONF := $(CURDIR)/.docker
else
	DOCKER_CONF := $(HOME)/.docker
endif

WORKDIR := $(shell mktemp -d)
ifeq ($(shell uname),Darwin)
	# Use a fixed folder to simplify limactl configuration (must be mounted with Write permissions)
	WORKDIR := /tmp/serverless-workflows
endif
ifeq ($(LOCAL_TEST), true)
	WORKDIR := ~/workdir
endif
SCRIPTS_DIR := scripts

GIT_USER_NAME ?= $(shell git config --get user.name)
GIT_USER_EMAIL ?= $(shell git config --get user.email)
GIT_REMOTE_URL := $(shell git config --get remote.origin.url)
GIT_REMOTE_URL := $(shell echo "$(GIT_REMOTE_URL)" | sed 's/\.git//')
GIT_REMOTE_URL := $(shell echo "$(GIT_REMOTE_URL)" | sed 's/git@/https:\/\//')
GIT_REMOTE_URL := $(shell echo "$(GIT_REMOTE_URL)" | sed 's/com:/com\//')
PR_OR_COMMIT_URL ?= "$(GIT_REMOTE_URL)/commits/$(shell git rev-parse --short=8 HEAD)"
ifneq (,$(findstring push-manifests,$(MAKECMDGOALS)))
  ifndef GIT_TOKEN
    ifeq ($(wildcard .git_token),)
      $(error No Git token found. Please provide it either via the GIT_TOKEN variable or the .git_token file )
    endif
    GIT_TOKEN ?= $(shell cat .git_token)
  endif
endif

LINUX_IMAGE ?= quay.io/orchestrator/ubi9-pipeline:latest
JDK_IMAGE ?= registry.access.redhat.com/ubi9/openjdk-17:1.17
BUILD_APPLICATION_SCRIPT ?= $(SCRIPTS_DIR)/build_application.sh
MVN_OPTS ?= -B

IMAGE_NAME := ""
REGISTRY ?= quay.io
REGISTRY_REPO ?= $(shell id -un)
REGISTRY_USERNAME ?= ""
REGISTRY_PASSWORD ?= ""
IMAGE_PREFIX ?= serverless-workflow
IMAGE_TAG ?= $(shell git rev-parse --short=8 HEAD)
ifeq ($(IS_WORKFLOW),true)
DOCKERFILE ?= pipeline/workflow-builder.Dockerfile
else 
DOCKERFILE ?= src/main/docker/Dockerfile.jvm
endif

DEV_DOCKERFILE ?= pipeline/workflow-builder-dev.Dockerfile

ifeq ($(IS_WORKFLOW),true)
IMAGE_NAME = $(REGISTRY)/$(REGISTRY_REPO)/$(IMAGE_PREFIX)-$(WORKFLOW_ID)
else
IMAGE_NAME = $(REGISTRY)/$(REGISTRY_REPO)/$(IMAGE_PREFIX)-$(APPLICATION_ID)
endif

DEPLOYMENT_REPO ?= parodos-dev/serverless-workflows-config
DEPLOYMENT_BRANCH ?= main

ENABLE_PERSISTENCE ?= false

# extra extensions needed for persistence at build time.
# The extentions listed below are included in the cache in image quay.io/kiegroup/kogito-swf-builder:9.99.1.CR1 or available from maven central repository
QUARKUS_EXTENSIONS=org.kie.kogito:kogito-addons-quarkus-jobs-knative-eventing:9.99.1.redhat-00003,org.kie.kogito:kogito-addons-quarkus-persistence-jdbc:9.99.1.redhat-00003,org.kie.kogito:kogito-addons-persistence-jdbc:9.99.1.redhat-00003,io.quarkus:quarkus-jdbc-postgresql:3.2.9.Final,io.quarkus:quarkus-agroal:3.2.9.Final
QUARKUS_DEV_EXTENSIONS=""
#org.kie:kie-addons-quarkus-persistence-jdbc:999-20240317-SNAPSHOT,io.quarkus:quarkus-jdbc-postgresql:3.2.9.Final,io.quarkus:quarkus-agroal:3.2.9.Final

# build time properties required for persistence.
MAVEN_ARGS_APPEND="-Dkogito.persistence.type=jdbc -Dquarkus.datasource.db-kind=postgresql -Dkogito.persistence.proto.marshaller=false"

.PHONY: all

all: build-image push-image gen-manifests push-manifests
for-local-tests: build-image push-image gen-manifests

# Target: prepare-workdir
# Description: copies the local repo content in a temporary WORKDIR for file manipulation.
# Usage: make prepare-workdir
prepare-workdir:
	@echo "Preparing workdir $(WORKDIR)"
	@rm -rf $(WORKDIR)
	@mkdir -p $(WORKDIR)
	@cp -R . $(WORKDIR)
	@find $(WORKDIR) -type d -name target -prune -exec rm -rf {} \;


# Target: build-image
# Description: Builds the workflow containerized image from the given WORKDIR.
# Depends on: prepare-workdir target.
# Usage: make build-image
ifeq ($(IS_WORKFLOW),true)
build-image: BUILD_ARGS=--build-arg WF_RESOURCES=$(WORKFLOW_ID) --build-arg=QUARKUS_EXTENSIONS=$(QUARKUS_EXTENSIONS) --build-arg=MAVEN_ARGS_APPEND=$(MAVEN_ARGS_APPEND)
endif
build-image: EXTRA_ARGS=--ulimit nofile=4096:4096
build-image: prepare-workdir
	@echo "Building $(IMAGE_NAME)"
ifeq ($(IS_APPLICATION),true)
	# First build the application
	$(BUILD_APPLICATION_SCRIPT) $(CONTAINER_ENGINE) $(WORKDIR) $(WORKFLOW_ID) $(APPLICATION_ID) $(JDK_IMAGE) $(MVN_OPTS)
	# Then build the containerized image from the application source
	@cd $(WORKDIR)/$(WORKFLOW_ID)/$(APPLICATION_ID) && $(CONTAINER_ENGINE) build -f $(DOCKERFILE) \
		$(BUILD_ARGS) $(EXTRA_ARGS) \
		--tag ${IMAGE_NAME}:${IMAGE_TAG} --tag ${IMAGE_NAME}:latest .
else
	@$(CONTAINER_ENGINE) build -f $(DOCKERFILE) \
		$(BUILD_ARGS) $(EXTRA_ARGS) \
		--tag ${IMAGE_NAME}:${IMAGE_TAG} --tag ${IMAGE_NAME}:latest .
endif

build-dev-image: QUARKUS_EXTENSIONS=$(QUARKUS_DEV_EXTENSIONS)
build-dev-image: DOCKERFILE=$(DEV_DOCKERFILE)
build-dev-image: build-image

# Target: push-image
# Description: Pushes the workflow containerized image to the configured REGISTRY.
# Usage: make push-image
push-image: 
	@echo "Pushing $(IMAGE_NAME)"
ifneq ($(strip $(REGISTRY_USERNAME)),"")
ifneq ($(strip $(REGISTRY_PASSWORD)),"")
	@echo "${REGISTRY_PASSWORD}" | $(CONTAINER_ENGINE) login -u ${REGISTRY_USERNAME} --password-stdin ${REGISTRY}
endif
endif
	@$(CONTAINER_ENGINE) push ${IMAGE_NAME}:latest
	@$(CONTAINER_ENGINE) push ${IMAGE_NAME}:${IMAGE_TAG}

# Target: save-oci
# Description: Extracts the containerized image to a local file in the current folder.
# Depends on: build-image target.
# Usage: make save-oci
ifeq ($(IS_WORKFLOW),true)
save-oci: OCI_NAME=$(IMAGE_PREFIX)-$(WORKFLOW_ID)-$(IMAGE_TAG).tar
else
save-oci: OCI_NAME=$(IMAGE_PREFIX)-$(APPLICATION_ID)-$(IMAGE_TAG).tar
endif
save-oci: build-image
	@echo "Saving OCI archive $(OCI_NAME)"
	@$(CONTAINER_ENGINE) save ${IMAGE_NAME}:${IMAGE_TAG} -o ${OCI_NAME}

# Target: gen-manifests
# Description: Generates the k8s manifests for the WORKFLOW_ID workflow under the configured WORKDIR.
# Depends on: prepare-workdir target.
# Usage: make gen-manifests
gen-manifests: prepare-workdir
	cd $(WORKDIR)
	@$(CONTAINER_ENGINE) run --rm -v $(WORKDIR):/workdir -w /workdir \
		$(LINUX_IMAGE) /bin/bash -c "${SCRIPTS_DIR}/gen_manifests.sh $(WORKFLOW_ID) $(ENABLE_PERSISTENCE)"
	@echo "Manifests are available in workdir $(WORKDIR)/$(WORKFLOW_ID)/manifests"

# Target: push-manifests
# Description: Pushes the generated k8s manifests from the configured WORKDIR to the 
# configured DEPLOYMENT_REPO.
# Usage: make push-manifests
push-manifests: prepare-workdir
	cd $(WORKDIR)
	@$(CONTAINER_ENGINE) run --rm -v $(WORKDIR):/workdir -w /workdir \
		$(LINUX_IMAGE) /bin/bash -c "${SCRIPTS_DIR}/push_manifests.sh '$(GIT_USER_NAME)' $(GIT_USER_EMAIL) $(GIT_TOKEN) $(PR_OR_COMMIT_URL) $(DEPLOYMENT_REPO) $(DEPLOYMENT_BRANCH) $(WORKFLOW_ID) $(APPLICATION_ID) $(IMAGE_NAME) $(IMAGE_TAG)"