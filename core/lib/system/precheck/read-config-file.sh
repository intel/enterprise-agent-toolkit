#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

read_config_file() {
    local config_file="$HOMEDIR/inventory/agentic-config.cfg"
    if [ -f "$config_file" ]; then
        echo "Configuration file found, setting vars!"
        echo "---------------------------------------"
        while IFS='=' read -r key value || [ -n "$key" ]; do
            # Trim leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Skip blank lines and comment lines
            [[ -z "$key" || "$key" == \#* ]] && continue
            # Set the variable using a temporary file
            if [[ "$value" == "on" ]]; then
                value="yes"
            elif [[ "$value" == "off" ]]; then
                value="no"
            fi
            printf "%s=%s\n" "$key" "$value" >> temp_env_vars                        
        done < "$config_file"        
        
        # Load the environment variables from the temporary file
        source temp_env_vars        
        rm temp_env_vars    
        local metadata_config_file="$HOMEDIR/inventory/metadata/agentic-metadata.cfg"
        if [ -f "$metadata_config_file" ]; then
            echo "Metadata configuration file found, setting vars!"
            echo "---------------------------------------"
            while IFS='=' read -r key value || [ -n "$key" ]; do                
                key=$(echo "$key" | xargs)
                value=$(echo "$value" | xargs)
                # Skip blank lines and comment lines
                [[ -z "$key" || "$key" == \#* ]] && continue
                printf "%s=%s\n" "$key" "$value" >> temp_env_vars_metadata
            done < "$metadata_config_file"            
            source temp_env_vars_metadata
            rm temp_env_vars_metadata
        else
            echo "Enterprise Inference Metadata configuration file not found"
            exit 1        
        fi
                
        echo -n "place-holder-123" > "$HOMEDIR/inventory/.vault-passfile"
        vault_pass_file="$HOMEDIR/inventory/.vault-passfile"        

        INVENTORY_ALL_FILE="$HOMEDIR"/inventory/metadata/all.yml
        # Always write proxy values (even empty) so stale hardcoded values are cleared.
        # An empty value in agentic-config.cfg means "no proxy" — don't leave old values.
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*http_proxy:.*|http_proxy: \"${http_proxy:-}\"|" "$INVENTORY_ALL_FILE"
        sed -i -E "/^env_proxy:/,/^[^[:space:]]/s|^[[:space:]]*http_proxy:.*|  http_proxy: \"${http_proxy:-}\"|" "$INVENTORY_ALL_FILE"

        sed -i -E "s|^[[:space:]]*#?[[:space:]]*https_proxy:.*|https_proxy: \"${https_proxy:-}\"|" "$INVENTORY_ALL_FILE"
        sed -i -E "/^env_proxy:/,/^[^[:space:]]/s|^[[:space:]]*https_proxy:.*|  https_proxy: \"${https_proxy:-}\"|" "$INVENTORY_ALL_FILE"

        # Always append k8s-internal suffixes and cluster domain to no_proxy so cluster
        # services (vLLM, LiteLLM, Redis, etc.) and the ingress hostname are never
        # routed through the corporate proxy.
        # Includes namespace-level wildcards (.default, .genai-gateway, etc.) to cover
        # short-form service DNS names (e.g. vllm-service.default) in addition to
        # fully-qualified names (e.g. vllm-service.default.svc.cluster.local).
        # Mandatory cluster entries (loopback, apiserver IP, service/pod CIDRs,
        # svc suffixes, node IP) are derived from kubespray's live k8s-cluster.yml
        # by _build_k8s_no_proxy(), defined in lib/system/setup-env.sh which is
        # sourced before this file. These are added unconditionally and can never
        # be lost if a user trims no_proxy in agentic-config.cfg.
        local _k8s_base; _k8s_base="$(_build_k8s_no_proxy)"
        # Namespace-level wildcards cover short-form service DNS names
        # (e.g. vllm-service.default) in addition to fully-qualified ones.
        local _ns_suffixes=".default,.genai-gateway,.redis,.ingress-nginx,.agent-sandbox,.flowise"
        local _k8s_no_proxy="${_k8s_base},${_ns_suffixes}${cluster_url:+,${cluster_url}}"
        if [[ -n "${no_proxy:-}" ]]; then
            no_proxy="${no_proxy},${_k8s_no_proxy}"
        else
            no_proxy="${_k8s_no_proxy}"
        fi
        # De-duplicate while preserving order. This function runs on every
        # invocation (and read_config_file is called from many entry points), so
        # without this the list grows with repeated entries on each re-run.
        no_proxy="$(echo "${no_proxy}" | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
            | awk 'NF && !seen[$0]++' | paste -sd, -)"
        # Also write the updated no_proxy back to all.yml — BOTH nested (under
        # env_proxy:) AND top-level. http_proxy/https_proxy above are written
        # top-level too; no_proxy was previously ONLY nested, so the bare Ansible
        # var `no_proxy` (read by helm/kubectl tasks' environment:) was undefined →
        # NO_PROXY="" → those tasks hit the local apiserver THROUGH the proxy → 403
        # Forbidden. The top-level write below fixes that. The ^(#?[[:space:]]*)?
        # ... but anchored so it matches the top-level (commented or not) line and
        # NEVER the indented nested one.
        sed -i -E "/^env_proxy:/,/^[^[:space:]]/s|^[[:space:]]*no_proxy:.*|  no_proxy: \"${no_proxy}\"|" "$INVENTORY_ALL_FILE"
        sed -i -E "s|^(#[[:space:]]*)?no_proxy:.*|no_proxy: \"${no_proxy}\"|" "$INVENTORY_ALL_FILE"

        [[ -n "${http_proxy:-}" ]]  && export http_proxy  && export HTTP_PROXY="${http_proxy}"
        [[ -n "${https_proxy:-}" ]] && export https_proxy && export HTTPS_PROXY="${https_proxy}"
        [[ -n "${no_proxy:-}" ]]    && export no_proxy    && export NO_PROXY="${no_proxy}"

        # ── Load all kuberay values from kuberay-config.yaml ─────────────────
        # These variables are consumed by kuberay-controller.sh during deployment.
        # They are sourced from kuberay-config.yaml rather than agentic-config.cfg
        # so that users have a single YAML file to tune KubeRay parameters.
        local _kuberay_cfg="$HOMEDIR/inventory/kuberay-config.yaml"
        if [[ -f "${_kuberay_cfg}" ]]; then
            eval "$(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('${_kuberay_cfg}'))
    ns      = cfg.get('namespace', 'ray-system')
    cluster = cfg.get('cluster', {})
    worker  = cluster.get('worker', {})
    print('kuberay_namespace=%s'          % ns)
    print('kuberay_ray_image=%s'          % cluster.get('rayImage', 'rayproject/ray:2.40.0-py312'))
    print('kuberay_worker_replicas=%s'    % worker.get('replicas', 2))
    print('kuberay_worker_min_replicas=%s'% worker.get('minReplicas', 1))
    print('kuberay_worker_max_replicas=%s'% worker.get('maxReplicas', 4))
    print('kuberay_worker_cpu_request=%s' % worker.get('cpuRequest', '500m'))
    print('kuberay_worker_cpu_limit=%s'   % worker.get('cpuLimit', '2'))
    print('kuberay_worker_memory_request=%s' % worker.get('memoryRequest', '2Gi'))
    print('kuberay_worker_memory_limit=%s'   % worker.get('memoryLimit', '4Gi'))
except Exception as e:
    print('kuberay_namespace=ray-system')
    print('kuberay_ray_image=rayproject/ray:2.40.0-py312')
    print('kuberay_worker_replicas=2')
    print('kuberay_worker_min_replicas=1')
    print('kuberay_worker_max_replicas=4')
    print('kuberay_worker_cpu_request=500m')
    print('kuberay_worker_cpu_limit=2')
    print('kuberay_worker_memory_request=2Gi')
    print('kuberay_worker_memory_limit=4Gi')
" 2>/dev/null)" || {
                kuberay_namespace="ray-system"
                kuberay_ray_image="rayproject/ray:2.40.0-py312"
                kuberay_worker_replicas=2
                kuberay_worker_min_replicas=1
                kuberay_worker_max_replicas=4
                kuberay_worker_cpu_request="500m"
                kuberay_worker_cpu_limit="2"
                kuberay_worker_memory_request="2Gi"
                kuberay_worker_memory_limit="4Gi"
            }
        else
            kuberay_namespace="ray-system"
            kuberay_ray_image="rayproject/ray:2.40.0-py312"
            kuberay_worker_replicas=2
            kuberay_worker_min_replicas=1
            kuberay_worker_max_replicas=4
            kuberay_worker_cpu_request="500m"
            kuberay_worker_cpu_limit="2"
            kuberay_worker_memory_request="2Gi"
            kuberay_worker_memory_limit="4Gi"
        fi
        
        
        case "$compute_platform" in
            "c" | "cpu")
            compute_platform="c"
            ;;
            *)
            echo "Invalid value for cpu. It should be 'c' or 'cpu' for CPU."
            exit 1
            ;;
        esac
        case "$deploy_genai_gateway" in
            "no")
                deploy_genai_gateway="no"                
                ;;
            "yes")
                deploy_genai_gateway="yes"                                
                ;;
            *)
                echo "Incorrect value for deploy_genai_gateway"
                exit 1
                ;;
        esac
        
    else
        echo "Configuration file not found. Using default values or prompting for input."
    fi    
}
