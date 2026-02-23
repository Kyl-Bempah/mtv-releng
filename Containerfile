FROM python:3.14

WORKDIR /app

COPY mtv_pipelines/ ./mtv_pipelines/
COPY pyproject.toml .
COPY poetry.lock .
COPY README.md .
COPY root.pem .

RUN pip install poetry

RUN poetry install

RUN apt-get update && apt-get -y install skopeo gh

