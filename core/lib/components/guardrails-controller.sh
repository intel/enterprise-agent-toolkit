# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# deploy_guardrails_controller
#
# Deploys the content-safety guardrail via the deploy-guardrails.yml playbook:
# the guard model as a vllm-chart release, plus a LiteLLM `custom_code` guardrail
# registered with the GenAI Gateway. Invoked after the GenAI Gateway, which holds
# that registration.
#
# Expected variables (set by the calling deployment flow):
#   • INVENTORY_PATH     — Ansible inventory path
#   • hugging_face_token — HF token for pulling the guardrail model
#   • GUARDRAIL_MODEL    — guardrail model name
#   • HOMEDIR            — core/ directory (its parent holds the code template)
#   • vault_pass_file    — Ansible vault password file
# ---------------------------------------------------------------------------
deploy_guardrails_controller() {
    # Ensure /tmp/helm-charts symlink exists (playbooks expect this path)
    sudo rm -rf /tmp/helm-charts
    sudo ln -sf "$(pwd)/helm-charts" /tmp/helm-charts
    # Balloon gate, same derivation as install-model.sh: CPU platform + policy on.
    local _cpu_playbook="false"
    if [ "${compute_platform:-}" == "c" ]; then
        _cpu_playbook="true"
    fi
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-guardrails.yml \
        --extra-vars "hugging_face_token=${hugging_face_token} \
                      guardrail_model=${GUARDRAIL_MODEL} \
                      guardrails_repo_dir=$(dirname "${HOMEDIR}") \
                      cpu_playbook=${_cpu_playbook} \
                      balloon_policy_cpu=${balloon_policy_cpu:-None}" \
        --vault-password-file "$vault_pass_file"
}
