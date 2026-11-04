# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Only a verified token for this server, holding the operation's scope, gets through."""
import time
import unittest

import auth
from testlib import OTHER_KEY, AuthCase, token


class CallerTest(AuthCase):
    def test_a_valid_token_yields_its_claims(self):
        self.call_as(token("mcp-test", "tools:x"))
        self.assertEqual(auth.caller("tools:x")["azp"], "agent-alice-lab")

    def test_no_bearer_is_refused(self):
        with self.assertRaises(auth.AuthError):
            auth.caller("tools:x")

    def test_forged_or_misdirected_tokens_are_refused(self):
        for tok in (token("mcp-test", "tools:x", key=OTHER_KEY), token("mcp-other", "tools:x"),
                    token("mcp-test", "tools:x", iss="https://evil"),
                    token("mcp-test", "tools:x", exp=int(time.time()) - 10),
                    token("mcp-test", "tools:x", azp=None),
                    token("mcp-test", "tools:x", scope_claim="mcp-other tools:x")):
            self.call_as(tok)
            with self.assertRaises(auth.AuthError):
                auth.caller("tools:x")

    def test_an_operation_outside_the_scopes_is_refused_even_when_cached(self):
        self.call_as(token("mcp-test", "tools:read"))
        auth.caller("tools:read")
        with self.assertRaises(auth.AuthError):
            auth.caller("tools:write")

    def test_the_cache_holds_no_token(self):
        tok = token("mcp-test", "tools:x")
        self.call_as(tok)
        auth.caller("tools:x")
        self.assertNotIn(tok, repr(auth._cache))


if __name__ == "__main__":
    unittest.main(verbosity=2)
