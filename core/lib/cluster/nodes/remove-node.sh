# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# shellcheck source=node-profile-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/node-profile-helpers.sh"

remove_inference_nodes_playbook() {
    echo "Remove Inference LLM Nodes playbook..."
    # Prompt the user for the worker node names to be removed
    read -p "Enter the names of the worker nodes to be removed (comma-separated, as defined in hosts.yml): " worker_nodes_to_remove
    if [ -z "$worker_nodes_to_remove" ]; then
        echo "Error: No worker node names provided."
        return 1
    fi
    # Check if the input contains invalid characters
    if ! [[ "$worker_nodes_to_remove" =~ ^[a-zA-Z0-9,-]+$ ]]; then
        echo "Error: Invalid characters in worker node names. Only alphanumeric characters, commas, and hyphens are allowed."
        return 1
    fi
    invoke_prereq_workflows "$@"

    # Rack-scale BGP mode: remove per-node BGPPeer CRDs before draining the node.
    # This prevents the switch from logging repeated connection failures after removal.
    if [[ "${rack_scale_mode:-no}" == "yes" && "${rack_scale_calico_mode:-}" == "bgp" ]]; then
        echo "Rack-scale mode: removing BGPPeer CRDs for node(s): ${worker_nodes_to_remove}..."
        IFS=',' read -ra _nodes <<< "${worker_nodes_to_remove}"
        for _node in "${_nodes[@]}"; do
            delete_bgp_peer_crds "${_node}"
        done
    fi

    # GPU-aware drain: warn on active vLLM pods, extend drain timeout, and warn
    # if this is the last node of a GPU vendor (operator left with no hardware).
    local _drain_timeout="30s"
    IFS=',' read -ra _remove_nodes <<< "${worker_nodes_to_remove}"
    for _node in "${_remove_nodes[@]}"; do
        if ! is_gpu_node "${_node}"; then
            continue
        fi

        # Warn if vLLM pods are actively serving on this node
        local _active_pods
        _active_pods="$(kubectl get pods --all-namespaces --field-selector \
            "spec.nodeName=${_node},status.phase=Running" \
            --no-headers 2>/dev/null \
            | grep -c 'vllm' || true)"
        if [[ "${_active_pods}" -gt 0 ]]; then
            echo "${YELLOW}WARNING: ${_active_pods} active vLLM pod(s) running on GPU node ${_node}.${NC}"
            echo "${YELLOW}         In-flight inference batches will be interrupted. Drain timeout extended to 300s.${NC}"
        fi
        _drain_timeout="300s"

        # Warn if this is the last node of its GPU vendor
        local _vendor
        _vendor="$(get_gpu_vendor "${_node}")"
        if [[ -n "${_vendor}" ]]; then
            local _flags_env="${HOMEDIR}/inventory/metadata/rack-scale-flags.env"
            if [[ -f "${_flags_env}" ]]; then source "${_flags_env}"; fi
            # Count remaining GPU nodes of the same vendor excluding the one being removed
            local _remaining_gpu_nodes
            _remaining_gpu_nodes="$(kubectl get nodes --no-headers \
                -l "gpu-vendor=${_vendor}" 2>/dev/null \
                | grep -v "^${_node} " | wc -l | tr -d ' ')"
            if [[ "${_remaining_gpu_nodes}" == "0" ]]; then
                echo "${YELLOW}WARNING: ${_node} is the last ${_vendor} GPU node in the cluster.${NC}"
                echo "${YELLOW}         After removal the GPU Operator will have no hardware to manage.${NC}"
                echo "${YELLOW}         Consider running: kubectl delete -n gpu-operator deployment gpu-operator${NC}"
            fi
        fi
    done

    # Flush bird routes on the departing node(s) before kubespray's reset role
    # runs its broken xargs-based removal, which fails on ECMP/multipath routes.
    # ip route flush proto bird is a no-op when no bird routes exist.
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/flush-bird-routes.yml --become --become-user=root -e node="$worker_nodes_to_remove" || true

    ansible-playbook -i "${INVENTORY_PATH}" playbooks/remove_node.yml --become --become-user=root \
        -e node="$worker_nodes_to_remove" \
        -e allow_ungraceful_removal=true \
        -e drain_timeout="${_drain_timeout}"

    # Rack-scale: regenerate inventory after removal so all parser-managed files
    # (bgp-peers/, netplan/, group_vars/) are pruned of the departed node.
    # This ensures a subsequent re-add with new IPs or a different leaf never
    # collides with stale manifests from the old configuration.
    if [[ "${rack_scale_mode:-no}" == "yes" ]]; then
        local _parser="${HOMEDIR}/lib/rack-profile-parser.sh"
        echo "Rack-scale mode: regenerating inventory to prune stale node artifacts..."
        bash "${_parser}" || echo "${YELLOW}WARNING: rack-profile-parser.sh failed — clean up core/inventory/ manually.${NC}"

        if [[ -d "${KUBESPRAYDIR}/inventory/mycluster" ]]; then
            cp "${HOMEDIR}/inventory/hosts.yaml" "${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"
            # Keep the Calico config (pod_cidr / service_cidr) in step with the
            # regenerated inventory so a later add-node re-uses identical CIDRs.
            sync_rack_calico_config
        fi
    fi
}

remove_worker_node() {
    echo "Removing a worker node from the Intel® AI for Enterprise Agent Toolkit..."
    read -p "${YELLOW}WARNING: Removing a worker node will drain all resources from the node, which may cause service interruptions or data loss. This process cannot be undone. Do you want to proceed? (y/n)${NC} " -r user_response
    user_response=$(echo "$user_response" | tr '[:upper:]' '[:lower:]')        
    if [[ ! $user_response =~ ^(yes|y|Y|YES)$ ]]; then        
        echo "Aborting node removal process. Exiting!!"
        exit 1
    fi
    echo "Draining resources and detaching the worker node. This may take some time..."
    skip_check="true"
    execute_and_check "Removing worker nodes..." remove_inference_nodes_playbook "$@" \
            "Removing  worker node is successful." \
            "Failed to remove worker node Exiting!."
    echo "------------------------------------------------------------------------"
    echo "|     Node is being removed from Intel® AI for Enterprise Agent Toolkit!               |"
    echo "------------------------------------------------------------------------"
    
}