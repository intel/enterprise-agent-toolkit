# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------------
# deploy_agent_sandbox_controller
#
# Deploys the Agent Sandbox controller + sandbox-router into the
# `agent-sandbox` namespace using the upstream Helm chart cloned
# from https://github.com/kubernetes-sigs/agent-sandbox at the pinned
# version, and applies a default SandboxTemplate to the `default` namespace.
#
# Installed components
# ────────────────────
#   1. Core CRDs + extension CRDs
#        CRDs are applied directly from the cloned source (helm/crds/).
#        This is safe for both fresh installs and upgrades; Helm does not
#        automatically upgrade CRDs placed in the chart's crds/ directory
#        during `helm upgrade`.
#
#   2. Agent Sandbox controller (Helm)
#        Deployed via helm upgrade --install from the cloned upstream chart
#        (helm/) overlaid with our values at
#        core/helm-charts/agent-sandbox/values.yaml.
#        extensions: true enables the SandboxTemplate, SandboxClaim, and
#        SandboxWarmPool reconcilers.  No WarmPool instances are
#        pre-created; extend by applying SandboxWarmPool CRs later.
#
#   3. sandbox-router image (locally built)
#        Python FastAPI reverse proxy.  No pre-built image exists in the
#        GitHub releases; the image is built with nerdctl + BuildKit from
#        clients/python/agentic-sandbox-client/sandbox-router/Dockerfile
#        in the cloned source tree.
#
#   4. python-runtime-sandbox image (locally built)
#        FastAPI server implementing the Agent Sandbox command-execution API
#        (POST /execute → {stdout, stderr, exit_code}).  Built from
#        examples/python-runtime-sandbox/Dockerfile in the cloned source.
#        This image runs inside each Sandbox pod.
#
#   5. sandbox-router Kubernetes manifest
#        Applied to the agent-sandbox namespace with the locally
#        built image and imagePullPolicy: Never.
#
#   6. Default SandboxTemplate
#        `python-sandbox-template` applied to the `agent-sandbox`
#        namespace so all components share one namespace and the controller's
#        auto-generated NetworkPolicy (app=sandbox-router selector) allows
#        router → sandbox pod traffic:
#          client.create_sandbox(template="python-sandbox-template",
#                                namespace="agent-sandbox")
#        Template YAML lives at core/helm-charts/agent-sandbox/default-templates.yaml.
#
# Version pinning
# ───────────────
#   agent_sandbox_version  (agentic-metadata.cfg)  e.g. v0.4.6
#
# Prerequisites
# ─────────────
#   • Kubernetes is running  (kubectl get nodes)
#   • SCRIPT_DIR points to the core/ directory
#   • Helm: installed automatically if absent
#   • nerdctl / BuildKit: installed automatically if absent
#   • git: used for a shallow clone; falls back to tarball download if absent
#
# Re-run safety
# ─────────────
#   • helm upgrade --install  is idempotent.
#   • kubectl apply           is idempotent.
#   • Image builds            are skipped when the target tag already exists
#                             in the containerd k8s.io namespace.
#   • Source clone            is skipped when the build directory already
#                             contains the expected helm/crds/ path.
# ---------------------------------------------------------------------------

deploy_agent_sandbox_controller() {
    local sandbox_ns="agent-sandbox"
    local sandbox_version="${agent_sandbox_version:-v0.4.6}"

    local router_image_name="sandbox-router"
    local router_image_tag="${sandbox_version}"
    local router_full_image="${router_image_name}:${router_image_tag}"

    local runtime_image_name="python-runtime-sandbox"
    local runtime_full_image="${runtime_image_name}:${sandbox_version}"

    local nerdctl_version="1.7.7"
    local buildkit_version="v0.19.0"
    local build_dir="/tmp/agent-sandbox-build-${sandbox_version}"

    local local_values="${SCRIPT_DIR}/helm-charts/agent-sandbox/values.yaml"
    local local_templates="${SCRIPT_DIR}/helm-charts/agent-sandbox/default-templates.yaml"

    echo ""
    echo "${BLUE}============================================================${NC}"
    echo "${BLUE}  Deploying Agent Sandbox (Helm + locally-built images)${NC}"
    echo "${BLUE}  Version  : ${sandbox_version}${NC}"
    echo "${BLUE}  Namespace: ${sandbox_ns}${NC}"
    echo "${BLUE}============================================================${NC}"

    # ── 0. Prerequisites ─────────────────────────────────────────────────────
    if ! command -v kubectl &>/dev/null; then
        echo "${RED}ERROR: kubectl is not available. Kubernetes must be installed first.${NC}"
        exit 1
    fi
    if ! kubectl get nodes &>/dev/null 2>&1; then
        echo "${RED}ERROR: Kubernetes cluster is not reachable.${NC}"
        echo "${RED}       Ensure Kubernetes is running before deploying Agent Sandbox.${NC}"
        exit 1
    fi

    # Detect containerd socket — required for nerdctl + BuildKit
    local containerd_sock=""
    if   [[ -S /run/containerd/containerd.sock ]];     then containerd_sock="/run/containerd/containerd.sock"
    elif [[ -S /var/run/containerd/containerd.sock ]]; then containerd_sock="/var/run/containerd/containerd.sock"
    else
        echo "${RED}ERROR: containerd socket not found. Is Kubernetes running?${NC}"
        echo "${RED}       Check: kubectl get nodes${NC}"
        exit 1
    fi
    echo "${CYAN}  containerd socket : ${containerd_sock}${NC}"

    # Detect host architecture for binary downloads
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)        arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             arch="amd64" ;;
    esac

    # ── 1. Tooling: Helm, nerdctl, BuildKit, buildkitd ───────────────────────
    echo ""
    echo "${CYAN}[1/8] Ensuring required tooling is present...${NC}"

    # Helm
    if ! command -v helm &>/dev/null; then
        echo "      Installing Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    echo "${GREEN}      Helm  : $(helm version --short 2>/dev/null)${NC}"

    # nerdctl
    if ! command -v nerdctl &>/dev/null; then
        echo "      Installing nerdctl v${nerdctl_version} (${arch})..."
        curl -fsSL \
            "https://github.com/containerd/nerdctl/releases/download/v${nerdctl_version}/nerdctl-${nerdctl_version}-linux-${arch}.tar.gz" \
            | sudo tar -xz -C /usr/local/bin
        echo "${GREEN}      nerdctl installed.${NC}"
    else
        echo "${GREEN}      nerdctl: $(nerdctl --version 2>/dev/null | head -1)${NC}"
    fi

    # BuildKit
    if ! command -v buildkitd &>/dev/null; then
        echo "      Installing BuildKit ${buildkit_version} (${arch})..."
        curl -fsSL \
            "https://github.com/moby/buildkit/releases/download/${buildkit_version}/buildkit-${buildkit_version}.linux-${arch}.tar.gz" \
            | sudo tar -xz -C /usr/local
        echo "${GREEN}      BuildKit installed.${NC}"
    else
        echo "${GREEN}      BuildKit: $(buildkitd --version 2>/dev/null | head -1)${NC}"
    fi

    # Start buildkitd daemon (systemd preferred; raw background process as fallback)
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        if ! sudo systemctl is-active --quiet buildkit 2>/dev/null; then
            if [[ ! -f /etc/systemd/system/buildkit.service ]]; then
                sudo tee /etc/systemd/system/buildkit.service > /dev/null <<BKSVC
[Unit]
Description=BuildKit daemon
Documentation=https://github.com/moby/buildkit
After=containerd.service

[Service]
ExecStart=/usr/local/bin/buildkitd --oci-worker=false --containerd-worker=true --containerd-worker-namespace=k8s.io --containerd-worker-addr ${containerd_sock}
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
BKSVC
                # Write proxy drop-in so image pulls inside the build honour
                # corporate proxy settings.
                sudo mkdir -p /etc/systemd/system/buildkit.service.d
                {
                    echo "[Service]"
                    [[ -n "${http_proxy:-}"  ]] && echo "Environment=\"http_proxy=${http_proxy}\""   || true
                    [[ -n "${https_proxy:-}" ]] && echo "Environment=\"https_proxy=${https_proxy}\"" || true
                    [[ -n "${no_proxy:-}"    ]] && echo "Environment=\"no_proxy=${no_proxy}\""       || true
                    [[ -n "${HTTP_PROXY:-}"  ]] && echo "Environment=\"HTTP_PROXY=${HTTP_PROXY}\""   || true
                    [[ -n "${HTTPS_PROXY:-}" ]] && echo "Environment=\"HTTPS_PROXY=${HTTPS_PROXY}\"" || true
                    [[ -n "${NO_PROXY:-}"    ]] && echo "Environment=\"NO_PROXY=${NO_PROXY}\""       || true
                } | sudo tee /etc/systemd/system/buildkit.service.d/proxy.conf > /dev/null
                sudo systemctl daemon-reload || true
                sudo systemctl enable buildkit 2>/dev/null || true
            fi
            sudo systemctl reset-failed buildkit 2>/dev/null || true
            sudo systemctl restart buildkit
        fi
        echo "${GREEN}      buildkitd is running via systemd.${NC}"
    else
        # Fallback: launch buildkitd directly in the background
        if ! sudo buildctl debug workers &>/dev/null 2>&1; then
            sudo env \
                ${http_proxy:+http_proxy="${http_proxy}"} \
                ${https_proxy:+https_proxy="${https_proxy}"} \
                ${no_proxy:+no_proxy="${no_proxy}"} \
                buildkitd \
                    --oci-worker=false \
                    --containerd-worker=true \
                    --containerd-worker-namespace=k8s.io \
                    --containerd-worker-addr "${containerd_sock}" \
                    &>/tmp/buildkitd-agent-sandbox.log &
            echo "${GREEN}      buildkitd started as a background process.${NC}"
        else
            echo "${GREEN}      buildkitd already running.${NC}"
        fi
    fi

    # Wait until buildkitd accepts connections (up to 40 s)
    local _bk_wait=0
    until sudo buildctl debug workers &>/dev/null 2>&1 || [[ ${_bk_wait} -ge 20 ]]; do
        sleep 2; _bk_wait=$(( _bk_wait + 1 ))
    done
    if [[ ${_bk_wait} -ge 20 ]]; then
        echo "${RED}ERROR: buildkitd did not become ready in time.${NC}"
        echo "${RED}       Check: sudo systemctl status buildkit  or  /tmp/buildkitd-agent-sandbox.log${NC}"
        exit 1
    fi
    echo "${GREEN}      buildkitd is ready.${NC}"

    # ── 2. Obtain agent-sandbox source ───────────────────────────────────────
    # A single clone serves three purposes: the upstream Helm chart,
    # the sandbox-router Dockerfile, and the python-runtime-sandbox Dockerfile.
    # Skip clone when the build directory already has the expected structure.
    echo ""
    echo "${CYAN}[2/8] Obtaining agent-sandbox source at ${sandbox_version}...${NC}"

    if [[ -d "${build_dir}/helm/crds" ]]; then
        echo "${GREEN}      Source directory already present at ${build_dir} — reusing.${NC}"
    else
        rm -rf "${build_dir}"

        if command -v git &>/dev/null; then
            git clone \
                --depth 1 \
                --branch "${sandbox_version}" \
                https://github.com/kubernetes-sigs/agent-sandbox.git \
                "${build_dir}"
        else
            echo "      git not found — downloading source tarball..."
            local _tarball="/tmp/agent-sandbox-${sandbox_version}.tar.gz"
            curl -fsSL \
                "https://github.com/kubernetes-sigs/agent-sandbox/archive/refs/tags/${sandbox_version}.tar.gz" \
                -o "${_tarball}"
            mkdir -p "${build_dir}"
            tar -xzf "${_tarball}" -C "${build_dir}" --strip-components=1
            rm -f "${_tarball}"
        fi

        if [[ ! -d "${build_dir}/helm/crds" ]]; then
            echo "${RED}ERROR: Helm crds/ directory not found in cloned source.${NC}"
            echo "${RED}       Expected: ${build_dir}/helm/crds${NC}"
            echo "${RED}       The source layout may have changed for version ${sandbox_version}.${NC}"
            exit 1
        fi
    fi
    echo "${GREEN}      Source ready at ${build_dir}.${NC}"

    # ── 3. Install / update CRDs ─────────────────────────────────────────────
    # CRDs are applied directly from helm/crds/ rather than through Helm so
    # they are correctly updated on upgrades.  Helm does not auto-upgrade CRDs
    # placed in the chart's crds/ directory during `helm upgrade`.
    echo ""
    echo "${CYAN}[3/8] Applying CRDs from source (upgrade-safe)...${NC}"
    if ! kubectl apply -f "${build_dir}/helm/crds/"; then
        echo "${RED}ERROR: Failed to apply CRDs from ${build_dir}/helm/crds/${NC}"
        exit 1
    fi
    echo "${GREEN}      CRDs applied.${NC}"

    # ── 4. Deploy controller via Helm ────────────────────────────────────────
    echo ""
    echo "${CYAN}[4/8] Deploying Agent Sandbox controller via Helm (waiting up to 10 min)...${NC}"

    if [[ ! -f "${local_values}" ]]; then
        echo "${RED}ERROR: Local values file not found: ${local_values}${NC}"
        echo "${RED}       Expected at core/helm-charts/agent-sandbox/values.yaml${NC}"
        exit 1
    fi

    helm upgrade --install agent-sandbox "${build_dir}/helm/" \
        --namespace "${sandbox_ns}" \
        --create-namespace \
        --values "${local_values}" \
        --set "image.tag=${sandbox_version}" \
        --set "namespace.name=${sandbox_ns}" \
        --set "namespace.create=false" \
        --wait \
        --timeout 10m

    echo "${GREEN}      Agent Sandbox controller is running.${NC}"

    # ── 5. Build sandbox-router image ────────────────────────────────────────
    echo ""
    echo "${CYAN}[5/8] Building sandbox-router image (${router_full_image})...${NC}"

    local _build_router=true
    if sudo ctr -n k8s.io images ls 2>/dev/null \
            | awk '{print $1}' \
            | grep -qxF "docker.io/library/${router_full_image}"; then
        echo "${GREEN}      Image '${router_full_image}' already present in containerd k8s.io — skipping build.${NC}"
        _build_router=false
    fi

    if [[ "${_build_router}" == "true" ]]; then
        local router_src="${build_dir}/clients/python/agentic-sandbox-client/sandbox-router"
        if [[ ! -f "${router_src}/Dockerfile" ]]; then
            echo "${RED}ERROR: sandbox-router Dockerfile not found at ${router_src}/Dockerfile${NC}"
            echo "${RED}       Check: https://github.com/kubernetes-sigs/agent-sandbox/tree/${sandbox_version}/clients/python/agentic-sandbox-client/sandbox-router${NC}"
            exit 1
        fi

        echo "      Pre-pulling base image python:3.14-slim through proxy..."
        sudo env \
            ${http_proxy:+http_proxy="${http_proxy}"} \
            ${https_proxy:+https_proxy="${https_proxy}"} \
            ${HTTP_PROXY:+HTTP_PROXY="${HTTP_PROXY}"} \
            ${HTTPS_PROXY:+HTTPS_PROXY="${HTTPS_PROXY}"} \
            ${no_proxy:+no_proxy="${no_proxy}"} \
            ${NO_PROXY:+NO_PROXY="${NO_PROXY}"} \
            nerdctl --namespace k8s.io pull python:3.14-slim || {
                echo "${YELLOW}WARN: Failed to pre-pull python:3.14-slim. Build may fail if proxy issues persist.${NC}"
            }

        echo "      Building '${router_full_image}' into containerd k8s.io namespace..."
        sudo nerdctl \
            --namespace k8s.io \
            build \
            --no-cache \
            --tag "${router_full_image}" \
            ${http_proxy:+--build-arg http_proxy="${http_proxy}"} \
            ${https_proxy:+--build-arg https_proxy="${https_proxy}"} \
            ${HTTP_PROXY:+--build-arg HTTP_PROXY="${HTTP_PROXY}"} \
            ${HTTPS_PROXY:+--build-arg HTTPS_PROXY="${HTTPS_PROXY}"} \
            ${no_proxy:+--build-arg no_proxy="${no_proxy}"} \
            ${NO_PROXY:+--build-arg NO_PROXY="${NO_PROXY}"} \
            "${router_src}"

        if sudo ctr -n k8s.io images ls 2>/dev/null | grep -q "${router_image_name}"; then
            echo "${GREEN}      sandbox-router image confirmed in containerd k8s.io: ${router_full_image}${NC}"
        else
            echo "${YELLOW}WARN: Cannot confirm sandbox-router image in containerd.${NC}"
            echo "${YELLOW}      The rollout may fail with ImagePullBackOff.${NC}"
            echo "${YELLOW}      Check: sudo ctr -n k8s.io images ls | grep sandbox-router${NC}"
        fi
    fi

    # ── 6. Build python-runtime-sandbox image ────────────────────────────────
    # This image runs inside each Sandbox pod.  It implements the Agent Sandbox
    # command-execution API consumed by the Python SDK:
    #   POST /execute  {"command": "..."}  →  {stdout, stderr, exit_code}
    echo ""
    echo "${CYAN}[6/8] Building python-runtime-sandbox image (${runtime_full_image})...${NC}"

    local _build_runtime=true
    if sudo ctr -n k8s.io images ls 2>/dev/null \
            | awk '{print $1}' \
            | grep -qxF "docker.io/library/${runtime_full_image}"; then
        echo "${GREEN}      Image '${runtime_full_image}' already present in containerd k8s.io — skipping build.${NC}"
        _build_runtime=false
    fi

    if [[ "${_build_runtime}" == "true" ]]; then
        local runtime_src="${build_dir}/examples/python-runtime-sandbox"
        if [[ ! -f "${runtime_src}/Dockerfile" ]]; then
            echo "${RED}ERROR: python-runtime-sandbox Dockerfile not found at ${runtime_src}/Dockerfile${NC}"
            echo "${RED}       Check: https://github.com/kubernetes-sigs/agent-sandbox/tree/${sandbox_version}/examples/python-runtime-sandbox${NC}"
            exit 1
        fi

        echo "      Pre-pulling base image python:3.11-slim through proxy..."
        sudo env \
            ${http_proxy:+http_proxy="${http_proxy}"} \
            ${https_proxy:+https_proxy="${https_proxy}"} \
            ${HTTP_PROXY:+HTTP_PROXY="${HTTP_PROXY}"} \
            ${HTTPS_PROXY:+HTTPS_PROXY="${HTTPS_PROXY}"} \
            ${no_proxy:+no_proxy="${no_proxy}"} \
            ${NO_PROXY:+NO_PROXY="${NO_PROXY}"} \
            nerdctl --namespace k8s.io pull python:3.11-slim || {
                echo "${YELLOW}WARN: Failed to pre-pull python:3.11-slim. Build may fail if proxy issues persist.${NC}"
            }

        echo "      Building '${runtime_full_image}' into containerd k8s.io namespace..."
        sudo nerdctl \
            --namespace k8s.io \
            build \
            --no-cache \
            --tag "${runtime_full_image}" \
            ${http_proxy:+--build-arg http_proxy="${http_proxy}"} \
            ${https_proxy:+--build-arg https_proxy="${https_proxy}"} \
            ${HTTP_PROXY:+--build-arg HTTP_PROXY="${HTTP_PROXY}"} \
            ${HTTPS_PROXY:+--build-arg HTTPS_PROXY="${HTTPS_PROXY}"} \
            ${no_proxy:+--build-arg no_proxy="${no_proxy}"} \
            ${NO_PROXY:+--build-arg NO_PROXY="${NO_PROXY}"} \
            "${runtime_src}"

        if sudo ctr -n k8s.io images ls 2>/dev/null | grep -q "${runtime_image_name}"; then
            echo "${GREEN}      python-runtime-sandbox image confirmed in containerd k8s.io: ${runtime_full_image}${NC}"
        else
            echo "${YELLOW}WARN: Cannot confirm python-runtime-sandbox image in containerd.${NC}"
            echo "${YELLOW}      Sandbox pods may fail with ImagePullBackOff.${NC}"
            echo "${YELLOW}      Check: sudo ctr -n k8s.io images ls | grep python-runtime-sandbox${NC}"
        fi
    fi

    # ── 7. Deploy sandbox-router Kubernetes manifest ──────────────────────────
    # Taken from the cloned source tree at the pinned version.
    # Two patches are applied before kubectl apply:
    #   a. ${ROUTER_IMAGE}  →  the locally-built image reference
    #   b. Uncomment `imagePullPolicy: Never` so Kubernetes uses the local
    #      image without attempting a registry pull.
    echo ""
    echo "${CYAN}[7/8] Deploying sandbox-router into namespace '${sandbox_ns}'...${NC}"

    local router_yaml_src="${build_dir}/clients/python/agentic-sandbox-client/sandbox-router/sandbox_router.yaml"
    local router_yaml_patched="/tmp/sandbox-router-${sandbox_version}-patched.yaml"

    if [[ ! -f "${router_yaml_src}" ]]; then
        # Fallback: download directly from GitHub raw content
        echo "      sandbox_router.yaml not found in source tree — downloading from GitHub..."
        local router_yaml_url="https://raw.githubusercontent.com/kubernetes-sigs/agent-sandbox/${sandbox_version}/clients/python/agentic-sandbox-client/sandbox-router/sandbox_router.yaml"
        if ! curl -fsSL "${router_yaml_url}" -o "${router_yaml_src}"; then
            echo "${RED}ERROR: Failed to download sandbox_router.yaml${NC}"
            echo "${RED}       URL: ${router_yaml_url}${NC}"
            exit 1
        fi
    fi

    sed \
        -e "s|\${ROUTER_IMAGE}|${router_full_image}|g" \
        -e "s|#[[:space:]]*imagePullPolicy:[[:space:]]*Never|imagePullPolicy: Never|g" \
        "${router_yaml_src}" > "${router_yaml_patched}"

    # The sandbox-router must run in the same namespace as the Sandbox pods so
    # that the NetworkPolicy auto-generated by the controller (podSelector:
    # app=sandbox-router in the local namespace) permits router → sandbox traffic.
    # All Agent Sandbox components live in agent-sandbox.
    kubectl apply -f "${router_yaml_patched}" -n "${sandbox_ns}"
    rm -f "${router_yaml_patched}"

    echo "      Waiting for sandbox-router to roll out (up to 5 min)..."
    if ! kubectl rollout status deployment/sandbox-router-deployment \
            -n "${sandbox_ns}" --timeout=5m; then
        echo "${RED}ERROR: sandbox-router deployment did not become ready in time.${NC}"
        echo "${RED}       Pods    : kubectl get pods -n ${sandbox_ns}${NC}"
        echo "${RED}       Describe: kubectl describe deployment sandbox-router-deployment -n ${sandbox_ns}${NC}"
        echo "${RED}       If pods are in ImagePullBackOff, verify the image:${NC}"
        echo "${RED}         sudo ctr -n k8s.io images ls | grep sandbox-router${NC}"
        echo "${RED}       If pods are in ImagePullBackOff, verify the image:${NC}"
        echo "${RED}         sudo ctr -n k8s.io images ls | grep sandbox-router${NC}"
        exit 1
    fi
    echo "${GREEN}      sandbox-router is running.${NC}"

    # ── 8. Apply default SandboxTemplate ─────────────────────────────────────
    # Applied to the agent-sandbox namespace — same namespace as the
    # controller and sandbox-router so the NetworkPolicy allows connectivity.
    # The AGENT_SANDBOX_VERSION placeholder is substituted with the pinned
    # version before applying.
    echo ""
    echo "${CYAN}[8/8] Applying default SandboxTemplate (python-sandbox-template → ${sandbox_ns})...${NC}"

    if [[ ! -f "${local_templates}" ]]; then
        echo "${YELLOW}WARN: Default templates file not found: ${local_templates}${NC}"
        echo "${YELLOW}      Skipping SandboxTemplate creation.${NC}"
        echo "${YELLOW}      Create it manually at core/helm-charts/agent-sandbox/default-templates.yaml${NC}"
    else
        sed "s|AGENT_SANDBOX_VERSION|${sandbox_version}|g" "${local_templates}" \
            | kubectl apply -f -
        echo "${GREEN}      SandboxTemplate 'python-sandbox-template' applied in namespace '${sandbox_ns}'.${NC}"
    fi

    # ── Cleanup ───────────────────────────────────────────────────────────────
    echo ""
    echo "      Cleaning up build directory..."
    rm -rf "${build_dir}"

    # ── Deployment summary ────────────────────────────────────────────────────
    echo ""
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  Agent Sandbox deployed successfully!${NC}"
    echo "${GREEN}  Namespace  : ${sandbox_ns}${NC}"
    echo "${GREEN}  Version    : ${sandbox_version}${NC}"
    echo "${GREEN}${NC}"
    echo "${GREEN}  Controller : deployment/agent-sandbox-controller  (ns: ${sandbox_ns})${NC}"
    echo "${GREEN}  Router     : deployment/sandbox-router-deployment  (ns: ${sandbox_ns})${NC}"
    echo "${GREEN}  Router SVC : sandbox-router-svc.${sandbox_ns}.svc.cluster.local:8080${NC}"
    echo "${GREEN}${NC}"
    echo "${GREEN}  Installed CRDs (agents.x-k8s.io):${NC}"
    echo "${GREEN}    sandboxes           — core Sandbox lifecycle${NC}"
    echo "${GREEN}    sandboxtemplates    — reusable Sandbox templates${NC}"
    echo "${GREEN}    sandboxclaims       — claim-based Sandbox allocation${NC}"
    echo "${GREEN}    sandboxwarmpools    — pre-warmed pool management${NC}"
    echo "${GREEN}                          (infra ready; no pools pre-created)${NC}"
    echo "${GREEN}${NC}"
    echo "${GREEN}  Default SandboxTemplate:${NC}"
    echo "${GREEN}    python-sandbox-template (namespace: ${sandbox_ns})${NC}"
    echo "${GREEN}    Image: ${runtime_full_image} (imagePullPolicy: Never)${NC}"
    echo "${GREEN}============================================================${NC}"
    echo ""
    echo "${CYAN}  Python SDK quick-start:${NC}"
    echo "    pip install k8s-agent-sandbox"
    echo "    # Port-forward the router (or use in-cluster direct URL):"
    echo "    kubectl port-forward -n ${sandbox_ns} svc/sandbox-router-svc 8080:8080 &"
    echo ""
    echo "    from k8s_agent_sandbox import SandboxClient, SandboxDirectConnectionConfig"
    echo "    client = SandboxClient(SandboxDirectConnectionConfig(api_url='http://localhost:8080'))"
    echo "    sandbox = client.create_sandbox(template='python-sandbox-template', namespace='${sandbox_ns}')"
    echo "    print(sandbox.commands.run(\"echo 'Hello from Agent Sandbox!'\").stdout)"
    echo "    sandbox.terminate()"
    echo ""
    echo "${CYAN}  To add WarmPools later, apply a SandboxWarmPool CR:${NC}"
    echo "    https://agent-sandbox.sigs.k8s.io/docs/"
}
