#!/usr/bin/env python3
# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# render-html.py — Reads health-report JSON and renders standalone HTML report.
# Runs as ansible script module, bypasses Ansible's Jinja2 re-templating.
#
# Usage: render-html.py <json_path> <html_archive_path> <html_latest_path>

import json
import sys
import html as html_module

def main():
    json_path = sys.argv[1]
    html_archive = sys.argv[2]
    html_latest = sys.argv[3]

    with open(json_path) as f:
        report = json.load(f)

    results = report.get('results', [])
    timestamp = report.get('timestamp', 'unknown')
    checked_at = report.get('checked_at', '')
    cluster_url = report.get('cluster_url', '')
    configured_models = report.get('configured_models', '')
    endpoints = report.get('endpoints', {})
    current_layers = set(report.get('current_layers', []))

    layer_order = [
        'e2e-inference', 'fabric', 'network', 'proxy', 'kubernetes',
        'storage', 'ai-stack', 'wiring', 'gpu', 'kuberay',
        'sandbox', 'flowise', 'platform-health', 'burn-quick', 'burn-extended'
    ]
    layer_names = {
        'e2e-inference': 'End-to-end inference', 'fabric': 'Fabric verified',
        'network': 'Network connectivity', 'proxy': 'Proxy configuration',
        'kubernetes': 'Kubernetes cluster', 'storage': 'Storage (Ceph)',
        'ai-stack': 'AI Stack services', 'wiring': 'Inter-component wiring',
        'gpu': 'GPU readiness', 'kuberay': 'KubeRay',
        'sandbox': 'Agent Sandbox', 'flowise': 'Agentic AI Plugin',
        'platform-health': 'Platform health', 'burn-quick': 'Quick burn (infra)',
        'burn-extended': 'Extended burn',
    }

    # Group by layer
    layer_checks = {}
    for r in results:
        l = r.get('layer', 'unknown')
        layer_checks.setdefault(l, []).append(r)

    # Compute worst status per layer
    layer_status = {}
    for l, checks in layer_checks.items():
        has_fail = any(c.get('status') == 'FAIL' for c in checks)
        has_pending = any(c.get('status') == 'PENDING' for c in checks)
        layer_status[l] = 'FAIL' if has_fail else ('PENDING' if has_pending else 'OK')

    # Order layers
    ordered = [l for l in layer_order if l in layer_checks]
    ordered += sorted(l for l in layer_checks if l not in layer_order)

    # Split current vs previous
    if current_layers:
        current = [l for l in ordered if l in current_layers]
        previous = [l for l in ordered if l not in current_layers]
    else:
        current = ordered
        previous = []

    # Counts
    ok = sum(1 for s in layer_status.values() if s == 'OK')
    pending = sum(1 for s in layer_status.values() if s == 'PENDING')
    fail = sum(1 for s in layer_status.values() if s == 'FAIL')
    total = ok + pending + fail

    def e(text):
        return html_module.escape(str(text)) if text else ''

    def badge(status):
        s = status.lower()
        return f'<span class="badge badge-{s}"><span class="dot dot-{s}"></span>{status}</span>'

    def render_layer(l, dimmed=False):
        worst = layer_status[l]
        worst_lower = worst.lower()
        open_class = ' open' if worst != 'OK' else ''
        opacity = ' style="opacity:0.7"' if dimmed else ''
        checked_ts = ''
        if dimmed:
            for c in layer_checks.get(l, []):
                if c.get('checked_at'):
                    checked_ts = f'<span style="font-size:0.75rem;color:var(--text-secondary);margin-left:0.5rem;">checked: {e(c["checked_at"])}</span>'
                    break

        html_parts = [f'<div class="layer{open_class}"{opacity}>']
        html_parts.append(f'<div class="layer-header" onclick="this.parentElement.classList.toggle(\'open\')"><span class="layer-name"><span class="arrow">&#9654;</span>{e(layer_names.get(l, l))}{checked_ts}</span>{badge(worst)}</div>')
        html_parts.append('<div class="checks">')
        for c in layer_checks.get(l, []):
            s = c.get('status', 'OK')
            s_lower = s.lower()
            html_parts.append('<div class="check-row"><div class="check-name">')
            html_parts.append(e(c.get('check', 'unnamed')))
            if c.get('evidence'):
                html_parts.append(f'<div class="check-evidence">{e(c["evidence"][:200])}</div>')
            if s == 'FAIL' and c.get('hint'):
                html_parts.append(f'<div class="check-hint hint-fail">{e(c["hint"])}</div>')
            elif s == 'PENDING' and c.get('hint'):
                html_parts.append(f'<div class="check-hint hint-pending">{e(c["hint"])}</div>')
            html_parts.append(f'</div>{badge(s)}</div>')
        html_parts.append('</div></div>')
        return '\n'.join(html_parts)

    # Build HTML
    h = []
    h.append(CSS_AND_HEADER.format(
        timestamp=e(timestamp), cluster_url=e(cluster_url),
        ok=ok, pending=pending, fail=fail, total=total,
        checked_at=e(checked_at),
        pending_section=f'<div class="summary-stat"><span class="num num-pending">{pending}</span><span class="label">Pending</span></div>' if pending else '',
        fail_section=f'<div class="summary-stat"><span class="num num-fail">{fail}</span><span class="label">Failed</span></div>' if fail else '',
    ))

    h.append('<div class="layers">')
    if current:
        h.append(f'<div style="padding:0.5rem 2rem 0.25rem;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-secondary);font-weight:600;">Current Run &mdash; {e(checked_at)}</div>')
        for l in current:
            h.append(render_layer(l))
    if previous:
        h.append('<div style="padding:1rem 2rem 0.25rem;font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;color:var(--text-secondary);font-weight:600;border-top:2px dashed var(--border);">Previous Results</div>')
        for l in previous:
            h.append(render_layer(l, dimmed=True))
    h.append('</div>')

    # Quick Start
    gateway_url = endpoints.get('gateway_url', '')
    if gateway_url or cluster_url:
        h.append('<div style="border-top:1px solid var(--border);padding:1.5rem 2rem;">')
        h.append('<h2 style="font-size:1rem;font-weight:600;margin-bottom:1rem;">Quick Start &mdash; Endpoints &amp; Commands</h2>')
        h.append('<table style="font-size:0.875rem;border-collapse:collapse;width:100%;">')
        def row(label, val, link=False):
            if not val: return ''
            td = f'<a href="{e(val)}" style="color:#0068b5;">{e(val)}</a>' if link else f'<b>{e(val)}</b>'
            return f'<tr><td style="padding:0.3rem 1rem 0.3rem 0;color:var(--text-secondary);white-space:nowrap;vertical-align:top;">{label}</td><td style="padding:0.3rem 0;">{td}</td></tr>'
        h.append(row('GenAI Gateway (LiteLLM)', gateway_url or f'https://{cluster_url}', True))
        h.append(row('Model', configured_models))
        h.append(row('Inference API', endpoints.get('inference_api', ''), True))
        h.append(row('Models API', endpoints.get('models_api', ''), True))
        h.append(row('Langfuse (traces)', endpoints.get('langfuse_ui', ''), True))
        h.append(row('Grafana (metrics)', endpoints.get('grafana_ui', ''), True))
        h.append(row('Flowise (agents)', endpoints.get('flowise_ui', ''), True))
        h.append(row('Ray dashboard', endpoints.get('ray_dashboard', ''), True))
        h.append('</table>')
        if endpoints.get('inference_api') and configured_models:
            h.append(f'''<div style="margin-top:1rem;">
<div style="font-size:0.8rem;color:var(--text-secondary);margin-bottom:0.4rem;">Test inference:</div>
<pre style="background:#1f2937;color:#e5e7eb;padding:0.75rem 1rem;border-radius:6px;font-size:0.8rem;overflow-x:auto;white-space:pre-wrap;word-break:break-all;">curl -sk {e(endpoints["inference_api"])} \\
  -H "Authorization: Bearer &lt;LITELLM_API_KEY&gt;" \\
  -H "Content-Type: application/json" \\
  -d '{{"model":"{e(configured_models)}","messages":[{{"role":"user","content":"Hello"}}],"max_tokens":50}}'</pre>
</div>''')
        h.append('</div>')

    h.append(f'<div class="footer"><span>Intel AI for Enterprise &mdash; validate-stack.yml</span><span>{e(timestamp)}</span></div>')
    h.append('</div></body></html>')

    html_content = '\n'.join(h)
    for dest in [html_archive, html_latest]:
        with open(dest, 'w') as f:
            f.write(html_content)
    print(f"Rendered {len(results)} results to {html_archive} and {html_latest}")

CSS_AND_HEADER = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Stack Health Report &mdash; {timestamp}</title>
<style>
  :root {{ --ok:#15803d; --ok-bg:#f0fdf4; --ok-border:#bbf7d0; --pending:#a16207; --pending-bg:#fefce8; --pending-border:#fef08a; --fail:#b91c1c; --fail-bg:#fef2f2; --fail-border:#fecaca; --text:#1f2937; --text-secondary:#6b7280; --surface:#ffffff; --border:#e5e7eb; }}
  * {{ box-sizing:border-box; margin:0; padding:0; }}
  body {{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif; color:var(--text); background:#f3f4f6; padding:2rem; line-height:1.5; }}
  .report {{ max-width:960px; margin:0 auto; background:var(--surface); border-radius:12px; box-shadow:0 1px 3px rgba(0,0,0,0.1); overflow:hidden; }}
  .header {{ background:#0068b5; color:#fff; padding:1.5rem 2rem; }}
  .header h1 {{ font-size:1.25rem; font-weight:600; margin-bottom:0.25rem; }}
  .header .ts {{ font-size:0.85rem; opacity:0.85; }}
  .summary-bar {{ display:flex; gap:1.5rem; padding:1.25rem 2rem; border-bottom:1px solid var(--border); flex-wrap:wrap; }}
  .summary-stat {{ display:flex; align-items:baseline; gap:0.4rem; }}
  .summary-stat .num {{ font-size:1.75rem; font-weight:700; line-height:1; }}
  .summary-stat .label {{ font-size:0.85rem; color:var(--text-secondary); text-transform:uppercase; letter-spacing:0.03em; }}
  .num-ok {{ color:var(--ok); }} .num-pending {{ color:var(--pending); }} .num-fail {{ color:var(--fail); }}
  .layers {{ padding:0.5rem 0; }}
  .layer {{ border-bottom:1px solid var(--border); }}
  .layer:last-child {{ border-bottom:none; }}
  .layer-header {{ display:flex; align-items:center; justify-content:space-between; padding:0.875rem 2rem; cursor:pointer; user-select:none; transition:background 0.15s; }}
  .layer-header:hover {{ background:#f9fafb; }}
  .layer-name {{ font-size:0.95rem; font-weight:500; display:flex; align-items:center; gap:0.5rem; }}
  .layer-name .arrow {{ font-size:0.7rem; color:var(--text-secondary); transition:transform 0.2s; display:inline-block; width:1em; }}
  .layer.open .layer-name .arrow {{ transform:rotate(90deg); }}
  .badge {{ display:inline-flex; align-items:center; gap:0.35rem; padding:0.2rem 0.65rem; border-radius:9999px; font-size:0.8rem; font-weight:600; white-space:nowrap; }}
  .badge-ok {{ background:var(--ok-bg); color:var(--ok); border:1px solid var(--ok-border); }}
  .badge-pending {{ background:var(--pending-bg); color:var(--pending); border:1px solid var(--pending-border); }}
  .badge-fail {{ background:var(--fail-bg); color:var(--fail); border:1px solid var(--fail-border); }}
  .dot {{ width:8px; height:8px; border-radius:50%; display:inline-block; }}
  .dot-ok {{ background:var(--ok); }} .dot-pending {{ background:var(--pending); }} .dot-fail {{ background:var(--fail); }}
  .checks {{ display:none; padding:0 2rem 1rem 3.25rem; }}
  .layer.open .checks {{ display:block; }}
  .check-row {{ display:flex; align-items:flex-start; justify-content:space-between; gap:1rem; padding:0.5rem 0; border-bottom:1px dashed #f0f0f0; font-size:0.875rem; }}
  .check-row:last-child {{ border-bottom:none; }}
  .check-name {{ flex:1; min-width:0; }}
  .check-evidence {{ color:var(--text-secondary); font-size:0.8rem; margin-top:0.2rem; font-family:"SF Mono",Consolas,monospace; word-break:break-word; }}
  .check-hint {{ font-size:0.8rem; margin-top:0.25rem; padding:0.35rem 0.6rem; border-radius:4px; }}
  .hint-fail {{ background:var(--fail-bg); color:var(--fail); border-left:3px solid var(--fail); }}
  .hint-pending {{ background:var(--pending-bg); color:var(--pending); border-left:3px solid var(--pending); }}
  .footer {{ padding:1rem 2rem; border-top:1px solid var(--border); font-size:0.8rem; color:var(--text-secondary); display:flex; justify-content:space-between; }}
  @media print {{ body {{ background:#fff; padding:0; }} .report {{ box-shadow:none; }} .layer.open .checks {{ display:block; }} }}
</style>
</head>
<body>
<div class="report">
  <div class="header">
    <h1>Intel AI for Enterprise &mdash; Stack Health Report</h1>
    <div class="ts">Generated: {timestamp} &middot; Cluster: {cluster_url}</div>
  </div>
  <div class="summary-bar">
    <div class="summary-stat"><span class="num num-ok">{ok}</span><span class="label">Passed</span></div>
    {pending_section}
    {fail_section}
    <div class="summary-stat" style="margin-left:auto;"><span class="num" style="font-size:1rem;color:var(--text-secondary);">{total}</span><span class="label">layers checked</span></div>
  </div>'''

if __name__ == '__main__':
    main()
