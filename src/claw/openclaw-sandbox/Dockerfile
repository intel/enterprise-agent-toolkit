# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# OpenClaw for the openshell agent runtime: the pinned upstream OpenClaw image, plus pip and
# venv. The agent runs and tests code in this pod, so it builds a venv under /sandbox and
# installs dependencies there; which index it may reach is the sandbox policy's decision, not
# the image's. The OpenShell runtime and supervisor are side-loaded by OpenShell, so nothing
# of theirs is needed here. Bump the digest together with agents.openclaw.digest
# (charts/claw/agent-operator/values.yaml).
# OpenClaw 2026.10.9
FROM ghcr.io/openclaw/openclaw@sha256:1a2a3ce113e435039dbeac5ae261759bb4759908563d91c81059e896b38c5d98

USER root
# upgrade: Debian security fixes released after the OpenClaw image was built.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# OpenShell's workdir. OpenClaw keeps its state and workspace under it (HOME=/sandbox).
RUN install -d -o node -g node /sandbox

USER node
