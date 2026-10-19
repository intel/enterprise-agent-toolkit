#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

model_selection(){
    
    if [ "$list_model_menu" != "skip" ]; then
        if [ -z "$hugging_face_token" ] && [ "$deploy_llm_models" = "yes" ]; then
            read -p "Enter the token for Huggingface: " hugging_face_token
        else
            echo "Using provided Huggingface token"            
        fi
        if [ -z "$deploy_llm_models" ]; then
            read -p "Do you want to proceed with deploying Large Language Model (LLM)? (yes/no): " deploy_llm_models
            if [ "$deploy_llm_models" == "yes" ]; then
                model_name_list=$(get_model_names)    
                echo "Proceeding to deploy models: $model_name_list"
            fi
        else
            model_name_list=$(get_model_names)                       
            echo "Proceeding with the setup of Large Language Model (LLM): $deploy_llm_models"
        fi
        if [ "$deploy_llm_models" = "yes" ]; then
            if [ "$hugging_face_model_deployment" != "true" ]; then                        
                if [ -z "$models" ]; then
                    if [ "$hugging_face_model_remove_deployment" != "true" ]; then
                        if [ "$compute_platform" = "x" ] || [ "$compute_platform" = "xpu" ]; then
                            # Prompt for XPU models
                            echo "Available Models for XPU Deployment:"
                            echo "31. Qwen/Qwen3-Coder-30B-A3B-Instruct"
                            echo "32. Qwen/Qwen2.5-Coder-14B-Instruct"
                            echo "33. meta-llama/Llama-3.1-8B-Instruct"
                            echo "34. Qwen/Qwen3-Coder-Next"
                            echo "35. google/gemma-4-31B-it"
                            echo "36. Qwen/Qwen3.6-27B"
                            read -p "Enter the number of the XPU model you want to deploy/remove: " xpu_model
                            # Validate input
                            if ! [[  "$xpu_model" =~ ^(31|32|33|34|35|36)$ ]]; then
                                echo "Error: Invalid model selected ($xpu_model). Exiting." >&2
                                exit 1
                            fi
                            models="$xpu_model"
                        elif [ "$compute_platform" = "g" ] || [ "$compute_platform" = "gpu" ]; then
                            # Prompt for GPU models
                            echo "Available Models for GPU Deployment:"
                            echo "41. meta-llama/Llama-3.1-70B-Instruct (NVIDIA B300 HGX)"
                            read -p "Enter the number of the GPU model you want to deploy/remove: " gpu_model
                            # Validate input
                            if ! [[ "$gpu_model" =~ ^(41)$ ]]; then
                                echo "Error: Invalid model selected ($gpu_model). Exiting." >&2
                                exit 1
                            fi
                            models="$gpu_model"
                        else
                            # Prompt for CPU models
                            echo "Available Models for CPU Deployment:"
                            echo "21. Qwen/Qwen3-Coder-30B-A3B-Instruct"
                            echo "22. Qwen/Qwen2.5-Coder-14B-Instruct"
                            echo "23. BAAI/bge-base-en-v1.5 (Embedding)"
                            echo "24. BAAI/bge-reranker-base (Reranker)"
                            echo "25. Qwen/Qwen3-30B-A3B-Instruct-2507"
                            echo "26. google/gemma-4-26B-A4B-it"
                            echo "27. meta-llama/Llama-3.1-8B-Instruct"
                            echo "28. meta-llama/Llama-3.1-8B-Instruct (Speculative Decoding)"
                            echo "29. Qwen/Qwen3-Coder-30B-A3B-Instruct (Speculative Decoding)"
                            echo "30. Qwen/Qwen3.6-35B-A3B"
                            read -p "Enter the number of the CPU model you want to deploy/remove: " cpu_model
                            # Validate input
                            if ! [[  "$cpu_model" =~ ^(21|22|23|24|25|26|27|28|29|30)$ ]]; then
                                echo "Error: Invalid model selected ($cpu_model). Exiting." >&2
                                exit 1
                            fi
                            models="$cpu_model"
                        fi
                    fi
                else
                    if [ "$hugging_face_model_deployment" != "true" ]; then
                        echo "Using provided models: $models"
                    fi
                fi
                
                model_names=$(get_model_names)                        
                if [ "$hugging_face_model_remove_deployment" != "true" ]; then
                    if [ -n "$model_names" ]; then
                        if [ "$hugging_face_model_deployment" != "true" ]; then
                            if [ "$compute_platform" = "x" ] || [ "$compute_platform" = "xpu" ]; then
                                echo "Deploying/removing XPU models: $model_names"
                            elif [ "$compute_platform" = "g" ] || [ "$compute_platform" = "gpu" ]; then
                                echo "Deploying/removing GPU models: $model_names"
                            else
                                echo "Deploying/removing CPU models: $model_names"
                            fi
                        fi
                    fi
                fi            
            fi
        else
            echo "Skipping model deployment/removal."
        fi

        
    fi
    
}

get_model_names() {
    local model_names=()
    IFS=','    
    read -ra model_array <<< "$models"
    for model in "${model_array[@]}"; do
        case "$model" in
            21)
                model_names+=("cpu-qwen3-coder-30b")
                ;;
            22)
                model_names+=("cpu-qwen2-5-coder-14b")
                ;;
            23)
                model_names+=("cpu-bge-base-en")
                ;;
            24)
                model_names+=("cpu-bge-reranker-base")
                ;;
            25)
                model_names+=("cpu-qwen3-30b-a3b")
                ;;
            26)
                model_names+=("cpu-gemma4-26b-a4b")
                ;;
            27)
                model_names+=("cpu-llama-8b")
                ;;
            28)
                model_names+=("cpu-llama-8b-specdec")
                ;;
            29)
                model_names+=("cpu-qwen3-coder-30b-specdec")
                ;;
            30)
                model_names+=("cpu-qwen3-6-35b-a3b")
                ;;
            "cpu-llama-8b"|"cpu-qwen3-coder-30b"|"cpu-qwen2-5-coder-14b"|"cpu-whisper-small"|"cpu-bge-base-en"|"cpu-bge-reranker-base"|"cpu-qwen3-30b-a3b"|"cpu-qwen3-6-35b-a3b"|"cpu-gemma4-26b-a4b"|"cpu-llama-8b-specdec"|"cpu-qwen3-coder-30b-specdec"|"cpu-qwen2-5-coder-14b-specdec")
                model_names+=("$model")
                ;;
            31)
                model_names+=("xpu-qwen3-coder-30b")
                ;;
            32)
                model_names+=("xpu-qwen2-5-coder-14b")
                ;;
            33)
                model_names+=("xpu-llama-8b")
                ;;
            34)
                model_names+=("xpu-qwen3-coder-next")
                ;;
            35)
                model_names+=("xpu-gemma4-31b")
                ;;
            36)
                model_names+=("xpu-qwen36-27b")
                ;;
            "xpu-qwen3-coder-30b"|"xpu-qwen2-5-coder-14b"|"xpu-llama-8b"|"xpu-qwen3-coder-next"|"xpu-gemma4-31b"|"xpu-qwen36-27b")
                model_names+=("$model")
                ;;
            41)
                model_names+=("gpu-nvidia-b300-llama-70b")
                ;;
            "gpu-nvidia-b300-llama-70b")
                model_names+=("$model")
                ;;
            *)
                echo "Error: Invalid model identifier: $model" >&2
                exit 1
                ;;
        esac
    done
    echo "${model_names[@]}"
}