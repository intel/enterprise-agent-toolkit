# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# Agent operator image. The unit tests are a build gate: a failing test fails the build.
ARG PYTHON_IMAGE=docker.io/library/python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

FROM ${PYTHON_IMAGE} AS deps
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --prefix=/install -r /tmp/requirements.txt

FROM ${PYTHON_IMAGE} AS test
COPY --from=deps /install /usr/local
WORKDIR /t
COPY . .
RUN PYTHONDONTWRITEBYTECODE=1 python -m unittest -v \
      test_controller_names test_controller_rbac test_controller_secretref test_claw_adapter \
    && touch /t/PASSED

FROM ${PYTHON_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/code
COPY --from=deps /install /usr/local
COPY controller.py claw_adapter.py openclaw-instance.yaml.j2 /code/
# BuildKit skips stages nothing copies from; this keeps the test gate in the build.
COPY --from=test /t/PASSED /code/.tests-passed
# kopf resolves the user name at startup, so the UID needs a passwd entry; pip is not
# needed at runtime.
RUN useradd --system --uid 65532 --no-create-home --shell /usr/sbin/nologin agent-operator \
    && python -m pip uninstall --yes --quiet pip
USER 65532:65532
EXPOSE 8080
CMD ["python", "-m", "kopf", "run", "/code/controller.py", "--all-namespaces", "--standalone", \
     "--liveness=http://0.0.0.0:8080/healthz"]
