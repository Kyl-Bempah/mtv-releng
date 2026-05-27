IMAGE_NAME := "mtv_pipelines"
WORKDIR    := "app"
NETWORK    := "mtv-dashboard"

.PHONY: update network test build shell dev run
update:
	poetry install --with dev

network:
	podman network exists $(NETWORK) || podman network create $(NETWORK)

test: update
	poetry run pytest

build: test
	podman build -t $(IMAGE_NAME) -f Containerfile .

logs/:
	mkdir -p logs/

data/:
	mkdir -p data/

shell:
	podman run --rm -it \
		--env-file .env \
		--network $(NETWORK) \
		-v ./logs/:/$(WORKDIR)/logs:z \
		-v ./data/:/$(WORKDIR)/data:z \
		$(IMAGE_NAME) /bin/bash

dev: | network logs/ data/ build shell

run: | logs/ data/
	@echo "Running with arguments: $(ARGS)"
	podman run --rm --env-file .env -v ./logs/:/$(WORKDIR)/logs:z -v ./data/:/$(WORKDIR)/data:z -it $(IMAGE_NAME) /bin/bash -c "poetry run python mtv_pipelines/main.py $(ARGS)"
