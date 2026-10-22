# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_bgp_peers() {
    echo "Applying per-node BGPPeer CRDs for secondary fabric uplinks..."
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-bgp-peers.yml
    if [ $? -eq 0 ]; then
        echo "${GREEN}BGPPeer CRDs applied successfully.${NC}"
    else
        echo "${RED}Failed to apply BGPPeer CRDs.${NC}"
        return 1
    fi
}

delete_bgp_peer_crds() {
    local node_name="$1"
    if [ -z "$node_name" ]; then
        echo "${RED}delete_bgp_peer_crds: node name required${NC}"
        return 1
    fi
    echo "Removing BGPPeer CRDs for node: ${node_name}..."
    # Delete all CRDs named <node>-<anything> that reference this node
    kubectl get bgppeers.crd.projectcalico.org \
        -o jsonpath="{.items[?(@.spec.node=='${node_name}')].metadata.name}" \
        | tr ' ' '\n' | grep -v '^$' \
        | xargs -r kubectl delete bgppeers.crd.projectcalico.org
    echo "${GREEN}BGPPeer CRDs for ${node_name} removed.${NC}"
}
