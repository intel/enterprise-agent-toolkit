# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# deploy_openshell_controller
#
# Deploys NVIDIA OpenShell (https://github.com/NVIDIA/OpenShell) on top of
# Agent Sandbox: a gateway that creates policy-enforced sandboxes as
# agents.x-k8s.io Sandbox CRs (egress default-deny, L7 policy, Landlock,
# seccomp, credential isolation) and a GenAI Gateway provider so sandboxes
# reach LiteLLM with a placeholder key only.
#
# Requires deploy_agent_sandbox=on (CRDs + controller). Version pins live in
# agentic-metadata.cfg (openshell_chart_version, openshell_image_tag,
# openshell_release_tag). Settings: inventory/metadata/vars/inference_openshell.yml.
# ---------------------------------------------------------------------------

# openshell_deploy_fingerprint <core_dir> <chart_version> <image_tag> <release_tag>
#
# Hash of what deploy_openshell_controller applies: the version pins plus the
# OpenShell settings, Helm values, provider profile and playbook. The playbook
# stores it in ConfigMap openshell-deploy-state after a successful run; the
# resume check skips OpenShell only while it still matches, so failed runs,
# version bumps and profile edits are re-applied on the next deployment.
openshell_deploy_fingerprint() {
    local core_dir="$1"
    {
        echo "$2 $3 $4"
        cat "${core_dir}/inventory/metadata/vars/inference_openshell.yml" \
            "${core_dir}/helm-charts/openshell/values.yaml" \
            "${core_dir}/helm-charts/openshell/genai-gateway-provider.yaml" \
            "${core_dir}/playbooks/deploy-openshell.yml"
    } | sha256sum | cut -d' ' -f1
}

# openshell_setting <core_dir> <key>
#
# Top-level scalar from inference_openshell.yml (e.g. openshell_namespace), for the
# shell-side checks and messages that must follow the configured names.
openshell_setting() {
    sed -nE "s/^$2: *\"?([^\"#[:space:]]*)\"?.*/\1/p" \
        "$1/inventory/metadata/vars/inference_openshell.yml" | head -1
}

deploy_openshell_controller() {
    local chart_version="${openshell_chart_version:-0.0.116}"
    local image_tag="${openshell_image_tag:-0.0.116}"
    local release_tag="${openshell_release_tag:-v0.0.116}"
    local ns release fingerprint
    ns="$(openshell_setting "${SCRIPT_DIR}" openshell_namespace)"
    release="$(openshell_setting "${SCRIPT_DIR}" openshell_release_name)"
    fingerprint="$(openshell_deploy_fingerprint "${SCRIPT_DIR}" "${chart_version}" "${image_tag}" "${release_tag}")"

    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${BLUE}  Deploying OpenShell via Ansible${NC}"
    echo "${BLUE}  Chart    : ${chart_version} (images ${image_tag})${NC}"
    echo "${BLUE}============================================================${NC}"
    echo ""

    ansible-playbook -i "${INVENTORY_PATH}" "${SCRIPT_DIR}/playbooks/deploy-openshell.yml" \
        -e "openshell_chart_version=${chart_version}" \
        -e "openshell_image_tag=${image_tag}" \
        -e "openshell_release_tag=${release_tag}" \
        -e "openshell_deploy_fingerprint=${fingerprint}" \
        ${openshell_extra_vars:+-e "${openshell_extra_vars}"}

    local exit_code=$?

    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        echo "${GREEN}  OpenShell deployed successfully!${NC}"
        echo ""
        echo "${CYAN}  Quick-start (admin, from the control plane):${NC}"
        echo "    kubectl port-forward -n ${ns} svc/${release} 8080:8080 &"
        echo "    # client mTLS bundle: secret openshell-client-tls in ${ns}"
        echo "    openshell gateway add https://127.0.0.1:8080 --local --name eat"
        echo "    openshell sandbox create --name demo --provider genai-gateway \\"
        echo "      --env OPENAI_BASE_URL=http://genai-gateway-service.genai-gateway.svc.cluster.local:4000/v1"
        echo ""
    else
        echo "${RED}  OpenShell deployment failed! Check Ansible output above.${NC}"
        echo "    kubectl get pods -n ${ns}"
        echo "    kubectl logs -n ${ns} statefulset/${release}"
        echo ""
        exit 1
    fi
}
