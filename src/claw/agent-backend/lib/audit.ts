// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Audit: who did what to which resource, and on what basis. The backend is the only Kubernetes
// client, so only it knows which person asked. Every event goes to stdout; with AUDIT_PG_DSN it is
// also stored in a month-partitioned table. A failed write never fails the request, and is logged.
import { readFileSync } from "node:fs";
import pg from "pg";

export type Outcome = "allowed" | "denied" | "error";

export interface AuditEvent {
  action: string;        // agent.create | agent.delete | grant.create | ...
  outcome: Outcome;
  actorSub: string;
  actorEmail: string;
  resourceType: string;  // agent | grant | gateway-token
  resourceId?: string;   // <namespace>/<name>
  tenantId?: string;
  requestId?: string;
  authMethod?: string;
  reason?: string;       // why denied, or the error
  decidedBy?: string;    // role | scope | owner | grant | break-glass | break-glass-refused
  metadata?: Record<string, unknown>;
}

const DSN = (process.env.AUDIT_PG_DSN || "").trim();
const TABLE = "audit_events";
const DEFAULT_PARTITION = `${TABLE}_default`;
const ENSURE_FN = `${TABLE}_ensure_partitions`;
const MONTHS_AHEAD = 2;
export const auditPersistenceEnabled = (): boolean => Boolean(DSN);

// Append-only from here: no statement in this service removes a row. Retention drops whole
// months from a separate CronJob. A month without a partition lands in the default one.
const DDL = `
CREATE TABLE IF NOT EXISTS ${TABLE} (
  id             BIGSERIAL,
  ts             TIMESTAMPTZ  NOT NULL DEFAULT now(),
  tenant_id      TEXT         NOT NULL DEFAULT '',
  actor_sub      TEXT         NOT NULL,
  actor_email    TEXT         NOT NULL DEFAULT '',
  auth_method    TEXT         NOT NULL DEFAULT '',
  action         TEXT         NOT NULL,
  resource_type  TEXT         NOT NULL,
  resource_id    TEXT         NOT NULL DEFAULT '',
  outcome        TEXT         NOT NULL,
  reason         TEXT         NOT NULL DEFAULT '',
  request_id     TEXT         NOT NULL DEFAULT '',
  decided_by     TEXT         NOT NULL DEFAULT '',
  metadata       JSONB        NOT NULL DEFAULT '{}'::jsonb
) PARTITION BY RANGE (ts);
CREATE TABLE IF NOT EXISTS ${DEFAULT_PARTITION} PARTITION OF ${TABLE} DEFAULT;

-- Creates this month and the next ones in UTC; the retention CronJob calls it too.
CREATE OR REPLACE FUNCTION ${ENSURE_FN}(ahead int DEFAULT ${MONTHS_AHEAD})
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  lo timestamp;
  part text;
BEGIN
  FOR i IN 0..ahead LOOP
    lo := date_trunc('month', now() AT TIME ZONE 'UTC') + make_interval(months => i);
    part := format('${TABLE}_%s', to_char(lo, 'YYYY_MM'));
    BEGIN
      EXECUTE format('CREATE TABLE %I PARTITION OF ${TABLE} FOR VALUES FROM (%L) TO (%L)',
                     part, lo AT TIME ZONE 'UTC', (lo + interval '1 month') AT TIME ZONE 'UTC');
    EXCEPTION
      WHEN duplicate_table OR invalid_object_definition THEN NULL;
      -- The month's rows are already in the default partition; a DBA must move them first.
      WHEN check_violation THEN
        RAISE WARNING 'audit: cannot create %: its rows are already in ${DEFAULT_PARTITION}', part;
    END;
  END LOOP;
END
$fn$;
SELECT ${ENSURE_FN}(${MONTHS_AHEAD});

CREATE INDEX IF NOT EXISTS ${TABLE}_tenant_ts_idx   ON ${TABLE} (tenant_id, ts DESC);
CREATE INDEX IF NOT EXISTS ${TABLE}_actor_ts_idx    ON ${TABLE} (actor_sub, ts DESC);
CREATE INDEX IF NOT EXISTS ${TABLE}_resource_ts_idx ON ${TABLE} (resource_type, resource_id, ts DESC);
CREATE INDEX IF NOT EXISTS ${TABLE}_request_idx     ON ${TABLE} (request_id);
CREATE INDEX IF NOT EXISTS ${TABLE}_denied_ts_idx   ON ${TABLE} (ts DESC) WHERE outcome = 'denied';
CREATE INDEX IF NOT EXISTS ${TABLE}_breakglass_ts_idx ON ${TABLE} (ts DESC)
  WHERE decided_by IN ('break-glass', 'break-glass-refused');
`;

export const AUDIT_DDL = DDL;
export const AUDIT_TABLE = TABLE;
export const AUDIT_DEFAULT_PARTITION = DEFAULT_PARTITION;
export const AUDIT_ENSURE_FN = ENSURE_FN;

let pool: pg.Pool | null = null;
let schemaReady: Promise<void> | null = null;

function getPool(): pg.Pool {
  if (!pool) {
    // A libpq keyword DSN (the platform's form) or a postgres:// URL.
    const url = /^postgres(ql)?:\/\//.test(DSN);
    pool = new pg.Pool({
      ...(url ? { connectionString: DSN } : parseKeywordDsn(DSN)),
      max: 4, connectionTimeoutMillis: 5000, idleTimeoutMillis: 30_000, application_name: "agent-backend-audit",
    });
    pool.on("error", (e) => console.error(JSON.stringify({ level: "error", msg: "audit pool error", err: String(e) })));
  }
  return pool;
}

// libpq sslmode semantics: verify-ca checks the chain, verify-full also the hostname.
function sslFromMode(mode?: string, rootCert?: string): false | Record<string, unknown> {
  if (!mode || mode === "disable") return false;
  if (mode !== "verify-ca" && mode !== "verify-full") return { rejectUnauthorized: false };
  return {
    rejectUnauthorized: true,
    ...(rootCert ? { ca: readFileSync(rootCert, "utf8") } : {}),
    ...(mode === "verify-ca" ? { checkServerIdentity: () => undefined } : {}),
  };
}

function parseKeywordDsn(dsn: string): pg.PoolConfig {
  const kv = Object.fromEntries(dsn.split(/\s+/).map((p) => [p.slice(0, p.indexOf("=")), p.slice(p.indexOf("=") + 1)]));
  return {
    host: kv.host, port: kv.port ? Number(kv.port) : undefined, database: kv.dbname, user: kv.user,
    password: kv.password, ssl: sslFromMode(kv.sslmode, kv.sslrootcert) as pg.PoolConfig["ssl"],
  };
}

// Once per process; a failure is retried on the next event.
function ensureSchema(): Promise<void> {
  schemaReady ??= getPool().query(DDL).then(() => undefined, (e) => {
    schemaReady = null;
    throw e;
  });
  return schemaReady;
}

export async function audit(e: AuditEvent): Promise<void> {
  console.log(JSON.stringify({
    audit: true, ts: new Date().toISOString(), action: e.action, outcome: e.outcome, actorSub: e.actorSub,
    actorEmail: e.actorEmail, authMethod: e.authMethod ?? "", resourceType: e.resourceType,
    resourceId: e.resourceId ?? "", tenantId: e.tenantId ?? "", requestId: e.requestId ?? "",
    decidedBy: e.decidedBy ?? "", reason: e.reason ?? "",
    ...(e.metadata && Object.keys(e.metadata).length ? { metadata: e.metadata } : {}),
  }));
  if (!DSN) return;
  try {
    await ensureSchema();
    await getPool().query(
      `INSERT INTO ${TABLE} (tenant_id, actor_sub, actor_email, auth_method, action, resource_type,
         resource_id, outcome, reason, request_id, decided_by, metadata)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [e.tenantId ?? "", e.actorSub, e.actorEmail, e.authMethod ?? "", e.action, e.resourceType, e.resourceId ?? "",
        e.outcome, e.reason ?? "", e.requestId ?? "", e.decidedBy ?? "", JSON.stringify(e.metadata ?? {})],
    );
  } catch (err: any) {
    console.error(JSON.stringify({
      level: "error", msg: "AUDIT PERSISTENCE FAILED: event survives only in stdout",
      action: e.action, requestId: e.requestId ?? "", err: err?.message ?? String(err),
    }));
  }
}

// At boot, so a broken DSN shows now rather than when the trail is needed.
export async function auditPreflight(): Promise<void> {
  if (DSN) await ensureSchema();
}

export async function auditShutdown(): Promise<void> {
  await pool?.end().catch(() => undefined);
  pool = null;
}
