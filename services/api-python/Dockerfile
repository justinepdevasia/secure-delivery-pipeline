# syntax=docker/dockerfile:1
#
# Multi-stage build. Both stages are pinned by digest — a floating tag in a repo
# about supply chain security is a self-inflicted wound.
#
# Builder and runtime are both Debian 13 / Python 3.13, so the site-packages
# directory copied between them is on the interpreter's default path.

# python:3.13-slim-trixie
FROM python@sha256:ffb752e139c0a19692a43af8d8523b274222dd68eebad5d583b45c2201c6e30a AS builder

WORKDIR /build

COPY requirements.txt ./
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir --no-deps --prefix=/install .

# gcr.io/distroless/python3-debian13:nonroot — no shell, no package manager,
# which is what keeps the Trivy CRITICAL/HIGH gate clean.
FROM gcr.io/distroless/python3-debian13@sha256:eff0a6050f5ea9e8154c3d137d468901864803ce3c7f4657d419e64f3f1f8b40

ARG SOURCE_URL="https://github.com/justinepdevasia/secure-delivery-pipeline"
ARG REVISION="unknown"
ARG CREATED="1970-01-01T00:00:00Z"

LABEL org.opencontainers.image.title="api-python" \
      org.opencontainers.image.description="Demo order API for the secure-delivery-pipeline" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="gcr.io/distroless/python3-debian13:nonroot"

COPY --from=builder /install/lib/python3.13/site-packages /usr/lib/python3.13/site-packages
COPY --from=builder /install/bin/uvicorn /usr/local/bin/uvicorn

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/usr/lib/python3.13/site-packages

# The distroless :nonroot tag already runs as uid 65532; stated explicitly so the
# guarantee survives a base image change.
USER 65532:65532

EXPOSE 8000

ENTRYPOINT ["/usr/bin/python3.13", "-m", "uvicorn"]
CMD ["api_python.main:app", "--host", "0.0.0.0", "--port", "8000"]
