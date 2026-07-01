#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
# INTEL AI FOR ENTERPRISE AGENT TOOLKIT — UNIFIED DEPLOYMENT SCRIPT
#
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Usage:
#   ./deploy-agentic-stack.sh        # Deploy full base stack
#   ./deploy-agentic-stack.sh --menu # Interactive cluster management menu
#
# Target: Single Ubuntu node (this machine)
# =============================================================================

set -euo pipefail

# Repo root — where this script lives
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Core directory containing lib files, playbooks, inventory, etc.
CORE_DIR="${REPO_DIR}/core"

# ──────────────────────────────────────────────────────────────────────────────
# COLOURS
# ──────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

banner()  { echo -e "\n${BLUE}══════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"; }
success() { echo -e "${GREEN}✔  $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $1${NC}"; }
error()   { echo -e "${RED}✘  $1${NC}" >&2; exit 1; }
info()    { echo -e "${CYAN}ℹ  $1${NC}"; }

# Force Ansible to emit ANSI colours even when stdout is not a TTY (e.g. when
# the script is piped or run from a terminal that strips colour detection).
export ANSIBLE_FORCE_COLOR=1

# ── ERR trap: print the exact failing command + line number on any silent exit ─
trap 'echo -e "\n${RED}✘  Command failed at line ${LINENO}: ${BASH_COMMAND}${NC}" >&2' ERR

# ── Prevent running as root — pip installs inside the venv would create       ─
# ── root-owned files, breaking subsequent non-root re-runs.                   ─
if [[ "${EUID}" -eq 0 ]]; then
    echo -e "${RED}✘  Do not run this script as root or with sudo.${NC}" >&2
    echo -e "${RED}   Run as a regular user; sudo is invoked internally where needed.${NC}" >&2
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# PARSE FLAGS
# ──────────────────────────────────────────────────────────────────────────────
SHOW_MENU=false
PROFILE_PERSISTENT_AGENTS=false

for arg in "$@"; do
    case "${arg}" in
        --menu)                 SHOW_MENU=true ;;
        --persistent-agents)    PROFILE_PERSISTENT_AGENTS=true ;;
        --help|-h)
            echo "Usage: $0 [--menu] [--persistent-agents]"
            echo "  (no flags)           Deploy full base stack"
            echo "  --menu               Open the interactive cluster management menu"
            echo "  --persistent-agents  Deploy with persistent-agents profile"
            echo "                       (enables: Keycloak, pgvector, Agent Sandbox, OpenClaw)"
            exit 0 ;;
        *)
            echo "ERROR: Unknown argument '${arg}'" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1 ;;
    esac
done

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEM DETECTION — OS family, architecture, package manager
# ──────────────────────────────────────────────────────────────────────────────
OS_ID=""        # ubuntu | debian | rhel | centos | amzn | fedora
OS_FAMILY=""    # debian | rhel
ARCH=""         # amd64 | arm64
PKG_MGR=""      # apt-get | dnf | yum
CONTAINERD_SOCK=""

# Version pins — override via env to test newer releases
NERDCTL_VERSION="${NERDCTL_VERSION:-1.7.7}"
BUILDKIT_VERSION="${BUILDKIT_VERSION:-v0.19.0}"

detect_system() {
    local raw_arch; raw_arch="$(uname -m)"
    case "${raw_arch}" in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) warn "Unsupported arch ${raw_arch} — defaulting to amd64"; ARCH="amd64" ;;
    esac

    local os_like=""
    if [[ -f /etc/os-release ]]; then
        OS_ID="$(. /etc/os-release && echo "${ID}")"
        os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    else
        OS_ID="unknown"
    fi

    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop)
            OS_FAMILY="debian"; PKG_MGR="apt-get" ;;
        rhel|centos|rocky|almalinux|ol)
            OS_FAMILY="rhel"; PKG_MGR="dnf" ;;
        fedora)
            OS_FAMILY="rhel"; PKG_MGR="dnf" ;;
        amzn)
            OS_FAMILY="rhel"; PKG_MGR="yum" ;;
        *)
            if echo "${os_like}" | grep -qi "debian"; then
                OS_FAMILY="debian"; PKG_MGR="apt-get"
            elif echo "${os_like}" | grep -qi "rhel\|fedora\|centos"; then
                OS_FAMILY="rhel"; PKG_MGR="dnf"
            else
                warn "Unknown OS '${OS_ID}' — assuming Debian-family"
                OS_FAMILY="debian"; PKG_MGR="apt-get"
            fi ;;
    esac

    if [[ -z "${ANSIBLE_USER:-}" ]]; then
        # Prefer the ansible_user already set in hosts.yaml if it exists
        local _hosts_yaml="${CORE_DIR}/inventory/hosts.yaml"
        if [[ -f "${_hosts_yaml}" ]]; then
            ANSIBLE_USER=$(grep 'ansible_user:' "${_hosts_yaml}" | head -1 | awk '{print $2}' | tr -d '"'"'" )
            # Discard Jinja2 template expressions (e.g. {{ lookup('env','USER') }})
            [[ "${ANSIBLE_USER}" == '{{'* ]] && ANSIBLE_USER=""
        fi
        # Fall back to OS-based default if hosts.yaml has no value
        if [[ -z "${ANSIBLE_USER:-}" ]]; then
            case "${OS_ID}" in
                ubuntu)                  ANSIBLE_USER="${SUDO_USER:-${USER:-$(id -un)}}" ;;
                debian)                  ANSIBLE_USER="${SUDO_USER:-${USER:-$(id -un)}}" ;;
                amzn)                    ANSIBLE_USER="ec2-user" ;;
                centos)                  ANSIBLE_USER="centos" ;;
                rhel|rocky|almalinux|ol) ANSIBLE_USER="ec2-user" ;;
                *)                       ANSIBLE_USER="${SUDO_USER:-${USER:-$(id -un)}}" ;;
            esac
        fi
    fi

    if [[ -z "${CONTAINERD_SOCK:-}" ]]; then
        if   [[ -S /run/containerd/containerd.sock ]];     then CONTAINERD_SOCK="/run/containerd/containerd.sock"
        elif [[ -S /var/run/containerd/containerd.sock ]]; then CONTAINERD_SOCK="/var/run/containerd/containerd.sock"
        else CONTAINERD_SOCK="/run/containerd/containerd.sock"
        fi
    fi

    success "System: OS=${OS_ID} (${OS_FAMILY}) | Arch=${ARCH} | PkgMgr=${PKG_MGR} | User=${ANSIBLE_USER}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these or pass as env vars before running
# ──────────────────────────────────────────────────────────────────────────────
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-api.example.com}"
HUGGINGFACE_TOKEN="${HUGGINGFACE_TOKEN:-}"          # REQUIRED
MODELS="${MODELS:-cpu-qwen2-5-coder-14b}"
ANSIBLE_USER="${ANSIBLE_USER:-}"
CERT_DIR="${HOME}/certs"
AGENTIC_DIR="${REPO_DIR}"                           # The repo itself

# GenAI Gateway (LiteLLM) secrets — change before production use
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-litellm-master-$(openssl rand -hex 8)}"
LITELLM_SALT_KEY="${LITELLM_SALT_KEY:-salt-$(openssl rand -hex 8)}"
LITELLM_DB_PASS="${LITELLM_DB_PASS:-pgpass-$(openssl rand -hex 8)}"
# Langfuse observability — recovered from vault.yml at deploy time
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"
LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-http://genai-gateway-trace-web.genai-gateway.svc.cluster.local:3000}"


DEPLOY_LOG="${REPO_DIR}/deploy.log"

# ──────────────────────────────────────────────────────────────────────────────
# PACKAGE INSTALLER ABSTRACTION
# ──────────────────────────────────────────────────────────────────────────────
pkg_install() {
    case "${PKG_MGR}" in
        apt-get) sudo apt-get install -y -qq "$@" 2>&1 | tail -3 ;;
        dnf)     sudo dnf install -y -q  "$@" ;;
        yum)     sudo yum install -y -q  "$@" ;;
        *)       warn "Unknown PKG_MGR '${PKG_MGR}' — trying apt-get"
                 sudo apt-get install -y -qq "$@" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# MODEL DISPLAY NAME — converts model number or internal ID to HF model name
# ──────────────────────────────────────────────────────────────────────────────
_model_display_name() {
    case "${1:-}" in
        21|cpu-qwen3-coder-30b)     echo "Qwen/Qwen3-Coder-30B-A3B-Instruct" ;;
        22|cpu-qwen2-5-coder-14b)   echo "Qwen/Qwen2.5-Coder-14B-Instruct" ;;
        23|cpu-bge-base-en)         echo "BAAI/bge-base-en-v1.5" ;;
        24|cpu-bge-reranker-base)   echo "BAAI/bge-reranker-base" ;;
        25|cpu-qwen3-30b-a3b)        echo "Qwen/Qwen3-30B-A3B-Instruct-2507" ;;
        26|cpu-gemma4-26b-a4b)      echo "google/gemma-4-26B-A4B-it" ;;
        *) echo "${1:-unknown}" ;;
    esac
}

# Resolve a comma-separated list of model IDs/slugs to their display names.
_model_display_list() {
    local _input="${1:-}" _out="" _id _name
    IFS=',' read -ra _ids <<< "${_input}"
    for _id in "${_ids[@]}"; do
        _id="${_id// /}"   # trim whitespace
        _name="$(_model_display_name "${_id}")"
        _out="${_out:+${_out}, }${_name}"
    done
    echo "${_out}"
}

# ──────────────────────────────────────────────────────────────────────────────
# VALIDATE INPUTS
# ──────────────────────────────────────────────────────────────────────────────
validate_inputs() {
    banner "Validating Inputs"
    [[ -z "${HUGGINGFACE_TOKEN}" ]] && \
        error "HUGGINGFACE_TOKEN is required.\n  Export it: export HUGGINGFACE_TOKEN=hf_xxxx\n  Then re-run this script."
    [[ "$(id -u)" -eq 0 ]] && \
        warn "Running as root is not recommended — prefer a sudo-enabled non-root user."
    success "Inputs OK  (model: $(_model_display_list "${MODELS}"), domain: ${CLUSTER_DOMAIN})"
}

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEM PREREQUISITES
# ──────────────────────────────────────────────────────────────────────────────
install_prereqs() {
    banner "Installing System Prerequisites"
    case "${PKG_MGR}" in
        apt-get)
            sudo apt-get update -qq
            pkg_install \
                git curl wget openssl sshpass python3 python3-pip python3-venv \
                software-properties-common apt-transport-https ca-certificates \
                jq unzip
            ;;
        dnf)
            sudo dnf makecache -q 2>/dev/null || true
            pkg_install epel-release 2>/dev/null || true
            pkg_install \
                git curl wget openssl sshpass python3 python3-pip \
                ca-certificates jq unzip
            ;;
        yum)
            sudo yum makecache -q 2>/dev/null || true
            pkg_install epel-release 2>/dev/null || true
            pkg_install \
                git curl wget openssl python3 python3-pip \
                ca-certificates jq unzip
            ;;
    esac
    success "System packages installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH KEY SETUP (passwordless localhost + remote worker nodes)
# ──────────────────────────────────────────────────────────────────────────────
setup_ssh() {
    banner "Configuring SSH (passwordless localhost)"
    if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
        ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" -q
        info "Generated new ed25519 key"
    fi
    local pubkey
    pubkey="$(cat "${HOME}/.ssh/id_ed25519.pub")"
    grep -qF "${pubkey}" "${HOME}/.ssh/authorized_keys" 2>/dev/null || \
        echo "${pubkey}" >> "${HOME}/.ssh/authorized_keys"
    chmod 600 "${HOME}/.ssh/authorized_keys"
    ssh-keyscan -H localhost >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
    ssh-keyscan -H 127.0.0.1 >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
    success "SSH configured for localhost"

    # For multi-node deployments: push the public key to every remote host in
    # hosts.yaml that is not localhost/127.0.0.1.
    local _hosts_yaml="${CORE_DIR}/inventory/hosts.yaml"
    if [[ -f "${_hosts_yaml}" ]]; then
        local _host_count
        _host_count=$(grep -c 'ansible_host:' "${_hosts_yaml}" 2>/dev/null || echo 0)
        if [[ "${_host_count}" -gt 1 ]]; then
            banner "Configuring SSH for remote worker nodes"
            local _local_ip
            _local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            # Extract each ansible_host IP and ansible_user from the YAML
            while IFS= read -r _line; do
                # Match lines like:  ansible_host: 10.x.x.x
                if [[ "${_line}" =~ ansible_host:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                    _remote_ip="${BASH_REMATCH[1]}"
                fi
                # Match lines like:  ansible_user: ubuntu
                if [[ "${_line}" =~ ansible_user:[[:space:]]*([^[:space:]]+) ]]; then
                    _remote_user="${BASH_REMATCH[1]}"
                fi
                # Match lines like:  ansible_ssh_private_key_file: /path/to/key
                if [[ "${_line}" =~ ansible_ssh_private_key_file:[[:space:]]*([^[:space:]]+) ]]; then
                    _remote_key="${BASH_REMATCH[1]}"
                fi
                # When we have a complete host entry (IP + user), push the key
                if [[ -n "${_remote_ip:-}" && -n "${_remote_user:-}" ]]; then
                    # Skip this node's own IP
                    if [[ "${_remote_ip}" != "${_local_ip}" && \
                          "${_remote_ip}" != "127.0.0.1" && \
                          "${_remote_ip}" != "localhost" ]]; then
                        local _key_opt=""
                        [[ -n "${_remote_key:-}" && -f "${_remote_key}" ]] && _key_opt="-i ${_remote_key}"
                        info "Pushing SSH key to ${_remote_user}@${_remote_ip}…"
                        if ssh-copy-id -i "${HOME}/.ssh/id_ed25519.pub" \
                                ${_key_opt} \
                                -o StrictHostKeyChecking=no \
                                -o ConnectTimeout=15 \
                                "${_remote_user}@${_remote_ip}" 2>/dev/null; then
                            # Add to known_hosts so ansible doesn't prompt
                            ssh-keyscan -H "${_remote_ip}" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
                            success "SSH key authorized on ${_remote_ip}"
                        else
                            warn "Could not push SSH key to ${_remote_ip} — verify the node is reachable and the key ${_remote_key:-~/.ssh/id_ed25519} is accepted there."
                        fi
                    fi
                    _remote_ip=""
                    _remote_user=""
                    _remote_key=""
                fi
            done < "${_hosts_yaml}"
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SELF-SIGNED TLS CERTIFICATE
# ──────────────────────────────────────────────────────────────────────────────
generate_certs() {
    banner "Generating Self-Signed TLS Certificate"
    mkdir -p "${CERT_DIR}"
    if [[ -f "${CERT_DIR}/cert.pem" && -f "${CERT_DIR}/key.pem" ]]; then
        warn "Certificates already exist at ${CERT_DIR} — reusing"
        return
    fi
    openssl req -x509 -newkey rsa:4096 -keyout "${CERT_DIR}/key.pem" \
        -out "${CERT_DIR}/cert.pem" -days 365 -nodes \
        -subj "/CN=${CLUSTER_DOMAIN}" \
        -addext "subjectAltName=DNS:${CLUSTER_DOMAIN},DNS:trace-${CLUSTER_DOMAIN},DNS:*.${CLUSTER_DOMAIN}" \
        2>/dev/null
    success "Certificate generated → ${CERT_DIR}/cert.pem"

    info "Adding ${CLUSTER_DOMAIN} and use-case subdomains → 127.0.0.1 to /etc/hosts (requires sudo)"
    if ! grep -q "${CLUSTER_DOMAIN}" /etc/hosts; then
        echo "127.0.0.1 ${CLUSTER_DOMAIN} trace-${CLUSTER_DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# PREPARE REPO — remove kubespray only when the pinned version has changed
# ──────────────────────────────────────────────────────────────────────────────
prepare_repo() {
    banner "Preparing Repository"

    # Read the pinned version from metadata (e.g. v2.27.0)
    local _pinned_version=""
    local _metadata="${CORE_DIR}/inventory/metadata/agentic-metadata.cfg"
    if [[ -f "${_metadata}" ]]; then
        _pinned_version="$(grep -E '^kubespray_version=' "${_metadata}" | cut -d= -f2- | tr -d '"'"'")"
    fi

    if [[ -d "${CORE_DIR}/kubespray" ]]; then
        # Check what tag/commit the existing checkout is at
        local _current_tag=""
        _current_tag="$(git -C "${CORE_DIR}/kubespray" describe --tags --exact-match HEAD 2>/dev/null || true)"

        if [[ -n "${_pinned_version}" && "${_current_tag}" == "${_pinned_version}" ]]; then
            success "kubespray already at ${_pinned_version} — reusing existing clone"
        else
            info "kubespray version mismatch (have: '${_current_tag}', need: '${_pinned_version}') — re-cloning…"
            rm -rf "${CORE_DIR}/kubespray"
        fi
    fi

    success "Repository prepared"
}

# ──────────────────────────────────────────────────────────────────────────────
# WRITE hosts.yaml (single-node — this machine)
# Skip if a multi-node hosts.yaml already exists (i.e. contains worker nodes)
# ──────────────────────────────────────────────────────────────────────────────
write_hosts_yaml() {
    local _hosts_yaml="${CORE_DIR}/inventory/hosts.yaml"
    if [[ -f "${_hosts_yaml}" ]]; then
        # Count distinct hosts — more than one means a multi-node inventory
        local _host_count
        _host_count=$(grep -c 'ansible_host:' "${_hosts_yaml}" 2>/dev/null || echo 0)
        if [[ "${_host_count}" -gt 1 ]]; then
            info "Multi-node hosts.yaml detected (${_host_count} hosts) — skipping overwrite."
            return 0
        fi
    fi
    banner "Writing Inventory (hosts.yaml)"
    mkdir -p "${CORE_DIR}/inventory"
    cat > "${CORE_DIR}/inventory/hosts.yaml" <<EOF
all:
  hosts:
    master1:
      ansible_connection: local
      ansible_user: "{{ lookup('env', 'USER') }}"
      ansible_become: true
  children:
    kube_control_plane:
      hosts:
        master1:
    kube_node:
      hosts:
        master1:
    etcd:
      hosts:
        master1:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
EOF
    success "hosts.yaml written"
}

# ──────────────────────────────────────────────────────────────────────────────
# WRITE agentic-config.cfg
# Enables: K8s · Ingress · GenAI Gateway · Observability · Qwen3-Coder-30B
# Keycloak and APISIX are explicitly excluded from this stack.
#
# IMPORTANT: If the file already exists, only missing keys are added.
#            Existing values are NEVER overwritten — re-runs are safe.
# ──────────────────────────────────────────────────────────────────────────────
write_config() {
    banner "Writing Agentic AI Config (agentic-config.cfg)"
    mkdir -p "${CORE_DIR}/inventory"
    local _cfg="${CORE_DIR}/inventory/agentic-config.cfg"

    # Helper: append key=value only when the key is not already in the file
    _cfg_set_default() {
        local _key="$1" _val="$2"
        if ! grep -qE "^${_key}=" "${_cfg}" 2>/dev/null; then
            echo "${_key}=${_val}" >> "${_cfg}"
        fi
    }

    # Compute proxy values (env vars take priority over nothing)
    local _http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
    local _https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
    local _no_proxy="${no_proxy:-${NO_PROXY:-}}"
    local _k8s_no_proxy=".svc,.svc.cluster.local,169.254.0.0/16,${CLUSTER_DOMAIN}"
    if [[ -n "${_no_proxy}" ]]; then
        [[ "${_no_proxy}" != *".svc.cluster.local"* ]] && _no_proxy="${_no_proxy},${_k8s_no_proxy}"
    else
        _no_proxy="${_k8s_no_proxy}"
    fi


    if [[ ! -f "${_cfg}" ]]; then
        # ── Fresh file: write all defaults ──────────────────────────────────
        cat > "${_cfg}" <<EOF
cluster_url=${CLUSTER_DOMAIN}
cert_file=${CERT_DIR}/cert.pem
key_file=${CERT_DIR}/key.pem
hugging_face_token=${HUGGINGFACE_TOKEN}
models=cpu-qwen2-5-coder-14b
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_agenticai_plugin=off
deploy_redis=on
deploy_kuberay=off
deploy_agent_sandbox=off
deploy_openclaw=off
http_proxy=${_http_proxy}
https_proxy=${_https_proxy}
no_proxy=${_no_proxy}
EOF
        success "agentic-config.cfg created with defaults"
    else
        # ── File already exists: only fill in any keys that are missing ─────
        warn "agentic-config.cfg already exists — preserving all existing values"
        info "Adding any missing config keys with defaults…"

        _cfg_set_default "cluster_url"              "${CLUSTER_DOMAIN}"
        _cfg_set_default "cert_file"                "${CERT_DIR}/cert.pem"
        _cfg_set_default "key_file"                 "${CERT_DIR}/key.pem"
        _cfg_set_default "hugging_face_token"        "${HUGGINGFACE_TOKEN}"
        _cfg_set_default "models"                   "cpu-qwen2-5-coder-14b"
        _cfg_set_default "deploy_kubernetes_fresh"  "on"
        _cfg_set_default "deploy_ingress_controller" "on"
        _cfg_set_default "deploy_genai_gateway"     "on"
        _cfg_set_default "deploy_observability"     "on"
        _cfg_set_default "deploy_llm_models"        "on"
        _cfg_set_default "deploy_agenticai_plugin"  "off"
        _cfg_set_default "deploy_redis"             "on"
        _cfg_set_default "deploy_kuberay"            "off"
        _cfg_set_default "deploy_agent_sandbox"     "off"
        _cfg_set_default "deploy_openclaw"          "off"
        _cfg_set_default "deploy_agent_operator"    "off"
        _cfg_set_default "http_proxy"               "${_http_proxy}"
        _cfg_set_default "https_proxy"              "${_https_proxy}"
        # no_proxy gets k8s suffixes injected only when the key is absent
        if ! grep -qE "^no_proxy=" "${_cfg}" 2>/dev/null; then
            echo "no_proxy=${_no_proxy}" >> "${_cfg}"
        fi

        success "agentic-config.cfg verified — all existing values preserved"
    fi

    # ── kuberay-config.yaml — only create if absent; never overwrite ──────────
    local _kuberay_cfg="${CORE_DIR}/inventory/kuberay-config.yaml"
    if [[ ! -f "${_kuberay_cfg}" ]]; then
        cat > "${_kuberay_cfg}" <<'KUBERAY_EOF'
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# KubeRay Configuration
#
# This file controls all tuning parameters for the Ray distributed computing
# cluster. Enable/disable the deployment with deploy_kuberay in agentic-config.cfg.
#
# In-cluster access points (after deployment):
#   Ray Client API  : ray://ray-cluster-head-svc.<namespace>.svc.cluster.local:10001
#   Ray Dashboard   : http://ray-cluster-head-svc.<namespace>.svc.cluster.local:8265
# ---------------------------------------------------------------------------

namespace: ray-system

cluster:
  name: ray-cluster
  rayImage: rayproject/ray:2.40.0-py312

  head:
    cpuRequest: "500m"
    cpuLimit: "1"
    memoryRequest: "2Gi"
    memoryLimit: "4Gi"

  worker:
    groupName: default-worker
    replicas: 2
    minReplicas: 1
    maxReplicas: 4
    cpuRequest: "500m"
    cpuLimit: "2"
    memoryRequest: "2Gi"
    memoryLimit: "4Gi"
KUBERAY_EOF
        success "kuberay-config.yaml created with defaults"
    else
        info "kuberay-config.yaml already exists — preserving existing values"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SOURCE CORE LIB FILES
# Sets SCRIPT_DIR / HOMEDIR / KUBESPRAYDIR to the core/ directory so all
# lib functions resolve paths correctly (ansible playbooks, inventory, etc.)
# ──────────────────────────────────────────────────────────────────────────────
_source_core_libs() {
    # The lib files use variables set dynamically by read_config_file / parse_arguments
    # and were written without nounset. Disable -u while sourcing and running lib code
    # to avoid "unbound variable" errors for conditionally-set config vars.
    set +u

    # Override SCRIPT_DIR / HOMEDIR before AND after sourcing config-vars.sh
    # because config-vars.sh resets HOMEDIR to $(pwd) and KUBESPRAYDIR to $0-based path.
    SCRIPT_DIR="${CORE_DIR}"
    HOMEDIR="${CORE_DIR}"
    KUBESPRAYDIR="${CORE_DIR}/kubespray"
    VENVDIR="${CORE_DIR}/kubespray225-venv"
    INVENTORY_PATH="${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"

    source "${CORE_DIR}/lib/system/config-vars.sh"

    # Re-apply after sourcing (config-vars.sh overwrites these with $(pwd)/$0 values)
    SCRIPT_DIR="${CORE_DIR}"
    HOMEDIR="${CORE_DIR}"
    KUBESPRAYDIR="${CORE_DIR}/kubespray"
    VENVDIR="${CORE_DIR}/kubespray225-venv"
    INVENTORY_PATH="${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"

    source "${CORE_DIR}/lib/system/execute-and-check.sh"
    source "${CORE_DIR}/lib/system/setup-env.sh"
    source "${CORE_DIR}/lib/system/precheck/read-config-file.sh"
    source "${CORE_DIR}/lib/system/precheck/prereq-check.sh"
    source "${CORE_DIR}/lib/system/precheck/readiness-check.sh"

    source "${CORE_DIR}/lib/cluster/config/cluster-config-init.sh"
    source "${CORE_DIR}/lib/cluster/config/setup-user-cluster-config.sh"
    source "${CORE_DIR}/lib/cluster/config/label-nodes.sh"
    source "${CORE_DIR}/lib/cluster/state/cluster-state-check.sh"
    source "${CORE_DIR}/lib/cluster/deployment/fresh-install.sh"
    source "${CORE_DIR}/lib/cluster/deployment/cluster-update.sh"
    source "${CORE_DIR}/lib/cluster/deployment/cluster-purge.sh"
    source "${CORE_DIR}/lib/cluster/nodes/add-node.sh"
    source "${CORE_DIR}/lib/cluster/nodes/remove-node.sh"

    source "${CORE_DIR}/lib/components/kubernetes-setup.sh"
    source "${CORE_DIR}/lib/components/ingress-controller.sh"
    source "${CORE_DIR}/lib/components/genai-gateway-controller.sh"
    source "${CORE_DIR}/lib/components/observability-controller.sh"
    source "${CORE_DIR}/lib/components/storage/install-ceph-cluster.sh"
    source "${CORE_DIR}/lib/components/storage/uninstall-ceph-cluster.sh"
    source "${CORE_DIR}/lib/components/service-mesh/install-istio.sh"
    source "${CORE_DIR}/lib/components/redis-controller.sh"
    source "${CORE_DIR}/lib/components/kuberay-controller.sh"
    source "${CORE_DIR}/lib/components/pgvector-controller.sh"
    source "${CORE_DIR}/lib/components/agent-sandbox-controller.sh"
    source "${CORE_DIR}/lib/components/openclaw-controller.sh"
    source "${CORE_DIR}/lib/components/agent-operator-controller.sh"

    source "${CORE_DIR}/lib/models/model-selection.sh"
    source "${CORE_DIR}/lib/models/list-model.sh"
    source "${CORE_DIR}/lib/models/install-model.sh"
    source "${CORE_DIR}/lib/models/uninstall-model.sh"
    source "${CORE_DIR}/lib/models/install-model-hf.sh"
    source "${CORE_DIR}/lib/models/uninstall-model-hf.sh"

    source "${CORE_DIR}/lib/xeon/ballon-policy.sh"

    source "${CORE_DIR}/lib/user-menu/parse-user-prompts.sh"
    source "${CORE_DIR}/lib/user-menu/user-menu.sh"

    source "${CORE_DIR}/lib/brownfield/brownfield_deployment.sh"
}

# ──────────────────────────────────────────────────────────────────────────────
# INTERACTIVE MANAGEMENT MENU (formerly core/agentic-stack.sh entry-point)
# ──────────────────────────────────────────────────────────────────────────────
_show_main_menu() {
    set +u
    _source_core_libs
    # Ensure lib functions see core/ as their working base
    SCRIPT_DIR="${CORE_DIR}"
    HOMEDIR="${CORE_DIR}"
    KUBESPRAYDIR="${CORE_DIR}/kubespray"
    VENVDIR="${CORE_DIR}/kubespray225-venv"
    INVENTORY_PATH="${KUBESPRAYDIR}/inventory/mycluster/hosts.yaml"

    # Strip --menu from args before passing to the core lib's parse_arguments,
    # which does not know about this wrapper-level flag.
    local _filtered_args=()
    for _a in "$@"; do [[ "${_a}" != "--menu" ]] && _filtered_args+=("${_a}"); done

    parse_arguments "${_filtered_args[@]+"${_filtered_args[@]}"}"

    echo -e "${BLUE}----------------------------------------------------------${NC}"
    echo -e "${BLUE}|  Intel AI for Enterprise Agent Toolkit                                |${NC}"
    echo -e "${BLUE}|---------------------------------------------------------|${NC}"
    echo -e "| ${CYAN}1)${NC} Provision Base stack Infrastructure                  |"
    echo -e "| ${CYAN}2)${NC} Decommission Existing Cluster                        |"
    echo -e "| ${CYAN}3)${NC} Update Deployed AI Stack                             |"
    echo -e "${BLUE}|---------------------------------------------------------|${NC}"
    echo -e "Please choose an option (${CYAN}1${NC}, ${CYAN}2${NC} or ${CYAN}3${NC}):"
    read -rp "$(echo -e "${CYAN}> ${NC}")" user_choice
    case "${user_choice}" in
        1) fresh_installation "${_filtered_args[@]+"${_filtered_args[@]}"}" ;;
        2) reset_cluster "${_filtered_args[@]+"${_filtered_args[@]}"}" ;;
        3) update_cluster "${_filtered_args[@]+"${_filtered_args[@]}"}" ;;
        *)
            echo "Invalid option. Please enter 1, 2 or 3."
            _show_main_menu "${_filtered_args[@]+"${_filtered_args[@]}"}"            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# RESUME DETECTION
# Before running fresh_installation, check what is already deployed in the
# cluster and turn the corresponding config flags to 'off' so they are skipped.
# This makes re-runs safe and resumable after a partial failure.
# ──────────────────────────────────────────────────────────────────────────────
_auto_skip_deployed_components() {
    local _cfg="${CORE_DIR}/inventory/agentic-config.cfg"
    [[ ! -f "${_cfg}" ]] && return

    # Only auto-skip when kubectl is available and the cluster is reachable
    if ! command -v kubectl &>/dev/null || ! kubectl get nodes &>/dev/null 2>&1; then
        info "Cluster not reachable yet — all components will be installed fresh"
        return
    fi

    banner "Checking Already-Deployed Components (Resume Mode)"

    # Helper: set a key to 'off' in the config file
    _cfg_turn_off() {
        local _key="$1"
        sed -i "s|^${_key}=.*|${_key}=off|" "${_cfg}" 2>/dev/null || true
    }

    # Kubernetes — skip only if every node in hosts.yaml is already in the cluster.
    # If hosts.yaml has more nodes than the cluster (e.g. a new worker was added),
    # keep deploy_kubernetes_fresh=on so kubespray runs cluster.yml to join them.
    if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
        local _hosts_yaml="${CORE_DIR}/inventory/hosts.yaml"
        local _inventory_host_count=0
        local _cluster_node_count
        _cluster_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        if [[ -f "${_hosts_yaml}" ]]; then
            _inventory_host_count=$(grep -c 'ansible_host:' "${_hosts_yaml}" 2>/dev/null || echo 0)
        fi
        if [[ "${_cluster_node_count}" -ge "${_inventory_host_count}" ]]; then
            _cfg_turn_off "deploy_kubernetes_fresh"
            success "Kubernetes: already running (${_cluster_node_count}/${_inventory_host_count} nodes) — skipping"
        else
            warn "Kubernetes: cluster has ${_cluster_node_count} node(s) but hosts.yaml defines ${_inventory_host_count} — running kubespray to join missing nodes"
        fi
    fi

    # Ingress NGINX controller
    if kubectl get namespace ingress-nginx &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_ingress_controller"
        success "Ingress NGINX: already deployed — skipping"
    fi

    # Keycloak / APISIX — not part of this stack; force off in case they
    # still exist in user-edited configs from a previous run.
    # Keycloak / APISIX — not part of this stack; force off in case they
    # still exist in user-edited configs from a previous run.
    _cfg_turn_off "deploy_keycloak"
    _cfg_turn_off "deploy_apisix"

    # GenAI Gateway (LiteLLM + Langfuse)
    if kubectl get namespace genai-gateway &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_genai_gateway"
        success "GenAI Gateway: already deployed — skipping"
    fi

    # Observability (Prometheus/Grafana/Langfuse trace stack)
    if kubectl get namespace observability &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_observability"
        success "Observability: already deployed — skipping"
    fi

    # LLM Models — only skip if the SPECIFIC requested model's helm release is already deployed.
    # If a different model is running, allow deployment of the new one.
    local _model_helm_release=""
    case "${MODELS}" in
        21|cpu-qwen3-coder-30b)   _model_helm_release="vllm-qwen3-coder-30b-cpu" ;;
        22|cpu-qwen2-5-coder-14b) _model_helm_release="vllm-qwen-2-5-coder-14b-cpu" ;;
        23|cpu-bge-base-en)               _model_helm_release="vllm-tei-cpu" ;;
        24|cpu-bge-reranker-base)            _model_helm_release="vllm-rerank-cpu" ;;
        25|cpu-qwen3-30b-a3b)      _model_helm_release="vllm-qwen3-30b-a3b-cpu" ;;
        26|cpu-gemma4-26b-a4b)    _model_helm_release="vllm-gemma4-26b-a4b-cpu" ;;
    esac
    if [[ -n "${_model_helm_release}" ]] && \
       helm list -n default --short 2>/dev/null | grep -q "^${_model_helm_release}$"; then
        _cfg_turn_off "deploy_llm_models"
        success "LLM Models: ${_model_helm_release} already deployed — skipping"
    else
        info "LLM Models: ${_model_helm_release:-unknown} not yet deployed — will install"
    fi

    # Redis
    if kubectl get namespace redis &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_redis"
        success "Redis: already deployed — skipping"
    fi

    # Agent Sandbox (CRD controller + sandbox-router)
    if kubectl get namespace agent-sandbox &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_agent_sandbox"
        success "Agent Sandbox: already deployed — skipping"
    fi

    # OpenClaw (operator + instance)
    if kubectl get namespace openclaw-operator-system &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_openclaw"
        success "OpenClaw: already deployed — skipping"
    fi

    # Agent Operator
    if kubectl get namespace agent-operator-system &>/dev/null 2>&1; then
        _cfg_turn_off "deploy_agent_operator"
        success "Agent Operator: already deployed — skipping"
    fi

    info "Resume check complete — only pending components will be installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# RUN THE MAIN DEPLOYMENT (one-click base stack)
# Sources the core lib files and calls fresh_installation directly.
# "yes" is fed automatically to the confirmation prompt.
# ──────────────────────────────────────────────────────────────────────────────
run_deployment() {
    banner "Running Intel AI for Enterprise Agent Toolkit Deployment"
    info "This will take 20-40 minutes for a fresh install…"
    info "Log: ${DEPLOY_LOG}"

    set +u
    _source_core_libs

    # Check what's already in the cluster and skip those components
    _auto_skip_deployed_components

    # Pass deployment parameters through the lib's argument parser
    parse_arguments \
        --cluster-url             "${CLUSTER_DOMAIN}" \
        --cert-file               "${CERT_DIR}/cert.pem" \
        --key-file                "${CERT_DIR}/key.pem" \
        --hugging-face-token      "${HUGGINGFACE_TOKEN}" \
        --models                  "${MODELS}" \
        --compute_platform        "cpu"

    # never blocks waiting for interactive input on these.
    deploy_keycloak="no"
    deploy_apisix="no"

    # ── Profile: --persistent-agents ─────────────────────────────────────────
    # Enables the components required for persistent agents as first-class objects.
    if [[ "${PROFILE_PERSISTENT_AGENTS}" == "true" ]]; then
        info "Profile: --persistent-agents — enabling required components"
        deploy_keycloak="yes"
        deploy_pgvector="yes"
        deploy_agent_sandbox="yes"
        deploy_openclaw="yes"
        deploy_agent_operator="yes"
    fi

    # ansible-playbook uses relative paths; lib functions must run with CWD=core/
    pushd "${CORE_DIR}" > /dev/null

    # Feed "yes" automatically to the "Do you wish to continue?" prompt inside
    # fresh_installation so the one-click flow requires no manual interaction.
    fresh_installation < <(echo "yes") 2>&1 | tee "${DEPLOY_LOG}"

    popd > /dev/null
    success "Base stack deployment complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# PRINT SUMMARY
# ──────────────────────────────────────────────────────────────────────────────
print_summary() {
    # Resolve live ingress external address (IP or hostname) if cluster is reachable
    local _ingress_addr="<pending — check: kubectl get svc -n ingress-nginx>"
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
        local _ext_ip _ext_host
        _ext_ip="$(kubectl get svc -n ingress-nginx \
            -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        _ext_host="$(kubectl get svc -n ingress-nginx \
            -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
        if [[ -n "${_ext_ip}" ]]; then
            _ingress_addr="${_ext_ip} (ports 80/443)"
        elif [[ -n "${_ext_host}" ]]; then
            _ingress_addr="${_ext_host} (ports 80/443)"
        else
            # HostPort mode — node IP serves traffic directly
            local _node_ip
            _node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
            [[ -n "${_node_ip}" ]] && _ingress_addr="${_node_ip} (HostPort 80/443)"
        fi
    fi

    # Detect optional components that may or may not be deployed
    local _sandbox_status="not deployed"
    local _pgvector_status="not deployed"
    local _kuberay_status="not deployed"
    local _kuberay_ns="ray-system"
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
        kubectl get namespace agent-sandbox  &>/dev/null 2>&1 && _sandbox_status="deployed"
        kubectl get namespace pgvector       &>/dev/null 2>&1 && _pgvector_status="deployed"
        # Detect kuberay namespace from kuberay-config.yaml if present
        local _krc="${CORE_DIR}/inventory/kuberay-config.yaml"
        if [[ -f "${_krc}" ]]; then
            _kuberay_ns="$(python3 -c "
import yaml,sys
try:
    print(yaml.safe_load(open('${_krc}')).get('namespace','ray-system'))
except Exception:
    print('ray-system')
" 2>/dev/null || echo 'ray-system')"
        fi
        kubectl get namespace "${_kuberay_ns}" &>/dev/null 2>&1 && _kuberay_status="deployed"
    fi

    # ── Print the full endpoint reference ────────────────────────────────────
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  DEPLOYMENT COMPLETE — ENDPOINT REFERENCE${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════${NC}"


    # ── GENAI GATEWAY ───────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── GENAI GATEWAY / LiteLLM ────────────────────────────────────────────${NC}"
    echo -e "  Dashboard UI    : ${GREEN}https://${CLUSTER_DOMAIN}/ui${NC}"
    echo -e "  In-cluster      : http://genai-gateway-service.genai-gateway.svc.cluster.local:4000"

    # ── MODELS ────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── MODELS  ────────────────────────────────${NC}"
    echo -e "  External API    : ${GREEN}https://${CLUSTER_DOMAIN}/v1${NC}  (routed through LiteLLM)"
    local _m _m_display _m_label _m_release _m_test_label _m_test_body
    IFS=',' read -ra _model_arr <<< "${MODELS}"
    for _m in "${_model_arr[@]}"; do
        _m="${_m// /}"
        _m_display="$(_model_display_name "${_m}")"
        case "${_m}" in
            21|cpu-qwen3-coder-30b)
                _m_label="Qwen3-Coder-30B"
                _m_release="vllm-qwen3-coder-30b-cpu"
                _m_test_label="Qwen3-Coder-30B via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/chat/completions \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\n      \"model\": \"openai/${_m_display}\",\n      \"messages\": [{\"role\":\"user\",\"content\":\"Write a Python function to reverse a string\"}],\n      \"max_tokens\": 200\n    }'"
                ;;
            22|cpu-qwen2-5-coder-14b)
                _m_label="${_m_display}"
                _m_release="vllm-qwen-2-5-coder-14b-cpu"
                _m_test_label="${_m_display} via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/chat/completions \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\n      \"model\": \"openai/${_m_display}\",\n      \"messages\": [{\"role\":\"user\",\"content\":\"Write a Python function to reverse a string\"}],\n      \"max_tokens\": 200\n    }'"
                ;;
            23|cpu-bge-base-en)
                _m_label="BGE Embedding"
                _m_release="vllm-tei-cpu"
                _m_test_label="BGE Embedding via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/embeddings \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\"model\": \"huggingface/BAAI/bge-base-en-v1.5\", \"input\": \"Hello world\"}'"
                ;;
            24|cpu-bge-reranker-base)
                _m_label="BGE Reranker"
                _m_release="vllm-rerank-cpu"
                _m_test_label="BGE Reranker via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/rerank \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\"model\": \"huggingface/BAAI/bge-reranker-base\", \"query\": \"search query\", \"documents\": [\"doc 1\", \"doc 2\"]}'"
                ;;
            25|cpu-qwen3-30b-a3b)
                _m_label="Qwen3-30B-A3B-Instruct-2507"
                _m_release="vllm-qwen3-30b-a3b-cpu"
                _m_test_label="Qwen3-30B-A3B-Instruct-2507 via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/chat/completions \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\n      \"model\": \"hosted_vllm/Qwen/Qwen3-30B-A3B-Instruct-2507\",\n      \"messages\": [{\"role\":\"user\",\"content\":\"Write a Python function to reverse a string\"}],\n      \"max_tokens\": 200\n    }'"
                ;;
            26|cpu-gemma4-26b-a4b)
                _m_label="gemma-4-26B-A4B-it"
                _m_release="vllm-gemma4-26b-a4b-cpu"
                _m_test_label="Gemma-4-26B via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/chat/completions \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\n      \"model\": \"openai/google/gemma-4-26B-A4B-it\",\n      \"messages\": [{\"role\":\"user\",\"content\":\"Write a Python function to reverse a string\"}],\n      \"max_tokens\": 200\n    }'"
                ;;
            *)
                _m_label="${_m_display}"
                _m_release="vllm-${_m}-cpu"
                _m_test_label="${_m_display} via LiteLLM"
                _m_test_body="  curl -k https://${CLUSTER_DOMAIN}/v1/chat/completions \\\n    -H \"Content-Type: application/json\" \\\n    -H \"Authorization: Bearer ${LITELLM_MASTER_KEY}\" \\\n    -d '{\n      \"model\": \"openai/${_m_display}\",\n      \"messages\": [{\"role\":\"user\",\"content\":\"Write a Python function to reverse a string\"}],\n      \"max_tokens\": 200\n    }'"
                ;;
        esac
        echo -e "  Model           : ${GREEN}${_m_label}${NC}  (${_m_display})"
        echo -e "  In-cluster vLLM : http://${_m_release}-service.default/v1"
        echo -e "  Test (${_m_test_label}):"
        echo -e "${_m_test_body}"
        echo ""
    done

    # ── MEMORY (Redis) ────────────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── MEMORY (Redis Stack) ───────────────────────────────────────────────${NC}"
    echo -e "  In-cluster      : redis://redis-stack-server.redis.svc.cluster.local:6379"

    # ── AGENT SANDBOX ─────────────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── AGENT SANDBOX (${_sandbox_status}) ─────────────────────────────────────────${NC}"
    if [[ "${_sandbox_status}" == "deployed" ]]; then
        echo -e "  Router (in-cluster) : http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080"
    else
        echo -e "  Not deployed — enable with: deploy_agent_sandbox=on in agentic-config.cfg"
    fi

    # ── DATABASE ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── DATABASE  ─────────────────────────────────────────${NC}"
    if [[ "${_pgvector_status}" == "deployed" ]]; then
        echo -e "    In-cluster    : postgresql://agentuser:<pass>@pgvector.pgvector.svc.cluster.local:5432/agentdb"
    else
        echo -e "  ${CYAN}pgvector${NC}  — not deployed (enable deploy_agenticai_plugin=on)"
    fi

    # ── FLOWISE ───────────────────────────────────────────────────────────────
    local _flowise_status="not deployed"
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
        kubectl get namespace flowise &>/dev/null 2>&1 && _flowise_status="deployed"
    fi
    echo ""
    echo -e "${YELLOW}── FLOWISE ADMIN (${_flowise_status}) ─────────────────────────────────────────────${NC}"
    if [[ "${_flowise_status}" == "deployed" ]]; then
        echo -e "  Flowise UI      : ${GREEN}https://flowise-${CLUSTER_DOMAIN}${NC}"
    else
        echo -e "  Not deployed — enable with: ${CYAN}deploy_agenticai_plugin=on${NC} in agentic-config.cfg"
    fi

    # ── KUBERAY ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── RAY DISTRIBUTED COMPUTING / KubeRay (${_kuberay_status}) ─────────────────────${NC}"
    if [[ "${_kuberay_status}" == "deployed" ]]; then
        local _ray_cluster_name="ray-cluster"
        local _krc2="${CORE_DIR}/inventory/kuberay-config.yaml"
        if [[ -f "${_krc2}" ]]; then
            _ray_cluster_name="$(python3 -c "
import yaml,sys
try:
    print(yaml.safe_load(open('${_krc2}')).get('cluster',{}).get('name','ray-cluster'))
except Exception:
    print('ray-cluster')
" 2>/dev/null || echo 'ray-cluster')"
        fi
        local _head_svc="${_ray_cluster_name}-head-svc"
        echo -e "  Ray Client API  : ray://${_head_svc}.${_kuberay_ns}.svc.cluster.local:10001"
        echo -e "  Dashboard (in-cluster): http://${_head_svc}.${_kuberay_ns}.svc.cluster.local:8265"
        echo -e "  Dashboard (local):      ${CYAN}kubectl port-forward svc/${_head_svc} 8265:8265 -n ${_kuberay_ns}${NC}"
        echo -e "  Config file     : core/inventory/kuberay-config.yaml"
    else
        echo -e "  Not deployed — enable with: ${CYAN}deploy_kuberay=on${NC} in agentic-config.cfg"
        echo -e "  Tune resources  : core/inventory/kuberay-config.yaml"
    fi

    # ── OBSERVABILITY ─────────────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}── OBSERVABILITY ──────────────────────────────────────────────────────${NC}"
    echo -e "  Langfuse UI     : ${GREEN}https://trace-${CLUSTER_DOMAIN}${NC}"
    echo -e "  Grafana UI      : ${GREEN}https://${CLUSTER_DOMAIN}/observability/login${NC}"

    # ── NEXT STEPS ────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${GREEN}Full deployment log: ${DEPLOY_LOG}${NC}"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
    # detect_system MUST run first — sets OS_ID, ARCH, PKG_MGR, ANSIBLE_USER, CONTAINERD_SOCK
    detect_system

    # Load settings from existing config so re-runs and one-click runs work without
    # requiring env vars for values that are already stored in agentic-config.cfg.
    local _base_cfg="${CORE_DIR}/inventory/agentic-config.cfg"
    if [[ -f "${_base_cfg}" ]]; then
        local _existing_url _existing_hf_token
        _existing_url=$(grep -E '^cluster_url=' "${_base_cfg}" | cut -d= -f2- || true)
        _existing_hf_token=$(grep -E '^hugging_face_token=' "${_base_cfg}" | cut -d= -f2- || true)

        # cluster_url: only override when CLUSTER_DOMAIN is still the placeholder
        [[ -n "${_existing_url}" && "${CLUSTER_DOMAIN}" == "api.example.com" ]] && \
            CLUSTER_DOMAIN="${_existing_url}"

        # hugging_face_token: load from config when not set via env var
        [[ -z "${HUGGINGFACE_TOKEN}" && -n "${_existing_hf_token}" ]] && \
            HUGGINGFACE_TOKEN="${_existing_hf_token}"

        # models: load from config so banner and deployment use the configured model
        local _existing_models
        _existing_models=$(grep -E '^models=' "${_base_cfg}" | cut -d= -f2- | xargs || true)
        [[ -n "${_existing_models}" ]] && MODELS="${_existing_models}"
    fi

    # ── Interactive menu mode ─────────────────────────────────────────────────
    if [[ "${SHOW_MENU}" == "true" ]]; then
        banner "Intel AI for Enterprise Agent Toolkit — Interactive Cluster Management"
        _show_main_menu "$@"
        return
    fi

    # ── One-click base stack deployment (Step 1) ──────────────────────────────
    banner "Intel AI for Enterprise Agent Toolkit — One-Click Deployment (Step 1: Base Stack)"
    info "Domain  : ${CLUSTER_DOMAIN}"
    info "Model   : $(_model_display_list "${MODELS}") (vLLM CPU)"
    info "OS      : ${OS_ID} (${OS_FAMILY}) | Arch: ${ARCH} | User: ${ANSIBLE_USER}"
    echo ""
    read -rp $'\e[0;36mDo you want to continue with the deployment? [yes/no]: \e[0m' _confirm
    case "${_confirm,,}" in
        y|yes) ;;
        *)
            echo "Deployment cancelled."
            exit 0
            ;;
    esac
    echo ""

    validate_inputs
    install_prereqs
    setup_ssh
    generate_certs
    prepare_repo
    write_hosts_yaml
    write_config

    run_deployment
    print_summary
}

[[ "${DEPLOY_SOURCED:-0}" == "1" ]] || main "$@"