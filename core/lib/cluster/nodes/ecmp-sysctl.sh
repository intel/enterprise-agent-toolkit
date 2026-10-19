# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_ecmp_sysctl() {
    echo "Deploying fabric sysctl (ECMP hashing + star-hub forwarding)..."
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-ecmp-sysctl.yml
    if [ $? -eq 0 ]; then
        echo "${GREEN}ECMP sysctl deployed successfully.${NC}"
    else
        echo "${RED}Failed to deploy ECMP sysctl.${NC}"
        return 1
    fi
}
