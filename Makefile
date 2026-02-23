IMAGE_NAME="mtv_pipelines"
WORKDIR="app"

.PHONY: update
update:
	poetry install

.PHONY: build
build:
	podman build -t $(IMAGE_NAME) -f Containerfile .

logs/:
	mkdir -p logs/

.PHONY: shell
shell: | logs/
	podman run --rm --env-file .env -v ./logs/:/$(WORKDIR)/logs:Z -it $(IMAGE_NAME) /bin/bash

.PHONY: run
run: | logs/
	@echo "Running with arguments: $(ARGS)"
	podman run --rm --env-file .env -v ./logs/:/$(WORKDIR)/logs:Z -it $(IMAGE_NAME) /bin/bash -c "poetry run python mtv_pipelines/main.py $(ARGS)"
