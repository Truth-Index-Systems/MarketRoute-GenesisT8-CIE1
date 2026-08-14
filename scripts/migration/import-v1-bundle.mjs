#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { COLLECTION_ORDER, validateBundle } from "./v1-contract.mjs";

function parseArgs(argv) {
  const args = { execute: false, allowRejections: false };
  for (let i = 2; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--execute") args.execute = true;
    else if (value === "--allow-rejections") args.allowRejections = true;
    else if (!args.file) args.file = value;
    else throw new Error(`Unknown argument ${value}`);
  }
  return args;
}

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required for --execute`);
  return value;
}

function errorCode(error) {
  const text = String(error?.message ?? error ?? "UNKNOWN");
  const match = text.match(/MARKETROUTE_[A-Z0-9_]+/);
  return match?.[0] ?? "MARKETROUTE_V1_IMPORT_RECORD_FAILED";
}

async function rpc(baseUrl, key, name, payload) {
  const response = await fetch(`${baseUrl.replace(/\/$/, "")}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const body = await response.text();
  let parsed = body;
  try { parsed = body ? JSON.parse(body) : null; } catch {}
  if (!response.ok) {
    const message = typeof parsed === "object" && parsed?.message ? parsed.message : body;
    throw new Error(`${name}:${response.status}:${message}`);
  }
  return parsed;
}

const RPC_BY_COLLECTION = {
  companies: "marketroute_import_v1_company_v1",
  people: "marketroute_import_v1_person_v1",
  accessPoints: "marketroute_import_v1_access_point_v1",
  sellerBusinesses: "marketroute_import_v1_seller_business_v1",
  sellerSources: "marketroute_import_v1_seller_source_v1",
  campaigns: "marketroute_import_v1_campaign_v1",
  campaignScopes: "marketroute_import_v1_campaign_scope_v1",
  evidence: "marketroute_import_v1_evidence_v1",
  historicalResearch: "marketroute_import_v1_historical_research_v1",
};

const args = parseArgs(process.argv);
if (!args.file) {
  console.error("Usage: node scripts/migration/import-v1-bundle.mjs <bundle.json> [--execute] [--allow-rejections]");
  process.exit(2);
}
const bundlePath = path.resolve(process.cwd(), args.file);
const bundle = JSON.parse(fs.readFileSync(bundlePath, "utf8"));
const validation = validateBundle(bundle);

if (!args.execute) {
  console.log(JSON.stringify({ mode: "DRY_RUN", ok: true, file: bundlePath, ...validation, writes: 0 }, null, 2));
  process.exit(0);
}

const supabaseUrl = requiredEnv("MR_V2_SUPABASE_URL");
const serviceRoleKey = requiredEnv("MR_V2_SUPABASE_SERVICE_ROLE_KEY");
const organisationId = requiredEnv("MR_V2_MIGRATION_ORGANISATION_ID");
const createdByUserId = requiredEnv("MR_V2_MIGRATION_CREATED_BY_USER_ID");

const batch = await rpc(supabaseUrl, serviceRoleKey, "marketroute_begin_v1_migration_v1", {
  p_target_organisation_id: organisationId,
  p_created_by_user_id: createdByUserId,
  p_source_export_fingerprint: validation.fingerprint,
  p_metadata: { exportedAt: bundle.exportedAt, exportMetadata: bundle.exportMetadata ?? {}, importer: "MRV2-BUILD17-IMPORTER-1.0.0" },
});
const batchId = batch.batchId;
if (!batchId) throw new Error("Migration batch id was not returned");
if (batch.status === "COMPLETED") {
  const report = await rpc(supabaseUrl, serviceRoleKey, "marketroute_v1_migration_report_v1", { p_batch_id: batchId });
  console.log(JSON.stringify({ mode: "EXECUTE", resumed: true, alreadyCompleted: true, report }, null, 2));
  process.exit(0);
}

let imported = 0;
let rejected = 0;
const failures = [];
for (const collection of COLLECTION_ORDER) {
  for (const record of bundle[collection] ?? []) {
    try {
      await rpc(supabaseUrl, serviceRoleKey, RPC_BY_COLLECTION[collection], {
        p_batch_id: batchId,
        p_source_table: record.sourceTable,
        p_v1_id: record.v1Id,
        p_payload: record.payload,
      });
      imported += 1;
    } catch (error) {
      rejected += 1;
      const reason = errorCode(error);
      failures.push({ collection, sourceTable: record.sourceTable, v1Id: record.v1Id, reason });
      try {
        await rpc(supabaseUrl, serviceRoleKey, "marketroute_reject_v1_migration_record_v1", {
          p_batch_id: batchId,
          p_entity_kind: collection.toUpperCase(),
          p_source_table: record.sourceTable,
          p_v1_id: record.v1Id,
          p_reason_code: reason,
          p_payload: record.payload,
          p_rejected_field_keys: [],
        });
      } catch (rejectionError) {
        failures.push({ collection, sourceTable: record.sourceTable, v1Id: record.v1Id, reason: `REJECTION_LOG_FAILED:${errorCode(rejectionError)}` });
      }
      if (!args.allowRejections) {
        console.error(JSON.stringify({ mode: "EXECUTE", ok: false, batchId, imported, rejected, failures, hint: "Fix the rejected record, then rerun the same bundle; immutable mappings make the import resumable." }, null, 2));
        process.exit(1);
      }
    }
  }
}

const completion = await rpc(supabaseUrl, serviceRoleKey, "marketroute_complete_v1_migration_v1", {
  p_batch_id: batchId,
  p_metadata: { importerVersion: "MRV2-BUILD17-IMPORTER-1.0.0", importedRecordCount: imported, rejectedRecordCount: rejected },
});
const report = await rpc(supabaseUrl, serviceRoleKey, "marketroute_v1_migration_report_v1", { p_batch_id: batchId });
console.log(JSON.stringify({ mode: "EXECUTE", ok: rejected === 0 || args.allowRejections, batchId, imported, rejected, completion, report, failures }, null, 2));
