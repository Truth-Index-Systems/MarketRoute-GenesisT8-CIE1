import { executeResearchEnvelope } from "./admitted-executor.mjs";
import { envelopeFingerprint } from "./executor.mjs";
import { createRecoveryLedger } from "./admission-ledger.mjs";
import { setTimeout as sleep } from "node:timers/promises";

const SOURCE_QUEUE_ARN = "arn:aws:sqs:eu-west-2:801132668416:marketroute-aws-v0-research-work";

const TRANSPORT_SCHEMA_VERSION = "1";
const TRANSPORT_NAME = "AWS_SQS";
const MAX_MESSAGE_BYTES = 65_536;

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function boundedString(value, maximumLength) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximumLength ? trimmed : null;
}

export function parseEnvelope(body) {
  if (typeof body !== "string" || Buffer.byteLength(body, "utf8") > MAX_MESSAGE_BYTES) return null;
  let value;
  try { value = JSON.parse(body); } catch { return null; }
  if (!isRecord(value)) return null;
  if (value.schemaVersion !== TRANSPORT_SCHEMA_VERSION || value.transport !== TRANSPORT_NAME) return null;
  if (!boundedString(value.workUnitId, 128) || !boundedString(value.dedupeKey, 256)) return null;
  if (!isRecord(value.workUnit) || value.workUnit.dedupeKey !== value.dedupeKey) return null;
  return value;
}

export async function handleEvent(event, context = {}, dependencies = {}) {
  const records = Array.isArray(event?.Records) ? event.Records : [];
  const batchItemFailures = [];
  for (const record of records) {
    const messageId = boundedString(record?.messageId, 256) ?? "unknown-message";
    const envelope = parseEnvelope(record?.body);
    if (envelope === null || process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED !== "true") {
      batchItemFailures.push({ itemIdentifier: messageId });
      continue;
    }
    try {
      const execute = dependencies.executeResearchEnvelope ?? executeResearchEnvelope;
      const worker = { workerId: boundedString(context?.awsRequestId, 200) ?? `sqs:${messageId}` };
      let outcome = await execute(envelope, worker, dependencies);
      // One short, bounded rate wait avoids spending another SQS receive simply
      // because the other worker won this permit. Never sleep through a budget denial.
      const delay = Date.parse(outcome?.retryAt) - Date.now() + 50;
      if (outcome?.reason === "REQUEST_RATE_LIMIT" && Number.isFinite(delay) && delay > 0 && delay <= 12000
          && typeof context.getRemainingTimeInMillis === "function"
          && context.getRemainingTimeInMillis() > 180000 + delay) {
        await (dependencies.sleep ?? sleep)(delay);
        if (context.getRemainingTimeInMillis() > 180000) outcome = await execute(envelope, worker, dependencies);
      }
      if (outcome?.acknowledge !== true) {
        await noteTransportFailure(record, envelope, outcome, dependencies);
        batchItemFailures.push({ itemIdentifier: messageId });
      }
    } catch {
      await noteTransportFailure(record, envelope, { outcome: "EXECUTION_ERROR" }, dependencies);
      batchItemFailures.push({ itemIdentifier: messageId });
    }
  }
  return { batchItemFailures };
}

async function noteTransportFailure(record, envelope, outcome, dependencies) {
  const count = Number(record?.attributes?.ApproximateReceiveCount);
  // Only source-queue failures are noted. Poison payloads stay unacknowledged;
  // no credentials, message body, secret or arbitrary error string is logged.
  if (record?.eventSourceARN !== SOURCE_QUEUE_ARN || !Number.isSafeInteger(count) || count < 1 || count > 1000000) return;
  let recovery;
  try {
    recovery = dependencies.recovery ?? await createRecoveryLedger();
    const allowed = new Set(["ADMISSION_DEFERRED","FAILED_RETRYABLE","SYNC_PENDING","RESULT_PERSISTENCE_PENDING","BUSY","EXECUTION_ERROR"]);
    await recovery.note(envelope, envelopeFingerprint(envelope), count,
      allowed.has(outcome?.outcome) ? outcome.outcome : "EXECUTION_ERROR");
  } catch {
    // The original message remains unacknowledged on a failed/ambiguous note.
  } finally { recovery?.destroy?.(); }
}

export const handler = handleEvent;
