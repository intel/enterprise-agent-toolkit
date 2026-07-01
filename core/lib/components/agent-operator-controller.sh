# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_agent_operator
#
# Installs the Intel AI Stack Agent Operator:
#   1. Agent CRDs (agents.intel-stack.io/v1alpha1)
#   2. Operator controller (Python/kopf)
#
# The operator reconciles Agent CRs using the facade pattern:
#   - Owns Stack-only concerns (namespace, identity, memory provisioning)
#   - References backend CRs by name (e.g. OpenClawInstance for runtime=claw)
#
# Prerequisites
# ─────────────
#   • Kubernetes cluster running
#   • OpenClaw operator installed (for runtime=claw backend)
#   • Helm 3 installed
#
# Re-run safety
# ─────────────
#   • helm upgrade --install is idempotent
# ---------------------------------------------------------------------------

deploy_agent_operator() {
    local operator_ns="agent-operator-system"
    local crds_chart="${SCRIPT_DIR}/helm-charts/agent-operator-crds"
    local operator_chart="${SCRIPT_DIR}/helm-charts/agent-operator"

    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${BLUE}  Deploying Agent Operator (CRDs + Controller)${NC}"
    echo "${BLUE}  Namespace: ${operator_ns}${NC}"
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

    # ── 1. Install CRDs ─────────────────────────────────────────────────────
    echo ""
    echo "${BLUE}  [1/2] Installing Agent CRDs...${NC}"

    if ! helm upgrade --install agent-operator-crds "${crds_chart}" \
        --namespace "${operator_ns}" \
        --create-namespace \
        --wait --timeout 60s 2>&1 | while IFS= read -r line; do echo "    ${line}"; done; then
        echo "${RED}  ✗ Failed to install Agent CRDs${NC}"
        return 1
    fi

    echo "${GREEN}  ✓ Agent CRDs installed${NC}"

    # ── 2. Install Operator ──────────────────────────────────────────────────
    echo ""
    echo "${BLUE}  [2/2] Installing Agent Operator controller...${NC}"

    if ! helm upgrade --install agent-operator "${operator_chart}" \
        --namespace "${operator_ns}" \
        --create-namespace \
        --wait --timeout 180s 2>&1 | while IFS= read -r line; do echo "    ${line}"; done; then
        echo "${RED}  ✗ Failed to install Agent Operator${NC}"
        return 1
    fi

    # Wait for operator pod
    echo "  Waiting for operator pod..."
    kubectl wait --for=condition=available deployment/agent-operator \
        -n "${operator_ns}" --timeout=120s 2>/dev/null || {
        echo "${YELLOW}  ⚠ Operator pod not ready yet (may still be installing deps)${NC}"
    }

    echo "${GREEN}  ✓ Agent Operator installed${NC}"

    # ── 3. Summary ───────────────────────────────────────────────────────────
    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${GREEN}  ✓ Agent Operator ready${NC}"
    echo "${BLUE}============================================================${NC}"
    echo ""
    echo "  CRDs:"
    echo "    - agents.intel-stack.io/v1alpha1 (kind: Agent)"
    echo ""
    echo "  Create an agent:"
    echo "    kubectl apply -f - <<EOF"
    echo "    apiVersion: intel-stack.io/v1alpha1"
    echo "    kind: Agent"
    echo "    metadata:"
    echo "      name: my-agent"
    echo "    spec:"
    echo "      runtime: claw"
    echo "      owner:"
    echo "        principal: user@intel.com"
    echo "      role: solo"
    echo "    EOF"
    echo ""
}
