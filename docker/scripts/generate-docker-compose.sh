#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Generate docker-compose.vllm.yml from model-configs.yaml
# This script dynamically creates vLLM service definitions based on models configured in config.cfg

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Global Variables
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${DOCKER_DIR}/config.cfg"
MODEL_CONFIGS="${DOCKER_DIR}/model-configs.yaml"
OUTPUT_FILE="${DOCKER_DIR}/docker-compose.vllm.yml"

VLLM_IMAGE="vllm/vllm-openai-cpu:v0.24.0"
BASE_PORT=2080

MODEL_ARRAY=()

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if required command exists
check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "$1 is required but not installed."
        log_error "Install: $2"
        exit 1
    fi
}

VALID_TOOL_PARSERS=(
    cohere_command3 cohere_command4 deepseek_v3 deepseek_v31 deepseek_v32
    deepseek_v4 ernie45 functiongemma gemma4 gigachat3 glm45 glm47 granite
    granite-20b-fc granite4 hermes hunyuan_a13b hy_v3 internlm jamba kimi_k2
    lfm2 llama3_json llama4_json llama4_pythonic longcat mimo minimax
    minimax_m2 mistral olmo3 openai phi4_mini_json poolside_v1 pythonic
    qwen3_coder qwen3_xml seed_oss step3 step3p5 xlam
)

# Strip -Specdec suffix to get the real HuggingFace model ID used for loading
get_hf_model_id() {
    echo "${1%-Specdec}"
}

# Emit --speculative-model / --num-speculative-tokens args when a model has
# speculative_decoding configured in model-configs.yaml. Triggered automatically
# by using a -Specdec model ID in config.cfg (e.g. Qwen/Qwen2.5-Coder-14B-Instruct-Specdec).
get_speculative_args() {
    local model_id="$1"
    local draft_model num_tokens
    draft_model=$(yq eval ".models[\"${model_id}\"].speculative_decoding.draft_model" "$MODEL_CONFIGS" 2>/dev/null)
    num_tokens=$(yq eval  ".models[\"${model_id}\"].speculative_decoding.num_speculative_tokens" "$MODEL_CONFIGS" 2>/dev/null)
    [[ -z "$draft_model" || "$draft_model" == "null" ]] && return 0
    local spec_json="{\"method\":\"draft_model\",\"model\":\"${draft_model}\",\"num_speculative_tokens\":${num_tokens}}"
    log_info "  Speculative decoding: ${spec_json}"
    echo "      - \"--speculative_config\""
    echo "      - '${spec_json}'"
}

# Read and validate tool_call_parser from config.cfg; sets TOOL_CALL_PARSER global
read_tool_call_parser() {
    local raw
    raw=$(grep "^tool_call_parser=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | cut -d'#' -f1 | xargs || true)
    raw="${raw:-none}"

    if [[ -z "$raw" || "$raw" == "none" ]]; then
        TOOL_CALL_PARSER="none"
        log_info "Tool call parser: disabled (default config will not include --tool-call-parser)"
        return 0
    fi

    local valid=false
    for p in "${VALID_TOOL_PARSERS[@]}"; do
        [[ "$p" == "$raw" ]] && valid=true && break
    done

    if [[ "$valid" != "true" ]]; then
        log_error "Invalid tool_call_parser value: '${raw}'"
        log_error "Valid options: ${VALID_TOOL_PARSERS[*]}"
        exit 1
    fi

    TOOL_CALL_PARSER="$raw"
    log_info "Tool call parser: ${TOOL_CALL_PARSER}"
}

# Update default.command_args in model-configs.yaml with the configured tool-call parser.
# Idempotent: strips any prior --enable-auto-tool-choice / --tool-call-parser <value> first.
update_default_tool_call_parser() {
    # Read current args, strip tool-call flags and the value that follows --tool-call-parser
    local -a cleaned=()
    local skip_next=false
    while IFS= read -r arg; do
        if [[ "$skip_next" == "true" ]]; then
            skip_next=false
            continue
        fi
        case "$arg" in
            --enable-auto-tool-choice) continue ;;
            --tool-call-parser) skip_next=true; continue ;;
        esac
        cleaned+=("$arg")
    done < <(yq eval '.default.command_args[]' "$MODEL_CONFIGS")

    # Append tool-call args if a parser is configured
    if [[ "${TOOL_CALL_PARSER}" != "none" ]]; then
        cleaned+=("--enable-auto-tool-choice" "--tool-call-parser" "${TOOL_CALL_PARSER}")
    fi

    # Build a YAML list string and write it back with yq
    local list_yaml
    list_yaml=$(printf '  - "%s"\n' "${cleaned[@]}" | yq eval -n '[.[] | . ]' - 2>/dev/null || true)

    # Fallback: build JSON array for yq to parse
    local json_array
    json_array="["
    local first=true
    for arg in "${cleaned[@]}"; do
        [[ "$first" == "true" ]] && first=false || json_array+=","
        json_array+="\"${arg}\""
    done
    json_array+="]"

    yq eval -i ".default.command_args = ${json_array}" "$MODEL_CONFIGS"

    if [[ "${TOOL_CALL_PARSER}" != "none" ]]; then
        log_success "Default tool-call parser set to: ${TOOL_CALL_PARSER}"
    else
        log_info "Default tool-call parser removed (none)"
    fi
}

# Generate URL-safe served name from model ID
generate_served_name() {
    local model_id="$1"
    # Convert org/model-name to org-model-name, then to lowercase
    echo "${model_id//\//-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

# Validate HuggingFace model ID format
validate_model_id() {
    local model_id="$1"
    if [[ ! "$model_id" =~ ^[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid model ID format: '${model_id}'"
        log_error "Expected format: org/model-name (e.g., Qwen/Qwen2.5-Coder-14B-Instruct)"
        return 1
    fi
    return 0
}

# Read models from config.cfg
read_models_from_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi

    # Extract models= line and remove comments
    local models_line
    models_line=$(grep "^models=" "$CONFIG_FILE" | head -1 | cut -d'#' -f1)

    if [[ -z "$models_line" ]]; then
        log_error "No 'models=' configuration found in ${CONFIG_FILE}"
        exit 1
    fi

    # Extract value and split by comma
    local models_raw="${models_line#models=}"

    # Split by comma and trim whitespace
    IFS=',' read -ra MODEL_ARRAY <<< "$models_raw"

    # Trim whitespace from each model ID
    for i in "${!MODEL_ARRAY[@]}"; do
        MODEL_ARRAY[$i]=$(echo "${MODEL_ARRAY[$i]}" | xargs)
    done

    if [[ ${#MODEL_ARRAY[@]} -eq 0 ]]; then
        log_error "No models configured in ${CONFIG_FILE}"
        exit 1
    fi

    log_info "Found ${#MODEL_ARRAY[@]} model(s) in configuration"
}

# Query model config from YAML using yq
get_model_config() {
    local model_id="$1"
    local field="$2"
    local default="$3"

    # Escape model ID for yq (handle special characters)
    local escaped_model="${model_id}"

    # Try to read from specific model config
    local value
    value=$(yq eval ".models[\"${escaped_model}\"].${field}" "$MODEL_CONFIGS" 2>/dev/null || echo "null")

    if [[ "$value" == "null" ]] || [[ -z "$value" ]]; then
        # Fallback to default config
        value=$(yq eval ".default.${field}" "$MODEL_CONFIGS" 2>/dev/null || echo "$default")
    fi

    echo "$value"
}

# Get environment variables for a model as Docker Compose YAML
get_model_environment() {
    local model_id="$1"
    local escaped_model="${model_id}"

    # Check if model exists in config
    local has_config
    has_config=$(yq eval ".models[\"${escaped_model}\"] | length" "$MODEL_CONFIGS" 2>/dev/null || echo "0")

    local env_yaml
    if [[ "$has_config" != "0" ]]; then
        env_yaml=$(yq eval ".models[\"${escaped_model}\"].environment" "$MODEL_CONFIGS" 2>/dev/null)
    else
        log_warn "Model '${model_id}' not found in model-configs.yaml, using default configuration"
        env_yaml=$(yq eval ".default.environment" "$MODEL_CONFIGS" 2>/dev/null)
    fi

    # Convert YAML to Docker Compose environment format
    echo "$env_yaml" | yq eval 'to_entries | .[] | "      " + .key + ": \"" + .value + "\""' -
}

# Get command args for a model as Docker Compose YAML array
get_model_command_args() {
    local model_id="$1"
    local escaped_model="${model_id}"

    # Check if model exists in config
    local has_config
    has_config=$(yq eval ".models[\"${escaped_model}\"] | length" "$MODEL_CONFIGS" 2>/dev/null || echo "0")

    local args_yaml
    if [[ "$has_config" != "0" ]]; then
        args_yaml=$(yq eval ".models[\"${escaped_model}\"].command_args[]" "$MODEL_CONFIGS" 2>/dev/null)
    else
        args_yaml=$(yq eval ".default.command_args[]" "$MODEL_CONFIGS" 2>/dev/null)
    fi

    # Format as Docker Compose command array
    echo "$args_yaml" | sed 's/^/      - "/' | sed 's/$/"/'
}

# Get additional bind-mount volumes for a model as Docker Compose YAML lines
get_model_volumes() {
    local model_id="$1"
    local count
    count=$(yq eval ".models[\"${model_id}\"].volumes | length" "$MODEL_CONFIGS" 2>/dev/null || echo "0")
    [[ "$count" == "0" || "$count" == "null" ]] && return 0
    yq eval ".models[\"${model_id}\"].volumes[]" "$MODEL_CONFIGS" | sed 's/^/      - /'
}

# Generate Docker Compose service for a single vLLM model
generate_vllm_service() {
    local model_id="$1"
    local port="$2"
    local index="$3"

    local served_name
    served_name=$(get_model_config "$model_id" "served_name" "$(generate_served_name "$model_id")")

    # If served_name is "auto-generated", generate it
    if [[ "$served_name" == "auto-generated" ]]; then
        served_name=$(generate_served_name "$model_id")
    fi

    # Strip -Specdec suffix to get the actual HuggingFace model ID for loading
    local hf_model_id
    hf_model_id=$(get_hf_model_id "$model_id")

    local memory
    memory=$(get_model_config "$model_id" "resources.memory" "80g")

    local shm_size
    shm_size=$(get_model_config "$model_id" "resources.shm_size" "16g")

    local container_name="agentic-vllm-${served_name}"

    log_info "  Model ${index}: ${model_id}"
    log_info "    Served as: ${served_name}"
    log_info "    Port: ${port}"
    log_info "    Container: ${container_name}"

    # Generate service definition
    # Note: served_name is used ONLY for Docker resource naming (container, hostname)
    # The actual API model name is the original HuggingFace model ID
    cat <<EOF

  vllm-${served_name}:
    image: ${VLLM_IMAGE}
    container_name: ${container_name}
    hostname: ${container_name}
    environment:
      HF_TOKEN: \${HF_TOKEN}
      HTTP_PROXY: \${HTTP_PROXY}
      HTTPS_PROXY: \${HTTPS_PROXY}
      http_proxy: \${HTTP_PROXY}
      https_proxy: \${HTTPS_PROXY}
      NO_PROXY: \${NO_PROXY}
      no_proxy: \${NO_PROXY}
$(get_model_environment "$model_id")
    command:
      - "--model"
      - "${hf_model_id}"
      - "--served-model-name"
      - "${model_id}"
      - "--host"
      - "0.0.0.0"
      - "--port"
      - "8000"
$(get_model_command_args "$model_id")
$(get_speculative_args "$model_id")
    ports:
      - "${port}:8000"
    volumes:
      - vllm-model-cache-${index}:/root/.cache/huggingface
$(get_model_volumes "$model_id")
    shm_size: "${shm_size}"
    deploy:
      resources:
        limits:
          memory: ${memory}
    restart: unless-stopped
    networks:
      - agentic-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 300s
EOF
}

# Generate LiteLLM routing configuration
generate_litellm_config() {
    log_info "Generating LiteLLM routing configuration..."

    local litellm_config="${DOCKER_DIR}/litellm/config.yaml"

    # Start with header
    cat > "$litellm_config" <<'EOF'
# LiteLLM Configuration for Agentic AI Stack
# Auto-generated by generate-docker-compose.sh
# DO NOT EDIT MANUALLY

litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]

model_list:
EOF

    # Add each model
    local port=$BASE_PORT
    for model_id in "${MODEL_ARRAY[@]}"; do
        local served_name
        served_name=$(get_model_config "$model_id" "served_name" "$(generate_served_name "$model_id")")
        [[ "$served_name" == "auto-generated" ]] && served_name=$(generate_served_name "$model_id")
        local container_name="agentic-vllm-${served_name}"
        local litellm_mode
        litellm_mode=$(get_model_config "$model_id" "litellm_mode" "null")
        cat >> "$litellm_config" <<EOF
  - model_name: ${model_id}
    litellm_params:
      model: openai/${model_id}
      api_base: http://${container_name}:8000/v1
      api_key: dummy
EOF
        # Embedding models need encoding_format set explicitly; LiteLLM's health check
        # sends encoding_format=null which vLLM rejects with a 400 validation error.
        if [[ "$litellm_mode" == "embedding" ]]; then
            cat >> "$litellm_config" <<EOF
      encoding_format: float
EOF
        fi
        if [[ "$litellm_mode" != "null" && -n "$litellm_mode" ]]; then
            cat >> "$litellm_config" <<EOF
    model_info:
      mode: ${litellm_mode}
EOF
        fi
        ((port++))
    done

    log_success "LiteLLM config written to: ${litellm_config}"
}

# Generate volumes section
generate_volumes() {
    cat <<EOF

volumes:
EOF

    for i in $(seq 0 $((${#MODEL_ARRAY[@]} - 1))); do
        echo "  vllm-model-cache-${i}:"
        echo "    driver: local"
    done
}

# Generate networks section
generate_networks() {
    cat <<EOF

networks:
  agentic-net:
    name: docker_agentic-net
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Function
# ═══════════════════════════════════════════════════════════════════════════

main() {
    log_info "Docker Compose vLLM Generator"
    log_info "=============================="
    echo

    # Check prerequisites
    log_info "Checking prerequisites..."
    check_command "yq" "https://github.com/mikefarah/yq#install"

    if [[ ! -f "$MODEL_CONFIGS" ]]; then
        log_error "Model configs not found: ${MODEL_CONFIGS}"
        exit 1
    fi

    # Validate YAML syntax
    if ! yq eval '.' "$MODEL_CONFIGS" &>/dev/null; then
        log_error "Invalid YAML syntax in ${MODEL_CONFIGS}"
        exit 1
    fi

    log_success "Prerequisites OK"
    echo

    # Read models from config
    log_info "Reading model configuration..."
    read_models_from_config
    echo

    # Read and validate tool call parser; update default config
    log_info "Configuring tool call parser..."
    read_tool_call_parser
    update_default_tool_call_parser
    echo

    # Validate model IDs
    log_info "Validating model IDs..."
    for model_id in "${MODEL_ARRAY[@]}"; do
        if ! validate_model_id "$model_id"; then
            exit 1
        fi
    done
    log_success "All model IDs valid"
    echo

    # Generate Docker Compose file
    log_info "Generating vLLM services..."

    # Write header
    cat > "$OUTPUT_FILE" <<'EOF'
# Docker Compose configuration for vLLM models
# Auto-generated by docker/scripts/generate-docker-compose.sh
# DO NOT EDIT MANUALLY - regenerate by running the script

services:
EOF

    # Generate service for each model
    local port=$BASE_PORT
    local index=0
    for model_id in "${MODEL_ARRAY[@]}"; do
        generate_vllm_service "$model_id" "$port" "$index" >> "$OUTPUT_FILE"
        port=$((port + 1))
        index=$((index + 1))
    done

    # Add volumes and networks
    generate_volumes >> "$OUTPUT_FILE"
    generate_networks >> "$OUTPUT_FILE"

    echo
    log_success "Generated: ${OUTPUT_FILE}"
    log_info "  Services: ${#MODEL_ARRAY[@]}"
    log_info "  Ports: ${BASE_PORT}-$((BASE_PORT + ${#MODEL_ARRAY[@]} - 1))"
    echo

    # Generate LiteLLM config
    generate_litellm_config
    echo

    log_success "Generation complete!"
    log_info "Next steps:"
    log_info "  1. Review: cat ${OUTPUT_FILE}"
    log_info "  2. Deploy: ./deploy-agentic-stack.sh --platform=docker"
}

# ═══════════════════════════════════════════════════════════════════════════
# Entry Point
# ═══════════════════════════════════════════════════════════════════════════

main "$@"
