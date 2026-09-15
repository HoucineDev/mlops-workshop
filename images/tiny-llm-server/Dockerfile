# syntax=docker/dockerfile:1.7
#
# elhou/tiny-llm-server — an OpenAI-compatible LLM server with the model baked in.
#
# Why this image exists at all: KServe's own `kserve/huggingfaceserver` (the
# runtime that would normally give you /v1/chat/completions) publishes
# linux/amd64 ONLY. On an Apple-Silicon kind cluster it cannot run. llama.cpp's
# server does publish linux/arm64, speaks the OpenAI API natively, and runs a
# 135M model on CPU in well under 512Mi.
#
# The GGUF is baked into the image rather than pulled from object storage at
# startup. That deliberately removes KServe's storage-initializer, an S3/GCS
# bucket and a set of credentials from the workshop — the InferenceService
# needs no `storageUri` at all.

# Global build args. These MUST sit above the first FROM: an ARG declared after
# a FROM is scoped to that stage only, and would resolve to empty in stage 2.
#
# The runtime base is pinned by digest so `make image` is reproducible.
# Refresh with: docker buildx imagetools inspect ghcr.io/ggml-org/llama.cpp:server
ARG LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server@sha256:b15cd87030b2eb8a284d398c095e03c6ba8baf386b68e1b83ab8b46e9555ffe8

# ---- stage 1: fetch the model weights -------------------------------------
FROM curlimages/curl:8.11.1 AS weights

ARG MODEL_URL=https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf
# sha256 of the LFS object, taken from HuggingFace's x-linked-etag header:
#   curl -sIL <url> | grep -i x-linked-etag
ARG MODEL_SHA256=2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d

WORKDIR /weights
RUN curl -fsSL --retry 5 --retry-delay 3 -o model.gguf "${MODEL_URL}" \
 && if [ -n "${MODEL_SHA256}" ]; then \
        echo "${MODEL_SHA256}  model.gguf" | sha256sum -c -; \
    else \
        echo "WARNING: MODEL_SHA256 not set, skipping checksum verification"; \
    fi \
 && ls -lh model.gguf

# ---- stage 2: the runtime --------------------------------------------------
FROM ${LLAMA_IMAGE}

# The base image's entrypoint is /app/llama-server and it already sets
# LLAMA_ARG_HOST=0.0.0.0. Every remaining knob is an LLAMA_ARG_* env var, which
# means the Helm chart can override any of them without rebuilding the image.
ENV LLAMA_ARG_MODEL=/models/model.gguf \
    LLAMA_ARG_ALIAS=smollm2-135m-instruct \
    LLAMA_ARG_PORT=8080 \
    LLAMA_ARG_CTX_SIZE=2048 \
    LLAMA_ARG_N_PARALLEL=1 \
    LLAMA_ARG_THREADS=2 \
    LLAMA_ARG_ENDPOINT_METRICS=1

COPY --from=weights /weights/model.gguf /models/model.gguf

# KServe's RawDeployment predictor Service targets 8080 by default.
EXPOSE 8080

# Run unprivileged: the cluster's restricted PodSecurity profile rejects root,
# and nothing here needs it. 65532 = the conventional "nonroot" uid.
USER 65532:65532

# /health is llama-server's own readiness endpoint — it reports 503 until the
# model is fully loaded into memory, which is exactly the signal KServe wants.
LABEL org.opencontainers.image.title="tiny-llm-server" \
      org.opencontainers.image.description="OpenAI-compatible SmolLM2-135M server for KServe on arm64" \
      org.opencontainers.image.source="https://github.com/HoucineDev/mlops-workshop"
