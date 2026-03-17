#!make
MIN_MAKE_VERSION := 3.81

ifneq ($(MIN_MAKE_VERSION),$(firstword $(sort $(MAKE_VERSION) $(MIN_MAKE_VERSION))))
$(error GNU Make $(MIN_MAKE_VERSION) or higher required)
endif

SHELL := /bin/bash

.DEFAULT_GOAL := help

CONTAINER     ?= claude-docker
GIT_BRANCH    := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_SHA       := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

##@ Container

.PHONY: start stop restart status rebuild shell exec

start: ## Build image and start container
	@bin/claude-docker-ctrl start

stop: ## Stop container
	@bin/claude-docker-ctrl stop

restart: stop start ## Restart container

status: ## Show container status
	@bin/claude-docker-ctrl status

rebuild: ## Rebuild image from scratch and restart
	@bin/claude-docker-ctrl rebuild

shell: ## Open a fish shell inside the container
	@bin/claude-docker-ctrl shell

exec: ## Start an interactive Claude session inside the container
	@bin/claude-docker-ctrl exec

##@ Testing

.PHONY: test test-verbose

test: ## Run host-side integration tests
	@echo "Running tests (branch: $(GIT_BRANCH), $(GIT_SHA))..."
	@bash test/test-claude-docker.sh

test-verbose: ## Run tests with bash -x tracing
	@bash -x test/test-claude-docker.sh

##@ Docker image

.PHONY: build-image

build-image: ## Build the Docker image without starting
	@docker compose -f docker-compose.yml build

##@ Help

.PHONY: help

help: ## Display this help screen
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
