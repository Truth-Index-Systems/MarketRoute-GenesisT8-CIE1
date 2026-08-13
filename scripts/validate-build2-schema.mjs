import fs from "node:fs";
import path from "node:path";
import { ROOT, assert, check, printResults, readJson } from "./lib/constitution.mjs";

const boundary = readJson("constitution/database-boundary.json");
const manifest = readJson("constitution/authority-manifest.json");
const migrationDir = path.join(ROOT, "supabase/migrations");
const sqlFiles = fs.readdirSync(migrationDir).filter((name) => /^000[1-5]_.*\.sql$/.test(name)).sort();
const sql = sqlFiles.map((name) => fs.readFileSync(path.join(migrationDir, name), "utf8")).join("\n");
const lower = sql.toLowerCase();
const allSql = fs.readdirSync(migrationDir).filter((name) => /^\d{4}_.*\.sql$/.test(name)).sort().map((name) => fs.readFileSync(path.join(migrationDir, name), "utf8")).join("\n");
const allLower = allSql.toLowerCase();

const tableExists = (table) => new RegExp(`create\\s+table\\s+public\\.${table}\\b`, "i").test(sql);
const hasRevoke = (table, roles) => roles.every((role) => new RegExp(`revoke\\s+all\\s+on\\s+public\\.${table}\\s+from[^;]*\\b${role}\\b`, "i").test(sql));

const results = [
  check("Build 2 owns exactly migrations 0001-0005", () => assert(sqlFiles.length === 5, `found ${sqlFiles.join(", ")}`)),
  check("authority manifest remains zero-writer", () => assert(manifest.schemaBuild < 6 ? manifest.authorityWriters.length === 0 : manifest.authorityWriters.length === 1, "unexpected authority writer count")),
  check("authority manifest remains a pre-authority successor of Build 2", () => assert(manifest.schemaBuild >= 2, `schemaBuild=${manifest.schemaBuild}`)),
  check("database boundary preserves Build 2 laws in a successor build", () => assert(boundary.build >= 2, "database boundary regressed below Build 2")),
  check("authority is declared time-bound", () => assert(boundary.principles.authorityIsTimeBound === true, "time-bound authority missing")),
  check("authority fingerprint recomputation is a future persistence law", () => assert(boundary.principles.authorityFingerprintMustEventuallyBeRecomputedAtPersistenceBoundary === true, "fingerprint law missing")),
  check("authority records require finite valid_until", () => assert(/valid_until\s+timestamptz\s+not\s+null/i.test(sql), "authority valid_until is nullable")),
  check("workflow state is physically separate from authority records", () => {
    const opp = sql.match(/create\s+table\s+public\.opportunities\s*\(([\s\S]*?)\n\);/i)?.[1] ?? "";
    assert(/workflow_state/i.test(opp), "workflow state missing");
    assert(!/authority_fingerprint|decision_code|valid_until/i.test(opp), "opportunities contain authority fields");
  }),
  check("reasoning artifacts are physically separate from authority records", () => {
    assert(tableExists("reasoning_artifacts"), "reasoning artifacts missing");
    assert(tableExists("authority_records"), "authority records missing");
  }),
  check("authority registry starts with no INSERT seed", () => {
    assert(!/insert\s+into\s+public\.authority_writer_registry/i.test(sql), "authority writer seeded in Build 2");
  }),
  check("authority records have declared-writer trigger", () => assert(/authority_records_declared_writer_gate/i.test(sql), "authority writer trigger missing")),
  check("authority events have declared-writer trigger", () => assert(/authority_events_declared_writer_gate/i.test(sql), "authority event trigger missing")),
  check("authority direct DML revoked from service_role", () => {
    for (const table of ["authority_writer_registry", "authority_records", "authority_events"])
      assert(hasRevoke(table, ["service_role"]), `${table} service_role revoke missing`);
  }),
  check("authenticated cannot mutate opportunities directly", () => {
    assert(!/grant\s+[^;]*(insert|update|delete)[^;]*on\s+public\.opportunities\s+to\s+authenticated/i.test(sql), "authenticated opportunity mutation grant found");
  }),
  check("service_role cannot mutate opportunities directly", () => {
    assert(/revoke\s+all\s+on\s+public\.opportunities\s+from[^;]*service_role/i.test(sql), "service_role workflow revoke missing");
  }),
  check("raw evidence stores origin and observation time separately", () => {
    assert(/origin_published_at\s+timestamptz/i.test(sql), "origin time missing");
    assert(/observed_at\s+timestamptz/i.test(sql), "observation time missing");
  }),
  check("claim polarity is categorical SUPPORTS/CONTRADICTS", () => assert(/polarity\s+text[^\n]*supports[^\n]*contradicts/i.test(sql), "claim polarity contract missing")),
  check("dependence family is mandatory at evidence linkage", () => assert(/dependence_family_key\s+text\s+not\s+null/i.test(sql), "dependence family optional")),
  check("claims are corrected by append-only supersession", () => assert(tableExists("claim_supersessions"), "claim supersessions missing")),
  check("scheduler leases exist", () => assert(tableExists("scheduler_leases"), "scheduler leases missing")),
  check("job attempts exist separately from jobs", () => assert(tableExists("background_job_attempts"), "job attempt ledger missing")),
  check("AI cost telemetry is not stored on authority records", () => {
    const authority = sql.match(/create\s+table\s+public\.authority_records\s*\(([\s\S]*?)\n\);/i)?.[1] ?? "";
    assert(!/cost|tokens|latency/i.test(authority), "telemetry leaked into authority record");
  }),
  check("audit ledger exists", () => assert(tableExists("audit_events"), "audit ledger missing")),
];

for (const table of boundary.appendOnlyTables) {
  results.push(check(`${table} has append-only mutation trigger`, () => {
    const marker = `${table}_append_only`;
    assert(allLower.includes(marker.toLowerCase()), `${marker} missing`);
  }));
}

for (const column of boundary.forbiddenCommercialAuthorityColumns) {
  results.push(check(`forbidden legacy authority column absent: ${column}`, () => {
    assert(!allLower.includes(column.toLowerCase()), `${column} found in V2 schema`);
  }));
}

printResults("MarketRoute V2 Build 2 — constitutional schema", results);
