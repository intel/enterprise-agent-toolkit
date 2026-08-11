# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_agent_sandbox_controller
#
# Deploys the Agent Sandbox controller + sandbox-router into the
# `agent-sandbox` namespace using the upstream Helm chart cloned
# from https://github.com/kubernetes-sigs/agent-sandbox at the pinned
# version, and applies a default SandboxTemplate to the `default` namespace.
#
# Installed components
# ────────────────────
#   1. Core CRDs + extension CRDs
#        CRDs are applied directly from the cloned source (helm/crds/).
#        This is safe for both fresh installs and upgrades; Helm does not
#        automatically upgrade CRDs placed in the chart's crds/ directory
#        during `helm upgrade`.
#
#   2. Agent Sandbox controller (Helm)
#        Deployed via helm upgrade --install from the cloned upstream chart
#        (helm/) overlaid with our values at
#        core/helm-charts/agent-sandbox/values.yaml.
#        extensions: true enables the SandboxTemplate, SandboxClaim, and
#        SandboxWarmPool reconcilers.  No WarmPool instances are
#        pre-created; extend by applying SandboxWarmPool CRs later.
#
#   3. sandbox-router image (locally built)
#        Python FastAPI reverse proxy.  No pre-built image exists in the
#        GitHub releases; the image is built with nerdctl + BuildKit from
#        clients/python/agentic-sandbox-client/sandbox-router/Dockerfile
#        in the cloned source tree.
#
#   4. python-runtime-sandbox image (locally built)
#        FastAPI server implementing the Agent Sandbox command-execution API
#        (POST /execute → {stdout, stderr, exit_code}).  Built from
#        examples/python-runtime-sandbox/Dockerfile in the cloned source.
#        This image runs inside each Sandbox pod.
#
#   5. sandbox-router Kubernetes manifest
#        Applied to the agent-sandbox namespace with the locally
#        built image and imagePullPolicy: Never.
#
#   6. Default SandboxTemplate
#        `python-sandbox-template` applied to the `agent-sandbox`
#        namespace so all components share one namespace and the controller's
#        auto-generated NetworkPolicy (app=sandbox-router selector) allows
#        router → sandbox pod traffic:
#          client.create_sandbox(template="python-sandbox-template",
#                                namespace="agent-sandbox")
#        Template YAML lives at core/helm-charts/agent-sandbox/default-templates.yaml.
#
# Version pinning
# ───────────────
#   agent_sandbox_version  (agentic-metadata.cfg)  e.g. v0.4.6
#
# Prerequisites
# ─────────────
#   • Kubernetes is running  (kubectl get nodes)
#   • SCRIPT_DIR points to the core/ directory
#   • Helm: installed automatically if absent
#   • nerdctl / BuildKit: installed automatically if absent
#   • git: used for a shallow clone; falls back to tarball download if absent
#
# Re-run safety
# ─────────────
#   • helm upgrade --install  is idempotent.
#   • kubectl apply           is idempotent.
#   • Image builds            are skipped when the target tag already exists
#                             in the containerd k8s.io namespace.
#   • Source clone            is skipped when the build directory already
#                             contains the expected helm/crds/ path.
# ---------------------------------------------------------------------------

deploy_agent_sandbox_controller() {
    local sandbox_ns="agent-sandbox"
    local sandbox_version="${agent_sandbox_version:-v0.5.0}"

    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${BLUE}  Deploying Agent Sandbox via Ansible${NC}"
    echo "${BLUE}  Version  : ${sandbox_version}${NC}"
    echo "${BLUE}  Namespace: ${sandbox_ns}${NC}"
    echo "${BLUE}============================================================${NC}"
    echo ""

    # Call the Ansible playbook to handle all deployment logic
    ansible-playbook -i "${INVENTORY_PATH}" "${SCRIPT_DIR}/playbooks/deploy-agent-sandbox.yml" \
        -e "agent_sandbox_version=${sandbox_version}"

    local exit_code=$?

    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        echo "${GREEN}============================================================${NC}"
        echo "${GREEN}  Agent Sandbox deployed successfully!${NC}"
        echo "${GREEN}  Version  : ${sandbox_version}${NC}"
        echo "${GREEN}  Namespace: ${sandbox_ns}${NC}"
        echo "${GREEN}============================================================${NC}"
        echo ""
        echo "${CYAN}  Python SDK quick-start (v0.5.0):${NC}"
        echo "    pip install k8s-agent-sandbox==0.5.0"
        echo "    kubectl port-forward -n ${sandbox_ns} svc/sandbox-router-svc 8080:8080 &"
        echo ""
        echo "    from k8s_agent_sandbox import SandboxClient, SandboxDirectConnectionConfig"
        echo "    client = SandboxClient(SandboxDirectConnectionConfig(api_url='http://localhost:8080'))"
        echo "    sandbox = client.create_sandbox(template='python-sandbox-template', namespace='${sandbox_ns}')"
        echo "    print(sandbox.commands.run(\"echo 'Hello from v0.5.0!'\").stdout)"
        echo "    sandbox.terminate()"
        echo ""
    else
        echo "${RED}============================================================${NC}"
        echo "${RED}  Agent Sandbox deployment failed!${NC}"
        echo "${RED}  Check Ansible output above for details.${NC}"
        echo "${RED}============================================================${NC}"
        echo ""
        echo "${CYAN}  Troubleshooting:${NC}"
        echo "    kubectl get pods -n ${sandbox_ns}"
        echo "    kubectl describe deployment -n ${sandbox_ns}"
        echo "    kubectl logs -n ${sandbox_ns} -l app.kubernetes.io/name=agent-sandbox"
        echo ""
        exit 1
    fi
}
