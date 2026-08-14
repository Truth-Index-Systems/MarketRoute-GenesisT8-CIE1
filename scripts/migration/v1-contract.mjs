import crypto from "node:crypto";

export const CONTRACT_VERSION = "MRV2-V1-FACTUAL-EXPORT-1.0.0";
export const COLLECTION_ORDER = [
  "companies",
  "people",
  "accessPoints",
  "sellerBusinesses",
  "sellerSources",
  "campaigns",
  "campaignScopes",
  "evidence",
  "historicalResearch",
];

const FORBIDDEN_NORMALISED_KEYS = new Set([
  "authority","authorityrecord","authorityrecordid","authorityfingerprint","authoritystate",
  "commercialreality","routeauthority","contactauthority","approvalauthority",
  "opportunityscore","fitscore","score","weightedscore","rankingscore","rank",
  "confidence","overallconfidence","routeconfidence","routequality","evidencesufficiency",
  "viability","isviable","ready","readystatus","workflowstate","approvalstate",
  "truthindex","truthprobability","probability","r4","r5","r6","oldr4","oldr5","oldr6",
]);

const ALLOWED_PAYLOAD_KEYS = {
  companies: new Set(["canonicalName","canonicalDomain","websiteUrl","countryCode"]),
  people: new Set(["displayName","canonicalName"]),
  accessPoints: new Set(["accessPointKind","canonicalValue","stableKey","label"]),
  sellerBusinesses: new Set(["name","canonicalDomain","websiteUrl"]),
  sellerSources: new Set(["sellerBusinessSourceTable","sellerBusinessV1Id","content"]),
  campaigns: new Set(["sellerBusinessSourceTable","sellerBusinessV1Id","name","objectiveText"]),
  campaignScopes: new Set(["campaignSourceTable","campaignV1Id","companySourceTable","companyV1Id"]),
  evidence: new Set(["subject","source","acquisition","evidence","claim"]),
  historicalResearch: new Set(["subject","text","observedAt","sourceLabel","metadata"]),
};

function normaliseKey(key) {
  return String(key).toLowerCase().replace(/[^a-z0-9]+/g, "");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function object(value, path) {
  assert(value && typeof value === "object" && !Array.isArray(value), `${path} must be an object`);
  return value;
}

function string(value, path, { optional = false } = {}) {
  if (optional && (value === undefined || value === null || value === "")) return null;
  assert(typeof value === "string" && value.trim().length > 0, `${path} must be a non-empty string`);
  return value.trim();
}

function allowedKeys(value, allowed, path) {
  object(value, path);
  for (const key of Object.keys(value)) assert(allowed.has(key), `${path}.${key} is not whitelisted for V1 migration`);
}

export function forbiddenKeys(value) {
  const found = new Set();
  const walk = (current) => {
    if (Array.isArray(current)) return current.forEach(walk);
    if (!current || typeof current !== "object") return;
    for (const [key, child] of Object.entries(current)) {
      const normalised = normaliseKey(key);
      if (FORBIDDEN_NORMALISED_KEYS.has(normalised)) found.add(normalised);
      walk(child);
    }
  };
  walk(value);
  return [...found].sort();
}

export function assertFactualPayload(value, path = "payload") {
  object(value, path);
  const forbidden = forbiddenKeys(value);
  assert(forbidden.length === 0, `${path} contains forbidden V1 authority/derived fields: ${forbidden.join(", ")}`);
}

function assertClaimKeyFactual(claimKey, path) {
  const raw = string(claimKey, path);
  const normalised = normaliseKey(raw);
  assert(!/(authority|opportunityscore|fitscore|score|confidence|routequality|routeconfidence|viability|ready|truthindex|truthprobability|probability|(^|old)r[456])/.test(normalised), `${path} is not a factual claim key`);
}

function refKey(entityKind, sourceTable, v1Id) {
  return `${String(entityKind).toUpperCase()}|${String(sourceTable).toLowerCase()}|${String(v1Id)}`;
}

function validateSubject(subject, path, refs) {
  object(subject, path);
  allowedKeys(subject, new Set(["entityKind","sourceTable","v1Id"]), path);
  const entityKind = string(subject.entityKind, `${path}.entityKind`).toUpperCase();
  assert(["COMPANY","PERSON","ACCESS_POINT","SELLER_BUSINESS","CAMPAIGN"].includes(entityKind), `${path}.entityKind is not migratable`);
  const sourceTable = string(subject.sourceTable, `${path}.sourceTable`);
  const v1Id = string(subject.v1Id, `${path}.v1Id`);
  assert(refs.has(refKey(entityKind, sourceTable, v1Id)), `${path} references an entity not present in the bundle`);
}

function validateEvidencePayload(payload, path, refs, sourceShapes) {
  allowedKeys(payload, ALLOWED_PAYLOAD_KEYS.evidence, path);
  validateSubject(payload.subject, `${path}.subject`, refs);
  const source = object(payload.source, `${path}.source`);
  allowedKeys(source, new Set(["sourceTable","v1Id","sourceKind","canonicalUrl","publisherDomain","title","publishedAt","stableLocator","dependenceFamilyKey","metadata"]), `${path}.source`);
  const sourceTable = string(source.sourceTable, `${path}.source.sourceTable`);
  const sourceId = string(source.v1Id, `${path}.source.v1Id`);
  const sourceKind = string(source.sourceKind, `${path}.source.sourceKind`).toUpperCase();
  assert(["WEB","DOCUMENT","API","REGISTRY","USER_PROVIDED","INTERNAL","OTHER"].includes(sourceKind), `${path}.source.sourceKind is invalid`);
  if (source.canonicalUrl) assert(/^https?:\/\/\S+$/i.test(source.canonicalUrl), `${path}.source.canonicalUrl must be http(s)`);
  const sourceKey = `${sourceTable.toLowerCase()}|${sourceId}`;
  const canonicalSource = stableStringify(source);
  if (sourceShapes.has(sourceKey)) assert(sourceShapes.get(sourceKey) === canonicalSource, `${path}.source changes payload for the same V1 source identity`);
  else sourceShapes.set(sourceKey, canonicalSource);

  const acquisition = payload.acquisition ?? {};
  allowedKeys(acquisition, new Set(["acquiredAt","observedContentFingerprint","httpStatus","rawLocator","parserVersion","requestId","metadata"]), `${path}.acquisition`);
  if (acquisition.httpStatus !== undefined && acquisition.httpStatus !== null) assert(Number.isInteger(acquisition.httpStatus) && acquisition.httpStatus >= 100 && acquisition.httpStatus <= 599, `${path}.acquisition.httpStatus is invalid`);
  if (acquisition.observedContentFingerprint) assert(/^[a-f0-9]{64}$/.test(acquisition.observedContentFingerprint), `${path}.acquisition.observedContentFingerprint must be SHA-256`);

  const evidence = object(payload.evidence, `${path}.evidence`);
  allowedKeys(evidence, new Set(["evidenceKind","excerptText","structuredValue","observedAt","originPublishedAt","extractionVersion"]), `${path}.evidence`);
  assert(["QUOTE","STRUCTURED_FIELD","OBSERVATION","DOCUMENT_SECTION","REGISTRY_RECORD","USER_ASSERTION","OTHER"].includes(string(evidence.evidenceKind, `${path}.evidence.evidenceKind`).toUpperCase()), `${path}.evidence.evidenceKind is invalid`);
  assert((typeof evidence.excerptText === "string" && evidence.excerptText.trim()) || (evidence.structuredValue !== undefined && evidence.structuredValue !== null), `${path}.evidence requires excerptText or non-null structuredValue`);

  if (payload.claim !== undefined && payload.claim !== null) {
    const claim = object(payload.claim, `${path}.claim`);
    allowedKeys(claim, new Set(["sourceTable","v1Id","claimKey","predicate","object","objectRefs","canonicalValueText","polarity"]), `${path}.claim`);
    assertClaimKeyFactual(claim.claimKey, `${path}.claim.claimKey`);
    string(claim.predicate, `${path}.claim.predicate`);
    if (claim.polarity !== undefined) assert(["SUPPORTS","CONTRADICTS"].includes(String(claim.polarity).toUpperCase()), `${path}.claim.polarity is invalid`);
    object(claim.object ?? {}, `${path}.claim.object`);
    if (claim.objectRefs !== undefined) {
      assert(Array.isArray(claim.objectRefs), `${path}.claim.objectRefs must be an array`);
      claim.objectRefs.forEach((ref, index) => {
        const refPath = `${path}.claim.objectRefs[${index}]`;
        object(ref, refPath);
        allowedKeys(ref, new Set(["key","entityKind","sourceTable","v1Id"]), refPath);
        assert(/^[A-Za-z][A-Za-z0-9_]{0,79}$/.test(string(ref.key, `${refPath}.key`)), `${refPath}.key is invalid`);
        const entityKind = string(ref.entityKind, `${refPath}.entityKind`).toUpperCase();
        const refTable = string(ref.sourceTable, `${refPath}.sourceTable`);
        const refId = string(ref.v1Id, `${refPath}.v1Id`);
        assert(refs.has(refKey(entityKind, refTable, refId)), `${refPath} references an entity not present in the bundle`);
      });
    }
  }
}

export function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function bundleFingerprint(bundle) {
  return crypto.createHash("sha256").update(stableStringify(bundle)).digest("hex");
}

export function validateBundle(bundle) {
  object(bundle, "bundle");
  const allowedRoot = new Set(["contractVersion","exportedAt","exportMetadata",...COLLECTION_ORDER]);
  allowedKeys(bundle, allowedRoot, "bundle");
  assert(bundle.contractVersion === CONTRACT_VERSION, `bundle.contractVersion must equal ${CONTRACT_VERSION}`);
  string(bundle.exportedAt, "bundle.exportedAt");
  if (bundle.exportMetadata !== undefined) object(bundle.exportMetadata, "bundle.exportMetadata");
  assertFactualPayload(bundle, "bundle");

  const refs = new Set();
  const recordsByCollection = {};
  for (const collection of COLLECTION_ORDER) {
    const records = bundle[collection] ?? [];
    assert(Array.isArray(records), `bundle.${collection} must be an array`);
    recordsByCollection[collection] = records;
    records.forEach((record, index) => {
      const path = `bundle.${collection}[${index}]`;
      object(record, path);
      allowedKeys(record, new Set(["sourceTable","v1Id","payload"]), path);
      const sourceTable = string(record.sourceTable, `${path}.sourceTable`);
      const v1Id = string(record.v1Id, `${path}.v1Id`);
      const payload = object(record.payload, `${path}.payload`);
      assertFactualPayload(payload, `${path}.payload`);
      allowedKeys(payload, ALLOWED_PAYLOAD_KEYS[collection], `${path}.payload`);
      const entityKind = ({companies:"COMPANY",people:"PERSON",accessPoints:"ACCESS_POINT",sellerBusinesses:"SELLER_BUSINESS",sellerSources:"SELLER_SOURCE_MATERIAL",campaigns:"CAMPAIGN",campaignScopes:"CAMPAIGN_SCOPE",evidence:"EVIDENCE",historicalResearch:"HISTORICAL_RESEARCH"})[collection];
      const key = refKey(entityKind, sourceTable, v1Id);
      assert(!refs.has(key), `${path} duplicates V1 identity ${key}`);
      refs.add(key);
    });
  }

  for (const [index, record] of recordsByCollection.sellerSources.entries()) {
    const p = record.payload; const key = refKey("SELLER_BUSINESS", p.sellerBusinessSourceTable, p.sellerBusinessV1Id);
    assert(refs.has(key), `bundle.sellerSources[${index}] references a seller business not present in the bundle`);
  }
  for (const [index, record] of recordsByCollection.campaigns.entries()) {
    const p = record.payload; const key = refKey("SELLER_BUSINESS", p.sellerBusinessSourceTable, p.sellerBusinessV1Id);
    assert(refs.has(key), `bundle.campaigns[${index}] references a seller business not present in the bundle`);
  }
  for (const [index, record] of recordsByCollection.campaignScopes.entries()) {
    const p = record.payload;
    assert(refs.has(refKey("CAMPAIGN", p.campaignSourceTable, p.campaignV1Id)), `bundle.campaignScopes[${index}] references a campaign not present in the bundle`);
    assert(refs.has(refKey("COMPANY", p.companySourceTable, p.companyV1Id)), `bundle.campaignScopes[${index}] references a company not present in the bundle`);
  }

  const sourceShapes = new Map();
  recordsByCollection.evidence.forEach((record, index) => validateEvidencePayload(record.payload, `bundle.evidence[${index}].payload`, refs, sourceShapes));
  recordsByCollection.historicalResearch.forEach((record, index) => validateSubject(record.payload.subject, `bundle.historicalResearch[${index}].payload.subject`, refs));

  return {
    contractVersion: bundle.contractVersion,
    fingerprint: bundleFingerprint(bundle),
    counts: Object.fromEntries(COLLECTION_ORDER.map((key) => [key, recordsByCollection[key].length])),
    totalRecords: COLLECTION_ORDER.reduce((sum, key) => sum + recordsByCollection[key].length, 0),
  };
}
