# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_kata_containers_controller
#
# Installs the Kata Containers runtime so Agent Sandbox can run each sandbox
# as a microVM (own guest kernel) instead of a runc pod sharing the host
# kernel. Driven by deploy-kata-containers.yml.
#
# Installed components
# ────────────────────
#   1. kata-deploy (Helm, oci://ghcr.io/kata-containers/kata-deploy-charts)
#        Installs the Kata artifacts on every eligible node and wires them
#        into containerd. Only the shims selected by kata_runtime are enabled;
#        the chart creates one RuntimeClass per shim (kata-fc / kata-qemu).
#
#   2. Node eligibility label (ei-kata-eligible)
#        Applied only to nodes whose preflight found /dev/kvm, so kata-deploy
#        never touches a node that cannot run a microVM.
#
#   3. kata-sandbox-template + kata-pool
#        A SandboxTemplate in the agent-sandbox namespace pinned to the kata
#        RuntimeClass, running the same published python-runtime-sandbox image
#        as the default template, plus a small warm pool.
#
# Configuration
# ─────────────
#   deploy_kata_containers  (agentic-config.cfg)   on / off
#   kata_runtime            (agentic-config.cfg)   kata-fc | kata-qemu | both
#   kata_version            (agentic-metadata.cfg) e.g. 3.32.0
#
# Prerequisites
# ─────────────
#   • deploy_agent_sandbox=on — the SandboxTemplate needs the agent-sandbox CRDs
#   • Hardware virtualisation (/dev/kvm) on the nodes that will run sandboxes
#   • containerd devmapper snapshotter for kata-fc (Firecracker cannot use
#     overlayfs).
#   • vhost_vsock loaded (loaded and persisted automatically)
#   • kata-fc on AMX CPUs (Sapphire Rapids+) needs kernel >= 5.17.
#   Any missing prerequisite stops the deployment with the cause and the
#   per-node preflight results.
#
# Re-run safety
# ─────────────
#   • helm upgrade --install and kubectl apply are idempotent
#   • Node labelling and CR creation use declarative state
# ---------------------------------------------------------------------------

deploy_kata_containers_controller() {
    local kata_version_val="${kata_version:-3.32.0}"
    local kata_runtime_val="${kata_runtime:-kata-fc}"

    # Guard repeated here so the function is safe to call directly.
    if [[ "${deploy_agent_sandbox:-no}" != "yes" ]]; then
        echo ""
        echo "${YELLOW}Agent Sandbox is disabled (deploy_agent_sandbox=off) — skipping Kata Containers.${NC}"
        echo "${YELLOW}Kata provides the sandbox runtime, so enable deploy_agent_sandbox=on first.${NC}"
        echo ""
        return 0
    fi

    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${BLUE}  Deploying Kata Containers via Ansible${NC}"
    echo "${BLUE}  Version  : ${kata_version_val}${NC}"
    echo "${BLUE}  Runtime  : ${kata_runtime_val}${NC}"
    echo "${BLUE}============================================================${NC}"
    echo ""

    ansible-playbook -i "${INVENTORY_PATH}" "${SCRIPT_DIR}/playbooks/deploy-kata-containers.yml" \
        -e "kata_version=${kata_version_val}" \
        -e "kata_runtime=${kata_runtime_val}" \
        -e "agent_sandbox_version=${agent_sandbox_version:-v0.5.0}"

    local exit_code=$?

    echo ""
    if [[ ${exit_code} -eq 0 ]]; then
        echo "${GREEN}============================================================${NC}"
        echo "${GREEN}  Kata Containers step completed!${NC}"
        echo "${GREEN}  Version  : ${kata_version_val}${NC}"
        echo "${GREEN}  Runtime  : ${kata_runtime_val}${NC}"
        echo "${GREEN}============================================================${NC}"
        echo ""
        echo "${CYAN}  Verify:${NC}"
        echo "    kubectl get runtimeclass"
        echo "    kubectl get nodes -l ei-kata-eligible=true"
        echo "    kubectl get sandboxtemplate,sandboxwarmpool -n agent-sandbox-system"
        echo ""
        echo "${CYAN}  Use it from the SDK:${NC}"
        echo "    sandbox = client.create_sandbox(template='kata-sandbox-template', namespace='agent-sandbox-system')"
        echo "    print(sandbox.commands.run('uname -r').stdout)   # microVM kernel, not the host's"
        echo ""
    else
        echo "${RED}============================================================${NC}"
        echo "${RED}  Kata Containers deployment failed!${NC}"
        echo "${RED}  Check Ansible output above for details.${NC}"
        echo "${RED}============================================================${NC}"
        echo ""
        echo "${CYAN}  Troubleshooting:${NC}"
        echo "    kubectl get pods -n kube-system -l name=kata-deploy"
        echo "    kubectl logs -n kube-system -l name=kata-deploy"
        echo "    ls /dev/kvm /dev/vhost-vsock && ctr plugins ls | grep devmapper"
        echo ""
        echo "${CYAN}  kata-fc on AMX CPUs (Sapphire Rapids+) needs kernel >= 5.17:${NC}"
        echo "    uname -r && grep -m1 -o amx_tile /proc/cpuinfo"
        echo "    # if the kernel is older (e.g. 5.15 on Ubuntu 22.04), on that node run:"
        echo "    sudo apt-get update && sudo apt-get install -y linux-generic-hwe-22.04"
        echo "    sudo reboot"
        echo ""
        exit 1
    fi
}
