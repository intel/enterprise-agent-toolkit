# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash

run_vllm_sr_playbook() {
    echo "Deploying vLLM Semantic Router..."
    echo "************************************"
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-vllm-sr.yml \
        --extra-vars "secret_name=${cluster_url} cert_file=${cert_file} key_file=${key_file} deploy_vllm_sr=${deploy_vllm_sr} model_name_list='${model_name_list//\ /,}' kubernetes_platform=${kubernetes_platform}" \
        --vault-password-file "$vault_pass_file"
}
