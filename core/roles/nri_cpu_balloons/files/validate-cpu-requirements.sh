#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

###############################################################################
# Script: validate-cpu-requirements.sh
# Description: Pre-flight validation for CPU-based model deployments
#              Validates BEFORE any deployment that system has sufficient
#              CPU resources for requested models and components
# Usage: validate_cpu_requirements_for_models "llama-8b,qwen-1.7b" "c"
###############################################################################

set -euo pipefail

# Color definitions
readonly RED=$(tput setaf 1)
readonly GREEN=$(tput setaf 2)
readonly YELLOW=$(tput setaf 3)
readonly BLUE=$(tput setaf 4)
readonly CYAN=$(tput setaf 6)
readonly NC=$(tput sgr0)

###############################################################################
# Model name to model ID mapping (from model-selection.sh)
###############################################################################
declare -A MODEL_ID_MAP=(
    # Standard names
    ["llama-8b"]="meta-llama/Llama-3.1-8B-Instruct"
    ["llama-3.2-3b"]="meta-llama/Llama-3.2-3B-Instruct"
    ["deepseek-r1-distill-llama-8b"]="deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
    ["deepseek-r1-distill-qwen-32b"]="deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
    ["qwen-1.7b"]="Qwen/Qwen3-1.7B"
    ["qwen-4b"]="Qwen/Qwen3-4B-Instruct-2507"
    ["qwen-coder-7b"]="Qwen/Qwen2.5-Coder-7B-Instruct"
    ["qwen-coder-30b"]="Qwen/Qwen3-Coder-30B-A3B-Instruct"
    ["qwen-coder-14b"]="Qwen/Qwen2.5-Coder-14B-Instruct"
    ["nemotron-4b"]="nvidia/Llama-3.1-Nemotron-Nano-4B-v1.1"
    ["qwen-30b"]="Qwen/Qwen3-30B-A3B-Instruct-2507"
    ["qwen3-6-35b-a3b"]="Qwen/Qwen3.6-35B-A3B"
    ["gemma-4-26b"]="google/gemma-4-26B-A4B-it"
    ["whisper-small"]="openai/whisper-small"

    # CPU-prefixed variants (used in deployment paths)
    ["cpu-llama-8b"]="meta-llama/Llama-3.1-8B-Instruct"
    ["cpu-llama-3.2-3b"]="meta-llama/Llama-3.2-3B-Instruct"
    ["cpu-deepseek-r1-distill-llama-8b"]="deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
    ["cpu-deepseek-r1-distill-qwen-32b"]="deepseek-ai/DeepSeek-R1-Distill-Qwen-32B"
    ["cpu-qwen-1.7b"]="Qwen/Qwen3-1.7B"
    ["cpu-qwen3-1-7b"]="Qwen/Qwen3-1.7B"
    ["cpu-qwen-4b"]="Qwen/Qwen3-4B-Instruct-2507"
    ["cpu-qwen3-4b"]="Qwen/Qwen3-4B-Instruct-2507"
    ["cpu-qwen-coder-7b"]="Qwen/Qwen2.5-Coder-7B-Instruct"
    ["cpu-qwen-coder-30b"]="Qwen/Qwen3-Coder-30B-A3B-Instruct"
    ["cpu-qwen-coder-14b"]="Qwen/Qwen2.5-Coder-14B-Instruct"
    ["cpu-nemotron-4b"]="nvidia/Llama-3.1-Nemotron-Nano-4B-v1.1"
    ["cpu-qwen-30b"]="Qwen/Qwen3-30B-A3B-Instruct-2507"
    ["cpu-qwen3-6-35b-a3b"]="Qwen/Qwen3.6-35B-A3B"
    ["cpu-gemma-4-26b"]="google/gemma-4-26B-A4B-it"
    ["cpu-whisper-small"]="openai/whisper-small"
)

###############################################################################
# Functions
###############################################################################

log_info() {
    echo "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    echo "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo "${RED}[ERROR]${NC} $*" >&2
}

# Parse YAML file to extract model configuration
parse_model_config() {
    local model_id="$1"
    local config_file="$2"
    local field="$3"

    # Use Python to parse YAML (more reliable than bash parsing)
    python3 - <<EOF
import yaml
import sys

try:
    with open("${config_file}", 'r') as f:
        config = yaml.safe_load(f)

    model_config = config.get('modelConfigs', {}).get('${model_id}', {})

    if '${field}' == 'optimal_cpu_cores':
        print(model_config.get('optimal_cpu_cores', 0))
    elif '${field}' == 'tensor_parallel_size':
        print(model_config.get('tensor_parallel_size', 1))
    elif '${field}' == 'data_parallel_size':
        # xeon-values.yaml uses replicaCount (global), not per-model — default to 1
        print(model_config.get('data_parallel_size', 1))
    elif '${field}' == 'min_cpu_cores':
        print(model_config.get('min_cpu_cores', 0))
    else:
        print(0)
except Exception as e:
    print(0, file=sys.stderr)
    sys.exit(1)
EOF
}

# Parse reserved CPU profile configuration
parse_profile_cpus() {
    local profile="$1"
    local config_file="$2"

    python3 - <<EOF
import yaml

try:
    with open("${config_file}", 'r') as f:
        config = yaml.safe_load(f)

    profiles = config.get('deployment_profiles', {})
    profile_config = profiles.get('${profile}', {})
    print(profile_config.get('total_reserved_cpus', 8))
except Exception as e:
    print(8)  # Default fallback
EOF
}

# Detect cluster topology
detect_cluster_topology() {
    local total_cpus total_numa

    # Check if we can access lscpu (might be in container)
    # IMPORTANT: Use PHYSICAL cores only (excluding hyperthreading)
    if command -v lscpu &> /dev/null; then
        local logical_cpus
        local threads_per_core
        logical_cpus=$(lscpu | grep "^CPU(s):" | head -1 | awk '{print $2}')
        threads_per_core=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')
        threads_per_core=${threads_per_core:-1}  # Default to 1 if not found (no hyperthreading)

        # Calculate physical cores
        total_cpus=$((logical_cpus / threads_per_core))
        total_numa=$(lscpu | awk -F: '/NUMA node\(s\):/{print $2}' | tr -d ' ')
    else
        # Fallback: use kubectl to exec on a node
        local kubectl_available=false
        if command -v kubectl &> /dev/null && kubectl get nodes &> /dev/null; then
            kubectl_available=true
        fi

        if [ "$kubectl_available" = true ]; then
            # Get a schedulable node
            local node_name
            node_name=$(kubectl get nodes -o jsonpath='{.items[?(@.spec.taints[*].effect!="NoSchedule")].metadata.name}' | awk '{print $1}')

            if [ -z "$node_name" ]; then
                # Fallback to any node
                node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
            fi

            if [ -n "$node_name" ]; then
                # Get CPU count from node capacity
                total_cpus=$(kubectl get node "$node_name" -o jsonpath='{.status.capacity.cpu}')

                # Try to get NUMA count (this might not be available in all k8s setups)
                # Fallback to estimating based on CPU count
                total_numa=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.numa-nodes}' 2>/dev/null || echo "")

                if [ -z "$total_numa" ]; then
                    # Estimate NUMA nodes (typical: 1 NUMA per 24-32 CPUs)
                    if [ "$total_cpus" -le 32 ]; then
                        total_numa=2
                    elif [ "$total_cpus" -le 64 ]; then
                        total_numa=4
                    elif [ "$total_cpus" -le 128 ]; then
                        total_numa=8
                    else
                        total_numa=16
                    fi
                    log_warning "Could not detect exact NUMA count, estimated ${total_numa} based on ${total_cpus} CPUs"
                fi
            fi
        fi
    fi

    # Validation
    if [ -z "$total_cpus" ] || [ "$total_cpus" -eq 0 ]; then
        log_error "Failed to detect CPU count"
        return 1
    fi

    if [ -z "$total_numa" ] || [ "$total_numa" -eq 0 ]; then
        log_error "Failed to detect NUMA node count"
        return 1
    fi

    echo "$total_cpus $total_numa"
}

# Get currently allocated CPUs from NRI balloons policy
get_allocated_cpus_from_nri() {
    local allocated_cpus=0

    # Check if NRI resource policy pod is running
    if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=nri-resource-policy &> /dev/null; then
        log_warning "NRI resource policy not found, cannot determine allocated CPUs"
        echo "0"
        return 0
    fi

    # Get NRI resource policy pod name
    local nri_pod
    nri_pod=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=nri-resource-policy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$nri_pod" ]; then
        echo "0"
        return 0
    fi

    # Query NRI for balloon allocations
    local balloon_data
    balloon_data=$(kubectl exec -n kube-system "$nri_pod" -- nri-resource-policy-cli show balloons 2>/dev/null || echo "")

    if [ -z "$balloon_data" ]; then
        echo "0"
        return 0
    fi

    # Parse balloon data and count allocated CPUs
    # Extract CPU ranges like "0-15,48-63" and count individual CPUs
    local cpu_ranges
    cpu_ranges=$(echo "$balloon_data" | grep -oP 'cpuset:\s*\K[0-9,\-]+' || echo "")

    for range in ${cpu_ranges//,/ }; do
        if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            allocated_cpus=$((allocated_cpus + end - start + 1))
        elif [[ "$range" =~ ^[0-9]+$ ]]; then
            allocated_cpus=$((allocated_cpus + 1))
        fi
    done

    echo "$allocated_cpus"
}

# Determine deployment profile based on components
determine_deployment_profile() {
    # Check which components are being deployed
    local profile="standard"  # Default

    # Check from environment variables set by user
    if [ "${deploy_observability:-no}" = "yes" ] && \
       [ "${deploy_istio:-no}" = "yes" ] && \
       [ "${deploy_ceph:-no}" = "yes" ]; then
        profile="full"
    elif [ "${deploy_observability:-no}" = "yes" ]; then
        profile="observability"
    elif [ "${deploy_keycloak:-yes}" = "yes" ] || \
         [ "${deploy_apisix:-yes}" = "yes" ] || \
         [ "${deploy_genai_gateway:-yes}" = "yes" ]; then
        profile="standard"
    else
        profile="minimal"
    fi

    echo "$profile"
}

# Main validation function
validate_cpu_requirements_for_models() {
    local models_list="$1"
    local cpu_or_gpu="$2"

    log_info "=============================================================="
    log_info "CPU Requirement Pre-Flight Validation"
    log_info "=============================================================="

    # Skip validation for GPU deployments
    if [ "$cpu_or_gpu" != "c" ]; then
        log_info "Skipping validation (GPU deployment detected)"
        return 0
    fi

    # Get script directory
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    # Configuration files. Honor env overrides so this script can be reused
    # outside the original Enterprise-Inference layout (e.g. when packaged
    # under an Ansible role's files/ directory).
    local model_config_file="${NRI_MODEL_BENCHMARK_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/model_benchmark_config.yml}"
    local reserved_config_file="${NRI_RESERVED_CPU_CONFIG:-$(dirname "${BASH_SOURCE[0]}")/reserved_cpu_config.yml}"

    # Check if config files exist
    if [ ! -f "$model_config_file" ]; then
        log_error "Model benchmark config not found: $model_config_file"
        exit 1
    fi

    if [ ! -f "$reserved_config_file" ]; then
        log_error "Reserved CPU config not found: $reserved_config_file"
        exit 1
    fi

    # Detect cluster topology
    log_info "Detecting cluster topology..."
    local topology_info
    topology_info=$(detect_cluster_topology)
    if [ $? -ne 0 ]; then
        log_error "Failed to detect cluster topology"
        exit 1
    fi

    read -r total_cpus total_numa <<< "$topology_info"
    log_success "Detected: ${total_cpus} CPUs, ${total_numa} NUMA nodes"

    # Determine deployment profile
    local deployment_profile
    deployment_profile=$(determine_deployment_profile)
    log_info "Deployment profile: ${deployment_profile}"

    # Calculate reserved CPUs
    local reserved_cpus
    reserved_cpus=$(parse_profile_cpus "$deployment_profile" "$reserved_config_file")
    log_info "Reserved CPUs for components: ${reserved_cpus}"

    # Parse models list and calculate requirements
    IFS=',' read -ra model_array <<< "$models_list"
    local total_model_cpus=0
    local max_tp_size=0
    declare -a model_details=()

    log_info ""
    log_info "Analyzing model requirements..."
    log_info "--------------------------------------------------------------"

    for model_name in "${model_array[@]}"; do
        model_name=$(echo "$model_name" | xargs)  # Trim whitespace

        # Get model ID
        local model_id="${MODEL_ID_MAP[$model_name]:-}"
        if [ -z "$model_id" ]; then
            log_warning "Unknown model name: ${model_name}, skipping"
            continue
        fi

        # Parse model configuration
        local cpu_cores tp_size replicas
        cpu_cores=$(parse_model_config "$model_id" "$model_config_file" "optimal_cpu_cores")
        tp_size=$(parse_model_config "$model_id" "$model_config_file" "tensor_parallel_size")
        replicas=$(parse_model_config "$model_id" "$model_config_file" "data_parallel_size")

        if [ "$cpu_cores" -eq 0 ]; then
            log_warning "No benchmark data for ${model_id}, using defaults (48 CPUs, TP=2, 1 replica)"
            cpu_cores=48
            tp_size=2
            replicas=1
        fi

        # Calculate total CPUs for all replicas
        local total_cpu_for_model=$((cpu_cores * replicas))

        log_info "  ${model_name} (${model_id})"
        log_info "    - CPU cores per replica: ${cpu_cores}"
        log_info "    - Replicas: ${replicas}"
        log_info "    - Total CPUs: ${total_cpu_for_model} (${cpu_cores} x ${replicas})"
        log_info "    - Tensor Parallel (TP): ${tp_size}"
        log_info "    - Requires ${tp_size} NUMA nodes per replica (balanced)"

        total_model_cpus=$((total_model_cpus + total_cpu_for_model))

        if [ "$tp_size" -gt "$max_tp_size" ]; then
            max_tp_size=$tp_size
        fi

        model_details+=("${model_name}:${cpu_cores}:${replicas}:${tp_size}")
    done

    log_info "--------------------------------------------------------------"
    log_info "Total model CPUs needed: ${total_model_cpus}"
    log_info ""

    # Get already allocated CPUs from NRI balloons
    log_info "Checking currently allocated CPUs from NRI balloons..."
    local already_allocated
    already_allocated=$(get_allocated_cpus_from_nri)
    log_info "Already allocated CPUs: ${already_allocated}"

    # Calculate total requirement and available CPUs
    local total_required=$((reserved_cpus + total_model_cpus))
    local available_cpus=$((total_cpus - already_allocated))

    # Validation checks
    local validation_failed=false
    local error_messages=()

    # Check 1: Total CPU availability
    if [ "$total_required" -gt "$available_cpus" ]; then
        validation_failed=true
        error_messages+=("INSUFFICIENT_TOTAL_CPUS")
    fi

    # Check 2: NUMA nodes availability
    if [ "$max_tp_size" -gt "$total_numa" ]; then
        validation_failed=true
        error_messages+=("INSUFFICIENT_NUMA_NODES")
    fi

    # Check 3: Minimum workload CPUs (ensure at least some headroom)
    local workload_cpus=$((available_cpus - reserved_cpus))
    if [ "$workload_cpus" -lt 16 ]; then
        validation_failed=true
        error_messages+=("INSUFFICIENT_WORKLOAD_CPUS")
    fi

    # Report results
    log_info "=============================================================="
    log_info "Validation Summary"
    log_info "=============================================================="
    log_info "System Configuration:"
    log_info "  Total CPUs: ${total_cpus}"
    log_info "  NUMA Nodes: ${total_numa}"
    log_info ""
    log_info "Resource Allocation:"
    log_info "  Already Allocated (existing models): ${already_allocated} CPUs"
    log_info "  Reserved (components): ${reserved_cpus} CPUs"
    log_info "  Requested (new models): ${total_model_cpus} CPUs"
    log_info "  Total Required: ${total_required} CPUs"
    log_info "  Available: ${available_cpus} CPUs (${total_cpus} - ${already_allocated} allocated)"

    if [ "$total_required" -le "$available_cpus" ]; then
        local spare_cpus=$((available_cpus - total_required))
        log_info "  Spare: ${spare_cpus} CPUs"
    else
        local shortfall=$((total_required - available_cpus))
        log_info "  ${RED}Shortfall: ${shortfall} CPUs${NC}"
    fi

    log_info "=============================================================="

    if [ "$validation_failed" = true ]; then
        echo ""
        echo "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo "${RED}║  ❌ VALIDATION FAILED - INSUFFICIENT RESOURCES             ║${NC}"
        echo "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        for error_type in "${error_messages[@]}"; do
            case "$error_type" in
                INSUFFICIENT_TOTAL_CPUS)
                    echo "${RED}Error: Insufficient total CPUs${NC}"
                    echo "  Required: ${total_required} CPUs (${reserved_cpus} reserved + ${total_model_cpus} models)"
                    echo "  Available: ${available_cpus} CPUs"
                    echo "  Shortfall: $((total_required - available_cpus)) CPUs"
                    echo ""
                    ;;
                INSUFFICIENT_NUMA_NODES)
                    echo "${RED}Error: Tensor Parallelism exceeds available NUMA nodes${NC}"
                    echo "  Requested TP: ${max_tp_size}"
                    echo "  Available NUMA nodes: ${total_numa}"
                    echo "  Maximum supported TP: ${total_numa}"
                    echo ""
                    echo "  ${YELLOW}Why this matters:${NC}"
                    echo "  Tensor parallel workers cannot split across NUMA nodes due to"
                    echo "  cross-NUMA bandwidth bottleneck (4-5x slower inter-node bandwidth)."
                    echo "  Each TP worker must be fully contained within a single NUMA node."
                    echo ""
                    echo "  ${CYAN}Solution:${NC}"
                    echo "  Edit: $(pwd)/inventory/metadata/vars/model_benchmark_config.yml"
                    echo "  Change tensor_parallel_size from ${max_tp_size} to ${total_numa} (or lower)"
                    echo ""
                    ;;
                INSUFFICIENT_WORKLOAD_CPUS)
                    echo "${RED}Error: Insufficient CPUs remaining after reservation${NC}"
                    echo "  Reserved: ${reserved_cpus} CPUs"
                    echo "  Remaining: ${workload_cpus} CPUs"
                    echo "  Minimum required: 16 CPUs"
                    echo ""
                    ;;
            esac
        done

        echo "${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}"
        echo "${YELLOW}│  Recommendations:                                          │${NC}"
        echo "${YELLOW}├────────────────────────────────────────────────────────────┤${NC}"

        if [[ " ${error_messages[*]} " =~ " INSUFFICIENT_TOTAL_CPUS " ]]; then
            echo "${YELLOW}│  1. Use a larger instance type:                           │${NC}"
            local recommended_cpus=$((total_required + 16))  # Add 16 CPU buffer
            echo "${YELLOW}│     • Recommended: ${recommended_cpus}+ vCPU instance                 │${NC}"
            echo "${YELLOW}│                                                            │${NC}"
            echo "${YELLOW}│  2. Deploy fewer models or reduce replicas:                │${NC}"
            for detail in "${model_details[@]}"; do
                IFS=':' read -r name cpus replicas tp <<< "$detail"
                local total=$((cpus * replicas))
                echo "${YELLOW}│     • ${name}: ${total} CPUs (${cpus} x ${replicas} replicas, TP=${tp})     │${NC}"
            done
            echo "${YELLOW}│     • Try deploying models one at a time                   │${NC}"
            echo "${YELLOW}│                                                            │${NC}"
            echo "${YELLOW}│  3. Use smaller TP size (reduces CPU requirement):         │${NC}"
            echo "${YELLOW}│     • TP=1: ~24 CPUs per model                             │${NC}"
            echo "${YELLOW}│     • TP=2: ~48 CPUs per model (current)                   │${NC}"
        fi

        if [[ " ${error_messages[*]} " =~ " INSUFFICIENT_NUMA_NODES " ]]; then
            echo "${YELLOW}│                                                            │${NC}"
            echo "${YELLOW}│  4. Reduce tensor parallelism to match NUMA nodes:        │${NC}"
            echo "${YELLOW}│     • Your system has ${total_numa} NUMA nodes                        │${NC}"
            echo "${YELLOW}│     • Maximum TP supported: ${total_numa}                             │${NC}"
            echo "${YELLOW}│     • Requested TP: ${max_tp_size} (exceeds limit)                    │${NC}"
            echo "${YELLOW}│                                                            │${NC}"
            echo "${YELLOW}│     Note: TP workers split across NUMA nodes suffer from  │${NC}"
            echo "${YELLOW}│     4-5x slower cross-NUMA bandwidth (QPI/UPI bottleneck).│${NC}"
            echo "${YELLOW}│     Update model config to use TP=${total_numa} or lower.             │${NC}"
        fi

        echo "${YELLOW}└────────────────────────────────────────────────────────────┘${NC}"
        echo ""

        exit 1
    else
        echo ""
        log_success "✅ Validation PASSED - Sufficient resources available"
        log_success "Deployment can proceed"
        echo ""

        # Export validated values for later use
        export VALIDATED_TOTAL_CPUS="$total_cpus"
        export VALIDATED_NUMA_NODES="$total_numa"
        export VALIDATED_RESERVED_CPUS="$reserved_cpus"
        export VALIDATED_MODEL_CPUS="$total_model_cpus"
        export VALIDATED_DEPLOYMENT_PROFILE="$deployment_profile"
        export VALIDATED_MAX_TP_SIZE="$max_tp_size"

        # Export model-specific TP sizes as comma-separated list
        local tp_list=""
        for detail in "${model_details[@]}"; do
            IFS=':' read -r name cpus tp <<< "$detail"
            tp_list="${tp_list}${name}=${tp},"
        done
        export VALIDATED_MODEL_TP_MAP="${tp_list%,}"

        return 0
    fi
}

# Allow sourcing this script
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Script is being run directly
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <models_list> <cpu_or_gpu>"
        echo "Example: $0 'llama-8b,qwen-1.7b' 'c'"
        exit 1
    fi
    validate_cpu_requirements_for_models "$1" "$2"
fi
