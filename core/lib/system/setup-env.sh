# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

setup_initial_env() {
    echo "Setting up the Initial Environment..."
    
    if [[ "$skip_check" != "true" ]]; then
        echo "Performing initial system prerequisites check..."
        if ! run_system_prerequisites_check; then
            echo "System prerequisites check failed. Please install missing dependencies and try again."
            exit 1
        fi
        echo "System prerequisites check completed successfully."
    else
        echo "Skipping system prerequisites check due to --skip-check argument."
    fi
        
    if [[ -n "$https_proxy" ]]; then
        git config --global http.proxy "$https_proxy"
        git config --global https.proxy "$https_proxy"
    fi
    # A directory without .git means a previous clone failed or was interrupted.
    # Remove it so the clone is retried cleanly.
    if [[ -d "$KUBESPRAYDIR" && ! -d "$KUBESPRAYDIR/.git" ]]; then
        echo "Kubespray directory exists but is not a valid git repo — removing and recloning..."
        rm -rf "$KUBESPRAYDIR"
    fi
    if [ ! -d "$KUBESPRAYDIR" ]; then
        git clone https://github.com/kubernetes-sigs/kubespray.git $KUBESPRAYDIR
        if [ $? -ne 0 ] || [ ! -d "$KUBESPRAYDIR/.git" ]; then
            echo -e "${RED}----------------------------------------------------------------------------${NC}"
            echo -e "${RED}|  NOTICE: Failed to clone Kubespray Repository.                           |${NC}"        
            echo -e "${RED}|  Unable to proceed with Inference Stack Deployment                        |${NC}"        
            echo -e "${RED}|  due to missing dependency                                                |${NC}"        
            echo -e "${RED}----------------------------------------------------------------------------${NC}"            
            exit 1
        fi
        cd $KUBESPRAYDIR        
        git checkout "$kubespray_version"
    else
        echo "Kubespray directory already exists, skipping clone."
        cd $KUBESPRAYDIR
    fi
    if [[ -n "$https_proxy" ]]; then
        git config --global --unset http.proxy
        git config --global --unset https.proxy
    fi
    
    VENVDIR="$KUBESPRAYDIR/venv"
    REMOTEDIR="/tmp/helm-charts"
    # Check for a valid venv — directory alone is not enough (bin/activate must exist).
    # A missing bin/ means the venv was never fully created (e.g. interrupted or
    # partially written by a previous root run). Remove the incomplete dir and recreate.
    if [[ -d "$VENVDIR" && ! -f "$VENVDIR/bin/activate" ]]; then
        echo "Incomplete virtual environment detected (bin/activate missing) — removing and recreating..."
        sudo chown -R "$(id -u):$(id -g)" "$VENVDIR"
        rm -rf "$VENVDIR"
    fi
    if [ ! -d "$VENVDIR" ]; then                
        echo "Installing python3-venv package..."
        if command -v apt &> /dev/null; then            
            python_version=$($python3_interpreter -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")            
            sudo apt install -y python${python_version}-venv || sudo apt install -y python3-venv        
        fi                
        if $python3_interpreter -m venv $VENVDIR; then
            echo "Virtual environment created within Kubespray directory."
        else
            echo -e "${RED}Failed to create virtual environment.${NC}"
            exit 1
        fi
    else
        echo "Virtual environment already exists within Kubespray directory, skipping creation."
    fi
    source $VENVDIR/bin/activate
    echo "Attempting to activate the virtual environment..."    
    if [ -z "$VIRTUAL_ENV" ]; then        
        rm -rf "$KUBESPRAYDIR"
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        echo -e "${RED}|  NOTICE: Failed to activate the virtual environment.                      |${NC}"
        echo -e "${RED}|  Please retrigger the Inference Stack Deployment                          |${NC}"
        echo -e "${RED}|                                                                           |${NC}"
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        exit 1
    else
        echo "Virtual environment activated successfully. Path: $VIRTUAL_ENV"
    fi                 
        
    export PIP_BREAK_SYSTEM_PACKAGES=1
    $VENVDIR/bin/python3 -m pip install --upgrade pip
    $VENVDIR/bin/python3 -m pip install -U -r requirements.txt    
    
    echo "Verifying Ansible Installation..."
    if $VENVDIR/bin/python3 -c "import ansible" &> /dev/null; then
        echo -e "${GREEN} Ansible installed successfully${NC}"
    else
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        echo -e "${RED}|  NOTICE: Ansible Installation Failed.                                     |${NC}"        
        echo -e "${RED}|  Unable to proceed with Inference Stack Deployment                        |${NC}"        
        echo -e "${RED}|  due to missing dependency                                                |${NC}"        
        echo -e "${RED}----------------------------------------------------------------------------${NC}"        
        exit 1
    fi    

    echo -e "${GREEN} Enterprise Inference requirements installed.${NC}"
    cp -r "$HOMEDIR"/helm-charts "$HOMEDIR"/scripts "$KUBESPRAYDIR"/
    cp -r "$KUBESPRAYDIR"/inventory/sample/ "$KUBESPRAYDIR"/inventory/mycluster
    cp  "$HOMEDIR"/inventory/hosts.yaml $KUBESPRAYDIR/inventory/mycluster/
    cp "$HOMEDIR"/inventory/metadata/addons.yml $KUBESPRAYDIR/inventory/mycluster/group_vars/k8s_cluster/addons.yml    
    cp "$HOMEDIR"/playbooks/* "$KUBESPRAYDIR"/playbooks/    
    xeon_values_file_path="$REMOTEDIR/vllm/xeon-values.yaml"
    cp "$HOMEDIR"/inventory/metadata/addons.yml $KUBESPRAYDIR/inventory/mycluster/group_vars/k8s_cluster/addons.yml
    cp "$HOMEDIR"/inventory/metadata/all.yml $KUBESPRAYDIR/inventory/mycluster/group_vars/all/all.yml
    # Copy roles to kubespray/roles/ AND to kubespray/playbooks/roles/ so Ansible
    # finds them both via roles_path config and relative-to-playbook discovery.
    mkdir -p "$KUBESPRAYDIR/roles" "$KUBESPRAYDIR/playbooks/roles"
    cp -r "$HOMEDIR"/roles/* $KUBESPRAYDIR/roles/
    cp -r "$HOMEDIR"/roles/* $KUBESPRAYDIR/playbooks/roles/

    mkdir -p "$KUBESPRAYDIR/config"        
    chmod +x $HOMEDIR/scripts/generate-vault-secrets.sh

    # Only generate vault secrets if vault.yml doesn't exist or is incomplete
    vault_file="$HOMEDIR/inventory/metadata/vault.yml"
    mandatory_keys=("litellm_master_key" "litellm_salt_key" "redis_password" "langfuse_secret_key" "langfuse_public_key" "postgresql_username" "postgresql_password" "clickhouse_username" "clickhouse_password" "langfuse_login" "langfuse_user" "langfuse_password" "minio_secret" "minio_user" "postgres_user" "postgres_password" "pgvector_password" "pgvector_postgres_password")

    if [ ! -f "$vault_file" ]; then
        echo "vault.yml not found at $vault_file, generating vault secrets..."
        bash $HOMEDIR/scripts/generate-vault-secrets.sh
    else
        echo "Checking vault.yml for mandatory keys..."
        missing_keys=()
        for key in "${mandatory_keys[@]}"; do
            if ! grep -q "^${key}:" "$vault_file"; then
                missing_keys+=("$key")
            fi
        done

        if [ ${#missing_keys[@]} -gt 0 ]; then
            echo -e "${YELLOW}vault.yml exists but is missing mandatory keys: ${missing_keys[*]}${NC}"
            echo "Regenerating vault.yml with all mandatory keys..."
            bash $HOMEDIR/scripts/generate-vault-secrets.sh
        else
            echo -e "${GREEN}vault.yml exists and contains all mandatory keys. Skipping generation...${NC}"
        fi

        # ── Backfill newer, non-mandatory keys without touching existing ones ──
        # Added after the initial release, so a pre-existing vault.yml will not
        # have it. Append only — a full regeneration would rotate every other
        # secret and break already-deployed components.
        if ! grep -q '^redis_stack_password:' "$vault_file"; then
            echo -e "${YELLOW}Adding missing redis_stack_password to vault.yml...${NC}"
            printf 'redis_stack_password: "%s"\n' \
                "$(openssl rand -base64 15 | tr -d '=+/' | cut -c1-20)" >> "$vault_file"
        fi
    fi

    # ── Sync litellm_master_key from the live cluster if already deployed ─────
    # If LiteLLM is already running, the key in vault.yml may be stale (e.g. from
    # a prior run on a different repo clone). Pull the live key from the pod env
    # so subsequent ansible/helm calls use the correct credential.
    if command -v kubectl &>/dev/null; then
        local _live_key
        _live_key="$(kubectl get secret -n genai-gateway litellm-secret \
            -o jsonpath='{.data.LITELLM_MASTER_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)"
        # Fall back to reading directly from the pod environment
        if [[ -z "${_live_key}" ]]; then
            _live_key="$(kubectl exec -n genai-gateway deployment/genai-gateway-deployment \
                -- env 2>/dev/null | grep '^LITELLM_MASTER_KEY=' | cut -d= -f2- || true)"
        fi
        if [[ -n "${_live_key}" ]]; then
            local _vault_key
            _vault_key="$(grep '^litellm_master_key:' "$vault_file" \
                | sed 's/litellm_master_key:[[:space:]]*//' | tr -d '"' || true)"
            if [[ "${_live_key}" != "${_vault_key}" ]]; then
                echo -e "${YELLOW}Syncing litellm_master_key in vault.yml with the live cluster key...${NC}"
                sed -i "s|^litellm_master_key:.*|litellm_master_key: \"${_live_key}\"|" "$vault_file"
                echo -e "${GREEN}vault.yml litellm_master_key updated.${NC}"
            fi
        fi
    fi

    if [ "$purge_inference_cluster" != "purging" ]; then        
        if [[ "$deploy_llm_models" == "yes" || "$deploy_genai_gateway" == "yes" || "$deploy_observability" == "yes" || "$deploy_logging" == "yes" || "$deploy_ceph" == "yes" || "$deploy_istio" == "yes" || "$deploy_finetune_plugin" == "yes" ]]; then
            if [ ! -s "$HOMEDIR/inventory/metadata/vault.yml" ]; then                
                echo -e "${YELLOW}----------------------------------------------------------------------------${NC}"
                echo -e "${YELLOW}|  NOTICE: inventory/metadata/vault.yml is empty!                           |${NC}"
                echo -e "${YELLOW}|  Please refer to docs/configuring-vault-values.md for instructions on     |${NC}"
                echo -e "${YELLOW}|  updating vault.yml                                                       |${NC}"
                echo -e "${YELLOW}----------------------------------------------------------------------------${NC}"
                exit 1
            fi      
        fi          
    fi    
    cp "$HOMEDIR"/inventory/metadata/vault.yml $KUBESPRAYDIR/config/vault.yml            
    mkdir -p "$KUBESPRAYDIR/config/vars" 
    cp -r "$HOMEDIR"/inventory/metadata/vars/* $KUBESPRAYDIR/config/vars/    
    cp "$HOMEDIR"/playbooks/* "$KUBESPRAYDIR"/playbooks/
    echo "Additional files and directories copied to Kubespray directory."
        
    if [[ "$skip_check" != "true" ]]; then
        echo "Performing infrastructure readiness check..."
        if ! run_infrastructure_readiness_check; then
            echo "Infrastructure readiness check failed. Please resolve the issues and try again."
            exit 1
        fi
    else
        echo "Skipping infrastructure readiness check due to --skip-check argument."
    fi
    echo "Infrastructure readiness check completed successfully."    
    ansible-galaxy collection install community.kubernetes        
}


invoke_prereq_workflows() {
    if [ $prereq_executed -eq 0 ]; then
        read_config_file "$@"
        if [ -z "$cluster_url" ] || [ -z "$cert_file" ] || [ -z "$key_file" ]; then
            echo "Some required arguments are missing. Prompting for input..."
            prompt_for_input
        fi
        setup_initial_env "$@"
        # Set the flag to 1 (executed)
        prereq_executed=1
    else
        echo "Prerequisites have already been executed. Skipping..."
    fi
}

install_ansible_collection() {
    echo "Installing community.general collection..."
    ansible-galaxy collection install community.general
}

# ---------------------------------------------------------------------------
# setup_kernel_and_containerd
#
# Fixes the three kubeadm preflight failures seen on fresh machines:
#   1. IP forwarding disabled  -> enables net.ipv4.ip_forward and bridge-nf
#   2. containerd not running  -> installs, configures SystemdCgroup=true,
#                                 and starts containerd
#   3. br_netfilter module missing -> loaded and persisted
#
# Safe to call on machines where containerd is already running; the function
# is idempotent and skips steps that are already in the desired state.
# ---------------------------------------------------------------------------
setup_kernel_and_containerd() {
    echo "Configuring kernel parameters and containerd for Kubernetes..."

    # ── Load required kernel modules ──────────────────────────────────────────
    sudo modprobe overlay    2>/dev/null || true
    sudo modprobe br_netfilter 2>/dev/null || true

    # Persist modules across reboots
    sudo tee /etc/modules-load.d/kubernetes.conf > /dev/null <<'EOF'
overlay
br_netfilter
EOF

    # ── Enable IP forwarding and bridge netfilter ──────────────────────────────
    sudo tee /etc/sysctl.d/99-kubernetes.conf > /dev/null <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    # On Ubuntu 22.04+ /etc/sysctl.d/99-sysctl.conf is expected to exist as a
    # symlink to /etc/sysctl.conf.  Some minimal images ship without it, causing
    # 'sysctl: cannot open ... No such file or directory' noise from --system.
    # Create the symlink (or a plain file as fallback) so sysctl --system is clean.
    if [[ ! -e /etc/sysctl.d/99-sysctl.conf ]]; then
        if [[ -f /etc/sysctl.conf ]]; then
            sudo ln -s /etc/sysctl.conf /etc/sysctl.d/99-sysctl.conf
        else
            sudo touch /etc/sysctl.d/99-sysctl.conf
        fi
    fi

    sudo sysctl --system

    echo -e "${GREEN}Kernel parameters applied.${NC}"

    # ── Disable swap (required by kubelet) ────────────────────────────────────
    if swapon --show | grep -q .; then
        echo "Swap is active — disabling..."
        sudo swapoff -a
        echo -e "${GREEN}Swap disabled (runtime).${NC}"
    else
        echo -e "${GREEN}Swap already off.${NC}"
    fi
    # Persist: comment out all swap entries in /etc/fstab
    sudo sed -i.bak -E 's|^([^#].*\s+swap\s+.*)$|# \1|' /etc/fstab
    echo -e "${GREEN}Swap entries disabled in /etc/fstab.${NC}"

    # ── Install and configure containerd ─────────────────────────────────────
    if systemctl is-active --quiet containerd 2>/dev/null; then
        echo -e "${GREEN}containerd is already running — reconfiguring.${NC}"
    else
        echo "containerd is not running. Installing..."
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y containerd
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y containerd
        else
            echo -e "${RED}ERROR: Cannot install containerd — unknown package manager.${NC}"
            exit 1
        fi
    fi

    # Always (re)write the containerd config so SystemdCgroup and sandbox_image
    # are correct — covers fresh installs, reinstalls, and version upgrades.
    # containerd 2.x changed the CRI plugin ID but the field names are the same;
    # a plain sed on the field value works for both 1.x and 2.x config formats.
    # Note: do NOT set base_runtime_spec to cri-base.json — containerd 2.x does
    # not generate that file via 'containerd config default', causing CRI to fail
    # with "unknown service runtime.v1.RuntimeService".
    sudo mkdir -p /etc/containerd
    containerd config default | sed \
        -e 's/SystemdCgroup = false/SystemdCgroup = true/g' \
        -e 's|sandbox_image = ".*"|sandbox_image = "registry.k8s.io/pause:3.10"|' | \
        sudo tee /etc/containerd/config.toml > /dev/null

    # ── Configure containerd proxy (required to pull images on proxied networks) ──
    # Read proxy from environment; these are set by read_config_file from
    # agentic-config.cfg before this function is called.
    local _http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
    local _https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
    local _no_proxy="${no_proxy:-${NO_PROXY:-}}"

    # Always ensure k8s service CIDR (10.96.0.0/12), pod CIDR (192.168.0.0/16),
    # and the service cluster IP (10.96.0.1) are excluded from proxy so that the
    # Calico CNI binary (which inherits containerd's env) never proxies traffic to
    # the k8s API server — a proxied TLS connection causes x509 IP SAN failures.
    local _k8s_noproxy="10.96.0.1,10.96.0.0/12,192.168.0.0/16"

    if [[ -n "${_no_proxy}" ]]; then
        _no_proxy="${_no_proxy},${_k8s_noproxy}"
    else
        _no_proxy="${_k8s_noproxy}"
    fi

    if [[ -n "${_http_proxy}" || -n "${_https_proxy}" ]]; then
        local _proxy_dir="/etc/systemd/system/containerd.service.d"
        local _proxy_file="${_proxy_dir}/http-proxy.conf"

        sudo mkdir -p "${_proxy_dir}"

        # Build the exact desired configuration string in memory
        local _desired_conf
        _desired_conf=$(cat <<EOF
[Service]
Environment="HTTP_PROXY=${_http_proxy}"
Environment="HTTPS_PROXY=${_https_proxy}"
Environment="NO_PROXY=${_no_proxy}"
EOF
)

        # Check if the file exists and exactly matches our desired configuration
        if [[ ! -f "${_proxy_file}" ]] || ! echo "${_desired_conf}" | sudo cmp -s - "${_proxy_file}"; then
            # File is missing or different: Write it and restart the service
            echo "${_desired_conf}" | sudo tee "${_proxy_file}" > /dev/null
            echo -e "${GREEN}containerd proxy drop-in written/updated.${NC}"

            sudo systemctl daemon-reload
            sudo systemctl enable --now containerd
            sudo systemctl restart containerd
            echo -e "${GREEN}containerd proxy configured and restarted successfully.${NC}"
        else
            # File exists and matches perfectly: Do nothing
            echo -e "${GREEN}containerd proxy configuration is already up to date. No restart needed.${NC}"
            sudo systemctl enable --now containerd
        fi
    else
        # No proxy variables were set, just ensure containerd is enabled and running
        sudo systemctl enable --now containerd
    fi

    # ── Configure containerd proxy so image pulls (registry.k8s.io) work ──────
    # containerd is installed via apt above (not Kubespray's containerd role), so
    # it has NO proxy env. Behind a corporate proxy, kubeadm init's preflight image
    # pulls fail with "dial tcp ... i/o timeout". Apply the drop-in unconditionally
    # so the re-run case (containerd already running, install block skipped) is
    # also covered.
    if [[ -n "${http_proxy:-}" || -n "${https_proxy:-}" ]]; then
        echo "Configuring containerd proxy (systemd drop-in)..."
        # Cluster-internal traffic must bypass the proxy: service CIDR + pod CIDR
        # (the CIDRs kubeadm init uses), plus whatever no_proxy already carries.
        # These MUST match the --service-cidr / --pod-network-cidr passed to
        # `kubeadm init` in core/playbooks/cluster.yml — keep in sync if changed there.
        local _ctr_no_proxy="${no_proxy:-localhost,127.0.0.1},10.96.0.0/12,192.168.0.0/16"
        sudo mkdir -p /etc/systemd/system/containerd.service.d
        sudo tee /etc/systemd/system/containerd.service.d/http-proxy.conf > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${http_proxy:-${https_proxy}}"
Environment="HTTPS_PROXY=${https_proxy:-${http_proxy}}"
Environment="NO_PROXY=${_ctr_no_proxy}"
EOF
        sudo systemctl daemon-reload
        sudo systemctl restart containerd
        echo -e "${GREEN}containerd proxy configured.${NC}"
    fi
}
