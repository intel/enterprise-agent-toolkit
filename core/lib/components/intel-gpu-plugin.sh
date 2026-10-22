# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

run_deploy_intel_gpu_plugin_playbook() {
    echo "Running the deploy-intel-gpu-plugin.yml playbook to deploy the Intel GPU Plugin for XPU..."
    ansible-playbook -i "${INVENTORY_PATH}" --become --become-user=root playbooks/deploy-intel-gpu-plugin.yml \
        --extra-vars "intel_gpu_plugin_ref=${intel_gpu_plugin_ref:-main}" \
        --vault-password-file "$vault_pass_file"
}
