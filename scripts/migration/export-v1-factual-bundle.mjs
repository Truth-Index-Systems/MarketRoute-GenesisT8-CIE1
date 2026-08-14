#!/usr/bin/env node
/**
 * MarketRoute V2 Build 17 — concrete V1 factual exporter.
 *
 * Source profile: MarketRoute / Genesis T8 Forensic Build 8 (schema through 0158).
 * This process is intentionally GET-only. It never calls a V1 RPC and never
 * sends POST/PATCH/PUT/DELETE requests to V1.
 */
import fs from "node:fs";
import path from "node:path";
import { CONTRACT_VERSION, validateBundle } from "./v1-contract.mjs";

const EXPORTER_VERSION = "MRV2-V1-FORENSIC-BUILD8-EXPORTER-1.0.0";
const SOURCE_PROFILE = "MRV2-V1-SOURCE-PROFILE-FORENSIC-BUILD8-1.0.0";
const PAGE_SIZE = 1000;

const READ_TABLES = Object.freeze([
  "business_profiles",
  "campaigns",
  "companies",
  "company_evidence",
  "contacts",
  "contact_evidence",
  "company_contact_channels",
  "genesis_g8_intelligence_entities",
  "genesis_g8_intelligence_claims",
  "genesis_g8_intelligence_evidence",
]);

const BLOCKED_TABLE_FRAGMENTS = Object.freeze([
  "truth_snapshot", "truth_v2_snapshot", "cie_r4", "cie_r5", "cie_r6",
  "opportunit", "commercial_route", "route_intelligence", "engagement_",
  "execution_queue", "human_review",
]);

function requiredEnv(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function clean(value) { return typeof value === "string" ? value.trim() : ""; }
function nonempty(value) { const text = clean(value); return text || null; }
function lower(value) { return clean(value).toLowerCase(); }
function normaliseName(value) { return clean(value).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(); }

function domainFromUrl(value) {
  const raw = clean(value);
  if (!raw) return null;
  try { return new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`).hostname.toLowerCase().replace(/^www\./, ""); }
  catch { return null; }
}
function validDomain(value) {
  const d = lower(value).replace(/^www\./, "");
  return /^[a-z0-9.-]+\.[a-z]{2,}$/.test(d) && !/[/:\s]/.test(d) ? d : null;
}
function canonicalDomain(row) { return validDomain(row.canonical_domain) || domainFromUrl(row.website_url) || domainFromUrl(row.canonical_url); }
function canonicalUrl(value, fallbackDomain = null) {
  const raw = clean(value);
  if (raw && /^https?:\/\/\S+$/i.test(raw)) return raw;
  return fallbackDomain ? `https://${fallbackDomain}` : null;
}
function publisherDomain(url, explicit = null) { return validDomain(explicit) || domainFromUrl(url); }
function isoCountry(value) {
  const raw = clean(value).toUpperCase();
  if (!raw) return null;
  if (raw === "UK" || raw === "UNITED KINGDOM" || raw === "ENGLAND" || raw === "SCOTLAND" || raw === "WALES" || raw === "NORTHERN IRELAND") return "GB";
  if (raw === "USA" || raw === "UNITED STATES" || raw === "UNITED STATES OF AMERICA") return "US";
  return /^[A-Z]{2}$/.test(raw) ? raw : null;
}
function emailKind(row) {
  const type = clean(row.channel_type).toUpperCase();
  if (type === "NAMED") return "PERSONAL_EMAIL";
  if (type === "DEPARTMENTAL") return "DEPARTMENT_EMAIL";
  return "GENERIC_EMAIL";
}
function sourceKindFromLegacy(value, url) {
  const kind = clean(value).toUpperCase();
  if (kind === "REGULATORY_FILING") return "REGISTRY";
  if (url) return "WEB";
  return "OTHER";
}
function dependenceFamily(url, fallback) { return publisherDomain(url) || fallback; }
function safeSourceTitle(value) { return nonempty(value); }

function assertReadTable(table) {
  if (!READ_TABLES.includes(table)) throw new Error(`V1 exporter table not whitelisted: ${table}`);
  const normal = table.toLowerCase();
  if (BLOCKED_TABLE_FRAGMENTS.some((fragment) => normal.includes(fragment))) throw new Error(`V1 exporter blocked table: ${table}`);
}

async function getAll({ baseUrl, key, table, select, filters = [], order = "id.asc" }) {
  assertReadTable(table);
  const rows = [];
  let offset = 0;
  for (;;) {
    const url = new URL(`${baseUrl.replace(/\/$/, "")}/rest/v1/${table}`);
    url.searchParams.set("select", select);
    if (order) url.searchParams.set("order", order);
    for (const [name, value] of filters) url.searchParams.set(name, value);
    const response = await fetch(url, {
      method: "GET",
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        Range: `${offset}-${offset + PAGE_SIZE - 1}`,
        "Range-Unit": "items",
      },
    });
    const text = await response.text();
    let page;
    try { page = text ? JSON.parse(text) : []; } catch { throw new Error(`V1 ${table} returned non-JSON (${response.status})`); }
    if (!response.ok && response.status !== 206) {
      const message = page && typeof page === "object" && !Array.isArray(page) ? page.message : text;
      throw new Error(`V1 read failed ${table}:${response.status}:${message}`);
    }
    if (!Array.isArray(page)) throw new Error(`V1 ${table} response must be an array`);
    rows.push(...page);
    if (page.length < PAGE_SIZE) break;
    offset += PAGE_SIZE;
  }
  return rows;
}

function companyRecord(sourceTable, row, overrides = {}) {
  const domain = overrides.domain ?? canonicalDomain(row);
  const name = nonempty(overrides.name ?? row.company_name ?? row.display_name ?? domain);
  if (!name) return null;
  return {
    sourceTable,
    v1Id: String(row.id),
    payload: {
      canonicalName: name,
      ...(domain ? { canonicalDomain: domain } : {}),
      ...((overrides.websiteUrl ?? canonicalUrl(row.website_url, domain)) ? { websiteUrl: overrides.websiteUrl ?? canonicalUrl(row.website_url, domain) } : {}),
      ...(isoCountry(row.country) ? { countryCode: isoCountry(row.country) } : {}),
    },
  };
}

function personRecord(sourceTable, row) {
  const displayName = nonempty(row.full_name ?? row.display_name);
  if (!displayName) return null;
  const canonicalName = nonempty(row.normalised_name) || normaliseName(displayName) || null;
  return { sourceTable, v1Id: String(row.id), payload: { displayName, ...(canonicalName ? { canonicalName } : {}) } };
}

function evidenceRecord({ sourceTable, v1Id, subject, url, sourceTitle, sourceKind = "WEB", sourceDomain = null, excerpt, observedAt, originPublishedAt = null, metadata = {} }) {
  const text = nonempty(excerpt);
  if (!text) return null;
  const domain = publisherDomain(url, sourceDomain);
  return {
    sourceTable,
    v1Id: String(v1Id),
    payload: {
      subject,
      source: {
        sourceTable,
        v1Id: String(v1Id),
        sourceKind,
        ...(canonicalUrl(url) ? { canonicalUrl: canonicalUrl(url) } : {}),
        ...(domain ? { publisherDomain: domain } : {}),
        ...(safeSourceTitle(sourceTitle) ? { title: safeSourceTitle(sourceTitle) } : {}),
        stableLocator: canonicalUrl(url) || `v1:${sourceTable}:${v1Id}`,
        dependenceFamilyKey: dependenceFamily(url, `v1:${sourceTable}:${v1Id}`),
        metadata,
      },
      acquisition: {
        acquiredAt: observedAt || new Date(0).toISOString(),
        rawLocator: `v1:${sourceTable}:${v1Id}`,
        parserVersion: EXPORTER_VERSION,
      },
      evidence: {
        evidenceKind: "QUOTE",
        excerptText: text,
        observedAt: observedAt || new Date(0).toISOString(),
        ...(originPublishedAt ? { originPublishedAt } : {}),
        extractionVersion: EXPORTER_VERSION,
      },
    },
  };
}

function parseGenesisDomain(entity) {
  const key = clean(entity.canonical_key);
  if (entity.entity_type === "company") return validDomain(key);
  const prefix = key.split("::", 1)[0];
  return validDomain(prefix);
}

function ref(entityKind, sourceTable, v1Id) { return { entityKind, sourceTable, v1Id: String(v1Id) }; }

function parseArgs(argv) {
  const args = {};
  for (let index = 2; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--organisation-id") args.organisationId = argv[++index];
    else if (!args.output) args.output = value;
    else throw new Error(`Unknown argument ${value}`);
  }
  return args;
}

const args = parseArgs(process.argv);
if (!args.output) {
  console.error("Usage: node scripts/migration/export-v1-factual-bundle.mjs <output.json> [--organisation-id <uuid>]");
  process.exit(2);
}

const baseUrl = requiredEnv("MR_V1_SUPABASE_URL");
const serviceRoleKey = requiredEnv("MR_V1_SUPABASE_SERVICE_ROLE_KEY");
const organisationId = clean(args.organisationId || process.env.MR_V1_ORGANISATION_ID);
if (!organisationId) throw new Error("MR_V1_ORGANISATION_ID or --organisation-id is required");

const orgFilter = [["organisation_id", `eq.${organisationId}`]];
const [
  businessProfiles, campaigns, companies, companyEvidence, contacts, contactEvidence, channels,
  genesisEntities, genesisClaims, genesisEvidence,
] = await Promise.all([
  getAll({ baseUrl, key: serviceRoleKey, table: "business_profiles", select: "id,website_url,canonical_url,company_name,summary,industry,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "campaigns", select: "id,business_profile_id,name,objective,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "companies", select: "id,campaign_id,company_name,website_url,canonical_domain,country,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "company_evidence", select: "id,company_id,claim,source_url,excerpt,source_title,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "contacts", select: "id,company_id,full_name,normalised_name,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "contact_evidence", select: "id,contact_id,claim,source_url,source_title,excerpt,evidence_type,source_kind,source_domain,retrieved_at,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "company_contact_channels", select: "id,company_id,associated_contact_id,email_address,normalised_email,channel_type,source_url,source_title,evidence_excerpt,created_at", filters: orgFilter }),
  getAll({ baseUrl, key: serviceRoleKey, table: "genesis_g8_intelligence_entities", select: "id,entity_type,canonical_key,display_name,created_at", filters: [["entity_type", "in.(company,contact,route)"]] }),
  getAll({ baseUrl, key: serviceRoleKey, table: "genesis_g8_intelligence_claims", select: "id,entity_id,claim_key,label,created_at" }),
  getAll({ baseUrl, key: serviceRoleKey, table: "genesis_g8_intelligence_evidence", select: "id,claim_id,source_class,source_uri,source_ref,source_family,excerpt,observed_at,intelligence_channel,created_at" }),
]);

const output = {
  contractVersion: CONTRACT_VERSION,
  exportedAt: new Date().toISOString(),
  exportMetadata: {
    exporterVersion: EXPORTER_VERSION,
    sourceProfile: SOURCE_PROFILE,
    organisationId,
    sourceSchema: "0158",
    sourceTables: READ_TABLES,
  },
  companies: [], people: [], accessPoints: [], sellerBusinesses: [], sellerSources: [],
  campaigns: [], campaignScopes: [], evidence: [], historicalResearch: [],
};

// Seller identity and safe seller-source material. Legacy numeric assessment is never read.
for (const row of businessProfiles) {
  const domain = canonicalDomain(row);
  output.sellerBusinesses.push({
    sourceTable: "business_profiles", v1Id: String(row.id), payload: {
      name: nonempty(row.company_name) || domain || "Imported seller",
      ...(domain ? { canonicalDomain: domain } : {}),
      ...(canonicalUrl(row.website_url || row.canonical_url, domain) ? { websiteUrl: canonicalUrl(row.website_url || row.canonical_url, domain) } : {}),
    },
  });
  output.sellerSources.push({
    sourceTable: "business_profiles", v1Id: String(row.id), payload: {
      sellerBusinessSourceTable: "business_profiles", sellerBusinessV1Id: String(row.id),
      content: {
        companyName: nonempty(row.company_name),
        websiteUrl: canonicalUrl(row.website_url || row.canonical_url, domain),
        canonicalDomain: domain,
        industry: nonempty(row.industry),
        summary: nonempty(row.summary),
        sourceType: "V1_SELLER_PROFILE",
      },
    },
  });
}

const sellerIds = new Set(output.sellerBusinesses.map((record) => record.v1Id));
for (const row of campaigns) {
  if (!sellerIds.has(String(row.business_profile_id))) continue;
  output.campaigns.push({ sourceTable: "campaigns", v1Id: String(row.id), payload: {
    sellerBusinessSourceTable: "business_profiles", sellerBusinessV1Id: String(row.business_profile_id),
    name: nonempty(row.name) || "Imported campaign", objectiveText: nonempty(row.objective),
  } });
}

// Campaign-scoped target companies.
const companyRefById = new Map();
const companyRefByDomain = new Map();
for (const row of companies) {
  const record = companyRecord("companies", row);
  if (!record) continue;
  output.companies.push(record);
  companyRefById.set(String(row.id), ref("COMPANY", record.sourceTable, record.v1Id));
  if (record.payload.canonicalDomain && !companyRefByDomain.has(record.payload.canonicalDomain)) companyRefByDomain.set(record.payload.canonicalDomain, companyRefById.get(String(row.id)));
  if (row.campaign_id) output.campaignScopes.push({
    sourceTable: "companies", v1Id: String(row.id), payload: {
      campaignSourceTable: "campaigns", campaignV1Id: String(row.campaign_id), companySourceTable: "companies", companyV1Id: String(row.id),
    },
  });
}

// Shared Genesis company identities are also factual assets. They deduplicate in V2 by canonical domain.
const genesisEntityById = new Map(genesisEntities.map((row) => [String(row.id), row]));
for (const entity of genesisEntities.filter((row) => row.entity_type === "company")) {
  const domain = parseGenesisDomain(entity);
  if (!domain) continue;
  const record = companyRecord("genesis_g8_intelligence_entities", entity, { domain, name: nonempty(entity.display_name) || domain, websiteUrl: null });
  output.companies.push(record);
  const entityRef = ref("COMPANY", record.sourceTable, record.v1Id);
  if (!companyRefByDomain.has(domain)) companyRefByDomain.set(domain, entityRef);
}

// Campaign contacts are retained as factual people. No employment edge crosses the bridge.
const personRefByContactId = new Map();
const contactCandidatesByDomainAndName = new Map();
const companyById = new Map(companies.map((row) => [String(row.id), row]));
for (const row of contacts) {
  const record = personRecord("contacts", row);
  if (!record) continue;
  output.people.push(record);
  const personRef = ref("PERSON", record.sourceTable, record.v1Id);
  personRefByContactId.set(String(row.id), personRef);
  const company = companyById.get(String(row.company_id));
  const domain = company ? canonicalDomain(company) : null;
  const key = domain ? `${domain}|${normaliseName(row.normalised_name || row.full_name)}` : null;
  if (key && !contactCandidatesByDomainAndName.has(key)) contactCandidatesByDomainAndName.set(key, personRef);
}

// G8-only contacts are retained, but where they clearly match an existing V1 contact by domain+name,
// their evidence is attached to that existing person instead of creating a duplicate person.
const personRefByGenesisEntityId = new Map();
for (const entity of genesisEntities.filter((row) => row.entity_type === "contact")) {
  const domain = parseGenesisDomain(entity);
  const nameKey = normaliseName(entity.display_name);
  const existing = domain && nameKey ? contactCandidatesByDomainAndName.get(`${domain}|${nameKey}`) : null;
  if (existing) { personRefByGenesisEntityId.set(String(entity.id), existing); continue; }
  const record = personRecord("genesis_g8_intelligence_entities", entity);
  if (!record) continue;
  output.people.push(record);
  personRefByGenesisEntityId.set(String(entity.id), ref("PERSON", record.sourceTable, record.v1Id));
}

// Contact channels cross only as access-point identities. No channel-to-person/company authority edge is imported.
for (const row of channels) {
  const email = lower(row.normalised_email || row.email_address);
  if (!email || !/^\S+@\S+\.\S+$/.test(email)) continue;
  output.accessPoints.push({ sourceTable: "company_contact_channels", v1Id: String(row.id), payload: {
    accessPointKind: emailKind(row), canonicalValue: email, stableKey: `email:${email}`, label: nonempty(row.email_address) || email,
  } });
}

// Raw V1 company evidence.
for (const row of companyEvidence) {
  const subject = companyRefById.get(String(row.company_id));
  if (!subject) continue;
  const record = evidenceRecord({
    sourceTable: "company_evidence", v1Id: row.id, subject, url: row.source_url, sourceTitle: row.source_title,
    excerpt: row.excerpt || row.claim, observedAt: row.created_at,
    metadata: { sourceClass: "V1_COMPANY_EVIDENCE" },
  });
  if (record) output.evidence.push(record);
}

// Raw V1 contact evidence.
for (const row of contactEvidence) {
  const subject = personRefByContactId.get(String(row.contact_id));
  if (!subject) continue;
  const record = evidenceRecord({
    sourceTable: "contact_evidence", v1Id: row.id, subject, url: row.source_url, sourceTitle: row.source_title,
    sourceKind: sourceKindFromLegacy(row.source_kind, row.source_url), sourceDomain: row.source_domain,
    excerpt: row.excerpt || row.claim, observedAt: row.retrieved_at || row.created_at,
    metadata: { evidenceType: nonempty(row.evidence_type), sourceClass: nonempty(row.source_kind) },
  });
  if (record) output.evidence.push(record);
}

// Channel source evidence is retained independently of old route/ranking semantics.
for (const row of channels) {
  const subject = ref("ACCESS_POINT", "company_contact_channels", row.id);
  const record = evidenceRecord({
    sourceTable: "company_contact_channels", v1Id: `${row.id}:source`, subject, url: row.source_url, sourceTitle: row.source_title,
    excerpt: row.evidence_excerpt, observedAt: row.created_at, metadata: { sourceClass: "V1_CHANNEL_SOURCE" },
  });
  if (record) output.evidence.push(record);
}

// Preserve dense shared Genesis source evidence, but discard V1 claim weighting, strengths,
// Truth calculations and route topology. Route evidence is safely reattached to the company
// identified by the route canonical key so V2 can rebuild relationships from source evidence.
const claimById = new Map(genesisClaims.map((row) => [String(row.id), row]));
for (const row of genesisEvidence) {
  const claim = claimById.get(String(row.claim_id));
  const entity = claim ? genesisEntityById.get(String(claim.entity_id)) : null;
  if (!entity) continue;
  let subject = null;
  if (entity.entity_type === "company") subject = ref("COMPANY", "genesis_g8_intelligence_entities", entity.id);
  else if (entity.entity_type === "contact") subject = personRefByGenesisEntityId.get(String(entity.id)) || null;
  else if (entity.entity_type === "route") {
    const domain = parseGenesisDomain(entity);
    subject = domain ? companyRefByDomain.get(domain) || null : null;
  }
  if (!subject) continue;
  const record = evidenceRecord({
    sourceTable: "genesis_g8_intelligence_evidence", v1Id: row.id, subject,
    url: row.source_uri, sourceTitle: row.source_ref, sourceDomain: row.source_family,
    sourceKind: row.source_uri ? "WEB" : "OTHER", excerpt: row.excerpt || row.source_ref,
    observedAt: row.observed_at || row.created_at,
    metadata: { sourceClass: nonempty(row.source_class), intelligenceChannel: nonempty(row.intelligence_channel), originalEntityType: entity.entity_type },
  });
  if (record) output.evidence.push(record);
}

// Deterministic ordering makes the export fingerprint stable for an unchanged V1 snapshot.
for (const collection of ["companies","people","accessPoints","sellerBusinesses","sellerSources","campaigns","campaignScopes","evidence","historicalResearch"]) {
  output[collection].sort((a, b) => `${a.sourceTable}|${a.v1Id}`.localeCompare(`${b.sourceTable}|${b.v1Id}`));
}

const result = validateBundle(output);
const outputPath = path.resolve(process.cwd(), args.output);
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
console.log(JSON.stringify({ ok: true, mode: "V1_GET_ONLY_EXPORT", output: outputPath, exporterVersion: EXPORTER_VERSION, sourceProfile: SOURCE_PROFILE, ...result, sourceRowsRead: {
  businessProfiles: businessProfiles.length, campaigns: campaigns.length, companies: companies.length, companyEvidence: companyEvidence.length,
  contacts: contacts.length, contactEvidence: contactEvidence.length, channels: channels.length, genesisEntities: genesisEntities.length,
  genesisClaims: genesisClaims.length, genesisEvidence: genesisEvidence.length,
} }, null, 2));
