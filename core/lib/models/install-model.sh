#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_inference_llm_models_playbook() {
    echo "Deploying Inference LLM Models playbook..."
    install_true="true"
    enable_cpu_balloons="false"
    cpu_playbook="false"
    gpu_playbook="false"
    xpu_playbook="false"

    if [ "$compute_platform" == "c" ]; then
        cpu_playbook="true"
        enable_cpu_balloons="true"  # Enable NRI balloons for CPU deployments
        # Suffix only a name the operator actually typed. On the pre-validated
        # path this is empty and must stay empty — suffixing unconditionally
        # yields a bare "-cpu" release name and an "install--cpu" tag.
        [ -n "$huggingface_model_deployment_name" ] && \
            huggingface_model_deployment_name="${huggingface_model_deployment_name}-cpu"
        if [ "$balloon_policy_cpu" == "enabled" ]; then
            echo "${GREEN}CPU deployment detected - using generic NRI balloon policy${NC}"
        fi
    elif [ "$compute_platform" == "g" ]; then
        gpu_playbook="true"
        [ -n "$huggingface_model_deployment_name" ] && \
            huggingface_model_deployment_name="${huggingface_model_deployment_name}-gpu"
        echo "${GREEN}GPU deployment detected - using GPU values file${NC}"
        # Derive gpu_values_file_path from the resolved model name list when
        # models= was blank in the config (user picked interactively) so the
        # path was never set during config parsing.
        if [[ -z "${gpu_values_file_path:-}" && -n "${model_name_list:-}" ]]; then
            local _first_resolved
            _first_resolved="$(echo "${model_name_list}" | awk '{print $1}')"
            if [[ "${_first_resolved}" == gpu-*-*-* ]]; then
                local _hw_model
                _hw_model="$(echo "${_first_resolved}" | cut -d'-' -f3)"
                gpu_values_file_path="/tmp/helm-charts/vllm/${_hw_model}-values.yaml"
                echo "Derived GPU values file path: ${gpu_values_file_path}"
            fi
        fi
    elif [ "$compute_platform" == "xpu" ]; then
        xpu_playbook="true"
        huggingface_model_deployment_name="${huggingface_model_deployment_name}-xpu"
        echo "${GREEN}XPU deployment detected - using XPU values file${NC}"
        # xpu_values_file_path is normally set in setup-env.sh, but derive it
        # here too in case this function is reached via a code path that
        # skipped setup (e.g. add-model on an already-bootstrapped cluster).
        if [[ -z "${xpu_values_file_path:-}" ]]; then
            xpu_values_file_path="/tmp/helm-charts/vllm/xpu-values.yaml"
            echo "Derived XPU values file path: ${xpu_values_file_path}"
        fi
    fi
    # Default kubernetes_platform to "vanilla" for standard on-prem clusters
    # (brownfield sets it explicitly; fresh installs leave it empty).
    if [[ -z "${kubernetes_platform:-}" ]]; then
        kubernetes_platform="vanilla"
    fi
    if [ "$deploy_observability" == "yes" ]; then
        vllm_metrics_enabled="true"        
    else
        vllm_metrics_enabled="false"        
    fi

    echo "Model Metrics Enabled: $vllm_metrics_enabled"
    echo "CPU NRI Balloons: $enable_cpu_balloons"
    
    tags=""
    for model in $model_name_list; do
        tags+="install-$model,"
    done    
    
    # Dedupe on the tag we are about to add. Testing for install-$huggingface_model_id
    # never matched, because the tag is built from the deployment name — so a
    # repeated deploy of the same model appended the tag twice.
    if [ -n "$huggingface_model_deployment_name" ] && [[ ",$tags" != *",install-$huggingface_model_deployment_name,"* ]]; then
        tags+="install-$huggingface_model_deployment_name,"
    fi

    # Always include install-genai-gateway tag so model registration in
    # LiteLLM runs regardless of whether genai-gateway itself is being deployed
    tags+="install-genai-gateway,"
    
    tags=${tags%,}

    if [[ "$brownfield_deployment" == "yes" ]]; then
        echo "Brownfield deployment setup is selected..."
        INVENTORY_PATH=$brownfield_deployment_host_file
        echo $INVENTORY_PATH
        echo "Brownfield deployment setup was selected..."
    fi
        
    ansible-playbook -i "${INVENTORY_PATH}" playbooks/deploy-inference-models.yml \
        --extra-vars "kubernetes_platform=${kubernetes_platform} secret_name=${cluster_url} cert_file=${cert_file} key_file=${key_file} hugging_face_token=${hugging_face_token} install_true=${install_true} model_name_list='${model_name_list//\ /,}' cpu_playbook=${cpu_playbook} huggingface_model_id=${huggingface_model_id} hugging_face_model_deployment=${hugging_face_model_deployment} huggingface_model_deployment_name=${huggingface_model_deployment_name} deploy_inference_llm_models_playbook=${deploy_inference_llm_models_playbook} huggingface_tensor_parellel_size=${huggingface_tensor_parellel_size} deploy_genai_gateway=${deploy_genai_gateway} vllm_metrics_enabled=${vllm_metrics_enabled} xeon_values_file=${xeon_values_file_path} deploy_ceph=${deploy_ceph} enable_cpu_balloons=${enable_cpu_balloons} balloon_policy_cpu=${balloon_policy_cpu} aws_certificate_arn=${aws_certificate_arn} gpu_playbook=${gpu_playbook} gpu_values_file=${gpu_values_file_path} xpu_playbook=${xpu_playbook} xpu_values_file=${xpu_values_file_path}" --tags "$tags" --vault-password-file "$vault_pass_file"

}

add_model() {
    read_config_file "$@"        
    prompt_for_input "$@"  
    skip_check="true"  
    if [ -z "$cluster_url" ] || [ -z "$cert_file" ] || [ -z "$key_file" ] || [ -z "$hugging_face_token" ] || [ -z "$models" ]; then
        echo "Some required arguments are missing. Prompting for input..."
        prompt_for_input "$@"
    fi    
    model_name_list=$(get_model_names)
    if [ -z "$model_name_list" ]; then
        echo "No models provided. Exiting..."
        exit 1
    fi
    echo "Deploying models: $model_name_list"
    if [ -n "$models" ]; then
        echo -en "${YELLOW}NOTICE: You are initiating a model deployment. This will create the required services. Do you wish to continue? (y/n) ${NC}"
        read -r user_response
        echo ""
        user_response=$(echo "$user_response" | tr '[:upper:]' '[:lower:]')          
        if [[ ! $user_response =~ ^(yes|y|Y|YES)$ ]]; then        
            echo "Deployment process has been cancelled. Exiting!!"
            exit 1
        fi
        if [ "$brownfield_deployment" == "yes" ]; then
        echo "Setting up Bastion Node..."
        setup_bastion "$@"
        INVENTORY_PATH=$brownfield_deployment_host_file
        fi        
        invoke_prereq_workflows "$@"

        # Re-sync core/helm-charts, core/roles, core/playbooks into the kubespray
        # checkout ansible-playbook actually runs from. invoke_prereq_workflows
        # only does this on the FIRST call per script session (gated by
        # $prereq_executed) -- without this, editing xeon-values.yaml (or any
        # role) mid-session and redeploying via this menu keeps reading
        # whatever was copied at session start.
        sync_repo_to_kubespray

        # Deploy NRI CPU Balloons for CPU deployments (after all infrastructure, before models)
        if [[ "$deploy_nri_balloon_policy" == "yes" ]]; then
            # Ensure this is a CPU deployment — GPU deployments do not use NRI balloons
            if [[ "$compute_platform" != "c" ]]; then
                    echo "${RED}Error: NRI Balloon Policy can only be deployed for CPU deployments (compute_platform='c')${NC}"
                    echo "${RED}Current compute_platform setting: '$compute_platform'${NC}"
                    echo "${RED}Please set compute_platform to 'c' or disable NRI balloon policy deployment. Exiting!${NC}"
                    exit 1
            fi
            execute_and_check "Deploying CPU Optimization (NRI Balloons & Topology Detection)..." deploy_nri_balloons_playbook "$@" \
                "CPU optimization deployed successfully." \
                "Failed to deploy CPU optimization. Exiting!."
        else
            echo "Skipping CPU optimization deployment..."
        fi
        execute_and_check "Deploying Inference LLM Models..." deploy_inference_llm_models_playbook "$@" \
            "Inference LLM Model is deployed successfully." \
            "Failed to deploy Inference LLM Model Exiting!." 
        echo -e "${BLUE}-------------------------------------------------------------------------------------${NC}"
        echo -e "${GREEN}|  AI LLM Model Deployment Complete!                                                |${NC}"        
        echo -e "${GREEN}|  The model is transitioning to a state ready for Inference.                       |${NC}"
        echo -e "${GREEN}|  This may take some time depending on system resources and other factors.         |${NC}"
        echo -e "${GREEN}|  Please standby...                                                                |${NC}"
        echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

    fi
}
