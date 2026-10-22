# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""GitHub server: whose PAT is used, what reaches the API, and what a scope allows."""
import ast
import os
import types
import unittest

import github
from testlib import AuthCase, token

PAT, SHARED = "ghp-alice-own", "ghp-shared"


class GithubCase(AuthCase):
    audience = "mcp-github"

    def setUp(self):
        super().setUp()
        self.calls = []

        def request(method, url, headers=None, timeout=None, **kw):
            self.calls.append((method, url, headers, kw))
            body = {"number": 7, "html_url": "https://github.example/pr/7", "default_branch": "main"}
            return types.SimpleNamespace(status_code=201, content=b"{}", text="", json=lambda: body)

        for name, value in (("SHARED_TOKEN", SHARED), ("_default_branches", {})):
            self.addCleanup(setattr, github, name, getattr(github, name))
            setattr(github, name, value)
        self.addCleanup(setattr, github._session, "request", github._session.request)
        github._session.request = request
        self.addCleanup(setattr, github, "get_http_headers", github.get_http_headers)
        github.get_http_headers = lambda include=None: {k: v for k, v in self.headers.items() if k in include}

    def as_agent(self, scope="tools:github.read tools:github.write", pat=None):
        self.call_as(token("mcp-github", scope))
        if pat:
            self.headers[github.PAT_HEADER] = pat


class TokenTest(GithubCase):
    def test_the_agent_s_own_pat_wins_over_the_shared_token(self):
        for pat, expected in ((PAT, PAT), (None, SHARED)):
            self.as_agent(pat=pat)
            github.create_issue("octo", "demo", "t")
            self.assertEqual(self.calls[-1][2]["Authorization"], f"Bearer {expected}")

    def test_no_token_at_all_is_an_error_not_an_anonymous_call(self):
        github.SHARED_TOKEN = ""
        self.as_agent()
        self.assertIn("no GitHub token", github.create_issue("octo", "demo", "t"))
        self.assertEqual(self.calls, [])

    def test_errors_never_carry_the_token(self):
        self.as_agent(pat=PAT)
        github._session.request = lambda *a, **kw: types.SimpleNamespace(status_code=401, text="Bad credentials",
                                                                         content=b"")
        self.assertNotIn(PAT, github.list_issues("octo", "demo"))


class RequestTest(GithubCase):
    def test_pull_requests_always_open_as_drafts(self):
        self.as_agent()
        self.assertIn("DRAFT", github.create_pull_request("octo", "demo", "t", "b", head="fix"))
        method, url, _, kw = self.calls[-1]
        self.assertEqual((method, url, kw["json"]["draft"], kw["json"]["base"]),
                         ("POST", "https://api.github.com/repos/octo/demo/pulls", True, "main"))

    def test_names_that_would_reach_another_api_path_are_refused(self):
        self.as_agent()
        for owner, repo in (("..", "x"), ("octo/../../user", "x"), ("octo", "demo?x=1"), ("", "x")):
            self.assertIn("invalid", github.list_issues(owner, repo))
        self.assertIn("invalid", github.create_branch("octo", "demo", "a b"))
        self.assertEqual(self.calls, [])

    def test_file_paths_are_url_quoted(self):
        self.as_agent()
        github.get_file_contents("octo", "demo", "dir/a b?.py", ref="main")
        self.assertTrue(self.calls[-1][1].endswith("/contents/dir/a%20b%3F.py"))


class ScopeTest(GithubCase):
    def test_a_read_only_agent_cannot_write(self):
        self.as_agent(scope="tools:github.read")
        self.assertIn("not entitled", github.create_issue("octo", "demo", "t"))
        self.assertNotIn("not entitled", github.list_issues("octo", "demo"))
        self.assertEqual([c[0] for c in self.calls], ["GET"])

    def test_every_tool_is_covered_by_an_operator_permission_scope(self):
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "agent-operator", "controller.py")) as fh:
            scopes = next(ast.literal_eval(n.value) for n in ast.parse(fh.read()).body
                          if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "PERMISSION_SCOPES")
        with open(github.__file__) as fh:
            tools = {f.name for f in ast.parse(fh.read()).body if isinstance(f, ast.FunctionDef)
                     and any("mcp.tool" in ast.unparse(d) for d in f.decorator_list)}
        self.assertEqual(len(tools), 11)
        self.assertEqual(tools, set(scopes["tools:github.read"]) | set(scopes["tools:github.write"]))

if __name__ == "__main__":
    unittest.main(verbosity=2)
