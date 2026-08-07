#!/usr/bin/env bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_redis_controller
#
# Deploys a standalone Redis Stack instance (with RediSearch) into the
# `redis` namespace using the bundled Helm chart at
# core/helm-charts/redis/.
#
# Redis requires a password and is exposed as a ClusterIP Service, so it is
# reachable only from inside the cluster. After deployment the in-cluster URL is:
#   redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379
#
# The password and full URL are stored in a Kubernetes Secret:
#   kubectl get secret redis-stack-server-credentials -n redis \
#     -o jsonpath='{.data.REDIS_URL}' | base64 -d
#
# To point the Coding Agent at this shared instance instead of its own
# bundled Redis, deploy it with:
#   --set redis.enabled=false
#   --set redisUrl="redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379"
#
# Prerequisites:
#   • Kubernetes is running  (kubectl get nodes)
#   • SCRIPT_DIR points to the core/ directory
# ---------------------------------------------------------------------------
deploy_redis_controller() {
    local chart_path="${SCRIPT_DIR}/helm-charts/redis"
    local redis_ns="redis"

    echo "${BLUE}======================================================${NC}"
    echo "${BLUE}  Deploying Standalone Redis Stack${NC}"
    echo "${BLUE}======================================================${NC}"

    if [[ ! -d "${chart_path}" ]]; then
        echo "${RED}ERROR: Redis Helm chart not found at ${chart_path}${NC}"
        exit 1
    fi

    # Ensure Helm is available
    if ! command -v helm &>/dev/null; then
        echo "${CYAN}Installing Helm...${NC}"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    echo "${CYAN}[1/4] Creating namespace '${redis_ns}'...${NC}"
    kubectl create namespace "${redis_ns}" --dry-run=client -o yaml | kubectl apply -f -

    # Read the Redis password from vault.yml (generated once by generate-vault-secrets.sh).
    echo "${CYAN}[2/4] Reading Redis credentials from vault.yml...${NC}"
    local vault_file="${SCRIPT_DIR}/inventory/metadata/vault.yml"
    local redis_pass=""
    if [[ -f "${vault_file}" ]]; then
        redis_pass="$(grep '^redis_stack_password:' "${vault_file}" \
            | sed 's/redis_stack_password:[[:space:]]*//' | tr -d '"' || true)"
    fi
    if [[ -z "${redis_pass}" ]]; then
        echo "${RED}ERROR: redis_stack_password not found in vault.yml.${NC}"
        echo "${RED}       Re-run generate-vault-secrets.sh to regenerate vault.yml.${NC}"
        exit 1
    fi

    echo "${CYAN}[3/4] Detecting cluster default StorageClass...${NC}"
    # Leave empty if none found — chart omits storageClassName entirely,
    # letting Kubernetes bind to its own cluster default (or none).
    local default_sc
    default_sc=$(kubectl get storageclass \
        -o jsonpath="{.items[?(@.metadata.annotations['storageclass.kubernetes.io/is-default-class']=='true')].metadata.name}" \
        2>/dev/null | awk '{print $1}')
    default_sc=${default_sc:-}

    echo "${CYAN}[4/4] Deploying with StorageClass: ${default_sc:-<cluster default>}${NC}"
    local retries=3
    local attempt=1
    until helm upgrade --install redis "${chart_path}" \
        --namespace "${redis_ns}" \
        --set "redis-stack-server.redis_stack_server.storage_class=${default_sc}" \
        --set-string "redis-stack-server.redis_stack_server.auth.password=${redis_pass}" \
        --wait --timeout 10m; do
        if (( attempt >= retries )); then
            echo "${RED}ERROR: Redis installation failed after ${retries} attempts.${NC}"
            exit 1
        fi
        echo "${YELLOW}WARN: Helm timed out (attempt ${attempt}/${retries}), retrying...${NC}"
        (( attempt++ ))
        sleep 10
    done

    echo ""
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  Redis Stack deployed successfully!${NC}"
    echo "${GREEN}  Namespace : ${redis_ns}${NC}"
    echo "${GREEN}  Service   : ClusterIP (in-cluster only, password required)${NC}"
    echo "${GREEN}  In-cluster URL: redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379${NC}"
    echo "${GREEN}  URL secret: redis-stack-server-credentials (key: REDIS_URL)${NC}"
    echo "${GREEN}============================================================${NC}"
}
