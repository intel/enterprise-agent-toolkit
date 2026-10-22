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

        # Map air_gapped (config-file flag) to AIR_GAPPED (env var consumed
        # by prereq-check.sh). The config reader normalises "on"→"yes", so check "yes".
        if [[ "${air_gapped:-}" == "yes" ]]; then
            export AIR_GAPPED=true
        fi

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
        # ── Loopback and every node/fabric address must bypass the proxy ─────
        # kubectl talks to the apiserver at https://<addr>:6443. If ANY form of
        # that address goes through the corporate proxy, the proxy answers 403
        # Forbidden and tasks like "Apply Calico CNI" fail.
        #
        # Three sources are needed; each has burned us:
        #   1. localhost / 127.0.0.1 / ::1 — Python urllib3 (used by Ansible's
        #      kubernetes modules) matches no_proxy entries LITERALLY, so the name
        #      "localhost" does NOT cover the literal address "127.0.0.1". Both
        #      forms must be listed. This caused a live 403 on "Apply Calico CNI".
        #   2. Every management IP on this host, not just the first — `hostname -I`
        #      ordering is not stable, and on rack-scale nodes the first address
        #      may be a fabric IP rather than the mgmt IP.
        #   3. The fabric prefixes from the generated inventory — in rack-scale
        #      mode access_ip (and so the apiserver address kubectl is handed) is
        #      a FABRIC IP, which never appears in `hostname -I` on the other nodes.
        local _node_ip; _node_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | paste -sd, -)"
        local _fabric_no_proxy=""
        local _hosts_yaml="$HOMEDIR/inventory/hosts.yaml"
        if [[ -f "${_hosts_yaml}" ]]; then
            # Collect the fabric /16 supernets covering every node's fabric NICs.
            # A supernet is correct HERE (unlike Calico autodetection, which needs
            # exact /32s) — no_proxy only decides "skip the proxy", so being wider
            # than strictly necessary is safe, and it keeps the string short.
            _fabric_no_proxy="$(python3 -c "
import ipaddress, sys, yaml
try:
    inv = yaml.safe_load(open('${_hosts_yaml}')) or {}
    nets = []
    for host in (inv.get('all', {}).get('hosts') or {}).values():
        for nic in (host.get('node_fabric_nics') or []):
            ip = nic.get('fabric_ip')
            if not ip:
                continue
            net = str(ipaddress.ip_network(f'{ip}/16', strict=False))
            if net not in nets:
                nets.append(net)
    print(','.join(nets))
except Exception:
    print('')
" 2>/dev/null)"
        fi
        # ── Cluster CIDRs ────────────────────────────────────────────────────
        # Used in every no_proxy string and in the containerd proxy drop-in, and
        # they must match what kubespray actually builds the cluster with.
        #
        # Precedence: agentic-config.cfg > rack-profile.yaml > built-in default.
        # In rack-scale mode rack-profile.yaml is the single source of truth, so
        # read it here rather than falling straight through to a hardcoded value —
        # otherwise no_proxy would carry 10.244/10.96 while the cluster ran on
        # whatever the profile declared, and in-cluster traffic would be sent to
        # the corporate proxy. The cfg still wins when explicitly set, so a
        # non-rack-scale deployment behaves exactly as before.
        local _profile="$HOMEDIR/inventory/rack-profile.yaml"
        if [[ -z "${pod_cidr:-}" || -z "${service_cidr:-}" ]] && [[ -f "${_profile}" ]]; then
            local _profile_cidrs
            _profile_cidrs="$(python3 -c "
import yaml
try:
    net = (yaml.safe_load(open('${_profile}')) or {}).get('network') or {}
    print(net.get('pod_cidr', ''))
    print(net.get('service_cidr', ''))
except Exception:
    print(); print()
" 2>/dev/null)"
            pod_cidr="${pod_cidr:-$(echo "${_profile_cidrs}" | sed -n 1p)}"
            service_cidr="${service_cidr:-$(echo "${_profile_cidrs}" | sed -n 2p)}"
        fi
        pod_cidr="${pod_cidr:-10.244.0.0/16}"
        service_cidr="${service_cidr:-10.96.0.0/12}"

        # Cluster CIDRs keep in-cluster pod/service traffic off the corporate proxy.
        # These MUST match kube_pods_subnet / kube_service_addresses in kubespray.

        # Mandatory cluster entries (loopback, apiserver IP, service/pod CIDRs,
        # svc suffixes, node IP) are derived from kubespray's live k8s-cluster.yml
        # by _build_k8s_no_proxy(), defined in lib/system/setup-env.sh which is
        # sourced before this file. These are added unconditionally and can never
        # be lost if a user trims no_proxy in agentic-config.cfg.
        local _k8s_base; _k8s_base="$(_build_k8s_no_proxy)"
        # Namespace-level wildcards cover short-form service DNS names
        # (e.g. vllm-service.default) in addition to fully-qualified ones.
        local _ns_suffixes=".default,.genai-gateway,.redis,.ingress-nginx,.agent-sandbox,.openshell-system,.flowise,.vllm-sr"
        local _k8s_no_proxy="${_k8s_base},${_ns_suffixes}localhost,127.0.0.1,::1,.svc,.svc.cluster.local,.default,.genai-gateway,.redis,.ingress-nginx,.agent-sandbox,.flowise,169.254.0.0/16,${service_cidr},${pod_cidr}${_node_ip:+,${_node_ip}}${_fabric_no_proxy:+,${_fabric_no_proxy}}${cluster_url:+,${cluster_url}}"
        if [[ -n "${no_proxy:-}" ]]; then
            no_proxy="${no_proxy},${_k8s_no_proxy}"
        else
            no_proxy="${_k8s_no_proxy}"
        fi
        # Collapse duplicates (first occurrence wins) and strip empty fields —
        # the user's agentic-config.cfg no_proxy commonly already lists localhost
        # or 127.0.0.1, and a repeated entry makes the string harder to read in
        # all.yml and in the containerd proxy drop-in.
        # De-duplicate while preserving order. This function runs on every
        # invocation (and read_config_file is called from many entry points), so
        # without this the list grows with repeated entries on each re-run.
        no_proxy="$(printf '%s' "${no_proxy}" | tr ',' '\n' \
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
            "g" | "gpu")
            compute_platform="g"
            ;;
            "x" | "xpu")
            compute_platform="xpu"
            ;;
            *)
            echo "Invalid value for compute_platform. Expected 'c'/'cpu' (CPU), 'g'/'gpu' (GPU), or 'x'/'xpu' (Intel XPU)."
            exit 1
            ;;
        esac

        # Derive GPU values file path from model name prefix gpu-<vendor>-<hwmodel>-*
        # e.g. gpu-nvidia-b300-llama-70b  →  b300-values.yaml
        if [[ "$compute_platform" == "g" && -n "${models:-}" ]]; then
            local _first_model
            _first_model="$(echo "${models}" | tr ',' ' ' | awk '{print $1}')"
            if [[ "${_first_model}" == gpu-*-*-* ]]; then
                local _hw_model
                _hw_model="$(echo "${_first_model}" | cut -d'-' -f3)"
                local _gpu_values_candidate="${HOMEDIR}/helm-charts/vllm/${_hw_model}-values.yaml"
                if [[ -f "${_gpu_values_candidate}" ]]; then
                    gpu_values_file_path="${REMOTEDIR:-/tmp/helm-charts}/vllm/${_hw_model}-values.yaml"
                else
                    echo "WARNING: GPU values file not found: ${_gpu_values_candidate} — deployment may fail"
                    gpu_values_file_path="${REMOTEDIR:-/tmp/helm-charts}/vllm/${_hw_model}-values.yaml"
                fi
            fi
        fi

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
