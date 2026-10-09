FROM python:3.14

WORKDIR /app

COPY mtv_pipelines/ ./mtv_pipelines/
COPY pyproject.toml .
COPY poetry.lock .
COPY README.md .
COPY root.pem .

RUN pip install poetry

RUN poetry install

RUN apt-get update && apt-get -y install skopeo

RUN (type -p wget >/dev/null || (apt update && apt install wget -y)) \
	&& mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& apt update \
	&& apt install gh -y

# kustomize >= v5.7.1 — required by the konflux_stream pipeline's build-single.sh
RUN apt-get update && apt-get -y install curl \
	&& curl -sfL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" \
	   | bash -s 5.7.1 /usr/local/bin \
	&& kustomize version

# yq (mikefarah/yq v4) — required by build-single.sh's ensure-releaseplan-authors.sh
RUN wget -qO /usr/local/bin/yq \
	"https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" \
	&& chmod +x /usr/local/bin/yq \
	&& yq --version
