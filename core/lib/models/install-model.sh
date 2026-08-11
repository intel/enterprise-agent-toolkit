#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_inference_llm_models_playbook() {
    echo "Deploying Inference LLM Models playbook..."    
    install_true="true"
    enable_cpu_balloons="false"
    
    if [ "$compute_platform" == "c" ]; then
        cpu_playbook="true"
        enable_cpu_balloons="true"  # Enable NRI balloons for CPU deployments
        huggingface_model_deployment_name="${huggingface_model_deployment_name}-cpu"
        if [ "$balloon_policy_cpu" == "enabled" ]; then
            echo "${GREEN}CPU deployment detected - using generic NRI balloon policy${NC}"
        fi        
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
    
    if [ -n "$huggingface_model_id" ] && [[ "$tags" != *"install-$huggingface_model_id"* ]]; then
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
        --extra-vars "kubernetes_platform=${kubernetes_platform} secret_name=${cluster_url} cert_file=${cert_file} key_file=${key_file} hugging_face_token=${hugging_face_token} install_true=${install_true} model_name_list='${model_name_list//\ /,}' cpu_playbook=${cpu_playbook} huggingface_model_id=${huggingface_model_id} hugging_face_model_deployment=${hugging_face_model_deployment} huggingface_model_deployment_name=${huggingface_model_deployment_name} deploy_inference_llm_models_playbook=${deploy_inference_llm_models_playbook} huggingface_tensor_parellel_size=${huggingface_tensor_parellel_size} deploy_genai_gateway=${deploy_genai_gateway} vllm_metrics_enabled=${vllm_metrics_enabled} xeon_values_file=${xeon_values_file_path} deploy_ceph=${deploy_ceph} enable_cpu_balloons=${enable_cpu_balloons} balloon_policy_cpu=${balloon_policy_cpu} aws_certificate_arn=${aws_certificate_arn}" --tags "$tags" --vault-password-file "$vault_pass_file"

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

        # Deploy NRI CPU Balloons for CPU deployments (after all infrastructure, before models)
        if [[ "$deploy_nri_balloon_policy" == "yes" ]]; then
            # Ensure this is a CPU deployment
            if [[ "$compute_platform" != "c" ]]; then
                    echo "${RED}Error: NRI Balloon Policy can only be deployed for CPU deployments (cpu='c')${NC}"
                    echo "${RED}Current compute_platform setting: '$compute_platform'${NC}"
                    echo "${RED}Please set cpu to 'c' or disable NRI balloon policy deployment. Exiting!${NC}"
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
