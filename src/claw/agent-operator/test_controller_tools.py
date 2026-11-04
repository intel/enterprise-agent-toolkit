# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Tool resolution: which registration an agent's skill reaches, and which are refused."""
import unittest

import testlib

C = testlib.load_controller()
URL = "http://mcp-memory-server.agent-operator-system.svc.cluster.local:8000/sse"


def _tool(name, skill, url=URL, created="2026-01-01T00:00:00Z", **spec):
    return {"metadata": {"name": name, "creationTimestamp": created},
            "spec": {"skill": skill, "url": url, **spec}}


class ResolveTest(unittest.TestCase):
    def test_a_tool_is_registered_with_its_fields(self):
        table, phases = C._resolve_tools([_tool("memory", "memory", requiresIdentity=True, alwaysOn=True)])
        self.assertEqual(phases, {"memory": "Registered"})
        self.assertEqual(table["memory"], {"url": URL, "transport": "sse", "requiresIdentity": True,
                                           "alwaysOn": True, "aliases": []})

    def test_the_oldest_tool_wins_a_skill(self):
        newer = _tool("b-new", "memory", url="http://other.ns.svc:8000/sse", created="2026-02-01T00:00:00Z")
        table, phases = C._resolve_tools([newer, _tool("z-old", "memory")])
        self.assertEqual(table["memory"]["url"], URL)
        self.assertEqual(phases, {"z-old": "Registered", "b-new": "Conflicting"})

    def test_off_cluster_urls_are_rejected(self):
        for url in ("http://10.42.3.17:8000/sse", "http://evil.example.com/sse",
                    "http://mcp-memory-server.pgvector.svc.cluster.local.evil.com/sse", ""):
            table, phases = C._resolve_tools([_tool("memory", "memory", url=url)])
            self.assertEqual((table, phases), ({}, {"memory": "Rejected"}), url)

    def test_the_short_service_form_is_accepted(self):
        table, _ = C._resolve_tools([_tool("memory", "memory", url="http://mcp-memory-server.ns.svc:8000/sse")])
        self.assertIn("memory", table)

    def test_an_alias_never_shadows_a_skill_or_an_earlier_alias(self):
        table, _ = C._resolve_tools([
            _tool("memory", "memory"),
            _tool("sandbox", "sandbox", created="2026-01-02T00:00:00Z", aliasSkills=["shell", "memory"]),
            _tool("other", "other", created="2026-01-03T00:00:00Z", aliasSkills=["shell"])])
        self.assertEqual((table["sandbox"]["aliases"], table["other"]["aliases"]), (["shell"], []))


if __name__ == "__main__":
    unittest.main(verbosity=2)
