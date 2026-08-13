import { APPLICATION_READ_CONTRACT_VERSION } from "./contracts";

const FORBIDDEN_NORMALISED_AUTHORITY_KEYS = new Set([
  "opportunityscore","companyfit","businessfit","routequality","routeconfidence","isviable",
  "overallconfidence","engagementconfidence","matchlabel","fitbreakdown",
]);

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function normaliseKey(key:string):string { return key.toLowerCase().replace(/[^a-z0-9]/g,""); }
function scan(value: unknown, path = "$"): void {
  if (Array.isArray(value)) { value.forEach((item,index)=>scan(item,`${path}[${index}]`)); return; }
  if (!isObject(value)) return;
  for (const [key,child] of Object.entries(value)) {
    if (FORBIDDEN_NORMALISED_AUTHORITY_KEYS.has(normaliseKey(key))) throw new Error(`MARKETROUTE_READ_MODEL_FORBIDDEN_AUTHORITY_FIELD:${path}.${key}`);
    scan(child,`${path}.${key}`);
  }
}

export function assertCanonicalApplicationRead<T extends object>(value: unknown, expectedResourceType?: string): T {
  if (!isObject(value)) throw new Error("MARKETROUTE_READ_MODEL_OBJECT_REQUIRED");
  if (value.contractVersion !== APPLICATION_READ_CONTRACT_VERSION) throw new Error("MARKETROUTE_READ_MODEL_CONTRACT_VERSION_MISMATCH");
  if (expectedResourceType && value.resourceType !== expectedResourceType) throw new Error("MARKETROUTE_READ_MODEL_RESOURCE_TYPE_MISMATCH");
  if (typeof value.evaluatedAt !== "string" || !Number.isFinite(Date.parse(value.evaluatedAt))) throw new Error("MARKETROUTE_READ_MODEL_EVALUATED_AT_INVALID");
  scan(value);
  return value as T;
}

export function assertCanonicalEngagementRead<T extends object>(value: unknown): T {
  if (!isObject(value)) throw new Error("MARKETROUTE_ENGAGEMENT_READ_MODEL_OBJECT_REQUIRED");
  if (value.contractVersion !== APPLICATION_READ_CONTRACT_VERSION) throw new Error("MARKETROUTE_READ_MODEL_CONTRACT_VERSION_MISMATCH");
  if (typeof value.evaluatedAt !== "string" || !Number.isFinite(Date.parse(value.evaluatedAt))) throw new Error("MARKETROUTE_READ_MODEL_EVALUATED_AT_INVALID");
  scan(value);
  return value as T;
}
