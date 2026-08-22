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

function parseEnvelope(body) {
  if (typeof body !== "string" || Buffer.byteLength(body, "utf8") > MAX_MESSAGE_BYTES) return null;
  let value;
  try { value = JSON.parse(body); } catch { return null; }
  if (!isRecord(value)) return null;
  if (value.schemaVersion !== TRANSPORT_SCHEMA_VERSION || value.transport !== TRANSPORT_NAME) return null;
  if (!boundedString(value.workUnitId, 128) || !boundedString(value.dedupeKey, 256)) return null;
  if (!isRecord(value.workUnit) || value.workUnit.dedupeKey !== value.dedupeKey) return null;
  return value;
}

export async function handler(event) {
  const records = Array.isArray(event?.Records) ? event.Records : [];
  const batchItemFailures = [];
  for (const record of records) {
    const messageId = boundedString(record?.messageId, 256) ?? "unknown-message";
    const envelope = parseEnvelope(record?.body);
    if (envelope === null || process.env.MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED !== "false") {
      batchItemFailures.push({ itemIdentifier: messageId });
      continue;
    }
    batchItemFailures.push({ itemIdentifier: messageId });
  }
  return { batchItemFailures };
}
