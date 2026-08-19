#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
# deploy.sh — Agentic AI Stack Docker Compose Deployment
# =============================================================================
# Auto-generates .env from the existing config.cfg + vault.yml,
# then starts all requested services.
#
# Usage:
#   bash docker/deploy.sh                   # Core stack only
#   bash docker/deploy.sh --observability   # + Langfuse LLM tracing
#   bash docker/deploy.sh --full            # Everything
#   bash docker/deploy.sh --skip-build      # Skip Docker image builds
#   bash docker/deploy.sh --down            # Tear down + delete all volumes (required: passwords regenerate each run)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${DOCKER_DIR}/.." && pwd)"
DOCKER_CFG="${DOCKER_DIR}/config.cfg"
VAULT_FILE="${DOCKER_DIR}/vault.yml"
INVENTORY_CFG="${REPO_ROOT}/core/inventory/config.cfg"
VAULT_YML="${REPO_ROOT}/core/inventory/metadata/vault.yml"
ENV_FILE="${DOCKER_DIR}/.env"
COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✔  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
info() { echo -e "${CYAN}ℹ  $1${NC}"; }
die()  { echo -e "${RED}✘  $1${NC}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PROFILES=()
SKIP_BUILD=false
PULL=false
DO_DOWN=false
DELETE_VOLUMES=false
SKIP_CONFIRMATION=false

for arg in "$@"; do
    case "${arg}" in
        --observability)    PROFILES+=(observability) ;;
        --full)             PROFILES=(observability) ;;
        --skip-build)       SKIP_BUILD=true ;;
        --pull)             PULL=true ;;
        --down)             DO_DOWN=true; DELETE_VOLUMES=true ;;
        --skip-confirmation) SKIP_CONFIRMATION=true ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "  --observability  Enable Langfuse LLM tracing (ClickHouse + MinIO)"
            echo "  --full           Enable all optional profiles"
            echo "  --skip-build     Skip docker image builds"
            echo "  --pull           Pull latest images before starting"
            echo "  --skip-confirmation  Skip deployment confirmation prompt (for CI/CD)"
            echo "  --down           Stop containers and delete all volumes (passwords regenerate each run)"
            exit 0 ;;
        *) die "Unknown argument: '${arg}'. Run '$0 --help' for usage." ;;
    esac
done

# ---------------------------------------------------------------------------
# Auto-detect profiles from docker/config.cfg when no CLI flags given
# ---------------------------------------------------------------------------
_dcfg() { grep "^${1}=" "${DOCKER_CFG}" 2>/dev/null | cut -d= -f2- | sed 's/#.*//' | tr -d '[:space:]' || true; }

if [[ "${#PROFILES[@]}" -eq 0 && -f "${DOCKER_CFG}" ]]; then
    [[ "$(_dcfg deploy_agenticai_plugin)" == "on" ]] && PROFILES+=(flowise)
    [[ "$(_dcfg deploy_observability)"    == "on" ]] && PROFILES+=(observability)
fi

# ---------------------------------------------------------------------------
# Deduplicate profiles
# ---------------------------------------------------------------------------
PROFILES=($(printf '%s\n' "${PROFILES[@]:-}" | sort -u))

# ---------------------------------------------------------------------------
# Docker Installation (with proxy support)
# ---------------------------------------------------------------------------
install_docker_fresh() {
    # Check if deploy_docker_fresh is enabled
    local deploy_fresh="$(_dcfg deploy_docker_fresh)"
    if [[ "${deploy_fresh}" != "on" ]]; then
        return 0
    fi

    info "deploy_docker_fresh=on detected — installing Docker & Docker Compose..."

    # Detect OS and package manager
    local os_id="" os_family="" pkg_mgr="" arch=""

    arch="$(uname -m)"
    case "${arch}" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             warn "Unsupported arch ${arch} — defaulting to amd64"; arch="amd64" ;;
    esac

    if [[ -f /etc/os-release ]]; then
        os_id="$(. /etc/os-release && echo "${ID}")"
        local os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    else
        os_id="unknown"
    fi

    case "${os_id}" in
        ubuntu|debian|linuxmint|pop)
            os_family="debian"; pkg_mgr="apt-get" ;;
        rhel|centos|rocky|almalinux|ol|fedora|amzn)
            os_family="rhel"; pkg_mgr="dnf" ;;
        *)
            if echo "${os_like}" | grep -qi "debian"; then
                os_family="debian"; pkg_mgr="apt-get"
            elif echo "${os_like}" | grep -qi "rhel\|fedora\|centos"; then
                os_family="rhel"; pkg_mgr="dnf"
            else
                warn "Unknown OS '${os_id}' — assuming Debian-family"
                os_family="debian"; pkg_mgr="apt-get"
            fi ;;
    esac

    # Read proxy settings from config.cfg
    local http_proxy_val="$(_dcfg http_proxy)"
    local https_proxy_val="$(_dcfg https_proxy)"
    local no_proxy_val="$(_dcfg no_proxy)"

    # Configure proxy for the installation process
    if [[ -n "${http_proxy_val}" ]]; then
        export http_proxy="${http_proxy_val}"
        export HTTP_PROXY="${http_proxy_val}"
    fi
    if [[ -n "${https_proxy_val}" ]]; then
        export https_proxy="${https_proxy_val}"
        export HTTPS_PROXY="${https_proxy_val}"
    fi
    if [[ -n "${no_proxy_val}" ]]; then
        export no_proxy="${no_proxy_val}"
        export NO_PROXY="${no_proxy_val}"
    fi

    # Uninstall old versions if present
    case "${pkg_mgr}" in
        apt-get)
            sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            ;;
        dnf|yum)
            sudo ${pkg_mgr} remove -y docker docker-client docker-client-latest \
                docker-common docker-latest docker-latest-logrotate \
                docker-logrotate docker-engine 2>/dev/null || true
            ;;
    esac

    # Install Docker based on OS family
    case "${pkg_mgr}" in
        apt-get)
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq

            # Install prerequisites
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg lsb-release

            # Add Docker's official GPG key
            sudo install -m 0755 -d /etc/apt/keyrings
            # Remove existing key to avoid prompt
            sudo rm -f /etc/apt/keyrings/docker.gpg
            if [[ -n "${https_proxy_val}" ]]; then
                curl -fsSL --proxy "${https_proxy_val}" https://download.docker.com/linux/ubuntu/gpg | \
                    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            else
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
            fi
            sudo chmod a+r /etc/apt/keyrings/docker.gpg

            # Set up repository
            echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            # Configure apt proxy if needed
            if [[ -n "${http_proxy_val}" || -n "${https_proxy_val}" ]]; then
                sudo mkdir -p /etc/apt/apt.conf.d
                {
                    [[ -n "${http_proxy_val}" ]]  && echo "Acquire::http::Proxy \"${http_proxy_val}\";"
                    [[ -n "${https_proxy_val}" ]] && echo "Acquire::https::Proxy \"${https_proxy_val}\";"
                } | sudo tee /etc/apt/apt.conf.d/95proxies > /dev/null
            fi

            # Install Docker Engine
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
            sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>&1 | tail -5
            ;;

        dnf|yum)
            info "Installing Docker on RHEL/CentOS/Fedora..."

            # Install prerequisites
            sudo ${pkg_mgr} install -y -q yum-utils device-mapper-persistent-data lvm2

            # Add Docker repository
            if [[ "${os_id}" == "fedora" ]]; then
                sudo yum-config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            else
                sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            fi

            # Configure yum/dnf proxy if needed
            if [[ -n "${http_proxy_val}" ]]; then
                echo "proxy=${http_proxy_val}" | sudo tee -a /etc/yum.conf > /dev/null
            fi

            # Install Docker Engine
            sudo ${pkg_mgr} install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
    esac

    # Configure Docker daemon with proxy settings
    if [[ -n "${http_proxy_val}" || -n "${https_proxy_val}" ]]; then
        sudo mkdir -p /etc/systemd/system/docker.service.d

        {
            echo "[Service]"
            [[ -n "${http_proxy_val}" ]] && echo "Environment=\"HTTP_PROXY=${http_proxy_val}\""
            [[ -n "${https_proxy_val}" ]] && echo "Environment=\"HTTPS_PROXY=${https_proxy_val}\""
            [[ -n "${no_proxy_val}" ]] && echo "Environment=\"NO_PROXY=${no_proxy_val}\""
        } | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null
    fi

    # Start and enable Docker service
    # Clear any previous start-limit-hit state so this restart isn't refused outright.
    sudo systemctl reset-failed docker.service 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl restart docker 2>/dev/null || sudo systemctl start docker
    sudo systemctl enable docker

    # Add current user to docker group
    local current_user="${SUDO_USER:-${USER}}"
    sudo usermod -aG docker "${current_user}" || true

    # Verify installation
    if ! docker --version &>/dev/null; then
        die "Docker installation failed"
    fi

    if ! docker compose version &>/dev/null; then
        die "Docker Compose installation failed"
    fi

    # Install yq for vLLM model configuration
    if ! command -v yq &>/dev/null; then
        info "Installing yq for model configuration..."
        local yq_version="v4.44.1"
        local yq_url="https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_${arch}"

        if [[ -n "${https_proxy_val}" ]]; then
            sudo curl -fsSL --proxy "${https_proxy_val}" -o /usr/local/bin/yq "${yq_url}"
        else
            sudo curl -fsSL -o /usr/local/bin/yq "${yq_url}"
        fi
        sudo chmod +x /usr/local/bin/yq

        if command -v yq &>/dev/null; then
            ok "yq installed: $(yq --version)"
        else
            warn "yq installation failed (non-fatal)"
        fi
    fi

    # Configure Docker client proxy for current user
    if [[ -n "${http_proxy_val}" || -n "${https_proxy_val}" ]]; then
        mkdir -p "${HOME}/.docker"
        {
            echo "{"
            echo "  \"proxies\": {"
            echo "    \"default\": {"
            if [[ -n "${http_proxy_val}" ]]; then
                echo "      \"httpProxy\": \"${http_proxy_val}\","
            fi
            if [[ -n "${https_proxy_val}" ]]; then
                echo "      \"httpsProxy\": \"${https_proxy_val}\","
            fi
            if [[ -n "${no_proxy_val}" ]]; then
                echo "      \"noProxy\": \"${no_proxy_val}\""
            fi
            echo "    }"
            echo "  }"
            echo "}"
        } > "${HOME}/.docker/config.json"
    fi

    # Try to test Docker with current session
    if ! docker ps &>/dev/null 2>&1; then
        warn "Docker requires elevated permissions in this session."
        info "Using sudo for Docker commands (or run: newgrp docker)"
        export DOCKER_SUDO="sudo"
    fi

    # Test Docker proxy connectivity
    if [[ -n "${http_proxy_val}" || -n "${https_proxy_val}" ]]; then
        local test_cmd="${DOCKER_SUDO:-} docker"
        if ! timeout 30 ${test_cmd} pull alpine:latest &>/dev/null; then
            warn "Docker image pull test failed - proxy may need additional configuration"
            warn "This could cause issues during deployment"
            warn "Verify proxy allows access to: docker.io, docker.litellm.ai, gcr.io, ghcr.io"
        else
            ${test_cmd} rmi alpine:latest &>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Install Docker if deploy_docker_fresh=on
# ---------------------------------------------------------------------------
if [[ -f "${DOCKER_CFG}" ]]; then
    install_docker_fresh
fi

# ---------------------------------------------------------------------------
# Check prerequisites
# ---------------------------------------------------------------------------
# Use DOCKER_SUDO if set (for fresh installs where group membership isn't active)
DOCKER_CMD="${DOCKER_SUDO:-} docker"
DOCKER_COMPOSE_CMD="${DOCKER_SUDO:-} docker compose"

if ! command -v docker &>/dev/null; then
    die "docker is not installed."
fi

if ! ${DOCKER_COMPOSE_CMD} version &>/dev/null 2>&1; then
    die "docker compose v2 is not installed."
fi

# `docker compose version` only checks the CLI plugin and succeeds even if the
# daemon is down, so explicitly probe the daemon before doing any real work.
if ! ${DOCKER_CMD} info &>/dev/null 2>&1; then
    die "Docker daemon is not running (or not reachable at unix:///var/run/docker.sock).\n   Start it with: sudo systemctl start docker"
fi

# ---------------------------------------------------------------------------
# Handle --down
# ---------------------------------------------------------------------------
if [[ "${DO_DOWN}" == "true" ]]; then
    COMPOSE_CMD="${DOCKER_COMPOSE_CMD} -f ${COMPOSE_FILE}"
    [[ -f "${ENV_FILE}" ]] && COMPOSE_CMD+=" --env-file ${ENV_FILE}"
    # Always include all known profiles so their volumes are also removed
    for p in flowise observability; do
        COMPOSE_CMD+=" --profile ${p}"
    done
    info "Stopping containers and removing all volumes (passwords are regenerated on each deploy)..."
    eval "${COMPOSE_CMD} down --volumes --remove-orphans"
    ok "Services stopped and volumes removed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Generate .env from docker/config.cfg (falls back to k8s config)
# ---------------------------------------------------------------------------
# _dcfg() is already defined above; _cfg() tries docker cfg first, then k8s cfg
_cfg() {
    local val
    val=$(grep "^${1}=" "${DOCKER_CFG}" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
    [[ -z "${val}" && -f "${INVENTORY_CFG}" ]] && \
        val=$(grep "^${1}=" "${INVENTORY_CFG}" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
    echo "${val}"
}
# _vault() reads docker/vault.yml first, falls back to k8s vault.yml
_vault() {
    local val
    val=$({ grep "^${1}:" "${VAULT_FILE}" 2>/dev/null || true; } | awk -F'"' '{print $2}')
    if [[ -z "${val}" && -f "${VAULT_YML}" ]]; then
        val=$({ grep "^${1}:" "${VAULT_YML}" 2>/dev/null || true; } | awk -F'"' '{print $2}')
    fi
    echo "${val}"
}

# Get model list from config
get_model_list() {
    local models_raw=$(_cfg models)
    if [[ -z "$models_raw" ]]; then
        echo "Qwen/Qwen2.5-Coder-14B-Instruct"  # Default
        return
    fi
    echo "$models_raw"
}

# Generate vLLM container names for NO_PROXY
# Matches the naming logic in generate-docker-compose.sh (reads served_name from model-configs.yaml)
get_vllm_container_names() {
    local models=$(get_model_list)
    IFS=',' read -ra MODEL_LIST <<< "$models"
    local container_names=""
    local model_configs="${DOCKER_DIR}/model-configs.yaml"

    for model_id in "${MODEL_LIST[@]}"; do
        model_id=$(echo "$model_id" | xargs)
        # Try to read served_name override from model-configs.yaml
        local served_name=""
        if command -v yq &>/dev/null && [[ -f "$model_configs" ]]; then
            served_name=$(yq eval ".models[\"${model_id}\"].served_name" "$model_configs" 2>/dev/null || echo "null")
            [[ "$served_name" == "null" || "$served_name" == "auto-generated" ]] && served_name=""
        fi
        # Fall back to derived name if no override
        if [[ -z "$served_name" ]]; then
            served_name=$(echo "${model_id//\//-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
        fi
        local container_name="agentic-vllm-${served_name}"

        if [[ -z "$container_names" ]]; then
            container_names="$container_name"
        else
            container_names="${container_names},${container_name}"
        fi
    done

    echo "$container_names"
}

# ---------------------------------------------------------------------------
# Auto-generate vault.yml if it doesn't exist
# ---------------------------------------------------------------------------
if [[ ! -f "${VAULT_FILE}" ]]; then
    info "No vault.yml found — generating secrets..."
    bash "${SCRIPT_DIR}/scripts/generate-vault-secrets.sh"
fi

if [[ -f "${DOCKER_CFG}" ]]; then
    : # reading docker/config.cfg
elif [[ -f "${INVENTORY_CFG}" ]]; then
    : # reading core/inventory/config.cfg
else
    warn "No config.cfg found — using defaults."
fi

# Both docker cfg (cluster_url) and k8s cfg (cluster_url) use the same key
# Domain for display URLs (hardcoded to localhost for Docker)
DOMAIN="localhost"

# HuggingFace token (required for model downloads)
HF_TOKEN=$(_cfg hugging_face_token)

# Proxy settings (optional)
HTTP_PROXY=$(_cfg http_proxy)
HTTPS_PROXY=$(_cfg https_proxy)
NO_PROXY=$(_cfg no_proxy)

# Map model alias → HF model ID (for backward compatibility with old aliases)
# New deployments should use full HuggingFace model IDs in config.cfg
_models=$(_cfg models)
case "${_models}" in
    *qwen2-5-coder-14b*) LLM_MODEL_ID="Qwen/Qwen2.5-Coder-14B-Instruct" ;;
    *qwen2-5-coder-7b*)  LLM_MODEL_ID="Qwen/Qwen2.5-Coder-7B-Instruct"  ;;
    *qwen2-5-coder-3b*)  LLM_MODEL_ID="Qwen/Qwen2.5-Coder-3B-Instruct"  ;;
    *neural-chat-7b*)    LLM_MODEL_ID="Intel/neural-chat-7b-v3-3"        ;;
    *)                   LLM_MODEL_ID="${_models}" ;;
esac

# Vault secrets — must be present in vault.yml
LITELLM_MASTER_KEY=$(_vault litellm_master_key)
[[ -z "${LITELLM_MASTER_KEY}" ]] && die "LITELLM_MASTER_KEY not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LITELLM_SALT_KEY=$(_vault litellm_salt_key)
[[ -z "${LITELLM_SALT_KEY}" ]] && die "LITELLM_SALT_KEY not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

# PostgreSQL — admin superuser + per-service users
POSTGRES_ADMIN_PASSWORD=$(_vault postgres_admin_password)
[[ -z "${POSTGRES_ADMIN_PASSWORD}" ]] && die "POSTGRES_ADMIN_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LITELLM_DB_PASSWORD=$(_vault litellm_db_password)
[[ -z "${LITELLM_DB_PASSWORD}" ]] && LITELLM_DB_PASSWORD=$(_vault postgresql_password)
[[ -z "${LITELLM_DB_PASSWORD}" ]] && die "LITELLM_DB_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

FLOWISE_DB_PASSWORD=$(_vault flowise_db_password)
[[ -z "${FLOWISE_DB_PASSWORD}" ]] && FLOWISE_DB_PASSWORD=$(_vault agenticai_postgres_password)
[[ -z "${FLOWISE_DB_PASSWORD}" ]] && die "FLOWISE_DB_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

# Redis — admin + per-service ACL passwords (all from vault)
REDIS_PASSWORD=$(_vault redis_password)
[[ -z "${REDIS_PASSWORD}" ]] && die "REDIS_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LITELLM_REDIS_PASSWORD=$(_vault litellm_redis_password)
[[ -z "${LITELLM_REDIS_PASSWORD}" ]] && die "LITELLM_REDIS_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

FLOWISE_REDIS_PASSWORD=$(_vault flowise_redis_password)
[[ -z "${FLOWISE_REDIS_PASSWORD}" ]] && die "FLOWISE_REDIS_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LANGFUSE_REDIS_PASSWORD=$(_vault langfuse_redis_password)
[[ -z "${LANGFUSE_REDIS_PASSWORD}" ]] && die "LANGFUSE_REDIS_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

FLOWISE_API_KEY=$(_vault flowise_api_key)               # may be empty — set after first run

# NOTE: Flowise 3.1.2 has NO environment-based admin bootstrap — the image contains no
# reference to FLOWISE_ADMIN_EMAIL/FLOWISE_ADMIN_PASSWORD, and its `user` CLI can only
# reset the password of an already-existing account.  The first owner is therefore
# created by a human through the UI's "Setup Account" page on first run.  Those two
# vault keys are intentionally NOT propagated to .env or the container: writing
# credentials that nothing consumes implies a pre-provisioned admin that does not exist.
FLOWISE_API_KEY=$(_vault flowise_api_key)               # may be empty — set after first run

# Loopback-only publish address for Flowise (see docker-compose.yml).  Override in
# config.cfg / environment only after first-time setup has been completed.
FLOWISE_BIND_ADDR="${FLOWISE_BIND_ADDR:-127.0.0.1}"

PGVECTOR_PASSWORD=$(_vault pgvector_password)
[[ -z "${PGVECTOR_PASSWORD}" ]] && die "PGVECTOR_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LANGFUSE_SECRET_KEY=$(_vault langfuse_secret_key)
[[ -z "${LANGFUSE_SECRET_KEY}" ]] && die "LANGFUSE_SECRET_KEY not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LANGFUSE_PUBLIC_KEY=$(_vault langfuse_public_key)
[[ -z "${LANGFUSE_PUBLIC_KEY}" ]] && die "LANGFUSE_PUBLIC_KEY not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LANGFUSE_INIT_USER_EMAIL="admin@admin.com"
LANGFUSE_INIT_USER_PASSWORD=$(_vault langfuse_init_user_password)
[[ -z "${LANGFUSE_INIT_USER_PASSWORD}" ]] && die "LANGFUSE_INIT_USER_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

LANGFUSE_DB_PASSWORD=$(_vault langfuse_db_password)
[[ -z "${LANGFUSE_DB_PASSWORD}" ]] && LANGFUSE_DB_PASSWORD=$(_vault postgresql_password)
[[ -z "${LANGFUSE_DB_PASSWORD}" ]] && die "LANGFUSE_DB_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

CLICKHOUSE_PASSWORD=$(_vault clickhouse_password)
[[ -z "${CLICKHOUSE_PASSWORD}" ]] && die "CLICKHOUSE_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

MINIO_ROOT_USER=$(_vault minio_user)
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minio}"  # Username can have a default

MINIO_ROOT_PASSWORD=$(_vault minio_secret)
[[ -z "${MINIO_ROOT_PASSWORD}" ]] && die "MINIO_ROOT_PASSWORD not found in vault.yml. Please regenerate vault.yml by running: bash docker/scripts/generate-vault-secrets.sh"

# Preserve existing FLOWISE_API_KEY if .env exists
if [[ -f "${ENV_FILE}" ]]; then
    _existing_key=$(grep '^FLOWISE_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    [[ -z "${FLOWISE_API_KEY}" && -n "${_existing_key}" ]] && FLOWISE_API_KEY="${_existing_key}"
fi

# Secrets from vault (stable across redeploys)
LANGFUSE_NEXTAUTH_SECRET=$(_vault langfuse_nextauth_secret)
LANGFUSE_NEXTAUTH_SECRET="${LANGFUSE_NEXTAUTH_SECRET:-$(openssl rand -hex 16 2>/dev/null || true)}"

# ---------------------------------------------------------------------------
# Generate Redis ACL file  (docker/redis/acl.conf)
# Each service authenticates with its own dedicated Redis user.
# ---------------------------------------------------------------------------
_sha256() { printf '%s' "${1}" | sha256sum | awk '{print $1}'; }
mkdir -p "${DOCKER_DIR}/redis"
cat > "${DOCKER_DIR}/redis/acl.conf" << ACLEOF
user default off nopass nocommands
user admin on #$(_sha256 "${REDIS_PASSWORD}") ~* &* +@all
user litellm on #$(_sha256 "${LITELLM_REDIS_PASSWORD}") ~* &* +@all
user flowise on #$(_sha256 "${FLOWISE_REDIS_PASSWORD}") ~* &* +@all
user langfuse on #$(_sha256 "${LANGFUSE_REDIS_PASSWORD}") ~* &* +@all
ACLEOF
chmod 600 "${DOCKER_DIR}/redis/acl.conf"

# -------------------------------------------------------------------------
# Generate PostgreSQL init script  (docker/postgres/init.sql)
# Creates per-service users, databases, and enables pgvector on agentdb.
# The script runs ONCE when the data directory is first initialised.
# To rotate passwords on an existing deployment:
#   docker exec agentic-postgres psql -U postgres -c "ALTER USER litellm WITH PASSWORD 'new';"
# -------------------------------------------------------------------------
mkdir -p "${DOCKER_DIR}/postgres"
cat > "${DOCKER_DIR}/postgres/init.sql" << SQLEOF
-- PostgreSQL init -- generated by deploy.sh on $(date)
-- Do not edit manually; re-run deploy.sh to regenerate.
-- Note: this file only takes effect when the postgres-data volume is empty.

-- =======================================================
-- Per-service roles (users)
-- =======================================================
CREATE USER litellm   WITH PASSWORD '${LITELLM_DB_PASSWORD}';
CREATE USER flowise   WITH PASSWORD '${FLOWISE_DB_PASSWORD}';
CREATE USER langfuse  WITH PASSWORD '${LANGFUSE_DB_PASSWORD}';
CREATE USER agentuser WITH PASSWORD '${PGVECTOR_PASSWORD}';

-- =======================================================
-- Per-service databases (each owned by its user)
-- =======================================================
CREATE DATABASE litellm  OWNER litellm;
CREATE DATABASE flowisedb OWNER flowise;
CREATE DATABASE langfuse  OWNER langfuse;
CREATE DATABASE agentdb   OWNER agentuser;

-- =======================================================
-- Revoke public connection access (defence-in-depth)
-- =======================================================
REVOKE CONNECT ON DATABASE litellm   FROM PUBLIC;
REVOKE CONNECT ON DATABASE flowisedb FROM PUBLIC;
REVOKE CONNECT ON DATABASE langfuse  FROM PUBLIC;
REVOKE CONNECT ON DATABASE agentdb   FROM PUBLIC;

-- =======================================================
-- pgvector extension (vector similarity search for RAG)
-- =======================================================
\connect agentdb
CREATE EXTENSION IF NOT EXISTS vector;
SQLEOF
chmod 644 "${DOCKER_DIR}/postgres/init.sql"

# NO_PROXY — append all Docker service names so containers can reach each other
# without routing through the corporate proxy. We also export the variable so
# that docker compose (invoked below) uses this value even when the host shell
# already has $NO_PROXY set from /etc/environment or similar system-wide files.
_docker_services="flowise,litellm,vllm,pgvector,langfuse-web,redis,postgres,clickhouse,minio"
_vllm_containers=$(get_vllm_container_names)
NO_PROXY="${NO_PROXY:+${NO_PROXY},}localhost,127.0.0.1,${_docker_services},${_vllm_containers}"
export NO_PROXY

# Capture old NO_PROXY from existing .env before overwriting (to detect env changes that require litellm recreate)
_litellm_no_proxy_before=""
[[ -f "${ENV_FILE}" ]] && _litellm_no_proxy_before=$(grep '^NO_PROXY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)

# Preserve the Flowise registration lockdown across redeploys.  Empty on a fresh
# deployment (the admin still has to create the owner account); set to the register
# endpoint by the post-start reconcile below once an owner exists.
FLOWISE_DENYLIST_URLS=""
[[ -f "${ENV_FILE}" ]] && FLOWISE_DENYLIST_URLS=$(grep '^FLOWISE_DENYLIST_URLS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)

# Write .env
cat > "${ENV_FILE}" << EOF
# Auto-generated by deploy.sh on $(date)
# Edit this file or re-run deploy.sh to refresh

DOMAIN=${DOMAIN}

HF_TOKEN=${HF_TOKEN}
LLM_MODEL_ID=${LLM_MODEL_ID}

LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}"
LITELLM_SALT_KEY="${LITELLM_SALT_KEY}"

# PostgreSQL — admin (healthchecks) + per-service database users
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD}"
POSTGRES_USER=postgres
LITELLM_DB_USER=litellm
LITELLM_DB_PASSWORD="${LITELLM_DB_PASSWORD}"
LITELLM_DB_NAME=litellm

# Redis — admin (health checks) + per-service ACL passwords
REDIS_PASSWORD="${REDIS_PASSWORD}"
LITELLM_REDIS_PASSWORD="${LITELLM_REDIS_PASSWORD}"
FLOWISE_REDIS_PASSWORD="${FLOWISE_REDIS_PASSWORD}"
LANGFUSE_REDIS_PASSWORD="${LANGFUSE_REDIS_PASSWORD}"

# Flowise host publish address — loopback by default so that an instance with an empty
# database is not reachable from an untrusted network before its owner account exists.
FLOWISE_BIND_ADDR=${FLOWISE_BIND_ADDR}
# Set to /api/v1/account/register once the owner exists (managed by deploy.sh).
FLOWISE_DENYLIST_URLS=${FLOWISE_DENYLIST_URLS}
FLOWISE_DB_USER=flowise
FLOWISE_DB_PASSWORD="${FLOWISE_DB_PASSWORD}"
FLOWISE_DB_NAME=flowisedb
FLOWISE_API_KEY="${FLOWISE_API_KEY}"

PGVECTOR_USER=agentuser
PGVECTOR_PASSWORD="${PGVECTOR_PASSWORD}"
PGVECTOR_DB=agentdb

LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY}"
LANGFUSE_NEXTAUTH_SECRET="${LANGFUSE_NEXTAUTH_SECRET}"
LANGFUSE_INIT_USER_EMAIL="${LANGFUSE_INIT_USER_EMAIL}"
LANGFUSE_INIT_USER_PASSWORD="${LANGFUSE_INIT_USER_PASSWORD}"
LANGFUSE_DB_USER=langfuse
LANGFUSE_DB_PASSWORD="${LANGFUSE_DB_PASSWORD}"
LANGFUSE_DB_NAME=langfuse
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD}"
MINIO_ROOT_USER="${MINIO_ROOT_USER}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}"

HTTP_PROXY=${HTTP_PROXY:-}
HTTPS_PROXY=${HTTPS_PROXY:-}
NO_PROXY=${NO_PROXY}
EOF

# ---------------------------------------------------------------------------
# Helper Functions for Configuration Display
# ---------------------------------------------------------------------------

# Mask sensitive values (show first 7 + last 4 chars)
mask_secret() {
    local secret="$1"
    local len=${#secret}
    if [[ $len -le 11 ]]; then
        echo "********"
    else
        local first="${secret:0:7}"
        local last="${secret: -4}"
        echo "${first}...${last}"
    fi
}


# Print deployment configuration summary
print_deployment_config() {
    local models=$(get_model_list)
    IFS=',' read -ra MODEL_LIST <<< "$models"
    local model_count=${#MODEL_LIST[@]}

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Agentic AI Stack — Deployment Configuration${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""

    # General Configuration
    echo -e "${CYAN}── General Configuration ──────────────────────────────${NC}"
    echo "  Domain              : ${DOMAIN}"
    echo ""

    # LLM Models
    echo -e "${CYAN}── LLM Models ─────────────────────────────────────────${NC}"
    local port=2080
    local total_memory=0
    for i in "${!MODEL_LIST[@]}"; do
        local model="${MODEL_LIST[$i]}"
        model=$(echo "$model" | xargs)  # Trim whitespace

        # Generate served name
        local served_name=$(echo "${model//\//-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

        # Memory per model (default 80GB, whisper is 40GB)
        local memory="80GB"
        local kvcache="40GB"
        if [[ "$model" == *"whisper"* ]]; then
            memory="40GB"
            kvcache="10GB"
            total_memory=$((total_memory + 40))
        else
            total_memory=$((total_memory + 80))
        fi

        echo "  Model $((i+1)): ${model}"
        echo "    Served Name     : ${served_name}"
        echo "    Port            : ${port}"
        echo "    Memory Limit    : ${memory}"
        echo "    KV Cache Space  : ${kvcache}"
        echo ""

        port=$((port + 1))
    done

    echo "  Total Models        : ${model_count}"
    echo "  Total Memory        : ~${total_memory}GB"
    echo ""

    # Components
    echo -e "${CYAN}── Components ─────────────────────────────────────────${NC}"
    echo "  GenAI Gateway (LiteLLM)  : on"
    echo "  Flowise                  : on"
    echo "  Consumer Portal          : on"
    echo "  PostgreSQL + pgvector    : on"
    echo "  Redis Stack              : on"

    local has_obs=false
    for p in "${PROFILES[@]:-}"; do
        case "$p" in
            observability) has_obs=true ;;
        esac
    done

    if [[ "$has_obs" == "true" ]]; then
        echo "  Langfuse (LLM tracing)   : on"
    else
        echo "  Langfuse (LLM tracing)   : off"
    fi
    echo ""

    # Proxy Settings
    if [[ -n "$HTTP_PROXY" || -n "$HTTPS_PROXY" ]]; then
        echo -e "${CYAN}── Proxy Settings ─────────────────────────────────────${NC}"
        [[ -n "$HTTP_PROXY" ]] && echo "  HTTP_PROXY          : ${HTTP_PROXY}"
        [[ -n "$HTTPS_PROXY" ]] && echo "  HTTPS_PROXY         : ${HTTPS_PROXY}"
        [[ -n "$NO_PROXY" ]] && echo "  NO_PROXY            : ${NO_PROXY:0:60}..."
        echo ""
    fi

    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
}

# Check system resources and warn if insufficient
check_system_resources() {
    # Calculate required memory
    local models=$(get_model_list)
    IFS=',' read -ra _MODEL_LIST <<< "$models"
    local model_count=${#_MODEL_LIST[@]}
    local base_memory=8  # Base services (litellm, flowise, etc.)
    local model_memory=$((model_count * 80))  # ~80GB per model

    local required_memory=$((base_memory + model_memory))

    # Get system total memory (in GB)
    if [[ -f /proc/meminfo ]]; then
        local total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local total_memory_gb=$((total_memory_kb / 1024 / 1024))

        # Calculate threshold (75% of available)
        local threshold=$((total_memory_gb * 75 / 100))

        echo ""
        echo -e "${CYAN}── System Resources ───────────────────────────────────${NC}"
        echo "  Required Memory     : ~${required_memory}GB"
        echo "  Available Memory    : ${total_memory_gb}GB"
        echo "  Usage               : ~$((required_memory * 100 / total_memory_gb))%"

        if [[ $required_memory -gt $threshold ]]; then
            echo ""
            warn "Memory requirement (${required_memory}GB) exceeds 75% of available memory (${total_memory_gb}GB)"
            warn "Performance may be degraded. Consider:"
            warn "  • Reducing the number of models in docker/config.cfg"
            warn "  • Disabling optional profiles (--observability)"
            warn "  • Upgrading system RAM"
            echo ""
        fi
    fi
}

# ---------------------------------------------------------------------------
# Generate vLLM compose file from model configs
# ---------------------------------------------------------------------------
MODEL_CONFIGS_FILE="${DOCKER_DIR}/model-configs.yaml"
VLLM_COMPOSE_FILE="${DOCKER_DIR}/docker-compose.vllm.yml"
GENERATOR_SCRIPT="${DOCKER_DIR}/scripts/generate-docker-compose.sh"

LITELLM_CONFIG_FILE="${DOCKER_DIR}/litellm/config.yaml"
_litellm_config_hash_before=""
[[ -f "${LITELLM_CONFIG_FILE}" ]] && _litellm_config_hash_before=$(sha256sum "${LITELLM_CONFIG_FILE}" 2>/dev/null | awk '{print $1}')

if [[ -f "${MODEL_CONFIGS_FILE}" && -f "${GENERATOR_SCRIPT}" ]]; then
    bash "${GENERATOR_SCRIPT}" || die "Failed to generate vLLM configuration"

    # Append vLLM compose file to main compose command if it exists
    if [[ -f "${VLLM_COMPOSE_FILE}" ]]; then
        VLLM_COMPOSE_ARG="-f ${VLLM_COMPOSE_FILE}"
    fi
else
    # Fallback: no multi-model support, use legacy single-model setup
    VLLM_COMPOSE_ARG=""
fi

# ---------------------------------------------------------------------------
# Display deployment configuration
# ---------------------------------------------------------------------------
print_deployment_config

# ---------------------------------------------------------------------------
# Check system resources
# ---------------------------------------------------------------------------
check_system_resources

# ---------------------------------------------------------------------------
# Confirmation prompt (unless --skip-confirmation)
# ---------------------------------------------------------------------------
if [[ "${SKIP_CONFIRMATION}" != "true" ]]; then
    echo ""
    read -r -p "$(echo -e ${CYAN})Proceed with deployment? [y/N]: $(echo -e ${NC})" response
    if [[ ! "${response}" =~ ^[Yy]$ ]]; then
        info "Deployment cancelled by user"
        exit 0
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Pre-deployment checks
# ---------------------------------------------------------------------------
# Remove any manually created network so Docker Compose can manage it properly
NETWORK_NAME="docker_agentic-net"
if ${DOCKER_CMD} network inspect "${NETWORK_NAME}" &>/dev/null 2>&1; then
    # Check if network was created manually (without compose labels)
    if ! ${DOCKER_CMD} network inspect "${NETWORK_NAME}" 2>/dev/null | grep -q "com.docker.compose.project"; then
        info "Removing manually created network ${NETWORK_NAME} (Compose will recreate it)..."
        ${DOCKER_CMD} network rm "${NETWORK_NAME}" 2>/dev/null || warn "Could not remove network (may be in use)"
    fi
fi

# ---------------------------------------------------------------------------
# Build docker compose command
# ---------------------------------------------------------------------------
COMPOSE_CMD="${DOCKER_COMPOSE_CMD} -f ${COMPOSE_FILE} ${VLLM_COMPOSE_ARG} --env-file ${ENV_FILE}"
for p in "${PROFILES[@]:-}"; do
    [[ -n "${p}" ]] && COMPOSE_CMD+=" --profile ${p}"
done

# ---------------------------------------------------------------------------
# Pull images
# ---------------------------------------------------------------------------
if [[ "${PULL}" == "true" ]]; then
    info "Pulling images..."
    eval "${COMPOSE_CMD} pull --ignore-pull-failures" || true
fi

# ---------------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------------
info "Starting services..."
eval "${COMPOSE_CMD} up -d --no-recreate"

# Reconcile LiteLLM after --no-recreate:
#   - NO_PROXY changed (new vLLM containers added) → force-recreate so new env vars take effect
#   - config.yaml changed only                    → restart is enough (bind-mount, no env change)
_litellm_no_proxy_after=$(grep '^NO_PROXY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)
_litellm_config_hash_after=$(sha256sum "${LITELLM_CONFIG_FILE}" 2>/dev/null | awk '{print $1}')
if [[ "${_litellm_no_proxy_before}" != "${_litellm_no_proxy_after}" ]]; then
    info "LiteLLM NO_PROXY changed — recreating container to register updated model endpoints..."
    eval "${DOCKER_COMPOSE_CMD} -f ${COMPOSE_FILE} --env-file ${ENV_FILE} up -d --force-recreate litellm" || warn "LiteLLM recreate failed (non-fatal)"
elif [[ -n "${_litellm_config_hash_after}" && "${_litellm_config_hash_before}" != "${_litellm_config_hash_after}" ]]; then
    info "LiteLLM config changed — restarting to register updated models..."
    eval "${DOCKER_COMPOSE_CMD} -f ${COMPOSE_FILE} --env-file ${ENV_FILE} restart litellm" || warn "LiteLLM restart failed (non-fatal)"
fi

# ---------------------------------------------------------------------------
# Post-start: create MinIO langfuse bucket (observability profile)
# ---------------------------------------------------------------------------
if [[ " ${PROFILES[*]} " =~ " observability " ]]; then
    info "Waiting for MinIO to become healthy..."
    for i in $(seq 1 30); do
        if ${DOCKER_CMD} exec agentic-minio mc ready local &>/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    if ${DOCKER_CMD} exec agentic-minio mc alias set local http://localhost:9000 \
        "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" &>/dev/null 2>&1; then
        ${DOCKER_CMD} exec agentic-minio mc mb --ignore-existing local/langfuse &>/dev/null 2>&1 && \
            ok "MinIO: langfuse bucket ready" || warn "MinIO: bucket creation failed (non-fatal)"
    else
        warn "MinIO: could not configure mc alias (non-fatal)"
    fi
fi

# ---------------------------------------------------------------------------
# Post-start: Flowise first-boot protection (flowise profile)
# ---------------------------------------------------------------------------
# Flowise 3.1.2 creates its first organization owner through an UNAUTHENTICATED
# POST /api/v1/account/register.  Only the first caller to reach that endpoint can ever
# become the owner — every later attempt is refused with "You can only have one
# organization" — so that account needs to be claimed by the administrator.  Two
# measures, applied here:
#   1. Flowise is published on loopback only (FLOWISE_BIND_ADDR), so an instance with
#      an empty database is not reachable from an untrusted network.
#   2. Once an owner exists, /api/v1/account/register is dropped from Flowise's public
#      whitelist via DENYLIST_URLS so the endpoint cannot be reached at all.
# Step 2 costs no functionality in open-source mode: that endpoint only ever succeeds
# for the first organization and returns 400 for every later caller, authenticated or
# not.  It MUST be reverted if FLOWISE_EE_LICENSE_KEY is ever set, because Enterprise
# mode reuses the same endpoint for invited users completing their signup.
FLOWISE_SETUP_PENDING=0
if [[ " ${PROFILES[*]} " =~ " flowise " ]]; then
    info "Flowise: checking first-boot state..."
    for i in $(seq 1 36); do
        if ${DOCKER_CMD} exec agentic-flowise curl -sf http://localhost:3000/api/v1/ping &>/dev/null 2>&1; then
            break
        fi
        sleep 5
    done

    # Does an owner already exist?  No output (table absent on a fresh database) => no.
    _flowise_orgs=$(${DOCKER_CMD} exec -e PGPASSWORD="${FLOWISE_DB_PASSWORD}" agentic-postgres \
        psql -U "${FLOWISE_DB_USER:-flowise}" -d "${FLOWISE_DB_NAME:-flowisedb}" \
        -tAc "SELECT count(*) FROM organization" 2>/dev/null | tr -d '[:space:]' || true)
    [[ "${_flowise_orgs}" =~ ^[0-9]+$ ]] || _flowise_orgs=0

    if [[ "${_flowise_orgs}" -gt 0 ]]; then
        if [[ "${FLOWISE_DENYLIST_URLS}" != "/api/v1/account/register" ]]; then
            info "Flowise: owner account found — closing the registration endpoint..."
            sed -i 's|^FLOWISE_DENYLIST_URLS=.*|FLOWISE_DENYLIST_URLS=/api/v1/account/register|' "${ENV_FILE}"
            if eval "${DOCKER_COMPOSE_CMD} -f ${COMPOSE_FILE} --env-file ${ENV_FILE} --profile flowise up -d --force-recreate flowise"; then
                ok "Flowise: registration endpoint closed"
            else
                warn "Flowise: could not recreate container to apply the lockdown (non-fatal)"
            fi
        else
            ok "Flowise: registration endpoint already closed"
        fi
    else
        FLOWISE_SETUP_PENDING=1
        info "Flowise: no owner account yet — claim it in the UI (see summary below)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Agentic AI Stack — Deployed Successfully!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
for p in "${PROFILES[@]:-}"; do
    case "${p}" in
        flowise) echo "  Flowise Admin    : http://localhost:3000  (bound to ${FLOWISE_BIND_ADDR})" ;;
    esac
done
echo "  LiteLLM UI       : http://localhost:4000"
for p in "${PROFILES[@]:-}"; do
    case "${p}" in
        observability)
            echo "  Langfuse         : http://localhost:3002"
            ;;
    esac
done
if [[ "${FLOWISE_SETUP_PENDING}" -eq 1 ]]; then
    echo ""
    echo -e "${YELLOW}── Flowise first-time setup ───────────────────────────────────${NC}"
    echo "  Flowise has no owner account yet.  The first caller to reach port 3000"
    echo "  becomes the sole organization owner, so claim it before anyone else:"
    echo ""
    echo -e "    1. Open ${CYAN}http://localhost:3000${NC} on this machine."
    echo "       Browsing from elsewhere? Tunnel rather than publishing the port:"
    echo -e "         ${CYAN}ssh -L 3000:127.0.0.1:3000 <user>@$(hostname -f 2>/dev/null || hostname)${NC}"
    echo "    2. Complete the \"Setup Account\" page (name, email, password)."
    echo ""
    echo "  The port is bound to ${FLOWISE_BIND_ADDR}, so only this host can reach it."
    echo "  Nothing further is required.  Any later run of this script will notice"
    echo "  the owner exists and close the registration endpoint for good."
    echo -e "${YELLOW}──────────────────────────────────────────────────────────────${NC}"
fi
echo ""
echo "  Logs: docker compose -f docker/docker-compose.yml logs -f [service]"
echo "  Stop+clean: bash docker/deploy.sh --down"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
