#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --cluster-url) cluster_url="$2"; shift ;;
            --cert-file) cert_file="$2"; shift ;;
            --key-file) key_file="$2"; shift ;;
            --hugging-face-token) hugging_face_token="$2"; shift ;;
            --models) models="$2"; shift ;;
            --compute_platform) cpu="$2"; shift ;;
            --deploy-nri-balloon-policy) deploy_nri_balloon_policy="$2"; shift ;;
            --skip-check) skip_check="true" ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown parameter passed: $1"; exit 1 ;;
        esac
        shift
    done
}


prompt_for_input() {   
    if [ -z "$deploy_kubernetes_fresh" ]; then
        read -p "Do you want to proceed with deploying fresh Kubernetes cluster setup? (yes/no): " deploy_kubernetes_fresh
    else
        echo "Proceeding with the setup of Fresh Kubernetes cluster: $deploy_kubernetes_fresh"
    fi
    if [ -z "$deploy_ingress_controller" ]; then
        read -p "Do you want to proceed with deploying Ingress NGINX Controller? (yes/no): " deploy_ingress_controller
    else
        echo "Proceeding with the setup of Ingress Controller: $deploy_ingress_controller"
    fi
    if [ -z "$deploy_genai_gateway" ]; then
        read -p "Do you want to proceed with deploying GenAI Gateway? (yes/no): " deploy_genai_gateway
    else
        echo "Proceeding with the setup of GenAI Gateway: $deploy_genai_gateway"
    fi
    
    if [ -z "$deploy_observability" ]; then
        read -p "Do you want to proceed with deploying Observability? (yes/no): " deploy_observability
    else
        echo "Proceeding with the setup of Observability: $deploy_observability"
    fi
    
    if [ "$deploy_kubernetes_fresh" == "no" ]; then
        if [ -z "$uninstall_ceph" ]; then
            read -p "Do you want to proceed with uninstalling Ceph cluster? (yes/no): " uninstall_ceph
        else
            echo "Proceeding with Ceph cluster uninstallation: $uninstall_ceph"
        fi
    fi
           
    if [ -z "$deploy_nri_balloon_policy" ]; then
        # Automatically enable NRI balloon policy for CPU deployments when the
        # flag is not specified in agentic-config.cfg. Set
        # deploy_nri_balloon_policy=off in the config to opt out (e.g. to run
        # multiple models on one node without the single-model CPU reservation).
        deploy_nri_balloon_policy="yes"
        if [ "$balloon_policy_cpu" == "enabled" ]; then
            echo "NRI CPU Balloon Policy automatically enabled for CPU deployment"
        fi
    else
        echo "Proceeding with the setup of NRI CPU Balloon Policy: $deploy_nri_balloon_policy"
    fi
    
    if [ "$deploy_nri_balloon_policy" == "yes" ]; then
        balloon_policy_cpu="enabled"
    else
        balloon_policy_cpu="disabled"
    fi

    model_selection "$@"    
    echo "----- Input -----"
    if [ -z "$cluster_url" ]; then
        read -p "Enter the CLUSTER URL (FQDN): " cluster_url
    else
        echo "Using provided CLUSTER URL: $cluster_url"
    fi
    if [ -z "$cert_file" ]; then
        read -p "Enter the full path to the certificate file: " cert_file
    else
        echo "Using provided certificate file: $cert_file"
    fi    
    if [ -z "$key_file" ]; then
        read -p "Enter the full path to the key file: " key_file
    else
        echo "Using provided key file: $key_file"
    fi
    
}