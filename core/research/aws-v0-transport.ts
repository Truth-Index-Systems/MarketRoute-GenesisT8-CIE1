import type {
  ResearchAction,
  ResearchLayer,
  ResearchOrigin,
  ResearchSubjectType,
  ResearchTier,
  ResearchWorkUnit,
} from "./contracts";

export const AWS_V0_RESEARCH_TRANSPORT_SCHEMA_VERSION = "1" as const;
export const AWS_V0_RESEARCH_TRANSPORT = "AWS_SQS" as const;
export const AWS_V0_RESEARCH_MAX_MESSAGE_BYTES = 65_536 as const;
export const AWS_V0_RESEARCH_MAX_BATCH_SIZE = 1 as const;
export const AWS_V0_RESEARCH_MAX_CONCURRENT_WORK_UNITS = 2 as const;
export const AWS_V0_RESEARCH_WORKER_TIMEOUT_SECONDS = 240 as const;
export const AWS_V0_RESEARCH_VISIBILITY_TIMEOUT_SECONDS = 1_440 as const;
export const AWS_V0_RESEARCH_DLQ_MAX_RECEIVE_COUNT = 5 as const;

export interface AwsV0ResearchWorkEnvelope {
  schemaVersion: typeof AWS_V0_RESEARCH_TRANSPORT_SCHEMA_VERSION;
  transport: typeof AWS_V0_RESEARCH_TRANSPORT;
  workUnitId: string;
  enqueuedAt: string;
  organisationId: string;
  campaignId: string;
  companyId: string;
  researchOrigin: ResearchOrigin;
  dedupeKey: string;
  workUnit: ResearchWorkUnit;
}

const RESEARCH_ORIGINS = new Set<ResearchOrigin>(["CUSTOMER_CAMPAIGN", "CUSTOMER_REFRESH", "SYSTEM_RETRY"]);
const RESEARCH_LAYERS = new Set<ResearchLayer>(["R4", "R5", "R6"]);
const RESEARCH_TIERS = new Set<ResearchTier>(["DECISION_BLOCKER", "CURRENTNESS_REPAIR", "EXPIRING_SOON", "ENRICHMENT"]);
const RESEARCH_ACTIONS = new Set<ResearchAction>([
  "ACQUIRE_CLAIM_EVIDENCE",
  "DISCOVER_ROUTE_STRUCTURE",
  "RESEARCH_CONTACT_BINDING",
  "REVALIDATE_R4",
  "REVALIDATE_R5",
  "REVALIDATE_R6",
]);
const RESEARCH_SUBJECT_TYPES = new Set<ResearchSubjectType>(["COMPANY", "PERSON", "RELATIONSHIP", "CHANNEL", "CAMPAIGN"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function boundedString(value: unknown, maximumLength: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximumLength ? trimmed : null;
}

function onlyKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  const allowedSet = new Set(allowed);
  return Object.keys(value).every((key) => allowedSet.has(key));
}

function queryHints(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length > 12) return null;
  const parsed: string[] = [];
  for (const item of value) {
    const hint = boundedString(item, 500);
    if (hint === null) return null;
    parsed.push(hint);
  }
  return parsed;
}

function parseWorkUnit(value: unknown): ResearchWorkUnit | null {
  if (!isRecord(value)) return null;
  if (!onlyKeys(value, ["ordinal", "gapKey", "layer", "tier", "action", "subjectType", "subjectId", "claimKey", "reasonCode", "queryHints", "costCeilingUsd", "dedupeKey", "payload"])) return null;
  if (!Number.isSafeInteger(value.ordinal) || Number(value.ordinal) < 0) return null;
  const gapKey = boundedString(value.gapKey, 256);
  const subjectId = boundedString(value.subjectId, 256);
  const reasonCode = boundedString(value.reasonCode, 256);
  const dedupeKey = boundedString(value.dedupeKey, 256);
  const hints = queryHints(value.queryHints);
  const claimKey = value.claimKey === null ? null : boundedString(value.claimKey, 256);
  if (gapKey === null || subjectId === null || reasonCode === null || dedupeKey === null || hints === null || claimKey === null && value.claimKey !== null) return null;
  if (!RESEARCH_LAYERS.has(value.layer as ResearchLayer) || !RESEARCH_TIERS.has(value.tier as ResearchTier)) return null;
  if (!RESEARCH_ACTIONS.has(value.action as ResearchAction) || !RESEARCH_SUBJECT_TYPES.has(value.subjectType as ResearchSubjectType)) return null;
  if (typeof value.costCeilingUsd !== "number" || !Number.isFinite(value.costCeilingUsd) || value.costCeilingUsd < 0) return null;
  if (!isRecord(value.payload)) return null;
  return {
    ordinal: Number(value.ordinal),
    gapKey,
    layer: value.layer as ResearchLayer,
    tier: value.tier as ResearchTier,
    action: value.action as ResearchAction,
    subjectType: value.subjectType as ResearchSubjectType,
    subjectId,
    claimKey,
    reasonCode,
    queryHints: hints,
    costCeilingUsd: value.costCeilingUsd,
    dedupeKey,
    payload: value.payload,
  };
}

export function parseAwsV0ResearchWorkEnvelope(value: unknown): AwsV0ResearchWorkEnvelope | null {
  if (!isRecord(value)) return null;
  if (!onlyKeys(value, ["schemaVersion", "transport", "workUnitId", "enqueuedAt", "organisationId", "campaignId", "companyId", "researchOrigin", "dedupeKey", "workUnit"])) return null;
  if (value.schemaVersion !== AWS_V0_RESEARCH_TRANSPORT_SCHEMA_VERSION || value.transport !== AWS_V0_RESEARCH_TRANSPORT) return null;
  const workUnitId = boundedString(value.workUnitId, 128);
  const enqueuedAt = boundedString(value.enqueuedAt, 64);
  const organisationId = boundedString(value.organisationId, 128);
  const campaignId = boundedString(value.campaignId, 128);
  const companyId = boundedString(value.companyId, 128);
  const dedupeKey = boundedString(value.dedupeKey, 256);
  const workUnit = parseWorkUnit(value.workUnit);
  if (!workUnitId || !enqueuedAt || !organisationId || !campaignId || !companyId || !dedupeKey || !workUnit) return null;
  if (!Number.isFinite(Date.parse(enqueuedAt)) || !RESEARCH_ORIGINS.has(value.researchOrigin as ResearchOrigin)) return null;
  if (workUnit.dedupeKey !== dedupeKey) return null;
  return {
    schemaVersion: AWS_V0_RESEARCH_TRANSPORT_SCHEMA_VERSION,
    transport: AWS_V0_RESEARCH_TRANSPORT,
    workUnitId,
    enqueuedAt,
    organisationId,
    campaignId,
    companyId,
    researchOrigin: value.researchOrigin as ResearchOrigin,
    dedupeKey,
    workUnit,
  };
}

export function serialiseAwsV0ResearchWorkEnvelope(envelope: AwsV0ResearchWorkEnvelope): string {
  const validated = parseAwsV0ResearchWorkEnvelope(envelope);
  if (validated === null) throw new Error("INVALID_AWS_V0_RESEARCH_WORK_ENVELOPE");
  const body = JSON.stringify(validated);
  if (new TextEncoder().encode(body).byteLength > AWS_V0_RESEARCH_MAX_MESSAGE_BYTES) throw new Error("AWS_V0_RESEARCH_WORK_ENVELOPE_TOO_LARGE");
  return body;
}
