#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

###############################################################################
# Script: compute_reserved_cpus_advanced.sh
# Description: Advanced CPU reservation calculation for Enterprise Inference
#              Replaces hardcoded 8 CPU reservation with component-based logic
# Usage: ./compute_reserved_cpus_advanced.sh [OPTIONS]
#
# Options:
#   --profile <name>       Use predefined profile (minimal|standard|observability|full)
#   --total <number>       Manually specify total reserved CPUs (legacy mode)
#   --strategy <method>    balanced|concentrated|first_node
#   --help                 Show this help message
#
# Environment Variables:
#   RESERVATION_PROFILE    Deployment profile (default: standard)
#   NUMA_STRATEGY          NUMA distribution strategy (default: balanced)
#   HT_STRATEGY            Hyperthreading strategy (default: balanced)
###############################################################################

set -euo pipefail

# Default values
RESERVATION_PROFILE="${RESERVATION_PROFILE:-standard}"
NUMA_STRATEGY="${NUMA_STRATEGY:-balanced}"
HT_STRATEGY="${HT_STRATEGY:-balanced}"
TOTAL_RESERVED=""
HELP=false

# Profile definitions (matching reserved_cpu_config.yml)
declare -A PROFILE_CPUS=(
    ["minimal"]=8
    ["standard"]=12
    ["observability"]=16
    ["full"]=20
    ["siblings"]=0
)

# Color definitions (handle missing TERM gracefully)
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && tput colors >/dev/null 2>&1; then
    readonly RED=$(tput setaf 1 2>/dev/null || echo "")
    readonly GREEN=$(tput setaf 2 2>/dev/null || echo "")
    readonly YELLOW=$(tput setaf 3 2>/dev/null || echo "")
    readonly BLUE=$(tput setaf 4 2>/dev/null || echo "")
    readonly NC=$(tput sgr0 2>/dev/null || echo "")
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly NC=""
fi

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

show_help() {
    cat << EOF
Advanced CPU Reservation Calculator for Enterprise Inference

Usage: $0 [OPTIONS]

Options:
    --profile <name>       Use predefined profile:
                            - minimal: 8 vCPUs (core services only)
                            - standard: 12 vCPUs (core + auth) [default]
                            - observability: 16 vCPUs (standard + monitoring)
                            - full: 20 vCPUs (all components)
                            - siblings: ALL sibling (HT) vCPUs — physical cores
                                        reserved exclusively for vLLM balloons

    --total <number>       Manually specify total reserved CPUs (legacy mode)

    --strategy <method>    NUMA distribution strategy:
                            - balanced: Distribute evenly across NUMA nodes [default]
                            - concentrated: Use fewer NUMA nodes
                            - first_node: Reserve from first NUMA only

    --ht-strategy <method> Hyperthreading handling:
                            - balanced: Mix physical and HT cores [default]
                            - physical_first: Prefer physical cores
                            - physical_only: Use only physical cores

    --help                 Show this help message

Environment Variables:
    RESERVATION_PROFILE    Deployment profile (default: standard)
    NUMA_STRATEGY          NUMA distribution strategy (default: balanced)
    HT_STRATEGY            Hyperthreading strategy (default: balanced)

Output:
    NRI_RESERVED_CPU_LIST=<comma-separated CPU IDs>

Examples:
    # Use standard profile (12 vCPUs)
    $0 --profile standard

    # Use full deployment profile (20 vCPUs)
    $0 --profile full

    # Reserve ALL sibling (HT) cores — physical cores for vLLM only
    $0 --profile siblings

    # Legacy mode with manual total
    $0 --total 12

    # Concentrated strategy to leave more NUMA nodes free
    $0 --profile observability --strategy concentrated

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                RESERVATION_PROFILE="$2"
                shift 2
                ;;
            --total)
                TOTAL_RESERVED="$2"
                shift 2
                ;;
            --strategy)
                NUMA_STRATEGY="$2"
                shift 2
                ;;
            --ht-strategy)
                HT_STRATEGY="$2"
                shift 2
                ;;
            --help)
                HELP=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Topology source.
#
# By default this script reads topology from `lscpu`, which requires the
# util-linux package and must run ON the node whose topology is wanted.
# To allow the script to run on the Ansible controller (no privileged, rooted,
# lscpu-bearing pod on each node), topology may instead be INJECTED via
# environment variables collected from each node's /sys tree:
#
#   NRI_TOPO_NUMA      NUMA node count            (e.g. 2)
#   NRI_TOPO_TPC       threads per core           (e.g. 2)
#   NRI_TOPO_LOGICAL   logical CPU count          (e.g. 256)
#   NRI_TOPO_SIBLINGS  comma-separated sibling (HT) CPU IDs
#   NRI_TOPO_NODECPUS  per-NUMA cpulists as "<i>:<cpulist>" pairs separated by
#                      ';' (e.g. "0:0-63,128-191;1:64-127,192-255")
#
# When NRI_TOPO_NUMA is set the injected values are used and lscpu is never
# invoked; otherwise the script falls back to lscpu for standalone/local use.
# -----------------------------------------------------------------------------
_topology_injected() {
    [[ -n "${NRI_TOPO_NUMA:-}" ]]
}

# Return the CPU list for NUMA node $1 from injected env or lscpu.
# Injected form is parsed out of NRI_TOPO_NODECPUS ("i:list;i:list;...").
_numa_cpulist() {
    local i="$1"
    if _topology_injected; then
        local entry
        IFS=';' read -ra _entries <<< "${NRI_TOPO_NODECPUS:-}"
        for entry in "${_entries[@]}"; do
            if [[ "${entry%%:*}" == "$i" ]]; then
                printf '%s' "${entry#*:}"
                return
            fi
        done
        printf ''
    else
        lscpu | grep "NUMA node$i CPU" | cut -d: -f2 | xargs
    fi
}

# Detect system topology
detect_topology() {
    local total_numa
    local threads_per_core
    local total_cpus

    if _topology_injected; then
        total_numa="${NRI_TOPO_NUMA}"
        threads_per_core="${NRI_TOPO_TPC:-1}"
        total_cpus="${NRI_TOPO_LOGICAL:-0}"
        if [[ -z "$total_cpus" || "$total_cpus" -eq 0 ]]; then
            log_error "NRI_TOPO_LOGICAL not provided with injected topology"
            exit 1
        fi
        echo "$total_numa $threads_per_core $total_cpus"
        return
    fi

    total_numa=$(lscpu | awk -F: '/NUMA node\(s\):/{print $2}' | tr -d ' ')
    if [[ -z "$total_numa" ]]; then
        log_error "Failed to detect NUMA nodes from lscpu"
        exit 1
    fi

    threads_per_core=$(lscpu | awk '/Thread.*per core:/{print $4}')
    [[ -n "$threads_per_core" ]] || threads_per_core=1

    # Get total logical CPUs (vCPUs) — profiles reserve vCPUs, not physical cores
    local logical_cpus
    logical_cpus=$(lscpu | grep "^CPU(s):" | head -1 | awk '{print $2}')
    total_cpus=$logical_cpus

    echo "$total_numa $threads_per_core $total_cpus"
}

# Determine total reserved CPUs
determine_total_reserved() {
    local total_numa=$1
    local total_cpus=$2
    local reserved_cpus

    if [[ -n "$TOTAL_RESERVED" ]]; then
        # Manual override (legacy mode)
        reserved_cpus=$TOTAL_RESERVED
        log_info "Using manually specified reservation: ${reserved_cpus} vCPUs"
    elif [[ "$RESERVATION_PROFILE" == "siblings" ]]; then
        # Siblings mode: reserve ALL sibling (HT) CPUs.
        # Physical cores stay available for vLLM balloons.
        local logical_cpus
        if _topology_injected; then
            logical_cpus="${NRI_TOPO_LOGICAL}"
        else
            logical_cpus=$(lscpu | grep "^CPU(s):" | head -1 | awk '{print $2}')
        fi
        local physical_cpus=$((logical_cpus / threads_per_core))
        if [[ $threads_per_core -le 1 ]]; then
            log_warning "SMT/Hyperthreading disabled — no siblings to reserve."
            log_warning "Falling back to 'standard' profile."
            reserved_cpus=${PROFILE_CPUS["standard"]}
        else
            reserved_cpus=$((logical_cpus - physical_cpus))
            log_info "Using 'siblings' profile: reserving ALL ${reserved_cpus} sibling vCPUs"
            log_info "Physical cores (${physical_cpus}) remain available for vLLM balloons"
        fi
    elif [[ -n "${PROFILE_CPUS[$RESERVATION_PROFILE]:-}" ]]; then
        # Use profile
        reserved_cpus=${PROFILE_CPUS[$RESERVATION_PROFILE]}
        log_info "Using profile '${RESERVATION_PROFILE}': ${reserved_cpus} vCPUs"
    else
        log_error "Unknown profile: ${RESERVATION_PROFILE}"
        log_error "Valid profiles: ${!PROFILE_CPUS[*]}"
        exit 1
    fi

    # Validation: Minimum 4 CPUs
    if [[ $reserved_cpus -lt 4 ]]; then
        log_warning "Reserved CPUs ($reserved_cpus) below minimum (4), adjusting to 4"
        reserved_cpus=4
    fi

    # Validation: Warn if reserved exceeds 25% of total CPUs
    local max_reserved=$((total_cpus * 25 / 100))
    if [[ $reserved_cpus -gt $max_reserved ]]; then
        log_warning "Reserved vCPUs ($reserved_cpus) exceeds 25% of total ($max_reserved)."
        log_warning "There may not be sufficient CPUs available for inference workloads."
        log_warning "Consider using a larger machine or a smaller reservation profile."
        log_warning "Proceeding with deployment..."
    fi

    # Validation: At least 16 CPUs must remain for workloads
    local workload_cpus=$((total_cpus - reserved_cpus))
    if [[ $workload_cpus -lt 16 ]]; then
        log_error "Insufficient CPUs remaining for workloads: $workload_cpus (minimum 16 required)"
        exit 1
    fi

    # Round to multiple of 2 for NUMA alignment
    reserved_cpus=$(( (reserved_cpus + 1) / 2 * 2 ))

    echo "$reserved_cpus"
}

# Select CPUs based on strategy
select_reserved_cpus() {
    local total_reserved=$1
    local total_numa=$2
    local threads_per_core=$3

    # Siblings mode: select ALL sibling (HT) CPUs across all NUMA nodes
    if [[ "$RESERVATION_PROFILE" == "siblings" && "$threads_per_core" -ge 2 ]]; then
        select_sibling_cpus "$total_numa"
        return
    fi

    local ht_enabled=false
    [[ "$threads_per_core" -eq 2 ]] && ht_enabled=true

    local cpus_per_numa=$(( (total_reserved + total_numa - 1) / total_numa ))
    local out=""

    case $NUMA_STRATEGY in
        balanced)
            # Distribute evenly across all NUMA nodes
            select_balanced_cpus "$cpus_per_numa" "$total_numa" "$ht_enabled"
            ;;
        concentrated)
            # Concentrate on fewer NUMA nodes
            select_concentrated_cpus "$total_reserved" "$total_numa" "$ht_enabled"
            ;;
        first_node)
            # Reserve from first NUMA node only
            select_first_node_cpus "$total_reserved" "$ht_enabled"
            ;;
        *)
            log_error "Unknown NUMA strategy: $NUMA_STRATEGY"
            exit 1
            ;;
    esac
}

# Sibling (HT) CPU selection — reserves ALL sibling cores across all NUMA nodes.
# Uses lscpu -p=CPU,Core to precisely identify which logical CPUs are siblings
# (the second thread on each physical core).
select_sibling_cpus() {
    local total_numa=$1
    local out=""

    # Fast path: siblings pre-computed from /sys and injected by the caller.
    if _topology_injected; then
        if [[ -z "${NRI_TOPO_SIBLINGS:-}" ]]; then
            log_error "Injected topology set but NRI_TOPO_SIBLINGS is empty"
            exit 1
        fi
        echo "${NRI_TOPO_SIBLINGS}"
        return
    fi

    # Use lscpu to build core→CPUs mapping and pick siblings
    local sibling_list
    sibling_list=$(lscpu -p=CPU,Core 2>/dev/null | awk -F, '
        /^[0-9]/ {
            core = $2 + 0
            cpu  = $1 + 0
            # Track the primary (lowest-numbered) CPU for each core
            if (!(core in primary) || cpu < primary[core]) {
                if (core in primary) {
                    # Current primary becomes a sibling
                    siblings[primary[core]] = 1
                }
                primary[core] = cpu
            } else {
                siblings[cpu] = 1
            }
        }
        END {
            # Collect sibling CPUs into a sorted array
            n = 0
            for (cpu in siblings) sorted[++n] = cpu + 0
            # Simple insertion sort
            for (i = 2; i <= n; i++) {
                v = sorted[i]
                j = i - 1
                while (j >= 1 && sorted[j] > v) {
                    sorted[j+1] = sorted[j]
                    j--
                }
                sorted[j+1] = v
            }
            # Output comma-separated
            for (i = 1; i <= n; i++) {
                printf "%s%s", (i > 1 ? "," : ""), sorted[i]
            }
            if (n > 0) print ""
        }
    ')

    if [[ -z "$sibling_list" ]]; then
        log_error "Failed to identify sibling CPUs via lscpu"
        exit 1
    fi

    echo "$sibling_list"
}

# Balanced NUMA selection
select_balanced_cpus() {
    local cpus_per_numa=$1
    local total_numa=$2
    local ht_enabled=$3

    local out=""

    for i in $(seq 0 $((total_numa - 1))); do
        local line
        line=$(_numa_cpulist "$i")
        if [[ -z "$line" ]]; then
            log_error "Failed to read NUMA node$i CPU list"
            exit 1
        fi

        # Parse CPU list
        IFS=',' read -ra segments <<< "$line"
        declare -a all_cpus=()
        for seg in "${segments[@]}"; do
            seg=$(echo "$seg" | xargs)
            if [[ "$seg" == *"-"* ]]; then
                IFS='-' read -r start end <<< "$seg"
                for ((c=start; c<=end; c++)); do
                    all_cpus+=("$c")
                done
            else
                all_cpus+=("$seg")
            fi
        done

        # Sort CPUs
        IFS=$'\n' sorted=($(printf '%s\n' "${all_cpus[@]}" | sort -n))
        unset IFS

        local total_cpus_in_numa=${#sorted[@]}
        local selected=()

        if [[ "$ht_enabled" == true ]] && [[ "$total_cpus_in_numa" -ge $((cpus_per_numa * 2)) ]]; then
            # Handle hyperthreading based on strategy
            local half=$((total_cpus_in_numa / 2))
            local physical_half=("${sorted[@]:0:$half}")
            local ht_half=("${sorted[@]:$half:$half}")

            case $HT_STRATEGY in
                balanced)
                    # Mix physical and HT cores
                    local reserve_from_physical=$(( (cpus_per_numa + 1) / 2 ))
                    local reserve_from_ht=$(( cpus_per_numa - reserve_from_physical ))

                    for ((j=0; j<reserve_from_physical && j<${#physical_half[@]}; j++)); do
                        selected+=("${physical_half[$j]}")
                    done
                    for ((j=0; j<reserve_from_ht && j<${#ht_half[@]}; j++)); do
                        selected+=("${ht_half[$j]}")
                    done
                    ;;
                physical_first)
                    # Prefer physical cores
                    for ((j=0; j<cpus_per_numa && j<${#physical_half[@]}; j++)); do
                        selected+=("${physical_half[$j]}")
                    done
                    # Fill remainder from HT if needed
                    local remaining=$((cpus_per_numa - ${#selected[@]}))
                    for ((j=0; j<remaining && j<${#ht_half[@]}; j++)); do
                        selected+=("${ht_half[$j]}")
                    done
                    ;;
                physical_only)
                    # Only physical cores
                    for ((j=0; j<cpus_per_numa && j<${#physical_half[@]}; j++)); do
                        selected+=("${physical_half[$j]}")
                    done
                    ;;
                *)
                    log_error "Unknown HT strategy: $HT_STRATEGY"
                    exit 1
                    ;;
            esac
        else
            # No hyperthreading or insufficient CPUs, take from beginning
            selected=("${sorted[@]:0:$cpus_per_numa}")
        fi

        # Sort selected CPUs and append
        IFS=$'\n' selected_sorted=($(printf '%s\n' "${selected[@]}" | sort -n))
        unset IFS
        for cpu in "${selected_sorted[@]}"; do
            out="${out}${cpu},"
        done
    done

    out="${out%,}"
    if [[ -z "$out" ]]; then
        log_error "Failed to compute reserved CPU list (empty result)"
        exit 1
    fi
    echo "$out"
}

# Concentrated NUMA selection
select_concentrated_cpus() {
    local total_reserved=$1
    local total_numa=$2
    local ht_enabled=$3

    # Use maximum 2 NUMA nodes for reservation
    local numa_to_use=$(( total_numa < 2 ? total_numa : 2 ))
    local cpus_per_numa=$(( (total_reserved + numa_to_use - 1) / numa_to_use ))

    local out=""

    for i in $(seq 0 $((numa_to_use - 1))); do
        local line
        line=$(_numa_cpulist "$i")
        if [[ -z "$line" ]]; then
            log_error "Failed to read NUMA node$i CPU list"
            exit 1
        fi

        # Same CPU selection logic as balanced
        IFS=',' read -ra segments <<< "$line"
        declare -a all_cpus=()
        for seg in "${segments[@]}"; do
            seg=$(echo "$seg" | xargs)
            if [[ "$seg" == *"-"* ]]; then
                IFS='-' read -r start end <<< "$seg"
                for ((c=start; c<=end; c++)); do
                    all_cpus+=("$c")
                done
            else
                all_cpus+=("$seg")
            fi
        done

        IFS=$'\n' sorted=($(printf '%s\n' "${all_cpus[@]}" | sort -n))
        unset IFS

        local selected=("${sorted[@]:0:$cpus_per_numa}")

        IFS=$'\n' selected_sorted=($(printf '%s\n' "${selected[@]}" | sort -n))
        unset IFS
        for cpu in "${selected_sorted[@]}"; do
            out="${out}${cpu},"
        done
    done

    out="${out%,}"
    echo "$out"
}

# First node NUMA selection
select_first_node_cpus() {
    local total_reserved=$1
    local ht_enabled=$2

    local line
    line=$(_numa_cpulist 0)
    if [[ -z "$line" ]]; then
        log_error "Failed to read NUMA node0 CPU list"
        exit 1
    fi

    # Parse and select CPUs from first NUMA node
    IFS=',' read -ra segments <<< "$line"
    declare -a all_cpus=()
    for seg in "${segments[@]}"; do
        seg=$(echo "$seg" | xargs)
        if [[ "$seg" == *"-"* ]]; then
            IFS='-' read -r start end <<< "$seg"
            for ((c=start; c<=end; c++)); do
                all_cpus+=("$c")
            done
        else
            all_cpus+=("$seg")
        fi
    done

    IFS=$'\n' sorted=($(printf '%s\n' "${all_cpus[@]}" | sort -n))
    unset IFS

    local selected=("${sorted[@]:0:$total_reserved}")

    IFS=$'\n' selected_sorted=($(printf '%s\n' "${selected[@]}" | sort -n))
    unset IFS

    local out=""
    for cpu in "${selected_sorted[@]}"; do
        out="${out}${cpu},"
    done

    out="${out%,}"
    echo "$out"
}

###############################################################################
# Main execution
###############################################################################

main() {
    parse_args "$@"

    if [[ "$HELP" == true ]]; then
        show_help
        exit 0
    fi

    log_info "Enterprise Inference Advanced CPU Reservation Calculator"
    log_info "=========================================================="

    # Detect topology
    read -r total_numa threads_per_core total_cpus <<< "$(detect_topology)"
    log_info "System topology: ${total_numa} NUMA nodes, ${total_cpus} CPUs, ${threads_per_core} threads/core"

    # Determine total reserved
    total_reserved=$(determine_total_reserved "$total_numa" "$total_cpus")
    log_info "Total reserved CPUs: ${total_reserved}"

    # Select CPUs
    reserved_cpu_list=$(select_reserved_cpus "$total_reserved" "$total_numa" "$threads_per_core")

    # Output result
    log_success "Reserved CPU list computed successfully"
    log_info "Strategy: ${NUMA_STRATEGY}, HT Strategy: ${HT_STRATEGY}"
    echo "NRI_RESERVED_CPU_LIST=${reserved_cpu_list}"
}

main "$@"
