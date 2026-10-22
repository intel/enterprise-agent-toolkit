# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

run_system_prerequisites_check() {
    echo "Running system prerequisites check..."
    echo "This will verify minimum system dependencies required for deployment."

    local missing_deps=()
    local warnings=()        
    echo "Checking essential system commands..."
    
    # Wait for dpkg lock to be released if present
    dpkg_lock_file="/var/lib/dpkg/lock"
    dpkg_lock_frontend="/var/lib/dpkg/lock-frontend"
    dpkg_lock_files=("$dpkg_lock_file" "$dpkg_lock_frontend")
    timeout=300
    for lock in "${dpkg_lock_files[@]}"; do
        waited=0
        if command -v lsof &>/dev/null; then
            while lsof "$lock" &>/dev/null && [ $waited -lt $timeout ]; do
                echo -e "${YELLOW}dpkg/apt process is using $lock (checked via lsof). Waiting for it to finish...${NC}"
                sleep 2
                waited=$((waited + 2))
            done
        elif command -v fuser &>/dev/null; then
            while fuser "$lock" &>/dev/null && [ $waited -lt $timeout ]; do
                echo -e "${YELLOW}dpkg/apt process is using $lock (checked via fuser). Waiting for it to finish...${NC}"
                sleep 2
                waited=$((waited + 2))
            done
        fi
        if [ $waited -ge $timeout ]; then
            if (command -v lsof &>/dev/null && lsof "$lock" &>/dev/null) || \
            (command -v fuser &>/dev/null && fuser "$lock" &>/dev/null); then
                echo -e "${RED}Timeout waiting for dpkg/apt lock file $lock to be released. Proceeding anyway.${NC}"
            fi
        fi
    done

    # Check for git
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    else
        echo -e "${GREEN}✓ git found${NC}"
    fi

    # Check for conntrack (required by kubeadm preflight)
    if ! command -v conntrack &> /dev/null; then
        missing_deps+=("conntrack")
    else
        echo -e "${GREEN}✓ conntrack found${NC}"
    fi

    # Check for socat (required by kubeadm preflight)
    if ! command -v socat &> /dev/null; then
        missing_deps+=("socat")
    else
        echo -e "${GREEN}✓ socat found${NC}"
    fi

    # Check for ebtables (required by kubeadm preflight)
    if ! command -v ebtables &> /dev/null; then
        missing_deps+=("ebtables")
    else
        echo -e "${GREEN}✓ ebtables found${NC}"
    fi
    
    


    # Check for python3 (version 3.10 or above) using configured interpreter
    if [ -z "$python3_interpreter" ]; then
        echo -e "${RED}✗ python3_interpreter not configured${NC}"
        missing_deps+=("python3 (interpreter not configured)")
    elif ! command -v "$python3_interpreter" &> /dev/null; then
        echo -e "${RED}✗ configured python interpreter not found: $python3_interpreter${NC}"
        missing_deps+=("python3")
    else
        # Check Python version using the configured interpreter
        python_version=$($python3_interpreter -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        if $python3_interpreter -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null; then
            echo -e "${GREEN}✓ python3 found (version $python_version) at $python3_interpreter${NC}"
        else
            echo -e "${RED}✗ python3 version $python_version found at $python3_interpreter, but version 3.10+ required${NC}"
            missing_deps+=("python3 (version 3.10+)")
        fi
    fi
    
    # Check for curl (needed for pip installation)
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    else
        echo -e "${GREEN}✓ curl found${NC}"
    fi
    
    # Check internet connectivity on the bastion/management node (NOT the fabric NICs).
    # Default: check runs; a warning (not a failure) is issued if unreachable.
    # To suppress: set air_gapped=on in agentic-config.cfg (air-gapped / local-mirror sites).
    echo "Checking internet connectivity..."
    if [[ "${AIR_GAPPED:-false}" == "true" ]]; then
        warnings+=("Internet connectivity check skipped (air_gapped=on). Ensure a local registry/mirror is configured.")
        echo -e "${YELLOW}  ! Internet check skipped — air_gapped=on${NC}"
    elif command -v curl &> /dev/null; then
        # Test multiple reliable endpoints to ensure connectivity
        if curl -s --connect-timeout 10 --max-time 15 https://google.com > /dev/null 2>&1 || \
           curl -s --connect-timeout 10 --max-time 15 https://github.com > /dev/null 2>&1 || \
           curl -s --connect-timeout 10 --max-time 15 https://registry-1.docker.io > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Internet connectivity confirmed${NC}"
        else
            echo -e "${YELLOW}! No internet connectivity detected${NC}"
            warnings+=("No internet connectivity — deployment requires local mirrors for container images, packages, and Git repos. Set air_gapped=on in agentic-config.cfg to suppress this warning.")
        fi
    else
        # curl not yet available; will be re-checked after install
        warnings+=("Internet connectivity check skipped - curl not available")
    fi
    
    # Check if pip is available for the configured Python interpreter
    if [ -n "$python3_interpreter" ]; then
        if ! $python3_interpreter -m pip --version &> /dev/null; then
            missing_deps+=("pip")
        else
            pip_version=$($python3_interpreter -m pip --version 2>/dev/null | cut -d' ' -f2)
            echo -e "${GREEN}✓ pip found for $python3_interpreter (version $pip_version)${NC}"
        fi
    else
        warnings+=("python3_interpreter not configured - pip check skipped")
    fi
    
    # Check for virtualenv capability (can be installed via pip)
    if [ -n "$python3_interpreter" ] && ! $python3_interpreter -c "import venv" &> /dev/null && ! $python3_interpreter -c "import virtualenv" &> /dev/null; then
        warnings+=("virtualenv not available - will be installed during setup")
    else
        echo -e "${GREEN}✓ virtualenv capability found${NC}"
    fi
    
    # Display warnings
    if [ ${#warnings[@]} -gt 0 ]; then
        echo -e "${YELLOW}Warnings:${NC}"
        for warning in "${warnings[@]}"; do
            echo -e "${YELLOW}  ! $warning${NC}"
        done
    fi
    

    echo "Updating system package lists..."
    if command -v apt &> /dev/null; then
        echo "Updating package lists using apt Ubuntu..."
        if sudo apt update; then
            echo -e "${GREEN}Package lists updated successfully${NC}"
        else
            echo -e "${YELLOW}Package list update failed, continuing anyway${NC}"
        fi
    elif command -v dnf &> /dev/null; then
        echo "Updating package lists using dnf (RHEL/CentOS)..."
        if sudo dnf check-update || [ $? -eq 100 ]; then
            echo -e "${GREEN} Package lists updated successfully${NC}"
        else
            echo -e "${YELLOW} Package list update failed, continuing anyway${NC}"
        fi
    else
        echo -e "${YELLOW}Unknown package manager, skipping package list update${NC}"
    fi
    echo ""

    # Check if any critical dependencies are missing and handle appropriately
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}Missing critical system dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo -e "${RED}  - $dep${NC}"
        done
        echo ""
        
        # Separate Python/pip issues and installable dependencies
        local python_issues=()
        local installable_deps=()

        for dep in "${missing_deps[@]}"; do
            if [[ "$dep" == "python3"* ]]; then
                python_issues+=("$dep")
            else
                installable_deps+=("$dep")
            fi
        done

        # Handle Python issues first - EXIT IMMEDIATELY (no user acknowledgment)
        if [ ${#python_issues[@]} -gt 0 ]; then
            echo -e "${RED}Critical Python requirements not met:${NC}"
            for issue in "${python_issues[@]}"; do
                echo -e "${RED}  - $issue${NC}"
            done
            echo ""
            echo -e "${YELLOW}Python 3.10+ is required for Intel® AI for Enterprise Agent Toolkit deployment.${NC}"
            echo -e "${YELLOW}Please install/configure Python 3.10+ and set python3_interpreter, then try again.${NC}"
            echo -e "${YELLOW}RHEL: dnf install python3 python3-pip${NC}"
            echo -e "${YELLOW}Ubuntu: apt update && apt install python3 python3-pip${NC}"
            exit 1
        fi
        
        # Handle installable dependencies (git, curl) with user acknowledgment
        if [ ${#installable_deps[@]} -gt 0 ]; then
            echo -e "${YELLOW}The following dependencies can be installed automatically:${NC}"
            for dep in "${installable_deps[@]}"; do
                echo -e "${YELLOW}  - $dep${NC}"
            done
            echo ""
            install_deps="yes"
            
            if [[ "$install_deps" =~ ^(yes|y|Y)$ ]]; then
                # Separate pip from other dependencies
                local pip_needed=false
                local other_deps=()
                
                for dep in "${installable_deps[@]}"; do
                    if [[ "$dep" == "pip" ]]; then
                        pip_needed=true
                    else
                        other_deps+=("$dep")
                    fi
                done
                
                # Install regular dependencies first (git, curl, conntrack, socat, ebtables)
                if [ ${#other_deps[@]} -gt 0 ]; then
                    if command -v dnf &> /dev/null; then
                        echo "Installing dependencies using dnf RHEL..."
                        # conntrack binary is in conntrack-tools on RHEL/CentOS
                        rhel_deps=()
                        for d in "${other_deps[@]}"; do
                            [[ "$d" == "conntrack" ]] && rhel_deps+=("conntrack-tools") || rhel_deps+=("$d")
                        done
                        sudo dnf install -y "${rhel_deps[@]}"
                    elif command -v apt &> /dev/null; then
                        echo "Installing dependencies using apt Ubuntu..."
                        sudo apt update && sudo apt install -y "${other_deps[@]}"
                    else
                        echo -e "${RED}Unsupported package manager. This script supports RHEL (dnf) and Ubuntu (apt) only.${NC}"
                        echo -e "${YELLOW}Please install manually:${NC}"
                        echo -e "${YELLOW}  RHEL: dnf install conntrack-tools socat ebtables ${other_deps[*]}${NC}"
                        echo -e "${YELLOW}  Ubuntu: apt install ${other_deps[*]}${NC}"
                        exit 1
                    fi
                fi
                
                # Install pip using system package manager if needed
                if [ "$pip_needed" = true ]; then
                    echo "Installing pip using system package manager..."
                    if command -v dnf &> /dev/null; then
                        python_version=$($python3_interpreter -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
                        if [[ "$python_version" == "3.11" ]]; then
                            echo "Installing python3.11-pip using dnf (RHEL 9)..."
                            if ! sudo dnf install -y python3.11-pip; then
                                echo -e "${RED}Failed to install python3.11-pip using dnf${NC}"
                                exit 1
                            fi
                        elif [[ "$python_version" == "3.12" ]]; then
                            echo "Installing python3.12-pip using dnf (RHEL 9)..."
                            if ! sudo dnf install -y python3.12-pip; then
                                echo -e "${RED}Failed to install python3.12-pip using dnf${NC}"
                                exit 1
                            fi
                        else
                            echo "Installing python3-pip using dnf (RHEL 9)..."
                            if ! sudo dnf install -y python3-pip; then
                                echo -e "${RED}Failed to install python3-pip using dnf${NC}"
                                exit 1
                            fi
                        fi
                    elif command -v apt &> /dev/null; then
                        echo "Installing python3-pip using apt (Ubuntu 22/24)..."
                        if ! sudo apt install -y python3-pip; then
                            echo -e "${RED}Failed to install python3-pip using apt${NC}"
                            exit 1
                        fi
                    else
                        echo -e "${RED}Unsupported system. This deployment only supports Ubuntu 22/24 and RHEL 9.4${NC}"
                        exit 1
                    fi
                fi
                
                # Verify installation
                local install_failed=()
                for dep in "${installable_deps[@]}"; do
                    if [[ "$dep" == "pip" ]]; then
                        if ! $python3_interpreter -m pip --version &> /dev/null; then
                            install_failed+=("$dep")
                        fi
                    else
                        if ! command -v "$dep" &> /dev/null; then
                            install_failed+=("$dep")
                        fi
                    fi
                done
                
                if [ ${#install_failed[@]} -gt 0 ]; then
                    echo -e "${RED}Failed to install: ${install_failed[*]}${NC}"
                    echo -e "${YELLOW}Please install them manually and try again.${NC}"
                    exit 1
                else
                    echo -e "${GREEN}All dependencies installed successfully!${NC}"
                fi
            else
                echo -e "${YELLOW}Installation cancelled. Please install the dependencies manually:${NC}"
                echo -e "${YELLOW}  RHEL: sudo dnf install ${installable_deps[*]}${NC}"
                echo -e "${YELLOW}  Ubuntu: sudo apt install ${installable_deps[*]}${NC}"
                exit 1
            fi
        fi
    fi
    
    echo -e "${GREEN}System prerequisites check completed successfully.${NC}"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Docker fail-fast check (all nodes)
# ──────────────────────────────────────────────────────────────────────────────
# Runs playbooks/precheck-docker.yml against every node in the inventory and
# aborts if Docker is found anywhere. Deliberately a detection-only check: it
# never purges packages or touches iptables. See precheck-docker.yml for the
# full rationale — in short, the Docker daemon sets the iptables FORWARD policy
# to DROP, which silently blackholes pod and fabric traffic, and its containerd
# can shadow the kubespray-managed one.
#
# Called before Kubernetes installation, so the operator finds out in seconds
# rather than minutes into a run that fails inside etcd or Calico.
run_docker_precheck() {
    local _play="${HOMEDIR}/playbooks/precheck-docker.yml"
    local _inv="${HOMEDIR}/inventory/hosts.yaml"

    if [[ ! -f "${_play}" ]]; then
        echo -e "${YELLOW}Docker precheck playbook not found at ${_play} — skipping.${NC}"
        return 0
    fi
    if [[ ! -f "${_inv}" ]]; then
        echo -e "${YELLOW}Inventory not found at ${_inv} — skipping Docker precheck.${NC}"
        return 0
    fi

    echo "Checking all nodes for Docker (must not be installed alongside Kubernetes)..."
    # any_errors_fatal so ONE dirty node stops the run — otherwise the failure is
    # buried in a PLAY RECAP and the deployment carries on toward a broken cluster.
    if ! ansible-playbook -i "${_inv}" "${_play}" -e any_errors_fatal=true; then
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        echo -e "${RED}|  Docker was found on one or more nodes.                                  |${NC}"
        echo -e "${RED}|  Remove it manually (see the instructions above) and re-run.              |${NC}"
        echo -e "${RED}----------------------------------------------------------------------------${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ No Docker found on any node.${NC}"
    return 0
}