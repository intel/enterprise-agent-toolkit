
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# shellcheck source=node-profile-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/node-profile-helpers.sh"

add_inference_nodes_playbook() {
    echo "Add Inference LLM Nodes playbook..."
    read -p "Enter the name of the worker node to be added (as defined in hosts.yml): " worker_node_name
    if [ -z "$worker_node_name" ]; then
        echo "Error: No worker node names provided."
        return 1
    fi
    if ! [[ "$worker_node_name" =~ ^[a-zA-Z0-9,-]+$ ]]; then
        echo "Error: Invalid characters in worker node names. Only alphanumeric characters, commas, and hyphens are allowed."
        return 1
    fi

    invoke_prereq_workflows "$@"

    # Rack-scale mode: regenerate inventory and push netplan to the new node
    # before joining it. The node must have its fabric IPs live before Kubespray
    # tries to reach it via access_ip.
    if [[ "${rack_scale_mode:-no}" == "yes" ]]; then
        local _parser="${HOMEDIR}/lib/rack-profile-parser.sh"
        echo "Rack-scale mode: regenerating inventory from rack-profile.yaml..."
        bash "${_parser}" || { echo "${RED}rack-profile-parser.sh failed. Exiting.${NC}"; exit 1; }

        if [[ -d "${KUBESPRAYDIR}/inventory/mycluster" ]]; then
            cp "${HOMEDIR}/inventory/hosts.yaml" "${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"
            # Carries pod_cidr / service_cidr from rack-profile.yaml. cluster.yml
            # below reads them, so a stale copy would join the new node with
            # different CIDRs than the rest of the cluster.
            sync_rack_calico_config
        fi

        # Pick up rack_scale_topology from the metadata the parser just wrote,
        # so the star-only widening below keys off the actual profile.
        local _flags_env="${HOMEDIR}/inventory/metadata/rack-scale-flags.env"
        if [[ -f "${_flags_env}" ]]; then
            # shellcheck source=/dev/null
            source "${_flags_env}"
        fi

        # On a star, adding a spoke ALSO changes the hub: the new cable is a new
        # leg, so the hub gains an address and the fabric gains a /30. Limiting
        # the netplan push to the new node leaves the hub with no address on its
        # end of the cable, and the spoke's next hop never resolves — the join
        # then dies as an opaque kubeadm timeout against the API server.
        # Clos has no hub, so the limit stays exactly as it was there.
        local _netplan_limit="${worker_node_name}"
        if [[ "${rack_scale_topology:-clos}" == "star" ]]; then
            _netplan_limit="${worker_node_name}:fabric_routers"
            echo "  -> star topology: including the fabric hub in the netplan push"
        fi

        echo "Rack-scale mode: pushing fabric netplan to new node(s)..."
        ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" \
            "${HOMEDIR}/playbooks/deploy-netplan.yml" \
            -e "netplan_src_dir=${HOMEDIR}/inventory/netplan" \
            --limit "${_netplan_limit}" \
            || { echo "${RED}deploy-netplan.yml failed. Exiting.${NC}"; exit 1; }

        # On a star the hub's FORWARD chain needs a rule row/column for the new
        # spoke's /30 before anything can reach it across the fabric, so the hub
        # sysctl+iptables step has to happen BEFORE the join, not only after it
        # (the post-join invocation further down stays, for ECMP on BGP sites).
        # Without this the kubeadm join dies as an opaque API server timeout.
        if [[ "${rack_scale_topology:-clos}" == "star" ]]; then
            echo "  -> star topology: opening hub transit for the new spoke..."
            ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" \
                "${HOMEDIR}/playbooks/deploy-ecmp-sysctl.yml" \
                || { echo "${RED}Hub FORWARD config failed. Exiting — the new node is unreachable across the fabric.${NC}"; exit 1; }
        fi

        # Verify only after transit is open — see verify-fabric.yml for the
        # ordering rationale. Limited to the nodes this run touched.
        local _verify_play="${HOMEDIR}/playbooks/verify-fabric.yml"
        if [[ -f "${_verify_play}" ]]; then
            echo "Rack-scale mode: verifying fabric reachability for the new node(s)..."
            ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" "${_verify_play}" \
                --limit "${_netplan_limit}" \
                || { echo "${RED}verify-fabric.yml failed. Exiting.${NC}"; exit 1; }
        fi
    fi

    # GPU host prerequisites — must run BEFORE kubespray join so the driver
    # container finds the correct kernel stack on first boot after the node joins.
    if [[ "${rack_scale_mode:-no}" == "yes" ]]; then
        local _gpu_vendor _gpu_form
        _gpu_vendor="$(get_gpu_vendor "${worker_node_name}")"
        _gpu_form="$(get_gpu_form "${worker_node_name}")"

        if [[ "${_gpu_form}" == "hgx" || "${_gpu_form}" == "sxm" ]]; then
            local _ofed_play="${HOMEDIR}/playbooks/deploy-mlnx-ofed.yml"
            echo "GPU node with form=${_gpu_form} — installing Mellanox OFED before join..."
            ansible-playbook -i "${HOMEDIR}/inventory/hosts.yaml" "${_ofed_play}" \
                --limit "${worker_node_name}" \
                || { echo "${RED}deploy-mlnx-ofed.yml failed. Exiting.${NC}"; exit 1; }
        fi

        if [[ -n "${_gpu_vendor}" && "${_gpu_vendor}" != "nvidia" ]]; then
            echo "${YELLOW}WARNING: GPU vendor '${_gpu_vendor}' on node ${worker_node_name} has no host prereq playbook defined.${NC}"
            echo "${YELLOW}         Continuing — verify vendor-specific drivers are pre-installed on the node.${NC}"
        fi
    fi

    # Use cluster.yml (consistent with infra-automation) to join the new worker
    # node to the existing cluster.
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/cluster.yml --become --become-user=root

    # GPU Operator: re-source flags (parser may have just updated them) and
    # deploy operator if this is the first GPU node of a vendor.
    local _flags_env="${HOMEDIR}/inventory/metadata/rack-scale-flags.env"
    if [[ -f "${_flags_env}" ]]; then source "${_flags_env}"; fi
    if [[ "${rack_scale_gpu_vendor:-}" == "nvidia" ]]; then
        local _operator_running
        _operator_running="$(kubectl get deployment -n gpu-operator gpu-operator \
            --ignore-not-found --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${_operator_running}" == "0" ]]; then
            echo "Adding first GPU node — deploying NVIDIA GPU Operator..."
            execute_and_check "Deploying NVIDIA GPU Operator..." deploy_nvidia_gpu_operator_playbook \
                "NVIDIA GPU Operator deployed successfully." \
                "Failed to deploy NVIDIA GPU Operator. Exiting."
        else
            echo "GPU Operator already running — NFD will auto-discover the new node."
        fi
    fi

    # Intel GPU Plugin: only relevant for XPU (Arc/Flex/Max) clusters. Deployed
    # once per cluster — the resulting DaemonSet auto-schedules to any newly
    # joined node, so this only matters the first time an XPU node is added.
    if [[ "${compute_platform:-}" == "xpu" ]]; then
        local _intel_gpu_plugin_running
        _intel_gpu_plugin_running="$(kubectl get daemonsets -A --no-headers 2>/dev/null | grep -ci intel-gpu-plugin || true)"
        if [[ "${_intel_gpu_plugin_running}" == "0" ]]; then
            echo "Adding first XPU node — deploying Intel GPU Plugin..."
            execute_and_check "Deploying Intel GPU Plugin..." run_deploy_intel_gpu_plugin_playbook \
                "Intel GPU Plugin deployed successfully." \
                "Failed to deploy Intel GPU Plugin. Exiting."
        else
            echo "Intel GPU Plugin already running — DaemonSet will auto-schedule to the new node."
        fi
    fi

    echo "Labeling new worker node with ei-inference-eligible=true..."
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/label-nodes.yml

    # Rack-scale BGP mode: apply any new per-node BGPPeer CRDs and ECMP sysctl
    # for the added node. The playbooks are idempotent — existing nodes unaffected.
    if [[ "${rack_scale_mode:-no}" == "yes" && "${rack_scale_calico_mode:-}" == "bgp" ]]; then
        echo "Rack-scale mode: applying BGPPeer CRDs for new node secondary uplinks..."
        deploy_bgp_peers
    fi

    # Fabric sysctl for the new node. Not gated on calico_mode — a star hub needs
    # ip_forward regardless. The --limit intersects with the playbook's own
    # ecmp_nodes/fabric_routers groups, so a node that needs neither is skipped.
    #
    # On a star the hub must be included: its FORWARD chain carries one scoped
    # ACCEPT per (src,dst) pair of fabric /30s, so a new spoke adds a whole row
    # and column of rules. Without them the hub's DROP policy blackholes every
    # flow to and from the new node while hub-to-spoke ping still works, which
    # looks like a healthy fabric. The new node is almost never the hub, so
    # limiting to it alone meant these rules were never refreshed.
    if [[ "${rack_scale_mode:-no}" == "yes" ]]; then
        local _sysctl_limit="${worker_node_name}"
        if [[ "${rack_scale_topology:-clos}" == "star" ]]; then
            _sysctl_limit="${worker_node_name}:fabric_routers"
        fi
        echo "Rack-scale mode: applying fabric sysctl to new node..."
        ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-ecmp-sysctl.yml \
            --limit "${_sysctl_limit}" 2>/dev/null || true
    fi
}

add_worker_node() {
    echo "Adding a new worker node to the Intel® AI for Enterprise Inference cluster..."
    read -p "${YELLOW}WARNING: Adding a node that is already managed by another Kubernetes cluster or has been manually configured using kubeadm, kubelet, or other tools can cause severe disruptions to your existing cluster. This may lead to issues such as pod restarts, service interruptions, and potential data loss. Do you want to proceed? (y/n) ${NC}" -r user_response
    echo ""    
    user_response=$(echo "$user_response" | tr '[:upper:]' '[:lower:]')        
    if [[ ! $user_response =~ ^(yes|y|Y|YES)$ ]]; then            
        echo "Aborting node addition process. Exiting!!"
        exit 1
    fi
    skip_check="true"
    execute_and_check "Adding new worker nodes..." add_inference_nodes_playbook "$@" \
            "Adding a new worker node to the cluster" \
            "Failed to add worker node Exiting!."
        
    echo -e "${BLUE}------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}|  Node is being added to the Intel® AI for Enterprise Inference Cluster!    |${NC}"
    echo -e "${GREEN}|  This process depends on network and available system resources.          |${NC}"
    echo -e "${GREEN}|  Please stand by while the node is being added...                         |${NC}"
    echo -e "${BLUE}------------------------------------------------------------------------------${NC}"    


    # Reapply NRI balloon policy only for CPU nodes. Gated on the node's own
    # node_family from rack-profile (starts with "cpu-") rather than the
    # cluster-wide compute_platform flag, so mixed CPU+GPU racks work correctly —
    # GPU nodes never get the CPU balloon policy applied.
    local _node_family
    _node_family="$(get_node_profile_field "${worker_node_name}" node_family)"
    if [[ "${_node_family}" == cpu-* ]] && ! is_gpu_node "${worker_node_name}"; then
        echo "CPU node (family=${_node_family}) — reapplying NRI CPU Balloons..."
        execute_and_check "Reapplying NRI CPU Balloons..." deploy_nri_balloons_playbook "$@" \
            "NRI CPU Balloons re-applied successfully." \
            "Failed to reapply NRI CPU Balloons. Exiting!."
        echo -e "${BLUE}------------------------------------------------------------------------------${NC}"
        echo -e "${GREEN}|  NRI CPU Balloons re-applied successfully!                                |${NC}"
        echo -e "${GREEN}|  This process may take some time depending on system resources.     |${NC}"
        echo -e "${GREEN}|  Please stand by while the NRI CPU Balloons are being re-applied... |${NC}"
        echo -e "${BLUE}------------------------------------------------------------------------------${NC}"
    elif [[ -n "${_node_family}" ]]; then
        echo "Non-CPU node (family=${_node_family}) — skipping NRI balloon policy."
    else
        # rack_scale_mode=off or node not in rack-profile — fall back to old behaviour
        if [[ "$compute_platform" == "c" ]]; then
            echo "Reapplying NRI CPU Balloons (non-rack-scale CPU deployment)..."
            execute_and_check "Reapplying NRI CPU Balloons..." deploy_nri_balloons_playbook "$@" \
                "NRI CPU Balloons re-applied successfully." \
                "Failed to reapply NRI CPU Balloons. Exiting!."
        fi
    fi           
}
