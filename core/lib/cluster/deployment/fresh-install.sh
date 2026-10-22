#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash


fresh_installation() {

     if [[ "$brownfield_deployment" == "yes" ]]; then
        echo "Brownfield deployment setup is selected..."
        # TODO: Check existing cluster status
        deploy_kubernetes_fresh="no"
        skip_check="true"
        # Update config file to reflect that Kubernetes deployment is disabled for Brownfield deployment
        sed -i 's/^deploy_kubernetes_fresh=.*/deploy_kubernetes_fresh=off/' "$SCRIPT_DIR/inventory/agentic-config.cfg" 2>/dev/null || true
        # Comment out the deploy_kubernetes_fresh line to make it clear it's disabled for Brownfield deployment
        # sed -i 's/^deploy_kubernetes_fresh=/#deploy_kubernetes_fresh=/' "$SCRIPT_DIR/inventory/agentic-config.cfg" 2>/dev/null || true
    fi

    read_config_file

    # OpenShell creates Agent Sandbox CRs: require the controller in this run or already on the cluster.
    if [[ "${deploy_openshell:-no}" == "yes" && "${deploy_agent_sandbox:-no}" != "yes" ]]; then
        if [[ "$deploy_kubernetes_fresh" == "yes" ]] || ! kubectl get crd sandboxes.agents.x-k8s.io &>/dev/null; then
            echo "${RED}deploy_openshell=on requires deploy_agent_sandbox=on (Agent Sandbox CRDs not found). Exiting.${NC}"
            exit 1
        fi
    fi

    echo "Deployment configuration: $deploy_kubernetes_fresh"

    if [[  "$deploy_kubernetes_fresh" == "no" && "$deploy_ingress_controller" == "no" && "$deploy_llm_models" == "no" && "$deploy_observability" == "no" && "$deploy_genai_gateway" == "no" && "$deploy_istio" == "no" && "$deploy_ceph" == "no" && "$uninstall_ceph" == "no"  && "$deploy_nri_balloon_policy" == "no" && "$deploy_agenticai_plugin" == "no" && "$deploy_finetune_plugin" == "no" && "$deploy_redis" == "no" && "$deploy_pgvector" == "no" && "${deploy_agent_sandbox:-no}" == "no" && "${deploy_kata_containers:-no}" == "no" && "${deploy_vllm_sr:-no}" == "no" && "${deploy_openshell:-no}" == "no" ]]; then
    # Check if all deployment steps are set to "no" after getting user input
        echo "No installation or deployment steps selected. Skipping setup_initial_env..."
        echo "--------------------------------------------------------------------"
        echo "|     Deployment Skipped for Intel® AI for Enterprise Agent Toolkit!               |"
        echo "--------------------------------------------------------------------"
    else
        prompt_for_input
        if [[ "$brownfield_deployment" == "yes" ]]; then
            read -p "${YELLOW}ATTENTION: Do you wish to continue with Brownfield Deployment setup? (yes/no) ${NC}" -r proceed_with_installation
        else
            read -p "${YELLOW}ATTENTION: Ensure that the nodes do not contain existing workloads. If necessary, please purge any previous cluster configurations before initiating a fresh installation to avoid an inappropriate cluster state. Proceeding without this precaution could lead to service disruptions or data loss. Do you wish to continue with the setup for Intel® AI for Enterprise Agent Toolkit? (yes/no) ${NC}" -r proceed_with_installation
        fi

        if [[ "$proceed_with_installation" =~ ^([yY][eE][sS]|[yY])+$ ]]; then

            setup_initial_env "$@"

             if [[ "$brownfield_deployment" == "yes" ]]; then
                echo "Setting up Bastion Node..."
                setup_bastion "$@"
                INVENTORY_PATH=$brownfield_deployment_host_file
            fi

            # ── Rack-scale mode: generate inventory from rack-profile.yaml ────────────
            # rack_scale_mode=on → run the parser to produce hosts.yaml, netplan files,
            # Calico group_vars, and Ceph vars before Kubespray runs.
            # rack_scale_mode=off (default) → hosts.yaml is used as-is; no-op for
            # standard single-node or hand-crafted multi-node deployments.
            if [[ "${rack_scale_mode:-no}" == "yes" ]]; then
                local _parser="${HOMEDIR}/lib/rack-profile-parser.sh"
                if [[ ! -f "${_parser}" ]]; then
                    echo "${RED}rack_scale_mode=on but parser not found: ${_parser}${NC}"
                    exit 1
                fi

                # Step 1 — Regenerate inventory from rack-profile.yaml
                echo "Rack-scale mode: generating inventory from rack-profile.yaml..."
                bash "${_parser}" || { echo "${RED}rack-profile-parser.sh failed. Exiting.${NC}"; exit 1; }
                echo "Rack-scale inventory generated successfully."

                # Re-source the flags file the parser just wrote so that
                # rack_scale_calico_mode / rack_scale_topology reflect the CURRENT
                # profile. setup_initial_env sourced the previous run's file before
                # the parser ran — without this re-source a first-ever deploy has
                # rack_scale_calico_mode="" and the BGP peers step silently skips.
                local _flags_env="${HOMEDIR}/inventory/metadata/rack-scale-flags.env"
                if [[ -f "${_flags_env}" ]]; then
                    source "${_flags_env}"
                    echo "  -> rack-scale flags reloaded: calico=${rack_scale_calico_mode} topology=${rack_scale_topology:-clos}"
                fi

                # Step 2 — Re-sync generated inventory to kubespray
                # (setup_initial_env already copied the old files before the parser
                # ran — overwrite them with the freshly generated versions)
                if [[ -d "${KUBESPRAYDIR}/inventory/mycluster" ]]; then
                    echo "Rack-scale mode: syncing generated hosts.yaml to kubespray..."
                    cp "${HOMEDIR}/inventory/hosts.yaml" \
                       "${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"
                    # Same reason, for the Calico config: it carries pod_cidr and
                    # service_cidr, so without this re-sync kubespray would build the
                    # cluster with the PREVIOUS run's CIDRs and any change made in
                    # rack-profile.yaml would appear to be ignored.
                    sync_rack_calico_config
                fi

                # Step 3 — Push fabric netplan config to all nodes
                # This makes fabric IPs persistent before Kubespray runs.
                # Kubespray needs all access_ip addresses to be reachable.
                # Addressing only — reachability is verified in Step 5, after the
                # star hub is forwarding. See verify-fabric.yml for why.
                local _netplan_play="${HOMEDIR}/playbooks/deploy-netplan.yml"
                if [[ ! -f "${_netplan_play}" ]]; then
                    echo "${RED}rack_scale_mode=on but deploy-netplan.yml not found: ${_netplan_play}${NC}"
                    exit 1
                fi
                echo "Rack-scale mode: deploying fabric netplan to all nodes..."
                ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" \
                    "${_netplan_play}" \
                    -e "netplan_src_dir=${HOMEDIR}/inventory/netplan" \
                    || { echo "${RED}deploy-netplan.yml failed. Exiting.${NC}"; exit 1; }
                echo "Fabric netplan deployed — all fabric IPs are live."

                # Step 4 — Star hub FORWARD rules, BEFORE Kubernetes.
                #
                # ORDERING IS LOAD-BEARING — star topology only.
                # On a star the hub must forward between legs before anything needs
                # spoke-to-spoke reachability. The FIRST thing that needs it is etcd:
                # kubespray publishes access_ip as each member's peer URL, so the
                # masters must reach each other through the hub for quorum to form.
                # ip_forward=1 alone is not enough — a FORWARD DROP policy silently
                # blackholes transit while hub-to-spoke pings keep working, making
                # the fabric look healthy right up until etcd times out.
                #
                # Clos sites do NOT run this pre-K8s: ecmp_nodes is empty until
                # Calico is running and ToR sessions are Established. Running it
                # early on a Clos site with an empty ecmp_nodes group causes Ansible
                # to error on an undefined host pattern → exit 1 → aborted install.
                # The post-K8s invocation below handles Clos ECMP sysctl.
                #
                # Uses the rack-scale inventory, not INVENTORY_PATH: the groups
                # (fabric_routers / ecmp_nodes) are generated by the parser and the
                # kubespray copy may not exist yet at this point.
                if [[ "${rack_scale_topology:-clos}" == "star" ]]; then
                    local _ecmp_play="${HOMEDIR}/playbooks/deploy-ecmp-sysctl.yml"
                    if [[ -f "${_ecmp_play}" ]]; then
                        echo "Star topology: configuring hub FORWARD rules before Kubernetes..."
                        ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" "${_ecmp_play}" \
                            || { echo "${RED}Hub FORWARD config failed. Exiting — etcd cannot form quorum across a partitioned fabric.${NC}"; exit 1; }
                        echo "Hub FORWARD rules configured — spoke-to-spoke transit is open."
                    fi
                fi

                # Step 5 — Verify fabric reachability, now that transit is open.
                #
                # ORDERING IS LOAD-BEARING. This runs LAST of the fabric steps,
                # after the hub forwards. These checks used to sit at the end of
                # deploy-netplan.yml (Step 3), which probed spoke-to-spoke
                # reachability before Step 4 had opened transit — so a correct
                # star fabric was reported as broken on every redeploy, because
                # reset leaves the hub's FORWARD chain flushed to DROP.
                local _verify_play="${HOMEDIR}/playbooks/verify-fabric.yml"
                if [[ -f "${_verify_play}" ]]; then
                    echo "Rack-scale mode: verifying fabric reachability from the deploy node..."
                    ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" "${_verify_play}" \
                        || { echo "${RED}verify-fabric.yml failed. Exiting.${NC}"; exit 1; }
                    echo "Fabric verified — all quorum member access_ip addresses are reachable."
                fi
            fi
            # ────────────────────────────────────────────────────────────────────────────

            # ── Preflight check — node readiness gate ──────────────────────────
            # Validates NTP, swap, disk space, DNS, gateway on all nodes BEFORE
            # spending 30 min on kubespray. Hard-stops on critical failures.
            # Writes results to the cumulative health report.
            local _preflight_play="${HOMEDIR}/playbooks/preflight-check.yml"
            if [[ -f "${_preflight_play}" && "$skip_check" != "true" ]]; then
                echo -e "${BLUE}Running preflight node readiness checks...${NC}"
                ansible-playbook -i "${INVENTORY_PATH}" "${_preflight_play}" \
                    || echo -e "${YELLOW}WARNING: Preflight check found issues. Review the report above. Continuing deployment...${NC}"
            fi

            if [[ "$deploy_kubernetes_fresh" == "yes" ]]; then
                # ── Docker fail-fast (detection only — never purges) ──────────
                if [[ "$skip_check" != "true" ]]; then
                    run_docker_precheck || exit 1
                else
                    echo "Skipping Docker precheck due to --skip-check argument."
                fi

                echo "Starting fresh installation of Intel® AI for Enterprise Agent Toolkit..."
                install_kubernetes "$@"
                echo "Restarting containerd and kubelet on all nodes to ensure CNI is initialized..."
                ansible -i "${INVENTORY_PATH}" all -b -m shell -a "systemctl restart containerd && sleep 5 && systemctl restart kubelet" --timeout=60 2>/dev/null || true
                sleep 20
            else
                echo "Skipping Kubernetes installation..."
            fi

            # Rack-scale BGP mode: apply per-node BGPPeer CRDs for secondary fabric NICs.
            # Any node with two or more fabric_nics gets a peer CRD for each secondary NIC,
            # using sourceAddress so bird dials the secondary leaf from the correct NIC IP.
            # Single-NIC clusters: the bgp-peers dir is empty → playbook is a no-op.
            if [[ "${rack_scale_mode:-no}" == "yes" && "${rack_scale_calico_mode:-}" == "bgp" ]]; then
                execute_and_check "Applying per-node BGPPeer CRDs for secondary uplinks..." deploy_bgp_peers \
                    "BGPPeer CRDs applied successfully." \
                    "Failed to apply BGPPeer CRDs. Continuing — primary uplink peering unaffected."
            fi

            # Rack-scale: fabric kernel tuning — ECMP hashing on multi-homed nodes and
            # ip_forward on a star hub. Both target parser-derived inventory groups
            # (ecmp_nodes / fabric_routers) which are empty unless the topology needs
            # them, so this is a no-op on single-homed Clos sites. Not gated on
            # calico_mode: a static-routed star still needs its hub to forward.
            if [[ "${rack_scale_mode:-no}" == "yes" ]]; then
                execute_and_check "Configuring ECMP dual-uplink sysctl on fabric nodes..." deploy_ecmp_sysctl \
                    "ECMP sysctl configured successfully." \
                    "Failed to configure ECMP sysctl. Continuing — cluster is functional but secondary uplink will be idle."
            fi

            execute_and_check "Deploying Cluster Configuration Playbook..." deploy_cluster_config_playbook \
                  "Cluster Configuration Playbook is deployed successfully." \
                  "Failed to deploy Cluster Configuration Playbook. Exiting."

            # Intel GPU Plugin — deployed AFTER kubespray, BEFORE models, for Intel XPU
            # (Arc/Flex/Max) deployments. Exposes gpu.intel.com/xe (or /i915) so the
            # vllm-*-xpu pods can request the accelerator resource.
            if [[ "${compute_platform:-}" == "xpu" ]]; then
                execute_and_check "Deploying Intel GPU Plugin..." run_deploy_intel_gpu_plugin_playbook \
                    "Intel GPU Plugin deployed successfully." \
                    "Failed to deploy Intel GPU Plugin. Exiting."
            fi

            # GPU Operator — deployed AFTER kubespray, BEFORE models.
            # rack_scale_gpu_vendor is written by the rack-profile parser (rack_scale_mode=on)
            # when at least one node in the profile carries an accelerator field. The profile
            # is the single source of truth — no separate opt-in flag is needed.
            local _flags_env="${HOMEDIR}/inventory/metadata/rack-scale-flags.env"
            if [[ -f "${_flags_env}" ]]; then
                source "${_flags_env}"
            fi
            if [[ "${rack_scale_gpu_vendor:-}" == "nvidia" ]]; then
                local _gpu_op_play="${HOMEDIR}/playbooks/deploy-nvidia-gpu-operator.yml"
                if [[ ! -f "${_gpu_op_play}" ]]; then
                    echo "${RED}GPU nodes present but playbook not found: ${_gpu_op_play}${NC}"
                    exit 1
                fi
                execute_and_check "Deploying NVIDIA GPU Operator..." deploy_nvidia_gpu_operator_playbook \
                    "NVIDIA GPU Operator deployed successfully." \
                    "Failed to deploy NVIDIA GPU Operator. Exiting."
            else
                echo "Skipping GPU Operator deployment (no GPU nodes in rack profile)."
            fi

            # Deploy NRI CPU Balloons for CPU deployments (after all infrastructure, before models)
            if [[ "$deploy_nri_balloon_policy" == "yes" ]]; then
                # Ensure this is a CPU deployment
                if [[ "$compute_platform" != "c" ]]; then
                    echo "${RED}Error: NRI Balloon Policy can only be deployed for CPU deployments (cpu='c')${NC}"
                    echo "${RED}Current compute_platform setting: '$compute_platform'${NC}"
                    echo "${RED}Please set cpu to 'c' or disable NRI balloon policy deployment. Exiting!${NC}"
                    exit 1
                fi
                execute_and_check "Deploying CPU Optimization (NRI Balloons & Topology Detection)..." deploy_nri_balloons_playbook "$@" \
                    "CPU optimization deployed successfully." \
                    "Failed to deploy CPU optimization. Exiting!."
            else
                echo "Skipping CPU optimization deployment..."
            fi

            if [[ "$uninstall_ceph" == "yes" ]]; then
                execute_and_check "Uninstalling CEPH storage..." uninstall_ceph_cluster "$@" \
                    "CEPH is uninstalled successfully." \
                    "Failed to uninstall CEPH. Exiting!."
            else
                echo "Skipping CEPH storage uninstallation..."
            fi

            if [[ "$deploy_ceph" == "yes" ]]; then
                execute_and_check "Deploying CEPH storage..." deploy_ceph_cluster "$@" \
                    "CEPH is deployed successfully." \
                    "Failed to deploy CEPH. Please use uninstall_ceph option to clean previous installation and format devices if needed."
            else
                echo "Skipping CEPH storage deployment..."
            fi

            if [[ "$deploy_ingress_controller" == "yes" ]]; then
                execute_and_check "Deploying Ingress NGINX Controller..." run_ingress_nginx_playbook \
                    "Ingress NGINX Controller is deployed successfully." \
                    "Failed to deploy Ingress NGINX Controller. Exiting."
                # The admission webhook uses a self-signed cert that other components can't verify.
                # Delete it so downstream helm installs (GenAI Gateway, Observability, etc.) are not blocked.
                echo "Removing ingress-nginx admission webhook (self-signed cert not trusted by helm)..."
                kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found=true
            else
                echo "Skipping Ingress NGINX Controller deployment..."
            fi

            if [[ "$deploy_genai_gateway" == "yes" ]]; then
                echo "successfully deploying genai gateway"
                execute_and_check "Deploying GenAI Gateway..." run_genai_gateway_playbook \
                    "GenAI Gateway is deployed successfully." \
                    "Failed to deploy GenAI Gateway. Exiting."
            else
                echo "Skipping GenAI Gateway deployment..."
            fi

            if [[ "$deploy_observability" == "yes" ]]; then
                echo "Deploying observability..."
                execute_and_check "Deploying Observability..." deploy_observability_playbook "$@" \
                    "Observability is deployed successfully." \
                    "Failed to deploy Observability. Exiting!."
            else
                echo "Skipping Observability deployment..."
            fi
            # Deploy Plugins
            # --------------
            # Plugins are deployed after core infrastructure is ready
            
            if [[ "$deploy_agenticai_plugin" == "yes" ]]; then
                echo "Deploying Agentic AI Plugin (Flowise)..."
                ansible-playbook -i "${INVENTORY_PATH}" ../../plugins/agenticai/playbooks/deploy-agenticai-plugin.yml \
                    --extra-vars "cluster_url=${cluster_url} \
                                  cert_file=${cert_file} \
                                  key_file=${key_file} \
                                  kubernetes_platform=${kubernetes_platform}" \
                    --vault-password-file "$vault_pass_file"
                if [ $? -eq 0 ]; then
                    echo "Agentic AI Plugin deployed successfully."
                else
                    echo "Failed to deploy Agentic AI Plugin. Exiting!."
                    exit 1
                fi
            else
                echo "Skipping Agentic AI Plugin deployment..."
            fi

            if [[ "$deploy_finetune_plugin" == "yes" ]]; then
                echo "Deploying Fine-Tuning Plugin..."
                ansible-playbook -i "${INVENTORY_PATH}" ../../blueprints/finetuning_service/playbooks/deploy-all.yml \
                    --extra-vars "cluster_url=${cluster_url} \
                                  cert_file=${cert_file} \
                                  key_file=${key_file} \
                                  kubernetes_platform=${kubernetes_platform}" \
                    --vault-password-file "$vault_pass_file"
                if [ $? -eq 0 ]; then
                    echo "Fine-Tuning Plugin deployed successfully."
                else
                    echo "Failed to deploy Fine-Tuning Plugin. Exiting!."
                    exit 1
                fi
            else
                echo "Skipping Fine-Tuning Plugin deployment..."
            fi
            
            if [[ "$deploy_istio" == "yes" ]]; then
                echo "Deploying Istio..."
                execute_and_check "Deploying Istio..." deploy_istio_playbook "$@" \
                    "Istio is deployed successfully." \
                    "Failed to deploy Istio. Exiting!."
            else
                echo "Skipping Istio deployment..."
            fi


            if [[ "$deploy_llm_models" == "yes" ]]; then
                model_name_list=$(get_model_names)
                if [ -z "$model_name_list" ]; then
                    echo "No models provided. Exiting..."
                    exit 1
                    fi
                execute_and_check "Deploying Inference LLM Models..." deploy_inference_llm_models_playbook "$@" \
                    "Inference LLM Model is deployed successfully." \
                    "Failed to deploy Inference LLM Model Exiting!."
            else
                echo "Skipping LLM Model deployment..."
            fi

            if [[ "$deploy_redis" == "yes" ]]; then
                execute_and_check "Deploying Standalone Redis Stack..." deploy_redis_controller \
                    "Redis Stack is deployed successfully." \
                    "Failed to deploy Redis Stack. Exiting!."
            else
                echo "Skipping Standalone Redis deployment..."
            fi

            if [[ "$deploy_kuberay" == "yes" ]]; then
                execute_and_check "Deploying KubeRay Operator & Cluster..." deploy_kuberay_controller \
                    "KubeRay Operator & Cluster deployed successfully." \
                    "Failed to deploy KubeRay. Exiting!."
            else
                echo "Skipping KubeRay deployment..."
            fi
            
            if [[ "$deploy_pgvector" == "yes" ]]; then
                execute_and_check "Deploying PostgreSQL + pgvector..." deploy_pgvector_controller \
                    "PostgreSQL + pgvector deployed successfully." \
                    "Failed to deploy PostgreSQL + pgvector. Exiting!."
            else
                echo "Skipping PostgreSQL + pgvector deployment..."
            fi

            if [[ "${deploy_agent_sandbox:-no}" == "yes" ]]; then
                execute_and_check "Deploying Agent Sandbox (CRD controller + sandbox-router)..." deploy_agent_sandbox_controller \
                    "Agent Sandbox deployed successfully." \
                    "Failed to deploy Agent Sandbox. Exiting!."
            else
                echo "Skipping Agent Sandbox deployment..."
            fi

            # Kata microVM runtime — an add-on to Agent Sandbox. The
            # SandboxTemplate it publishes needs the agent-sandbox CRDs, so it
            # cannot be deployed on its own.
            if [[ "${deploy_kata_containers:-no}" == "yes" ]]; then
                if [[ "${deploy_agent_sandbox:-no}" != "yes" ]]; then
                    echo "${YELLOW}WARNING: deploy_kata_containers=on but Agent Sandbox is disabled — skipping Kata Containers deployment.${NC}"
                else
                    execute_and_check "Deploying Kata Containers (${kata_runtime:-kata-fc})..." deploy_kata_containers_controller \
                        "Kata Containers deployed successfully." \
                        "Failed to deploy Kata Containers. Exiting!."
                fi
            else
                echo "Skipping Kata Containers deployment..."
            fi

            # Guardrails — deployed after the GenAI Gateway, which is where the
            # guardrail is registered (and which screens requests against it).
            if [[ "${DEPLOY_GUARDRAILS:-off}" == "on" ]]; then
                execute_and_check "Deploying content-safety guardrail (model: ${GUARDRAIL_MODEL})..." deploy_guardrails_controller \
                    "Content-safety guardrail deployed successfully." \
                    "Failed to deploy content-safety guardrail. Exiting!."
            else
                echo "Skipping content-safety guardrail deployment..."
            fi

            if [[ "${deploy_openshell:-no}" == "yes" ]]; then
                execute_and_check "Deploying OpenShell (policy-enforced sandboxes)..." deploy_openshell_controller \
                    "OpenShell deployed successfully." \
                    "Failed to deploy OpenShell. Exiting!."
            else
                echo "Skipping OpenShell deployment..."
            fi

            if [[ "${deploy_vllm_sr:-no}" == "yes" || "${deploy_vllm_sr:-off}" == "on" ]]; then
                execute_and_check "Deploying vLLM Semantic Router..." run_vllm_sr_playbook \
                    "vLLM Semantic Router deployed successfully." \
                    "Failed to deploy vLLM Semantic Router. Exiting!."
            else
                echo "Skipping vLLM Semantic Router deployment..."
            fi

            if [ "$deploy_llm_models" == "yes" ]; then
            echo -e "${BLUE}-------------------------------------------------------------------------------------${NC}"
            echo -e "${GREEN}|  AI LLM Model Deployment Complete!                                                |${NC}"
            echo -e "${GREEN}|  The model is transitioning to a state ready for Inference.                       |${NC}"
            echo -e "${GREEN}|  This may take some time depending on system resources and other factors.         |${NC}"
            echo -e "${GREEN}|  Please standby...                                                                |${NC}"
            echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

            else
            echo -e "${BLUE}-------------------------------------------------------------------------------------${NC}"
            echo -e "${GREEN}|  AI Inference Deployment Complete!                                                |${NC}"
            echo -e "${GREEN}|  Resources are transitioning to a state ready for Inference.                      |${NC}"
            echo -e "${GREEN}|  This may take some time depending on system resources and other factors.         |${NC}"
            echo -e "${GREEN}|  Please standby...                                                                |${NC}"
            echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"
            echo ""

            fi
        else
            echo "-------------------------------------------------------------------"
            echo "|     Deployment Skipped for Intel® AI for Enterprise Agent Toolkit!               |"
            echo "--------------------------------------------------------------------"
        fi
    fi
}


run_fresh_install_playbook() {
    echo "Running the cluster.yml playbook to set up the Kubernetes cluster..."
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/cluster.yml
}