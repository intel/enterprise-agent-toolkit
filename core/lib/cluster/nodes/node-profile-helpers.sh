# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Helpers for resolving per-node silicon fields from rack-profile.yaml at runtime.
# Sourced by add-node.sh and remove-node.sh.

# get_node_profile_field <node_name> <field>
#
# Reads core/inventory/rack-profile.yaml, resolves the node's profile: reference
# (profile fields are the base; node-level fields win on conflict), and prints
# the value of <field>. Prints empty string if the node or field is not present.
#
# Example:
#   accelerator=$(get_node_profile_field gnr-worker-01 accelerator)
#   gpu_form=$(get_node_profile_field gnr-worker-01 gpu_form)
#   node_family=$(get_node_profile_field gnr-worker-01 node_family)
get_node_profile_field() {
    local node_name="$1"
    local field="$2"
    local profile_file="${HOMEDIR}/inventory/rack-profile.yaml"

    if [[ ! -f "${profile_file}" ]]; then
        echo ""
        return 0
    fi

    python3 - "${profile_file}" "${node_name}" "${field}" <<'EOF'
import sys, yaml

profile_file, node_name, field = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    doc = yaml.safe_load(open(profile_file)) or {}
except Exception:
    print("")
    sys.exit(0)

profiles = doc.get("node_profiles") or {}
nodes = doc.get("nodes") or []

# Find the node entry
node_entry = None
for n in nodes:
    if n.get("name") == node_name:
        node_entry = n
        break

if node_entry is None:
    print("")
    sys.exit(0)

# Resolve profile merge: profile is the base, node-level fields win
merged = {}
profile_ref = node_entry.get("profile")
if profile_ref and profile_ref in profiles:
    merged.update(profiles[profile_ref])
merged.update(node_entry)

print(merged.get(field, ""))
EOF
}

# is_gpu_node <node_name>
# Returns 0 (true) if the node has an accelerator field in its resolved profile.
is_gpu_node() {
    local _accel
    _accel="$(get_node_profile_field "$1" accelerator)"
    [[ -n "${_accel}" ]]
}

# get_gpu_vendor <node_name>
# Prints the vendor portion of the accelerator field (e.g. "nvidia", "intel", "amd").
# accelerator format is <vendor>-<model>[-<form>], e.g. nvidia-b300-hgx
get_gpu_vendor() {
    local _accel
    _accel="$(get_node_profile_field "$1" accelerator)"
    echo "${_accel%%-*}"
}

# get_gpu_form <node_name>
# Prints the form factor (third dash-segment) or empty if not present.
# e.g. nvidia-b300-hgx → hgx   nvidia-h100-sxm → sxm   nvidia-h100 → ""
get_gpu_form() {
    local _accel
    _accel="$(get_node_profile_field "$1" accelerator)"
    # field 3 of dash-split; empty when fewer than 3 segments
    echo "${_accel}" | awk -F'-' '{print ($3 != "" ? $3 : "")}'
}
