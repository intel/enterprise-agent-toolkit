// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Token verification against a real JWKS: only a token signed by the realm, for this API, passes.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import type { webcrypto } from "node:crypto";

type Key = webcrypto.CryptoKey;

const ISS = "https://keycloak.example.com/realms/agent-toolkit";
let server: Server;
let authn: typeof import("../lib/security/authn.js");
let key: Key, other: Key;

before(async () => {
  const pair = await generateKeyPair("RS256");
  key = pair.privateKey as Key;
  other = (await generateKeyPair("RS256")).privateKey as Key;
  const jwk = { ...(await exportJWK(pair.publicKey)), kid: "k1", alg: "RS256", use: "sig" };
  server = createServer((_q, s) => s.end(JSON.stringify({ keys: [jwk] })));
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as any).port;
  Object.assign(process.env, { JWT_JWKS_URL: `http://127.0.0.1:${port}/certs`, JWT_ISSUER: ISS, JWT_AUDIENCE: "agent-backend", JWT_AUTHORIZED_PARTIES: "agent-console" });
  authn = await import("../lib/security/authn.js");
});

after(() => server.close());

const sign = (claims: Record<string, unknown>, k = key, alg = "RS256") =>
  new SignJWT({ email: "alice@example.com", email_verified: true, preferred_username: "alice", scope: "openid agent:read",
    realm_access: { roles: ["agent-editor"] }, ...claims })
    .setProtectedHeader({ alg, kid: "k1" }).setIssuer(String(claims.iss ?? ISS)).setSubject("sub-1")
    .setIssuedAt().setExpirationTime((claims.exp as number | undefined) ?? "5m").sign(k);

test("a realm token for this API yields the caller", async () => {
  const c = authn.contextFromClaims(await authn.verifyToken(await sign({ aud: "agent-backend" })), "r1");
  assert.deepEqual([c.email, c.username, c.roles, c.scopes], ["alice@example.com", "alice", ["agent-editor"], ["openid", "agent:read"]]);
  await authn.verifyToken(await sign({ aud: "account", azp: "agent-console" })); // an authorized party is enough
});

test("an API client's mapped owner_username names the owner", async () => {
  const c = authn.contextFromClaims(await authn.verifyToken(await sign({
    aud: "agent-backend", preferred_username: "service-account-agent-api", owner_username: "automation" })), "r1");
  assert.equal(c.username, "automation");
});

test("forged, misdirected and expired tokens are 401", async () => {
  for (const t of [await sign({ aud: "agent-backend" }, other), await sign({ aud: "account", azp: "agent-alice-lab" }),
    await sign({ aud: "agent-backend", iss: "https://evil.example.com" }), await sign({ aud: "agent-backend", exp: Math.floor(Date.now() / 1000) - 120 })]) {
    await assert.rejects(authn.verifyToken(t), (e: any) => e.status === 401);
  }
});

test("a token without an email cannot be scoped and is refused", async () => {
  const claims = await authn.verifyToken(await sign({ aud: "agent-backend", email: "" }));
  assert.throws(() => authn.contextFromClaims(claims, "r1"), (e: any) => e.status === 401);
});

test("a token whose email is not verified is refused", async () => {
  // Ownership and grants match on email, which users can usually edit themselves.
  for (const email_verified of [false, undefined, "true"]) {
    const claims = await authn.verifyToken(await sign({ aud: "agent-backend", email_verified }));
    assert.throws(() => authn.contextFromClaims(claims, "r1"), (e: any) => e.status === 401 && /not verified/.test(e.message));
  }
});

test("only the bearer header carries the token", () => {
  assert.equal(authn.extractToken({ authorization: "Bearer abc" }), "abc");
  assert.equal(authn.extractToken({ "x-forwarded-access-token": "abc" }), "");
});
