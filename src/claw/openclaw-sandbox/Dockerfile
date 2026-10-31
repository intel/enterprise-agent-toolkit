# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# OpenClaw for the openshell agent runtime: the pinned upstream OpenClaw image, plus pip and
# venv. The agent runs and tests code in this pod, so it builds a venv under /sandbox and
# installs dependencies there; which index it may reach is the sandbox policy's decision, not
# the image's. The OpenShell runtime and supervisor are side-loaded by OpenShell, so nothing
# of theirs is needed here. Bump the digest together with agents.openclaw.digest
# (charts/claw/agent-operator/values.yaml).
FROM ghcr.io/openclaw/openclaw@sha256:2f5ce8848a1a69b3c460622e566cb9395da9fd18d7ef7b038cd8e2c4f195decf

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# OpenShell's workdir. OpenClaw keeps its state and workspace under it (HOME=/sandbox).
RUN install -d -o node -g node /sandbox

USER node
