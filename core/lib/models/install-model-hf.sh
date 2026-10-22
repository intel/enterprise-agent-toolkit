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

    # Enforce the naming rule the NOTICE above states. The name becomes a Helm
    # release name and, through it, Service/Ingress names — so an invalid name
    # otherwise fails deep inside the playbook with an opaque helm error.
    # -cpu/-gpu is appended later, hence the 49-char budget against Helm's 53.
    if [ -n "$huggingface_model_deployment_name" ]; then
        if ! [[ "$huggingface_model_deployment_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
            echo -e "${RED}Invalid deployment name '${huggingface_model_deployment_name}': use lowercase letters, numbers and hyphens only, starting and ending with a letter or number. Exiting!!${NC}"
            exit 1
        fi
        if [ ${#huggingface_model_deployment_name} -gt 49 ]; then
            echo -e "${RED}Deployment name '${huggingface_model_deployment_name}' is too long (${#huggingface_model_deployment_name} chars, max 49). Exiting!!${NC}"
            exit 1
        fi
    fi

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

        # Deploy ONLY the requested Hugging Face model. read_config_file/
        # model_selection populate model_name_list from models= in
        # agentic-config.cfg, and deploy_inference_llm_models_playbook emits one
        # install-<model> tag per entry — so leaving it set silently redeployed
        # the pre-validated model from the config file alongside this one.
        models=""
        model_name_list=""

        invoke_prereq_workflows "$@"

        # See install-model.sh's add_model() for why this can't be skipped:
        # invoke_prereq_workflows only syncs core/ into kubespray on the first
        # call per session.
        sync_repo_to_kubespray

        # The CPU model blocks annotate the pod with vllm-balloon-tp<N>, which
        # only resolves if the NRI balloon policy carrying that type has been
        # generated for this node's topology. add_model does this before
        # deploying; without it the pod dies with
        #   CreateContainerError: balloons: no balloon for annotation
        if [ "$compute_platform" == "c" ] && [ "$balloon_policy_cpu" == "enabled" ]; then
            execute_and_check "Deploying CPU Optimization (NRI Balloons & Topology Detection)..." deploy_nri_balloons_playbook "$@" \
                "CPU optimization deployed successfully." \
                "Failed to deploy CPU optimization. Exiting!."
        fi

        # The pre-validated GPU path derives its values file from the model name
        # (gpu-<vendor>-<hwmodel>-*). A Hugging Face model ID carries no hardware
        # hint, so resolve it from the GPU values files the chart ships: without
        # one helm falls back to values.yaml, which requests no GPU at all.
        if [ "$compute_platform" == "g" ] && [ -z "${gpu_values_file_path:-}" ]; then
            gpu_values_candidates=()
            for _values_file in "$HOMEDIR"/helm-charts/vllm/*-values.yaml; do
                [ -e "$_values_file" ] || continue
                case "$(basename "$_values_file")" in
                    xeon-values.yaml|ci-values.yaml|embedding-values.yaml|reranker-values.yaml|guardrail-values.yaml)
                        continue
                        ;;
                esac
                gpu_values_candidates+=("$(basename "$_values_file")")
            done
            if [ ${#gpu_values_candidates[@]} -eq 0 ]; then
                echo -e "${RED}No GPU values file found under $HOMEDIR/helm-charts/vllm. Exiting!!${NC}"
                exit 1
            elif [ ${#gpu_values_candidates[@]} -eq 1 ]; then
                gpu_values_file_path="${REMOTEDIR:-/tmp/helm-charts}/vllm/${gpu_values_candidates[0]}"
            else
                echo "Available GPU values files: ${gpu_values_candidates[*]}"
                read -p "Enter the GPU values file to use [${gpu_values_candidates[0]}]: " _gpu_values_choice
                gpu_values_file_path="${REMOTEDIR:-/tmp/helm-charts}/vllm/${_gpu_values_choice:-${gpu_values_candidates[0]}}"
            fi
            echo "Using GPU values file: ${gpu_values_file_path}"
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

    else
        echo "Required huggingface model name and model id not provided. Exiting!!"
    fi
}