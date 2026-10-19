#!/bin/bash
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# report-renderer.sh — Reads a health-report JSON file and prints a
# traffic-light summary table to stdout. Supports cumulative merged reports.

set -euo pipefail

REPORT_FILE="${1:?Usage: report-renderer.sh <health-report.json>}"

if [[ ! -f "$REPORT_FILE" ]]; then
    echo "ERROR: Report file not found: $REPORT_FILE" >&2
    exit 1
fi

python3 - "$REPORT_FILE" <<'PYTHON'
import json
import sys

report_file = sys.argv[1]

with open(report_file, 'r') as f:
    report = json.load(f)

results = report.get('results', [])
timestamp = report.get('timestamp', 'unknown')
current_layers = set(report.get('current_layers', []))

layer_order = [
    'e2e-inference', 'fabric', 'network', 'proxy', 'kubernetes',
    'storage', 'ai-stack', 'wiring', 'gpu', 'kuberay',
    'sandbox', 'flowise', 'platform-health', 'burn-quick', 'burn-extended'
]

layer_display_names = {
    'e2e-inference': 'End-to-end inference',
    'fabric': 'Fabric verified',
    'network': 'Network connectivity',
    'proxy': 'Proxy configuration',
    'kubernetes': 'Kubernetes cluster',
    'storage': 'Storage (Ceph)',
    'ai-stack': 'AI Stack services',
    'wiring': 'Inter-component wiring',
    'gpu': 'GPU readiness',
    'kuberay': 'KubeRay',
    'sandbox': 'Agent Sandbox',
    'flowise': 'Agentic AI Plugin',
    'platform-health': 'Platform health',
    'burn-quick': 'Quick burn (infra)',
    'burn-extended': 'Extended burn',
}

status_priority = {'FAIL': 0, 'PENDING': 1, 'OK': 2}

layer_results = {}
for r in results:
    layer = r.get('layer', 'unknown')
    if layer not in layer_results:
        layer_results[layer] = []
    layer_results[layer].append(r)

layer_statuses = {}
layer_evidence = {}
for layer, checks in layer_results.items():
    worst = 'OK'
    evidence_parts = []
    for c in checks:
        s = c.get('status', 'OK')
        if status_priority.get(s, 2) < status_priority.get(worst, 2):
            worst = s
        if c.get('evidence'):
            evidence_parts.append(c['evidence'])
    layer_statuses[layer] = worst
    layer_evidence[layer] = '; '.join(evidence_parts[:2]) if evidence_parts else ''

total = len(layer_statuses)
passed = sum(1 for s in layer_statuses.values() if s == 'OK')
pending = sum(1 for s in layer_statuses.values() if s == 'PENDING')
failed = sum(1 for s in layer_statuses.values() if s == 'FAIL')

def fmt_status(status, evidence=''):
    if status == 'OK':
        tag = '[ OK ]'
        extra = f'  ({evidence[:50]})' if evidence else ''
    elif status == 'PENDING':
        tag = '[ PENDING ]'
        extra = f' {evidence[:50]}' if evidence else ''
    else:
        tag = '[ FAIL ]'
        extra = f' {evidence[:50]}' if evidence else ''
    return f'{tag}{extra}'

def print_layer(layer):
    name = layer_display_names.get(layer, layer)
    status = layer_statuses[layer]
    evidence = layer_evidence.get(layer, '')
    status_str = fmt_status(status, evidence)
    padding = max(1, 38 - len(name))
    print(f'  {name}{" " * padding}{status_str}')

# Split into current and previous
all_layers = [l for l in layer_order if l in layer_statuses]
all_layers += sorted(l for l in layer_statuses if l not in layer_order)

if current_layers:
    current = [l for l in all_layers if l in current_layers]
    previous = [l for l in all_layers if l not in current_layers]
else:
    current = all_layers
    previous = []

width = 60
print('=' * width)
print('  Intel® AI for Enterprise — Stack Health Report')
print('=' * width)

if current:
    for layer in current:
        print_layer(layer)

if previous:
    print('-' * width)
    print('  Previous results:')
    for layer in previous:
        checked_at = ''
        for r in layer_results.get(layer, []):
            if r.get('checked_at'):
                checked_at = f' ({r["checked_at"][:16]})'
                break
        name = layer_display_names.get(layer, layer)
        status = layer_statuses[layer]
        status_str = fmt_status(status)
        padding = max(1, 38 - len(name))
        print(f'  {name}{" " * padding}{status_str}{checked_at}')

print('-' * width)

pending_items = [r for r in results if r.get('status') == 'PENDING']
if pending_items:
    for item in pending_items:
        hint = item.get('hint', '')
        if hint:
            print(f'  {item.get("check", item.get("layer", ""))}: {hint}')
    print()

fail_items = [r for r in results if r.get('status') == 'FAIL']
if fail_items:
    for item in fail_items:
        layer = item.get('layer', 'unknown')
        check = item.get('check', 'unknown')
        hint = item.get('hint', 'No remediation hint available')
        print(f'  FAILED: [{layer}] {check}')
        print(f'          Hint: {hint}')
    print()

print('=' * width)
if failed == 0 and pending == 0:
    print('  RESULT: ALL CHECKS PASSED')
else:
    parts = []
    if passed:
        parts.append(f'{passed} PASSED')
    if pending:
        parts.append(f'{pending} PENDING')
    if failed:
        parts.append(f'{failed} FAILED')
    print(f'  RESULT: {total} layers — {", ".join(parts)}')
print('=' * width)

sys.exit(0)
PYTHON
