#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

deploy_from_huggingface() {
    echo "-------------------------------------------------"
    echo "|         Deploy Model from Huggingface          |"
    echo "|------------------------------------------------|"    
    hugging_face_model_deployment="true"
    read_config_file "$@"        
    prompt_for_input "$@"    
    skip_check="true"
    if [ -z "$cluster_url" ] || [ -z "$cert_file" ] || [ -z "$key_file" ] || [ -z "$hugging_face_token" ] || [ -z "$models" ]; then
        echo "Some required arguments are missing. Prompting for input..."
        prompt_for_input
    fi        
        
    read -p "Enter the Huggingface Model ID: " huggingface_model_id    
    echo -e "${YELLOW}NOTICE: The model deployment name will be used as the release identifier for deployment. It must be unique, meaningful, and follow Kubernetes naming conventions — lowercase letters, numbers, and hyphens only. Capital letters or special characters are not allowed. ${NC}"
    read -p "Enter Deployment Name for the Model: " huggingface_model_deployment_name
    if [ -n "$huggingface_model_deployment_name" ] && [ -n "$huggingface_model_id" ]; then
        echo -en "${YELLOW}NOTICE: You are about to deploy a model directly from Hugging Face, which has not been pre-validated by our team. Do you wish to continue? (y/n) ${NC}"
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
        execute_and_check "Deploying Inference LLM Models..." deploy_inference_llm_models_playbook "$@" \
            "Inference LLM Model is deployed successfully." \
            "Failed to deploy Inference LLM Model Exiting!." 
        echo -e "${BLUE}-------------------------------------------------------------------------------------${NC}"
        echo -e "${GREEN}|  AI LLM Model Deployment Complete!                                                |${NC}"        
        echo -e "${GREEN}|  The model is transitioning to a state ready for Inference.                       |${NC}"
        echo -e "${GREEN}|  This may take some time depending on system resources and other factors.         |${NC}"
        echo -e "${GREEN}|  Please standby...                                                                |${NC}"
        echo -e "${BLUE}--------------------------------------------------------------------------------------${NC}"

    else
        echo "Required huggingface model name and model id not provided. Exiting!!"
    fi
}