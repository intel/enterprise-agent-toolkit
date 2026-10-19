#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# rack-profile-parser.sh
#
# Reads core/inventory/rack-profile.yaml and generates:
#   - core/inventory/hosts.yaml
#   - core/inventory/metadata/k8s-net-fabric.yml
#   - core/inventory/metadata/vars/ceph-storage.yml
#
# Usage:
#   ./core/lib/rack-profile-parser.sh [--dry-run] [--profile <path>]
#
# Options:
#   --profile <path>   Path to rack-profile.yaml (default: core/inventory/rack-profile.yaml)
#   --dry-run          Print generated files to stdout without writing
#   --help             Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE_FILE="${CORE_DIR}/inventory/rack-profile.yaml"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)  PROFILE_FILE="$2";  shift 2 ;;
    --dry-run)  DRY_RUN=true;       shift ;;
    --help|-h)
      sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,2\}//; p }' "$0"
      exit 0 ;;
    *) echo "Unknown argument: $1. Use --help for usage."; exit 1 ;;
  esac
done

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required"; exit 1
fi
if ! python3 -c "import yaml" &>/dev/null; then
  echo "ERROR: PyYAML required. pip3 install pyyaml"; exit 1
fi
if [[ ! -f "${PROFILE_FILE}" ]]; then
  echo "ERROR: Profile not found: ${PROFILE_FILE}"; exit 1
fi

python3 - "${PROFILE_FILE}" "${DRY_RUN}" "${CORE_DIR}" << 'PYEOF'
import sys, os, yaml

profile_file  = sys.argv[1]
dry_run       = sys.argv[2].lower() == "true"
core_dir      = sys.argv[3]
inventory_dir = os.path.join(core_dir, "inventory")

with open(profile_file) as f:
    profile = yaml.safe_load(f)

site         = profile.get("site", {})
network      = profile.get("network", {})
racks        = profile.get("racks", {})
storage      = profile.get("storage", {})

# ── node_profiles ─────────────────────────────────────────────────────────────
# Defines silicon once; individual nodes reference by name via `profile:`.
node_profiles = profile.get("node_profiles", {})

site_name        = site.get("name", "unknown")
calico_mode              = network.get("calico_mode", "vxlan")
leafs                    = network.get("leafs", [])
cluster_asn              = network.get("bgp", {}).get("cluster_asn", 65100)
pod_cidr                 = network.get("pod_cidr", "10.244.0.0/16")
service_cidr             = network.get("service_cidr", "10.96.0.0/12")
fabric_mtu               = network.get("mtu", 9000)
# VXLAN encapsulation overhead subtracted from the link MTU to get the pod MTU.
# 50 bytes for IPv4 VXLAN (outer IP 20 + UDP 8 + VXLAN 8 + inner Ethernet 14).
vxlan_overhead           = network.get("vxlan_overhead", 50)
cp_on_fabric             = network.get("control_plane_on_fabric", False)
# 'mgmt_nic' (site-wide and per-node) is no longer read. It fed Calico's
# interface=<nic> autodetection for CP nodes off the fabric; kubespray's
# can-reach=$(NODEIP) default supersedes it and resolves per-node, so a NIC name
# is neither needed nor safe (calico-node is one cluster-wide DaemonSet, so a
# single name is only ever correct when identical on every host). Profiles still
# carrying the key parse fine — it is ignored, with a NOTE emitted below.
# Fabric topology: 'clos' (leaf/spine with ToR gateways — the proven default) or
# 'star' (switchless hub-and-spoke; one node routes between point-to-point links).
# Defaults to 'clos' so existing sites are unaffected by this key's introduction.
topology                 = network.get("topology", "clos")
# Default on-link prefix length for fabric NICs. Clos sites share one flat subnet
# per leaf (/16); star sites use per-cable /30s declared per NIC.
fabric_prefix            = network.get("fabric_prefix", 16)
# Netplan renderer — 'networkd' or 'NetworkManager'. Sites running NetworkManager
# must set this or the generated file fights the existing renderer.
netplan_renderer         = network.get("netplan_renderer", "networkd")
# SSH defaults for non-bastion nodes; overridable per node in the rack profile.
access                   = profile.get("access", {})
default_ansible_user     = access.get("ansible_user", "ubuntu")
default_ssh_key          = access.get("ansible_ssh_private_key_file", "~/.ssh/id_ed25519")

# Migration: old profiles put ssh_private_key_file under site: instead of access:.
# Auto-migrate silently so existing profiles keep working, but warn so operators
# know to update their file — the site: key will stop being read in a future version.
_legacy_ssh_key = site.get("ssh_private_key_file")
if _legacy_ssh_key:
    print(f"  WARNING: site.ssh_private_key_file is deprecated. "
          f"Move it to access.ansible_ssh_private_key_file in rack-profile.yaml. "
          f"Auto-migrating for this run: {_legacy_ssh_key}")
    default_ssh_key = _legacy_ssh_key
ceph_nic         = storage.get("ceph_fabric_nic", "")
ceph_public_net  = storage.get("ceph_public_network", "")
ceph_cluster_net = storage.get("ceph_cluster_network", "")

# Build leaf lookup by name for cross-leaf route generation
leaf_by_name = {l["name"]: l for l in leafs}

# ── Schema: valid keys per block ──────────────────────────────────────────────
# Unknown keys are hard errors so typos (gpu_counts vs gpu_count) surface immediately.
VALID_PROFILE_KEYS = {
    "node_family", "sku", "accelerator", "gpu_count",
}
VALID_NODE_KEYS = {
    "hostname", "mgmt_ip", "local", "roles", "fabric_nics", "fabric_router",
    "ceph_fabric_nic", "ansible_user", "ansible_ssh_private_key_file",
    "node_family", "sku", "accelerator", "gpu_count", "rdma_nics",
    "profile",
    # meta keys injected by the parser
    "_rack",
    # legacy / deprecated (warned, not errored)
    "mgmt_nic",
}
VALID_FABRIC_NIC_KEYS = {
    "nic", "fabric_ip", "prefix", "leaf", "peer",
}
KNOWN_CPU_FAMILIES = {"cpu-gnr-ap", "cpu-gnr-sp", "cpu-cwf", "cpu-spr"}
VALID_ACCELERATOR_VENDORS = {"nvidia", "intel", "amd"}

schema_errors = []

def _check_keys(block, valid, path):
    for k in block:
        if k not in valid:
            schema_errors.append(f"unknown field '{k}' in {path} — typo?")

for prof_name, prof in (node_profiles or {}).items():
    if not isinstance(prof, dict):
        schema_errors.append(f"node_profiles.{prof_name} must be a mapping")
        continue
    _check_keys(prof, VALID_PROFILE_KEYS, f"node_profiles.{prof_name}")
    if "gpu_count" in prof and not isinstance(prof["gpu_count"], int):
        schema_errors.append(
            f"node_profiles.{prof_name}.gpu_count must be an integer, "
            f"got {type(prof['gpu_count']).__name__!r}")

# ── node_profiles resolution ──────────────────────────────────────────────────
# Flatten nodes preserving rack membership, then resolve `profile:` references.
all_nodes = {}
for rack_name, rack in racks.items():
    for node_name, node_cfg in (rack.get("nodes") or {}).items():
        node_cfg["_rack"] = rack_name
        all_nodes[node_name] = node_cfg

for node_name, node in all_nodes.items():
    _check_keys(node, VALID_NODE_KEYS, f"node '{node_name}'")
    for i, fn in enumerate(node.get("fabric_nics", [])):
        _check_keys(fn, VALID_FABRIC_NIC_KEYS, f"node '{node_name}' fabric_nics[{i}]")
    if "gpu_count" in node and not isinstance(node["gpu_count"], int):
        schema_errors.append(
            f"node '{node_name}' gpu_count must be an integer, "
            f"got {type(node['gpu_count']).__name__!r}")

if schema_errors:
    print("\nERROR: rack-profile.yaml schema validation failed:", file=sys.stderr)
    for e in schema_errors:
        print(f"  • {e}", file=sys.stderr)
    print("\nNo files were generated. Fix the above and re-run.", file=sys.stderr)
    sys.exit(1)

# Resolve profile references. Node-level keys WIN over profile keys (spread merge).
profile_resolve_errors = []
for node_name, node in all_nodes.items():
    prof_ref = node.get("profile")
    if prof_ref is None:
        continue
    if prof_ref not in node_profiles:
        profile_resolve_errors.append(
            f"node '{node_name}' references unknown profile '{prof_ref}' "
            f"(valid: {', '.join(sorted(node_profiles.keys())) or 'none'})")
        continue
    # Merge: profile fields are the base; explicit node fields override.
    merged = {**node_profiles[prof_ref], **node}
    all_nodes[node_name] = merged

if profile_resolve_errors:
    print("\nERROR: profile resolution failed:", file=sys.stderr)
    for e in profile_resolve_errors:
        print(f"  • {e}", file=sys.stderr)
    print("\nNo files were generated. Fix the above and re-run.", file=sys.stderr)
    sys.exit(1)

# ── Per-node silicon validation ───────────────────────────────────────────────
silicon_errors = []
for node_name, node in all_nodes.items():
    accel = node.get("accelerator")
    node_family = node.get("node_family")
    if accel:
        if not node_family:
            silicon_errors.append(
                f"node '{node_name}' has accelerator='{accel}' but no node_family "
                f"(set it directly or via profile:)")
        if not node.get("gpu_count"):
            silicon_errors.append(
                f"node '{node_name}' has accelerator='{accel}' but no gpu_count — required")
        # Validate accelerator format: vendor-model[-form]
        parts = accel.split("-")
        if len(parts) < 2:
            silicon_errors.append(
                f"node '{node_name}' accelerator='{accel}' must follow vendor-model[-form] format")
        else:
            vendor = parts[0]
            if vendor not in VALID_ACCELERATOR_VENDORS:
                silicon_errors.append(
                    f"node '{node_name}' accelerator='{accel}' has unknown vendor '{vendor}' "
                    f"(valid: {', '.join(sorted(VALID_ACCELERATOR_VENDORS))})")
        rdma_nics = node.get("rdma_nics", [])
        form = parts[-1] if len(parts) >= 3 else ""
        if form == "hgx" and not rdma_nics:
            print(f"  WARNING: node '{node_name}' has form=hgx but no rdma_nics declared",
                  file=sys.stderr)
    elif node.get("gpu_count"):
        silicon_errors.append(
            f"node '{node_name}' has gpu_count but no accelerator — "
            f"gpu_count requires accelerator to be set")

if silicon_errors:
    print("\nERROR: GPU/accelerator validation failed:", file=sys.stderr)
    for e in silicon_errors:
        print(f"  • {e}", file=sys.stderr)
    print("\nNo files were generated. Fix the above and re-run.", file=sys.stderr)
    sys.exit(1)

# Warn (not error) for nodes with no node_family — backwards-compat with pre-GPU profiles.
for node_name, node in all_nodes.items():
    if not node.get("node_family") and not node.get("profile"):
        if node.get("accelerator"):
            pass  # already caught above as hard error
        else:
            print(f"  WARNING: node '{node_name}' has no node_family or profile — "
                  f"cpu-gen label will not be emitted (backwards-compatible, not an error)",
                  file=sys.stderr)

leaf_names = {l["name"] for l in leafs}

# Roles the parser acts on. Anything else is a typo or an unimplemented feature —
# both silently produced no inventory group before, so warn rather than ignore.
KNOWN_ROLES = {"kube_control_plane", "kube_node", "etcd", "storage",
               "gnr_ap", "gnr_sp", "cwf", "spr"}

def nic_prefix(fn):
    """On-link prefix length for one fabric NIC — per-NIC override, else site default."""
    return fn.get("prefix", fabric_prefix)

def node_ceph_nic(node):
    """Ceph fabric NIC for one node — per-node override, else the site-wide default."""
    return node.get("ceph_fabric_nic", ceph_nic)

def ecmp_nodes():
    """
    Nodes that can actually load-balance across multiple fabric uplinks.

    ECMP needs two or more equal-cost paths to the SAME destination, which
    requires per-NIC upstream routers advertising overlapping prefixes:

      1. >= 2 fabric NICs, each facing a router with a usable next-hop, AND
      2. a routing protocol installing multipath routes (calico_mode=bgp).

    In a Clos fabric both NICs peer with distinct leaves that each reach every
    pod prefix, so multipath forms. In a star the hub's legs are the sole path
    to their own point-to-point subnet, so no two paths are ever equal-cost and
    this returns nothing — no topology special-case needed, it falls out of the
    same rule. Static-routed fabrics are excluded too: without BGP nothing
    installs a second route for the kernel to hash over.
    """
    if calico_mode != "bgp":
        return []

    result = []
    for name, cfg in sorted(all_nodes.items()):
        routed = 0
        for fn in cfg.get("fabric_nics", []):
            leaf = leaf_by_name.get(fn.get("leaf"))
            if leaf and leaf.get("peer_ip", "TBD") != "TBD":
                routed += 1
        if routed >= 2:
            result.append(name)
    return result

def node_primary_nic(node):
    """
    The fabric NIC carrying the node's own address — the one that becomes
    ip/access_ip. Secondary NICs are extra uplinks (Clos ECMP) or transit legs
    (star hub); neither may be published as the node IP.
    """
    fnics = node.get("fabric_nics", [])
    return fnics[0] if fnics else None


def fabric_supernets():
    """Every prefix carrying fabric traffic, as on-link supernets.

    Needs the WIDEST safe form: cover all fabric traffic in as few firewall
    rules as possible. Includes ALL fabric NICs, primary and secondary — a star hub's
    transit legs and a Clos node's secondary uplinks carry real traffic and must
    be permitted to forward.
    """
    import ipaddress
    nets = []
    for _, node in sorted(all_nodes.items()):
        for fn in node.get("fabric_nics", []):
            if not fn.get("fabric_ip"):
                continue
            net = ipaddress.ip_network(f"{fn['fabric_ip']}/{nic_prefix(fn)}", strict=False)
            if net not in nets:
                nets.append(net)
    # Drop any prefix already contained in another, so overlapping profile
    # entries do not produce redundant firewall rules.
    merged = [n for n in nets if not any(n != o and n.subnet_of(o) for o in nets)]
    return [str(n) for n in sorted(merged, key=lambda n: (n.network_address, n.prefixlen))]


def fabric_addressing_conflicts():
    """
    Nodes whose fabric addressing is ambiguous, as [(node, reason)].

    Checks the PROFILE, not any generated Calico value. Calico now selects each
    node's address via can-reach against its own --node-ip, so it can no longer
    pick a neighbour's address. But a node whose own on-link prefixes overlap is
    still misaddressed at the routing layer, which shows up as an unreachable
    fabric IP or an unformed etcd quorum rather than a generation error.

    Two failure modes:
      1. Two of the node's OWN fabric NICs share an on-link prefix. The kernel
         then has two routes to the same subnet on two interfaces and picks the
         source address by route order, so which NIC serves that prefix is not
         deterministic. In a star this means the hub's transit legs collide.
      2. The node's PRIMARY address is inside another NIC's on-link prefix.
         The primary is what becomes ip/access_ip, so it must be served by its
         own NIC, not shadowed by a secondary uplink.

    A star hub is expected to hold several /30s; that is fine because they do not
    overlap. Only genuine overlap is reported.
    """
    import ipaddress
    conflicts = []
    for name, node in sorted(all_nodes.items()):
        fnics = [fn for fn in node.get("fabric_nics", []) if fn.get("fabric_ip")]
        if len(fnics) < 2:
            continue
        nets = {}
        for fn in fnics:
            net = ipaddress.ip_network(f"{fn['fabric_ip']}/{nic_prefix(fn)}", strict=False)
            nets.setdefault(net, []).append(fn)
        for net, sharing in sorted(nets.items(), key=lambda kv: str(kv[0])):
            if len(sharing) > 1:
                addrs = ", ".join(f"{fn['nic']}={fn['fabric_ip']}/{nic_prefix(fn)}" for fn in sharing)
                conflicts.append(
                    (name, f"{len(sharing)} of its own fabric NICs share the on-link prefix "
                           f"{net} ({addrs}) — the kernel cannot deterministically choose "
                           f"which NIC serves it"))
        primary = node_primary_nic(node)
        if primary and primary.get("fabric_ip"):
            paddr = ipaddress.ip_address(primary["fabric_ip"])
            for fn in fnics:
                if fn is primary:
                    continue
                net = ipaddress.ip_network(f"{fn['fabric_ip']}/{nic_prefix(fn)}", strict=False)
                pnet = ipaddress.ip_network(f"{primary['fabric_ip']}/{nic_prefix(primary)}",
                                            strict=False)
                if paddr in net and net != pnet:
                    conflicts.append(
                        (name, f"primary {primary['nic']}={primary['fabric_ip']} falls inside "
                               f"the prefix {net} of secondary {fn['nic']}={fn['fabric_ip']} — "
                               f"the address published as ip/access_ip would be routed out the "
                               f"wrong NIC"))
    return conflicts


def unusable_fabric_addresses():
    """Fabric IPs that are not assignable host addresses on their own prefix.

    On a /30 only two of the four addresses are usable: the first is the network
    address and the last is the broadcast address. Assigning either leaves the
    NIC with an address the kernel will not source traffic from, and — because
    the two ends then compute different subnets — silently breaks the on-link
    relationship the star model depends on.

    Netplan accepts such an address without complaint and the interface comes up
    looking configured, so this has to be caught here. Skipped for prefixes with
    no distinct network/broadcast address (/31 point-to-point and /32 host).
    """
    import ipaddress
    bad = []
    for name, node in sorted(all_nodes.items()):
        for fn in node.get("fabric_nics", []):
            if not fn.get("fabric_ip"):
                continue
            pfx = nic_prefix(fn)
            if pfx >= 31:
                continue
            iface = ipaddress.ip_interface(f"{fn['fabric_ip']}/{pfx}")
            net = iface.network
            usable = f"{list(net.hosts())[0]}-{list(net.hosts())[-1]}"
            if iface.ip == net.network_address:
                bad.append((name, f"NIC '{fn.get('nic')}' fabric_ip {iface.ip}/{pfx} is the "
                                  f"NETWORK address of {net} — not assignable. "
                                  f"Usable in this block: {usable}"))
            elif iface.ip == net.broadcast_address:
                bad.append((name, f"NIC '{fn.get('nic')}' fabric_ip {iface.ip}/{pfx} is the "
                                  f"BROADCAST address of {net} — not assignable. "
                                  f"Usable in this block: {usable}"))
    return bad


def star_cable_faults():
    """Star cables whose two ends are not on the same on-link prefix.

    'peer:' declares the node at the other end of a cable, so the two ends must
    land in one subnet — that is what makes the next hop on-link and lets the hub
    route rather than blackhole. When they do not match, the spoke gets no route
    to the fabric and falls back to its management default gateway: the interface
    is up, the address is configured, and every fabric destination times out.
    That failure surfaces much later as an opaque kubeadm/etcd timeout, so it is
    an error here rather than a warning.
    """
    import ipaddress
    faults = []
    by_name = all_nodes
    for name, node in sorted(all_nodes.items()):
        for fn in node.get("fabric_nics", []):
            peer = fn.get("peer")
            if not peer or not fn.get("fabric_ip"):
                continue
            peer_cfg = by_name.get(peer)
            if peer_cfg is None:
                continue  # already reported as an undefined-peer error
            my_net = ipaddress.ip_network(f"{fn['fabric_ip']}/{nic_prefix(fn)}", strict=False)
            # The peer must have a NIC pointing back at us on the same subnet.
            back = [pfn for pfn in peer_cfg.get("fabric_nics", [])
                    if pfn.get("fabric_ip")
                    and ipaddress.ip_address(pfn["fabric_ip"]) in my_net]
            if not back:
                peer_addrs = ", ".join(
                    f"{p.get('nic')}={p.get('fabric_ip')}/{nic_prefix(p)}"
                    for p in peer_cfg.get("fabric_nics", []) if p.get("fabric_ip")) or "none"
                faults.append(
                    (name, f"NIC '{fn.get('nic')}' {fn['fabric_ip']}/{nic_prefix(fn)} declares "
                           f"peer '{peer}', but no NIC on '{peer}' is in {my_net}. "
                           f"'{peer}' has: {peer_addrs}. Both ends of a cable must share one "
                           f"/{nic_prefix(fn)} or the link is not on-link and no route is generated"))
    return faults


# ── Validation ────────────────────────────────────────────────────────────────
# Fail fast on contradictions that otherwise surface as a half-built cluster:
# duplicate IPs silently give two nodes the same etcd identity, and an unknown
# leaf/role silently drops a node out of the group it was meant to join.
errors = []

if topology not in ("clos", "star"):
    errors.append(f"network.topology '{topology}' is invalid — expected 'clos' or 'star'")

if calico_mode == "bgp":
    for leaf in leafs:
        if leaf.get("peer_ip", "TBD") == "TBD":
            print(f"  WARNING: leaf '{leaf['name']}' peer_ip is TBD — configure before enabling BGP", file=sys.stderr)

for node_name, node in all_nodes.items():
    for fn in node.get("fabric_nics", []):
        if fn.get("leaf") and fn["leaf"] not in leaf_names:
            print(f"  WARNING: node '{node_name}' references unknown leaf '{fn['leaf']}'", file=sys.stderr)
    for role in node.get("roles", []):
        if role not in KNOWN_ROLES:
            print(f"  WARNING: node '{node_name}' has unrecognized role '{role}' — "
                  f"no inventory group will be generated for it "
                  f"(known: {', '.join(sorted(KNOWN_ROLES))})", file=sys.stderr)

# Duplicate address detection — collect every claim, then report collisions.
_mgmt_claims = {}
_fabric_claims = {}
for node_name, node in all_nodes.items():
    mgmt = node.get("mgmt_ip")
    if mgmt:
        _mgmt_claims.setdefault(mgmt, []).append(node_name)
    for fn in node.get("fabric_nics", []):
        fip = fn.get("fabric_ip")
        if fip:
            _fabric_claims.setdefault(fip, []).append(f"{node_name}:{fn.get('nic','?')}")

for ip, owners in sorted(_mgmt_claims.items()):
    if len(owners) > 1:
        errors.append(f"duplicate mgmt_ip {ip} claimed by: {', '.join(owners)}")
for ip, owners in sorted(_fabric_claims.items()):
    if len(owners) > 1:
        errors.append(f"duplicate fabric_ip {ip} claimed by: {', '.join(owners)}")

# Storage nodes must actually carry the NIC that Ceph will bind to. Rook's
# host-network provider with a NIC selector brings OSDs up and then fails to
# peer if the name is wrong, which is far harder to diagnose than this check.
for node_name, node in all_nodes.items():
    if "storage" not in node.get("roles", []):
        continue
    want = node_ceph_nic(node)
    if not want:
        continue
    have = [fn.get("nic") for fn in node.get("fabric_nics", [])]
    if want not in have:
        print(f"  WARNING: storage node '{node_name}' has no NIC named '{want}' "
              f"(ceph_fabric_nic); found: {', '.join(have) or 'none'}", file=sys.stderr)

# Star topology invariants: exactly one hub must forward between the spokes.
if topology == "star":
    routers = [n for n, cfg in all_nodes.items() if cfg.get("fabric_router")]
    if len(routers) == 0:
        errors.append("network.topology=star requires exactly one node with "
                      "'fabric_router: true' — no node declares it")
    elif len(routers) > 1:
        errors.append("network.topology=star supports one hub, but "
                      f"{len(routers)} nodes declare 'fabric_router: true': {', '.join(routers)}")
    for node_name, node in all_nodes.items():
        for fn in node.get("fabric_nics", []):
            peer = fn.get("peer")
            if peer and peer not in all_nodes:
                errors.append(f"node '{node_name}' NIC '{fn.get('nic','?')}' "
                              f"declares peer '{peer}' which is not a defined node")
elif any(cfg.get("fabric_router") for cfg in all_nodes.values()):
    print("  WARNING: 'fabric_router: true' is set but network.topology is not 'star' "
          "— the flag will be ignored", file=sys.stderr)

# mgmt_nic is obsolete and ignored — say so rather than letting an operator
# believe they have pinned Calico's interface on the control plane.
if network.get("mgmt_nic") or any(cfg.get("mgmt_nic") for cfg in all_nodes.values()):
    print("  NOTE: 'mgmt_nic' is set but is obsolete and ignored. Calico selects "
          "each node's address via kubespray's can-reach=$(NODEIP), which resolves "
          "per-node from the kubelet's --node-ip (this parser's 'ip:'). No interface "
          "name is needed, and a global one would be wrong on any site with mixed "
          "NIC naming. Remove the key.", file=sys.stderr)

# Calico picks each node's address by resolving can-reach against that node's own
# --node-ip, so ambiguity cannot arise from a generated list any more. This check
# is kept as a PROFILE sanity check: a node whose fabric prefixes fail to isolate
# its primary NIC is misaddressed regardless of how Calico selects, and that
# surfaces later as a broken data plane rather than a generation error.
for node_name, reason in fabric_addressing_conflicts():
    errors.append(f"fabric addressing is ambiguous for node '{node_name}': {reason}. "
                  f"Fabric prefixes must isolate each node's primary NIC — check "
                  f"'prefix:' on its fabric_nics")

# An unusable address (network/broadcast of its own prefix) configures cleanly and
# then never carries traffic, so it must not reach netplan.
for node_name, reason in unusable_fabric_addresses():
    errors.append(f"node '{node_name}': {reason}")

# A cable whose ends are on different subnets yields a spoke with no fabric route.
# This was previously only a warning emitted while generating netplan, which let a
# deployment proceed to a node that could never reach the API server.
if topology == "star":
    for node_name, reason in star_cable_faults():
        errors.append(f"node '{node_name}': {reason}")

# ── Cluster CIDR sanity ───────────────────────────────────────────────────────
# pod_cidr and service_cidr are now applied verbatim to kubespray, so a bad value
# reaches a real cluster. An overlap is the dangerous case: kube-proxy and Calico
# would both claim the same addresses as the fabric or the management network, and
# the symptom is a node that resolves services to addresses belonging to a NIC —
# a data-plane fault that looks nothing like a config error. Malformed values are
# caught here too, since ipaddress accepts only well-formed CIDRs.
def cluster_cidr_faults():
    """pod_cidr / service_cidr values that are malformed or overlap something."""
    import ipaddress
    faults = []
    parsed = {}
    for label, value in (("network.pod_cidr", pod_cidr),
                         ("network.service_cidr", service_cidr)):
        try:
            # strict=False would silently accept a host address like 10.244.0.1/16
            # and renormalise it; require a true network address instead.
            parsed[label] = ipaddress.ip_network(value, strict=True)
        except ValueError as exc:
            faults.append(f"{label} '{value}' is not a valid CIDR network: {exc}")
    if len(parsed) < 2:
        return faults

    pods = parsed["network.pod_cidr"]
    svcs = parsed["network.service_cidr"]
    if pods.overlaps(svcs):
        faults.append(f"network.pod_cidr {pods} overlaps network.service_cidr {svcs} — "
                      f"pod and service address space must be disjoint")

    # Fabric prefixes and mgmt IPs are the two other address families on these
    # hosts. An overlap with either blackholes real traffic once Calico programs
    # its routes, so both are hard errors.
    for label, net in parsed.items():
        for sup in fabric_supernets():
            fab = ipaddress.ip_network(sup)
            if net.overlaps(fab):
                faults.append(f"{label} {net} overlaps fabric prefix {fab} — "
                              f"cluster traffic would collide with the fabric")
        for node_name, node in sorted(all_nodes.items()):
            mgmt = node.get("mgmt_ip")
            if not mgmt:
                continue
            if ipaddress.ip_address(mgmt) in net:
                faults.append(f"{label} {net} contains mgmt_ip {mgmt} of node "
                              f"'{node_name}' — cluster traffic would collide with "
                              f"the management network")
    return faults

for reason in cluster_cidr_faults():
    errors.append(reason)

if errors:
    print("\nERROR: rack-profile.yaml validation failed:", file=sys.stderr)
    for e in errors:
        print(f"  • {e}", file=sys.stderr)
    print("\nNo files were generated. Fix the above and re-run.", file=sys.stderr)
    sys.exit(1)

# ── 1. hosts.yaml ─────────────────────────────────────────────────────────────
def gen_hosts_yaml():
    lines = [
        "# Copyright (C) 2025-2026 Intel Corporation",
        "# SPDX-License-Identifier: Apache-2.0",
        "#",
        "# AUTO-GENERATED by rack-profile-parser.sh",
        f"# Source: rack-profile.yaml (site: {site_name})",
        "# DO NOT EDIT MANUALLY — edit rack-profile.yaml and regenerate.",
        "---",
        "all:",
        "  hosts:",
    ]

    storage_nodes_map = {n["name"]: n for n in storage.get("nodes", [])}

    for name, node in all_nodes.items():
        nics        = node.get("fabric_nics", [])
        roles       = node.get("roles", [])
        mgmt_ip     = node.get("mgmt_ip", "")
        is_cp       = "kube_control_plane" in roles or "etcd" in roles
        node_family = node.get("node_family", "")
        sku         = node.get("sku", "")
        accel       = node.get("accelerator", "")
        gpu_count   = node.get("gpu_count", "")

        # ip/access_ip logic:
        #   Workers always bind kubelet/pod traffic to fabric IP.
        #   CP/etcd nodes: only use fabric IP if control_plane_on_fabric=true AND they have a fabric NIC.
        #   Otherwise CP nodes fall back to mgmt_ip so kube-apiserver/etcd stay on management network.
        #   This makes the system portable to customer sites without 100G on master nodes.
        if nics and (not is_cp or cp_on_fabric):
            bind_ip = nics[0]["fabric_ip"]
        else:
            bind_ip = mgmt_ip

        lines.append(f"    {name}:")
        if node.get("local", False):
            lines.append("      ansible_connection: local")
            lines.append("      ansible_user: \"{{ lookup('env', 'USER') }}\"")
        else:
            lines.append(f"      ansible_host: {mgmt_ip}")
            # SSH identity: per-node override → site default → historical default.
            # Customer sites rarely use 'ubuntu' with an ed25519 key at a fixed path.
            lines.append(f"      ansible_user: {node.get('ansible_user', default_ansible_user)}")
            lines.append("      ansible_ssh_private_key_file: "
                         f"{node.get('ansible_ssh_private_key_file', default_ssh_key)}")
        lines.append("      ansible_become: true")
        if bind_ip:
            lines.append(f"      ip: {bind_ip}")
            lines.append(f"      access_ip: {bind_ip}")
        if node.get("hostname"):
            lines.append(f"      node_hostname: {node['hostname']}")

        # Per-node fabric NIC map — consumed by Calico BGP and Multus roles
        if nics:
            lines.append("      node_fabric_nics:")
            for fn in nics:
                lines.append(f"        - nic: {fn['nic']}")
                lines.append(f"          fabric_ip: {fn['fabric_ip']}")
                if fn.get("leaf"):
                    lines.append(f"          leaf: {fn['leaf']}")

        # Silicon metadata — emitted as hostvars so label-nodes.yml can apply them.
        if node_family:
            lines.append(f"      node_family: {node_family}")
        if sku:
            lines.append(f"      node_sku: {sku}")
        if accel:
            accel_parts = accel.split("-")
            accel_vendor = accel_parts[0]
            accel_model  = accel_parts[1] if len(accel_parts) >= 2 else accel
            accel_form   = accel_parts[2] if len(accel_parts) >= 3 else ""
            lines.append(f"      node_accelerator: {accel}")
            lines.append(f"      node_gpu_vendor: {accel_vendor}")
            lines.append(f"      node_gpu_model: {accel_model}")
            if accel_form:
                lines.append(f"      node_gpu_form: {accel_form}")
        if gpu_count:
            lines.append(f"      node_gpu_count: {gpu_count}")

        # OSD devices per node — sourced from storage.nodes in rack-profile.yaml
        if name in storage_nodes_map:
            devs = storage_nodes_map[name].get("devices", [])
            if devs:
                lines.append(f"      devices: {devs}")

    def in_role(role):
        return [n for n, cfg in all_nodes.items() if role in cfg.get("roles", [])]

    def with_family(family):
        return [n for n, cfg in all_nodes.items()
                if cfg.get("node_family") == family and not cfg.get("accelerator")]

    cp           = in_role("kube_control_plane")
    workers      = in_role("kube_node")
    etcd         = in_role("etcd")
    gnr_ap       = in_role("gnr_ap")
    ceph_storage = in_role("storage")
    # Silicon-family groups (CPU nodes only — GPU nodes go to gpu_nodes instead)
    gnr_sp_nodes = with_family("cpu-gnr-sp")
    cwf_nodes    = with_family("cpu-cwf")
    spr_nodes    = with_family("cpu-spr")
    # GPU nodes: any node with an accelerator set
    gpu_nodes    = [n for n, cfg in all_nodes.items() if cfg.get("accelerator")]

    lines += ["  children:", "    kube_control_plane:", "      hosts:"]
    for n in cp:      lines.append(f"        {n}:")
    lines += ["    kube_node:", "      hosts:"]
    for n in workers: lines.append(f"        {n}:")
    lines += ["    etcd:", "      hosts:"]
    for n in etcd:    lines.append(f"        {n}:")
    lines += [
        "    k8s_cluster:",
        "      children:",
        "        kube_control_plane:",
        "        kube_node:",
        "    calico_rr:",
        "      hosts: {}",
    ]
    # No Calico-related groups are emitted. There used to be two families —
    # cp_mgmt_* (interface=<mgmt_nic> for CP nodes off the fabric) and
    # fabric_*/leaf_* (interface=<nic>, later a cidr= list) — both existing only
    # to carry calico_ip_auto_method into group_vars. Kubespray's default
    # can-reach=$(NODEIP) resolves per-node from status.hostIP and is correct on
    # every host without any generated state, so the groups have no purpose.
    # See section 3 (Calico IP autodetection) for the full reasoning.
    if gnr_ap:
        lines += ["    gnr_ap:", "      hosts:"]
        for n in gnr_ap: lines.append(f"        {n}:")
    if gnr_sp_nodes:
        lines += ["    gnr_sp:", "      hosts:"]
        for n in gnr_sp_nodes: lines.append(f"        {n}:")
    if cwf_nodes:
        lines += ["    cwf:", "      hosts:"]
        for n in cwf_nodes: lines.append(f"        {n}:")
    if spr_nodes:
        lines += ["    spr:", "      hosts:"]
        for n in spr_nodes: lines.append(f"        {n}:")
    if gpu_nodes:
        lines += ["    gpu_nodes:", "      hosts:"]
        for n in gpu_nodes: lines.append(f"        {n}:")
    if ceph_storage:
        lines += ["    ceph_storage_nodes:", "      hosts:"]
        for n in ceph_storage: lines.append(f"        {n}:")
    # ECMP is a property of the fabric, not of the CPU family. A node can hash
    # flows across uplinks only when two or more of its NICs have a router that
    # can reach the same prefixes — see ecmp_nodes() for the derivation.
    ecmp = ecmp_nodes()
    if ecmp:
        lines += ["    ecmp_nodes:", "      hosts:"]
        for n in ecmp: lines.append(f"        {n}:")
    # The star hub forwards between point-to-point legs; it needs ip_forward and
    # loose reverse-path filtering, which is a distinct concern from ECMP hashing.
    fabric_routers = [n for n, cfg in all_nodes.items() if cfg.get("fabric_router")] \
                     if topology == "star" else []
    if fabric_routers:
        lines += ["    fabric_routers:", "      hosts:"]
        for n in fabric_routers: lines.append(f"        {n}:")

    return "\n".join(lines) + "\n"

# ── 2. k8s-net-fabric.yml ─────────────────────────────────────────────────────
def gen_fabric_vars():
    lines = [
        "# Copyright (C) 2025-2026 Intel Corporation",
        "# SPDX-License-Identifier: Apache-2.0",
        "#",
        "# AUTO-GENERATED by rack-profile-parser.sh",
        f"# Source: rack-profile.yaml (site: {site_name})",
        "# DO NOT EDIT MANUALLY.",
        "---",
        "",
        f"rack_site: {site_name}",
        f"rack_calico_mode: {calico_mode}",
        f"rack_pod_cidr: {pod_cidr}",
        f"rack_service_cidr: {service_cidr}",
        f"rack_cluster_asn: {cluster_asn}",
        f"rack_fabric_mtu: {fabric_mtu}",
        "",
        "# Every prefix that carries fabric traffic, as on-link supernets.",
        "# Consumed by deploy-ecmp-sysctl.yml to scope the star hub's iptables",
        "# FORWARD ACCEPT rule to fabric traffic only, rather than flipping the",
        "# whole chain policy to ACCEPT. Supernets are correct here (unlike Calico",
        "# autodetection, which needs exact /32s) because the rule only has to",
        "# cover fabric traffic, not identify a single address.",
        "rack_fabric_cidrs:",
    ] + [f"  - {c}" for c in fabric_supernets()] + [
        "",
        "# Leaf switch definitions — used by STORY-2 (Calico BGP peers)",
        "rack_leafs:",
    ]
    for leaf in leafs:
        lines += [
            f"  - name: {leaf['name']}",
            f"    asn: {leaf['asn']}",
            f"    peer_ip: {leaf.get('peer_ip', 'TBD')}",
            f"    fabric_subnet: {leaf.get('fabric_subnet', 'TBD')}",
        ]
        if leaf.get("switch_name"):
            lines.append(f"    switch_name: {leaf['switch_name']}")
        if leaf.get("switch_mgmt_ip"):
            lines.append(f"    switch_mgmt_ip: {leaf['switch_mgmt_ip']}")

    lines += [""]
    # NOTE: Calico kubespray settings are written to k8s-net-calico.yml (not here).
    # This file is rack metadata only — consumed by playbooks and roles.

    return "\n".join(lines) + "\n"

# ── 2b. k8s-net-calico.yml (kubespray Calico config) ─────────────────────────
def gen_calico_yml():
    """
    Generates inventory/metadata/k8s-net-calico.yml — the authoritative
    Calico config copied to kubespray group_vars/k8s_cluster/.
    Content is fully driven by calico_mode from rack-profile.yaml:
      bgp  → native BGP, no encapsulation, peer with all leaf gateways
      vxlan → VXLAN overlay (switchless / dev environments)
    """
    lines = [
        "# Copyright (C) 2025-2026 Intel Corporation",
        "# SPDX-License-Identifier: Apache-2.0",
        "#",
        "# AUTO-GENERATED by rack-profile-parser.sh",
        f"# Source: rack-profile.yaml (site: {site_name})",
        "# DO NOT EDIT MANUALLY — edit rack-profile.yaml and regenerate.",
        "---",
        "",
        "# Cluster CIDRs — the single source of truth is network.pod_cidr and",
        "# network.service_cidr in rack-profile.yaml.",
        "#",
        "# Both are set HERE rather than in group_vars/k8s_cluster/k8s-cluster.yml",
        "# because that file is kubespray's pristine sample and is overwritten every",
        "# time inventory/sample/ is re-copied. Ansible loads a group_vars directory",
        "# in alphabetical order and later files win, and 'k8s-net-calico.yml' sorts",
        "# after 'k8s-cluster.yml', so these two keys override the sample's",
        "# 10.233.x.x defaults without editing a vendored file.",
        "#",
        "# Neither may overlap a fabric prefix or a mgmt subnet — validated by the",
        "# parser before any file is written.",
        f"kube_pods_subnet: {pod_cidr}",
        f"kube_service_addresses: {service_cidr}",
        "kube_network_node_prefix: 24",
        "",
    ]
    if calico_mode == "bgp":
        lines += [
            "# ── Network backend ──────────────────────────────────────────────────",
            "calico_network_backend: bird      # BGP — required for native L3",
            "",
            "# ── Encapsulation — DISABLED ────────────────────────────────────────",
            "# Native L3 eBGP Clos fabric — no overlay needed.",
            "calico_ipip_mode: Never",
            "calico_vxlan_mode: Never",
            "",
            "# ── NAT outgoing ────────────────────────────────────────────────────",
            "# Pods reach internet via 10G management NIC NAT.",
            "# 100G fabric has no internet uplink — by design.",
            "calico_nat_outgoing: true",
            "",
            "# ── MTU ─────────────────────────────────────────────────────────────",
            f"calico_mtu: {fabric_mtu}",
            "",
            "# ── BGP ─────────────────────────────────────────────────────────────",
            f'global_as_num: "{cluster_asn}"',
            "",
            "# Node-to-node mesh DISABLED — ToR peering only.",
            "# With per-node BGPPeer CRDs (metadata/bgp-peers/) every node peers",
            "# directly with its leaf switch(es). Pod routes flow:",
            "#   originating node → leaf → spine → leaf → destination node",
            "# This keeps BGP session count constant (one per fabric NIC per node)",
            "# regardless of cluster size, and enables ECMP across dual uplinks.",
            "# VXLAN/star topology overrides this to true (no ToR router available).",
            "calico_node_to_node_mesh: \"false\"",
            "",
            "# No global BGPPeer CRDs — per-node peers with correct sourceAddress",
            "# are generated in metadata/bgp-peers/ and applied by deploy-bgp-peers.yml.",
        ]
    else:
        # VXLAN encapsulates every pod packet, so the pod-facing MTU must be the
        # link MTU minus the encap header or large pod-to-pod flows silently
        # black-hole (small packets and TCP handshakes pass, which makes this look
        # like an application bug rather than a network one).
        lines += [
            "# ── Network backend ──────────────────────────────────────────────────",
            "# VXLAN mode — for switchless / dev environments.",
            "calico_network_backend: vxlan",
            "",
            "calico_ipip_mode: Never",
            "calico_vxlan_mode: Always",
            "",
            "calico_nat_outgoing: true",
            "",
            "# ── MTU ─────────────────────────────────────────────────────────────",
            f"# Fabric link MTU {fabric_mtu} minus {vxlan_overhead}B VXLAN encapsulation.",
            f"calico_mtu: {fabric_mtu - vxlan_overhead}",
            "",
            "# ── BGP ─────────────────────────────────────────────────────────────",
            "# Node-to-node mesh ENABLED — there is no ToR switch to peer with, so",
            "# nodes must exchange pod routes directly with each other.",
            'calico_node_to_node_mesh: "true"',
        ]
    return "\n".join(lines) + "\n"

# ── 3. Calico IP autodetection — deliberately NOT generated ───────────────────
#
# There is no generator here, and no group_vars are emitted for Calico.
#
# We used to emit group_vars setting calico_ip_auto_method, first as
# interface=<nic> per leaf, then as a cidr= list of primary /32s. Both were
# working around the wrong constraint. calico-node is a DaemonSet: kubespray
# renders IP_AUTODETECTION_METHOD once and applies it cluster-wide, so any value
# we compute has to be simultaneously correct on every node.
#
# Kubespray's own default already solves that, and better than we can:
#
#     - name: NODEIP
#       valueFrom:
#         fieldRef: {fieldPath: status.hostIP}
#     - name: IP_AUTODETECTION_METHOD
#       value: "can-reach=$(NODEIP)"
#
# status.hostIP is a per-POD field reference — the kubelet substitutes each
# node's OWN address at pod start, so one manifest yields a different, correct
# value on every host. And it is the address we want: kubelet is started with
# --node-ip={{ ip }}, and this parser sets ip: to each node's primary fabric IP,
# so status.hostIP IS the fabric IP. can-reach=<own address> resolves via
# 'ip route get', which returns 'local <addr> dev lo src <addr>' for an address
# the host owns — an exact match, never a neighbour's.
#
# Leaving it undefined is therefore both simpler and more robust than any list we
# could generate: nothing to regenerate when a node is added, no static value
# that can go stale, and no NIC-name assumption anywhere. It is also the
# configuration the tested Clos topology actually ran, since the per-leaf files
# were emitted without matching inventory groups and never took effect.
#
# fabric_addressing_conflicts() still runs as a profile sanity check — it catches
# genuinely ambiguous fabric addressing regardless of the method used.

# ── 4. Netplan per-node (persistent fabric IP + cross-leaf static routes) ─────
def _star_hub():
    """Return (hub_name, hub_cfg) for the star's routing node, or (None, None)."""
    for name, cfg in all_nodes.items():
        if cfg.get("fabric_router"):
            return name, cfg
    return None, None

def _star_fabric_supernet():
    """
    Smallest prefix covering every fabric IP in the profile — the destination
    spokes route toward the hub for. Derived rather than declared so adding a
    node cannot leave a spoke with a stale route.
    """
    import ipaddress
    ips = [ipaddress.ip_address(fn["fabric_ip"])
           for node in all_nodes.values()
           for fn in node.get("fabric_nics", [])]
    if not ips:
        return None
    net = ipaddress.ip_network(f"{min(ips)}/32")
    while not all(ip in net for ip in ips):
        net = net.supernet()
    return str(net)

def _star_routes_for(node_name, node, fn):
    """
    Static routes for one NIC in star topology.

    Spokes: one route to the fabric supernet via the hub's IP on *this* cable.
    Because each cable is its own subnet, the hub address is on-link, so the
    route needs no gateway trickery — the kernel can resolve it directly.

    Hub: nothing. Its legs are all directly connected, so the kernel already
    has a connected route per cable; it only needs ip_forward enabled.
    """
    if node.get("fabric_router"):
        return []

    hub_name, hub_cfg = _star_hub()
    if not hub_name:
        return []

    peer = fn.get("peer")
    if peer != hub_name:
        # Spoke NIC not facing the hub — no transit path exists over this cable.
        return []

    supernet = _star_fabric_supernet()
    if not supernet:
        return []

    # Find the hub's address on the far end of this specific cable.
    my_ip = fn["fabric_ip"]
    my_pfx = nic_prefix(fn)
    import ipaddress
    my_net = ipaddress.ip_network(f"{my_ip}/{my_pfx}", strict=False)
    for hub_fn in hub_cfg.get("fabric_nics", []):
        hub_ip = hub_fn["fabric_ip"]
        if ipaddress.ip_address(hub_ip) in my_net:
            return [{"to": supernet, "via": hub_ip}]

    print(f"  WARNING: star spoke '{node_name}' NIC '{fn.get('nic')}' ({my_ip}/{my_pfx}) "
          f"shares no subnet with any NIC on hub '{hub_name}' — no route generated",
          file=sys.stderr)
    return []

def gen_netplan_files():
    """
    Returns dict of {relative_path: content} for per-node netplan YAML files.
    Each node gets:
      - Its fabric NIC(s) configured with persistent IP
      - clos: static routes to all OTHER leaf subnets via its own leaf gateway
      - star: a route to the fabric supernet via the hub, on the cable facing it
    """
    leaf_by_name_local = {l["name"]: l for l in leafs}
    files = {}

    for node_name, node in all_nodes.items():
        nics = node.get("fabric_nics", [])
        if not nics:
            continue  # mgmt-only node, no netplan needed

        hostname = node.get("hostname", node_name)
        ethernets = {}

        for fn in nics:
            nic      = fn["nic"]
            fab_ip   = fn["fabric_ip"]
            leaf_name = fn.get("leaf")
            leaf_cfg  = leaf_by_name_local.get(leaf_name, {})
            gateway   = leaf_cfg.get("peer_ip", "")
            own_subnet = leaf_cfg.get("fabric_subnet", "")

            if topology == "star":
                routes = _star_routes_for(node_name, node, fn)
            else:
                # Cross-leaf static routes: to every other leaf subnet via this leaf's gateway
                routes = []
                if gateway and gateway != "TBD":
                    for other_leaf in leafs:
                        if other_leaf["name"] != leaf_name and other_leaf.get("fabric_subnet", "TBD") != "TBD":
                            routes.append({"to": other_leaf["fabric_subnet"], "via": gateway})

            iface_cfg = {
                "addresses": [f"{fab_ip}/{nic_prefix(fn)}"],
                "mtu": fabric_mtu,
            }
            if routes:
                iface_cfg["routes"] = routes

            ethernets[nic] = iface_cfg

        # Build netplan YAML
        netplan = {"network": {"version": 2, "renderer": netplan_renderer, "ethernets": {}}}
        for nic, cfg in ethernets.items():
            entry = {"dhcp4": False, "dhcp6": False, "addresses": cfg["addresses"], "mtu": cfg["mtu"]}
            if "routes" in cfg:
                entry["routes"] = [{"to": r["to"], "via": r["via"]} for r in cfg["routes"]]
            netplan["network"]["ethernets"][nic] = entry

        import yaml as _yaml
        content = (
            "# Copyright (C) 2025-2026 Intel Corporation\n"
            "# SPDX-License-Identifier: Apache-2.0\n"
            "#\n"
            "# AUTO-GENERATED by rack-profile-parser.sh\n"
            f"# Node: {hostname} ({node_name})\n"
            "# DO NOT EDIT MANUALLY.\n"
            "# Deploy: sudo cp this /etc/netplan/99-fabric.yaml && sudo netplan apply\n"
            "# NOTE: named 99-fabric.yaml to outrank any DHCP config (e.g. 50-cloud-init,\n"
            "#       warewulf) on the same NIC and prevent DHCP from overriding fabric IPs.\n"
            "#\n"
        )
        content += _yaml.dump(netplan, default_flow_style=False, sort_keys=False)
        files[os.path.join("netplan", f"{hostname}.yaml")] = content

    return files

# ── 5. ceph-storage.yml ────────────────────────────────────────────────────────
def gen_ceph_vars():
    lines = [
        "# Copyright (C) 2025-2026 Intel Corporation",
        "# SPDX-License-Identifier: Apache-2.0",
        "#",
        "# AUTO-GENERATED by rack-profile-parser.sh",
        f"# Source: rack-profile.yaml (site: {site_name})",
        "# DO NOT EDIT MANUALLY.",
        "---",
        "",
        "# Presence of ceph_fabric_nic enables 'provider: host' in the Rook cluster",
        "# values, which is what actually puts Ceph daemons on the fabric (they bind",
        "# to the node IP, i.e. the primary fabric IP set as 'ip:' above). The name",
        "# itself is not passed to Rook — it is validated against each storage node's",
        "# real NICs by this parser. Per-node 'ceph_fabric_nic:' overrides are",
        "# checked the same way but deliberately not emitted: 'provider: host' is a",
        "# cluster-wide setting with no per-node form, so there is nothing to carry.",
        f'ceph_fabric_nic: "{ceph_nic}"',
        "",
        "# Ceph network CIDRs — routes client and replication traffic over fabric",
        "# public_network:  client-to-OSD (pods reading/writing PVCs)",
        "# cluster_network: OSD-to-OSD replication (internal)",
        f'ceph_public_network: "{ceph_public_net}"',
        f'ceph_cluster_network: "{ceph_cluster_net}"',
        "",
        "# Cleanup: sgdisk --zap-all + wipefs per device before re-deploy.",
        "ceph_replica_size: 3",
        "# Informational only. generate-ceph-values.yml rebuilds the storage node",
        "# list from inventory hostvars ('devices'), so this block documents the",
        "# intended layout rather than feeding the Helm values.",
        "ceph_storage_nodes:",
    ]
    for node in storage.get("nodes", []):
        lines.append(f'  - name: "{node["name"]}"')
        lines.append("    devices:")
        for dev in node.get("devices", []):
            lines.append(f'      - name: "{dev}"')

    return "\n".join(lines) + "\n"

# ── Write or print ─────────────────────────────────────────────────────────────

def gen_flags_env():
    """
    Emits a shell-sourceable env file consumed by setup-env.sh.
    Captures derived flags that shell scripts need without re-parsing rack-profile.yaml.
    """
    # Determine whether the Ansible controller (local: true node) can reach worker
    # access_ips.  If cp_on_fabric=False and no CP node has a fabric NIC, the controller
    # lives only on the mgmt network and cannot ping fabric IPs → kubespray precheck fails.
    controller_has_fabric = any(
        node.get("local") and node.get("fabric_nics")
        for node in all_nodes.values()
    )
    # ping_access_ip must be false when the controller cannot reach fabric access_ips
    ping_access_ip = "true" if (cp_on_fabric or controller_has_fabric) else "false"

    lines = [
        "# Copyright (C) 2025-2026 Intel Corporation",
        "# SPDX-License-Identifier: Apache-2.0",
        "#",
        "# AUTO-GENERATED by rack-profile-parser.sh  —  DO NOT EDIT MANUALLY.",
        "# Source this file in shell scripts: source core/inventory/metadata/rack-scale-flags.env",
        "",
        f"rack_scale_cp_on_fabric={str(cp_on_fabric).lower()}",
        f"rack_scale_ping_access_ip={ping_access_ip}",
        f"rack_scale_calico_mode={calico_mode}",
    ]
    # Topology-derived flags. Emitted after the flags above so a site that never
    # sets 'topology' still produces the historical prefix byte-for-byte.
    if topology != "clos":
        lines.append(f"rack_scale_topology={topology}")
    if ecmp_nodes():
        lines.append(f"rack_scale_ecmp_nodes={','.join(ecmp_nodes())}")

    # GPU-derived flags — empty strings when no GPU nodes present.
    gpu_vendor = ""
    gpu_model  = ""
    gpu_form   = ""
    for node in all_nodes.values():
        accel = node.get("accelerator")
        if accel:
            parts = accel.split("-")
            gpu_vendor = parts[0] if len(parts) >= 1 else ""
            gpu_model  = parts[1] if len(parts) >= 2 else ""
            gpu_form   = parts[2] if len(parts) >= 3 else ""
            break  # All GPU nodes in the cluster share the same vendor for MVP

    lines.append(f"rack_scale_gpu_vendor={gpu_vendor}")
    lines.append(f"rack_scale_gpu_model={gpu_model}")
    lines.append(f"rack_scale_gpu_form={gpu_form}")
    return "\n".join(lines) + "\n"

# ── 5. Per-node BGPPeer CRDs (all fabric NICs) ────────────────────────────────
def gen_bgp_peers():
    """
    Generate one Calico BGPPeer CRD per node per fabric NIC.

    No global BGPPeers are used. Every ToR session is explicit: each CRD names
    the node, the leaf's SVI as peerIP, and the NIC's IP as sourceAddress. This
    gives Calico/bird full control over which NIC each TCP session originates from,
    which is required when a node has multiple fabric NICs on different leaf
    switches — each switch's bgp listen range only accepts connections from its
    own subnet.

    Works for any node type (worker, control-plane, storage) with any number of
    fabric_nics. Single-NIC nodes get one CRD. Only generated when
    calico_mode == 'bgp' and the node has at least one fabric NIC with a known leaf.

    Returns dict of {relative_path: content}.
    """
    if calico_mode != "bgp":
        return {}

    files = {}
    for node_name, node in all_nodes.items():
        nics = node.get("fabric_nics", [])
        for fn in nics:
            leaf_name = fn.get("leaf")
            if not leaf_name or leaf_name not in leaf_by_name:
                continue
            leaf     = leaf_by_name[leaf_name]
            peer_ip  = leaf.get("peer_ip", "TBD")
            peer_asn = leaf.get("asn")
            src_ip   = fn["fabric_ip"]

            if peer_ip == "TBD" or not peer_asn:
                continue

            peer_name = f"{node_name}-{leaf_name}"
            content = "\n".join([
                "# Copyright (C) 2025-2026 Intel Corporation",
                "# SPDX-License-Identifier: Apache-2.0",
                "#",
                "# AUTO-GENERATED by rack-profile-parser.sh",
                f"# Source: rack-profile.yaml (site: {site_name})",
                "# DO NOT EDIT MANUALLY.",
                "#",
                f"# Per-node BGPPeer: {node_name} → {leaf_name} ({peer_ip})",
                f"# sourceAddress: bird uses {fn['nic']} ({src_ip}) as the TCP source,",
                "# so the switch's bgp listen range accepts the connection.",
                "---",
                "apiVersion: crd.projectcalico.org/v1",
                "kind: BGPPeer",
                "metadata:",
                f"  name: {peer_name}",
                "spec:",
                f"  node: {node_name}",
                f"  peerIP: {peer_ip}",
                f"  asNumber: {peer_asn}",
                f"  sourceAddress: {src_ip}",
                # Allow bird to accept routes containing the cluster ASN in the AS path.
                # Without this, routes learned from the leaf (AS path: <leaf-AS> <cluster-AS>)
                # are dropped by bird's loop detection because the node's own AS appears.
                "  numAllowedLocalASNumbers: 1",
            ]) + "\n"

            rel_path = os.path.join("metadata", "bgp-peers", f"{peer_name}.yaml")
            files[rel_path] = content

    return files


outputs = {
    os.path.join(inventory_dir, "hosts.yaml"):                                    gen_hosts_yaml(),
    os.path.join(inventory_dir, "metadata", "k8s-net-fabric.yml"):               gen_fabric_vars(),
    os.path.join(inventory_dir, "metadata", "k8s-net-calico.yml"):               gen_calico_yml(),
    os.path.join(inventory_dir, "metadata", "vars", "ceph-storage.yml"):         gen_ceph_vars(),
    os.path.join(inventory_dir, "metadata", "rack-scale-flags.env"):             gen_flags_env(),
}

# Add per-node netplan files
for rel_path, content in gen_netplan_files().items():
    outputs[os.path.join(inventory_dir, rel_path)] = content

# Add per-node BGPPeer CRDs (secondary NIC peering)
for rel_path, content in gen_bgp_peers().items():
    outputs[os.path.join(inventory_dir, rel_path)] = content

print(f"\nRack Profile Parser — site: {site_name}")
print(f"  Calico   : {calico_mode}  |  Leafs: {', '.join(l['name'] for l in leafs) or 'none'}")
print(f"  Ceph     : NIC: {ceph_nic or 'not set'}  |  nodes: {len(storage.get('nodes', []))}")
if node_profiles:
    print(f"  Profiles ({len(node_profiles)}): {', '.join(sorted(node_profiles.keys()))}")
gpu_list = [n for n, cfg in all_nodes.items() if cfg.get("accelerator")]
if gpu_list:
    # Summarise the GPU flags that will be written
    _gv = _gm = _gf = ""
    for _node in all_nodes.values():
        _a = _node.get("accelerator")
        if _a:
            _parts = _a.split("-")
            _gv = _parts[0]; _gm = _parts[1] if len(_parts)>1 else ""; _gf = _parts[2] if len(_parts)>2 else ""
            break
    print(f"  GPU nodes({len(gpu_list)}): vendor={_gv} model={_gm} form={_gf or 'n/a'}")
print(f"  Nodes ({len(all_nodes)}):")
for name, node in all_nodes.items():
    nics   = node.get("fabric_nics", [])
    roles  = node.get("roles", [])
    rack   = node.get("_rack", "")
    accel  = node.get("accelerator", "")
    family = node.get("node_family", "")
    nic_summary = ", ".join(f"{fn['nic']}@{fn['fabric_ip']} [{fn.get('leaf','')}]" for fn in nics) if nics else "mgmt only"
    silicon_summary = f" [{family}{'+'+accel if accel else ''}]" if family or accel else ""
    print(f"    [{rack}] {name:10s} {', '.join(roles):40s} {nic_summary}{silicon_summary}")
print()

if dry_run:
    # Dry-run: show merged node list including resolved profile fields
    print("=== Dry-run: merged node list (profile fields resolved) ===")
    for name, node in all_nodes.items():
        prof = node.get("profile", "—")
        family = node.get("node_family", "")
        sku_val = node.get("sku", "")
        accel = node.get("accelerator", "")
        gpu_count_val = node.get("gpu_count", "")
        if prof != "—" or family or accel:
            print(f"  Node {name}: profile={prof}")
            if family:   print(f"    node_family={family}", end="")
            if sku_val:  print(f" sku={sku_val}", end="")
            if family or sku_val: print()
            if accel:
                print(f"    accelerator={accel} gpu_count={gpu_count_val}")
    print()

# ── Reconcile: remove stale files in parser-managed directories ───────────────
# These directories are FULLY owned by the parser.  Any file present on disk
# that was NOT produced in this run is from a node that has since been removed
# (or renamed/moved to a different leaf).  Delete it so that:
#   • deploy-bgp-peers.yml never re-applies a dead node's CRD
#   • add-node --re-add never collides with an old manifest carrying stale IPs
#   • git diff gives a clean picture of exactly what changed
MANAGED_DIRS = [
    os.path.join(inventory_dir, "metadata", "bgp-peers"),
    os.path.join(inventory_dir, "netplan"),
    # group_vars is no longer written to at all (see section 3), but stays listed
    # so any calico.yml left behind by an older parser version is cleaned up
    # rather than lingering as a stale calico_ip_auto_method source.
    os.path.join(inventory_dir, "metadata", "group_vars"),
]

def reconcile_managed_dirs(outputs, dry_run):
    removed = []
    for d in MANAGED_DIRS:
        if not os.path.isdir(d):
            continue
        for fname in os.listdir(d):
            fpath = os.path.join(d, fname)
            if not os.path.isfile(fpath):
                continue
            if fpath not in outputs:
                removed.append(fpath)
                if dry_run:
                    print(f"# DRY RUN — would delete stale: {fpath}")
                else:
                    os.remove(fpath)
                    print(f"  ✗ removed stale: {fpath}")
    return removed

for path, content in outputs.items():
    if dry_run:
        print(f"{'='*70}")
        print(f"# DRY RUN — would write: {path}")
        print(f"{'='*70}")
        print(content)
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        print(f"  ✓ {path}")

stale = reconcile_managed_dirs(outputs, dry_run)

if not dry_run:
    if stale:
        print(f"\n  Pruned {len(stale)} stale file(s) from managed directories.")
    print("\nDone. Run 'git diff core/inventory/' to review changes before deploying.")
PYEOF
