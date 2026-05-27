# Production image name
IMAGE_NAME      := "mtv_pipelines"
# Ephemeral image used only for running the test suite
TEST_IMAGE_NAME := "mtv_pipelines_test"
# Working directory inside every container
WORKDIR         := "app"
# Podman network shared between the app and its dependencies
NETWORK         := "mtv-dashboard"

.PHONY: update network test-image test test-local build shell dev run

# Install all dependencies including dev (pytest etc.) into the local venv
update:
	poetry install --with dev

# Create the podman network if it does not already exist
network:
	podman network exists $(NETWORK) || podman network create $(NETWORK)

# Build the lightweight test container image (no skopeo/gh, no root.pem)
test-image:
	podman build -t $(TEST_IMAGE_NAME) -f Containerfile.test .

# Run the full test suite inside the test container; build depends on this
# passing so a broken test prevents a new production image from being built
test: test-image
	podman run --rm $(TEST_IMAGE_NAME)

# Run tests directly in the local venv without rebuilding the container —
# useful for quick iteration during development
test-local: update
	poetry run pytest

# Build the production image; tests must pass first
build: test
	podman build -t $(IMAGE_NAME) -f Containerfile .

logs/:
	mkdir -p logs/

data/:
	mkdir -p data/

# Drop into a bash shell inside a running production container
shell:
	podman run --rm -it \
		--env-file .env \
		--network $(NETWORK) \
		-v ./logs/:/$(WORKDIR)/logs:z \
		-v ./data/:/$(WORKDIR)/data:z \
		$(IMAGE_NAME) /bin/bash

# Full local development cycle: network → logs/data dirs → build → shell
dev: | network logs/ data/ build shell

# Run the pipeline with arbitrary arguments, e.g.: make run ARGS="--help"
run: | logs/ data/
	@echo "Running with arguments: $(ARGS)"
	podman run --rm --env-file .env -v ./logs/:/$(WORKDIR)/logs:z -v ./data/:/$(WORKDIR)/data:z -it $(IMAGE_NAME) /bin/bash -c "poetry run python mtv_pipelines/main.py $(ARGS)"
