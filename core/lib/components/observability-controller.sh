# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_observability_playbook() {
    tags=""
    if [ "${deploy_observability:-}" = "yes" ]; then
        tags+="deploy_observability,"
    fi
    if [ "${deploy_logging:-}" = "yes" ]; then
        tags+="deploy_logging,"
    fi
    tags="${tags%,}"

    local playbook_path="playbooks/deploy-observability.yml"
    if [ "$(echo "${kubernetes_platform:-vanilla}" | tr '[:upper:]' '[:lower:]')" = "openshift" ]; then
        playbook_path="playbooks/deploy-observability-openshift.yml"
    fi

    # Source the rack-scale flags so the observability playbook can conditionally
    # wire up GPU observability (DCGM ServiceMonitor, dashboard, alerts) when the
    # rack profile has NVIDIA GPU nodes. Empty/absent => GPU tasks are skipped.
    local _flags_env="${HOMEDIR}/inventory/metadata/rack-scale-flags.env"
    if [[ -f "${_flags_env}" ]]; then
        source "${_flags_env}"
    fi

    local extra_vars="secret_name=${cluster_url:-} cert_file=${cert_file:-} key_file=${key_file:-} deploy_observability=${deploy_observability:-} deploy_logging=${deploy_logging:-} observability_stack_chart_version=${observability_stack_chart_version:-} kubernetes_platform=${kubernetes_platform:-} rack_scale_gpu_vendor=${rack_scale_gpu_vendor:-}"

    ansible-playbook -i "${INVENTORY_PATH}" "$playbook_path" --become --become-user=root --extra-vars "$extra_vars" --tags "$tags" --vault-password-file "$vault_pass_file"
}