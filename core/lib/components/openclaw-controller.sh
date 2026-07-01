# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_openclaw
#
# Installs the OpenClaw Operator only (CRDs + controller).
# The operator manages OpenClawInstance resources.
#
# Instance deployment is a separate manual step because each instance
# needs to be configured for its specific model endpoint and integration.
# Use the helm chart at core/helm-charts/openclaw-instance/ to deploy instances.
#
# What gets installed
# ───────────────────
#   • Namespace: openclaw-operator-system
#   • CRDs: OpenClawInstance, OpenClawClusterDefaults, OpenClawSelfConfig
#   • Deployment: openclaw-operator (controller manager)
#   • Service: openclaw-operator-metrics
#
# Configuration (from agentic-config.cfg)
# ────────────────────────────────────────
#   openclaw_operator_version   Helm chart version (default: latest)
#
# Re-run safety
# ─────────────
#   • helm upgrade --install is idempotent
#
# Instance deployment (manual)
# ────────────────────────────
#   helm install openclaw-enhanced core/helm-charts/openclaw-instance/ \
#     --namespace openclaw --create-namespace \
#     --set model.id="Qwen/Qwen3-Coder-30B-A3B-Instruct" \
#     --set model.baseUrl="http://vllm-qwen3-coder-30b-cpu-service.default.svc.cluster.local:80/v1"
# ---------------------------------------------------------------------------

deploy_openclaw() {
    local operator_ns="openclaw-operator-system"
    local operator_chart="oci://ghcr.io/paperclipinc/charts/openclaw-operator"
    local operator_version="${openclaw_operator_version:-}"

    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${BLUE}  Deploying OpenClaw Operator${NC}"
    echo "${BLUE}  Namespace: ${operator_ns}${NC}"
    echo "${BLUE}  Chart    : ${operator_chart}${NC}"
    echo "${BLUE}============================================================${NC}"

    # ── 0. Prerequisites ─────────────────────────────────────────────────────
    if ! command -v kubectl &>/dev/null; then
        echo "${RED}ERROR: kubectl is not available.${NC}"
        return 1
    fi
    if ! command -v helm &>/dev/null; then
        echo "${RED}ERROR: helm is not available.${NC}"
        return 1
    fi
    if ! kubectl get nodes &>/dev/null 2>&1; then
        echo "${RED}ERROR: Kubernetes cluster is not reachable.${NC}"
        return 1
    fi

    # ── 1. Install OpenClaw Operator ─────────────────────────────────────────
    local helm_version_flag=""
    if [[ -n "${operator_version}" ]]; then
        helm_version_flag="--version ${operator_version}"
    fi

    if kubectl get namespace "${operator_ns}" &>/dev/null 2>&1; then
        echo "  Operator namespace already exists, upgrading..."
    fi

    if ! helm upgrade --install openclaw-operator "${operator_chart}" \
        --namespace "${operator_ns}" \
        --create-namespace \
        ${helm_version_flag} \
        --wait --timeout 120s 2>&1 | while IFS= read -r line; do echo "    ${line}"; done; then
        echo "${RED}  ✗ Failed to install OpenClaw Operator${NC}"
        return 1
    fi

    # Wait for operator to be ready
    echo "  Waiting for operator pod..."
    kubectl wait --for=condition=available deployment -l app.kubernetes.io/name=openclaw-operator \
        -n "${operator_ns}" --timeout=90s 2>/dev/null || {
        echo "${RED}  ✗ Operator pod not ready${NC}"
        return 1
    }

    echo "${GREEN}  ✓ OpenClaw Operator installed${NC}"

    # ── 2. Summary ───────────────────────────────────────────────────────────
    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${GREEN}  ✓ OpenClaw Operator ready${NC}"
    echo "${BLUE}============================================================${NC}"
    echo ""
    echo "  CRDs installed:"
    echo "    - OpenClawInstance"
    echo "    - OpenClawClusterDefaults"
    echo "    - OpenClawSelfConfig"
    echo ""
    echo "  Next step — deploy an instance:"
    echo "    helm install openclaw-enhanced core/helm-charts/openclaw-instance/ \\"
    echo "      --namespace openclaw --create-namespace \\"
    echo "      --set model.id=\"Qwen/Qwen3-Coder-30B-A3B-Instruct\" \\"
    echo "      --set model.baseUrl=\"http://vllm-qwen3-coder-30b-cpu-service.default.svc.cluster.local:80/v1\""
    echo ""
}
