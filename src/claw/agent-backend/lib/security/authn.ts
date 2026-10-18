// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Authentication: a Keycloak access token, verified here even though the gateway checks it too.
import { createRemoteJWKSet, jwtVerify, errors as joseErrors, type JWTPayload } from "jose";
import { HttpError, type HeaderSource, headerGet } from "../identity.js";
import { parseScopeClaim } from "./scopes.js";

const list = (v: string | undefined) => (v || "").split(",").map((s) => s.trim()).filter(Boolean);

// Keys come from the in-cluster URL; `iss` carries the realm's public URL, so both are set.
const JWKS_URL = (process.env.JWT_JWKS_URL || "").trim();
const ISSUERS = list(process.env.JWT_ISSUER);
// The token must be for this API: an accepted audience or authorized party (azp).
const AUDIENCES = new Set(list(process.env.JWT_AUDIENCE));
const AZP = new Set(list(process.env.JWT_AUTHORIZED_PARTIES));
const ADMIN_ROLE = (process.env.JWT_ADMIN_ROLE || "platform-admin").trim();
const CLOCK_SKEW_S = Number(process.env.JWT_CLOCK_SKEW_SECONDS || "60");
const JWKS_TIMEOUT_MS = Number(process.env.JWT_JWKS_TIMEOUT_MS || "5000");
// An unknown `kid` refetches at most this often, so key rotation works and a flood cannot.
const JWKS_COOLDOWN_MS = Number(process.env.JWT_JWKS_COOLDOWN_MS || "30000");
const JWKS_CACHE_MS = Number(process.env.JWT_JWKS_CACHE_MS || "600000");

export interface SecurityContext {
  readonly subject: string;   // `sub`
  readonly email: string;     // the owner key (spec.owner.principal)
  readonly username: string;  // keys the owner's namespace
  readonly roles: readonly string[];
  readonly scopes: readonly string[]; // the `scope` claim; scopes.ts decides which are ours
  readonly isAdmin: boolean;
  readonly tenantId: string;
  readonly requestId: string;
  readonly authMethod: "jwt";
}

let keys: ReturnType<typeof createRemoteJWKSet> | null = null;

function keySet() {
  keys ??= createRemoteJWKSet(new URL(JWKS_URL), {
    timeoutDuration: JWKS_TIMEOUT_MS, cooldownDuration: JWKS_COOLDOWN_MS, cacheMaxAge: JWKS_CACHE_MS,
  });
  return keys;
}

function claimStr(p: JWTPayload, key: string): string {
  const v = (p as Record<string, unknown>)[key];
  return typeof v === "string" ? v.trim() : "";
}

// Realm roles plus the requesting client's own roles.
function extractRoles(p: JWTPayload): string[] {
  const azp = claimStr(p, "azp");
  const all = [...((p as any)?.realm_access?.roles ?? []), ...((azp && (p as any)?.resource_access?.[azp]?.roles) || [])];
  return [...new Set(all.filter((r): r is string => typeof r === "string"))];
}

export function extractToken(h: HeaderSource): string {
  const m = /^Bearer\s+(.+)$/i.exec(headerGet(h, "authorization"));
  return m ? m[1].trim() : "";
}

// 401 names the failed check, never the token; an unreachable IdP is our outage (503).
export async function verifyToken(token: string): Promise<JWTPayload> {
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(token, keySet(), {
      issuer: ISSUERS,
      clockTolerance: CLOCK_SKEW_S,
      // Asymmetric only, so a public key can never act as an HMAC secret.
      algorithms: ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256"],
      requiredClaims: ["sub", "iss", "exp", "iat"],
    }));
  } catch (e: any) {
    if (e instanceof joseErrors.JWTExpired) throw new HttpError(401, "unauthenticated: token expired");
    if (e instanceof joseErrors.JWKSNoMatchingKey) {
      throw new HttpError(401, "unauthenticated: token signing key is not published by the configured issuer");
    }
    if (e instanceof joseErrors.JWSSignatureVerificationFailed) {
      throw new HttpError(401, "unauthenticated: token signature is invalid");
    }
    if (e instanceof joseErrors.JOSEError) throw new HttpError(401, `unauthenticated: ${e.code || "token rejected"}`);
    throw new HttpError(503, `identity provider unreachable: ${e?.message ?? e}`);
  }
  const auds = [payload.aud ?? []].flat().map(String);
  if (!auds.some((a) => AUDIENCES.has(a)) && !AZP.has(claimStr(payload, "azp"))) {
    // A genuine token for something else, e.g. an agent's own service-account token.
    throw new HttpError(401, "unauthenticated: token was not issued for this API");
  }
  return payload;
}

export function contextFromClaims(p: JWTPayload, requestId: string): SecurityContext {
  const email = claimStr(p, "email").toLowerCase();
  // Ownership is keyed by email, so a token without one cannot be scoped.
  if (!email) throw new HttpError(401, "unauthenticated: token has no 'email' claim (add an email mapper to the client)");
  const roles = extractRoles(p);
  return {
    subject: claimStr(p, "sub"),
    email,
    // owner_username: set by a realm mapper on API clients, whose own usernames carry hyphens.
    username: claimStr(p, "owner_username") || claimStr(p, "preferred_username") || email.split("@")[0],
    roles,
    scopes: parseScopeClaim((p as Record<string, unknown>)["scope"]),
    isAdmin: roles.includes(ADMIN_ROLE),
    tenantId: claimStr(p, "tenant_id"),
    requestId,
    authMethod: "jwt",
  };
}

// Refused at boot: each of these would otherwise fail open per request.
export function assertAuthnConfig(): void {
  if (!JWKS_URL || !ISSUERS.length) throw new Error("authn misconfigured: set JWT_JWKS_URL and JWT_ISSUER");
  if (!AUDIENCES.size && !AZP.size) {
    throw new Error("authn misconfigured: set JWT_AUDIENCE or JWT_AUTHORIZED_PARTIES, or any token from the realm is accepted");
  }
}

// Full values, for the boot log only.
export function authnConfigSummary(): Record<string, unknown> {
  return {
    jwksUrl: JWKS_URL, issuers: ISSUERS, audiences: [...AUDIENCES], authorizedParties: [...AZP],
    adminRole: ADMIN_ROLE, clockSkewSeconds: CLOCK_SKEW_S,
  };
}

// Counts only, for unauthenticated callers: which client IDs are accepted is a target list.
export function authnConfigPublicSummary(): Record<string, unknown> {
  return {
    jwtEnabled: Boolean(JWKS_URL && ISSUERS.length), issuerCount: ISSUERS.length, audienceCount: AUDIENCES.size,
    authorizedPartyCount: AZP.size, adminRole: ADMIN_ROLE, clockSkewSeconds: CLOCK_SKEW_S,
  };
}
