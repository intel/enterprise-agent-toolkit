# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_nvidia_gpu_operator_playbook() {
    echo "Deploying NVIDIA GPU Operator..."
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-nvidia-gpu-operator.yml \
        --extra-vars "nvidia_gpu_operator_version=${nvidia_gpu_operator_version}" \
        --vault-password-file "$vault_pass_file"
}
