import { AwsV0ResearchExecutionError, createAuroraResearchExecutionLedger,
  parseCompanyUnderstandingInput, parseCompanyUnderstandingOutput, envelopeFingerprint,
  AWS_V0_COMPANY_UNDERSTANDING_CONTRACT, AWS_V0_RESEARCH_EXECUTION_CONTRACT } from "./executor.mjs";
import { createPreparedBedrockProvider } from "./prepared-provider.mjs";
import { createInferenceAdmissionLedger } from "./admission-ledger.mjs";

const measured = (t) => Number.isSafeInteger(t?.inputUnits) && t.inputUnits >= 0
  && Number.isSafeInteger(t?.outputUnits) && t.outputUnits >= 0;
const safeCode = (error) => error instanceof AwsV0ResearchExecutionError ? error.code
  : "MARKETROUTE_AWS_V0_ADMISSION_OR_PERSISTENCE_FAILURE";

// Production entry: there is deliberately no unguarded provider fallback.
export async function executeResearchEnvelope(envelope, context = {}, dependencies = {}) {
  const input = parseCompanyUnderstandingInput(envelope);
  const fingerprint = envelopeFingerprint(envelope);
  const workerId = context.workerId;
  if (typeof workerId !== "string" || !workerId.trim() || workerId.length > 200) {
    throw new Error("MARKETROUTE_AWS_V0_WORKER_ID_REQUIRED");
  }
  const now = dependencies.now ?? (() => new Date());
  const ledger = dependencies.ledger ?? await createAuroraResearchExecutionLedger();
  let admission = dependencies.admission ?? null;
  let provider = dependencies.provider ?? null;
  let claimed = false, invoked = false, completed = false, completionAttempted = false;
  let plan = null, grant = null, settled = null, providerTelemetry = {};
  try {
    const claim = await ledger.claim(envelope, fingerprint, workerId, now().toISOString());
    if (claim.outcome === "DEDUPLICATED") {
      const syncState = await ledger.sync(envelope.workUnitId, fingerprint, claim.resultFingerprint, now().toISOString());
      return { acknowledge: ["SYNCED", "ALREADY_SYNCED"].includes(syncState), outcome: "DEDUPLICATED", syncState };
    }
    if (claim.outcome === "TERMINAL") {
      const syncState = await ledger.syncFailure(envelope.workUnitId, fingerprint, now().toISOString());
      return { acknowledge: ["FAILED_SYNCED", "ALREADY_FAILED"].includes(syncState), outcome: "TERMINAL", syncState };
    }
    if (claim.outcome !== "CLAIMED") return { acknowledge: false, outcome: claim.outcome };
    claimed = true;
    admission ??= await createInferenceAdmissionLedger();
    const ready = await admission.preflight(envelope.workUnitId, fingerprint, workerId);
    if (ready?.outcome !== "READY") {
      await admission.defer(envelope.workUnitId, fingerprint, workerId);
      return { acknowledge: false, outcome: "ADMISSION_DEFERRED", reason: ready?.reason ?? "PREFLIGHT_NOT_READY" };
    }
    provider ??= await createPreparedBedrockProvider();
    plan = await provider.prepare(input);
    const admissionStarted = performance.now();
    grant = await admission.admit(envelope, fingerprint, workerId, plan);
    if (grant?.outcome !== "ADMITTED") {
      // A denied admission is not a provider attempt. The SQL release refuses
      // to decrement a claim once a durable provider reservation exists.
      if (grant?.outcome === "DEFERRED") await admission.defer(envelope.workUnitId, fingerprint, workerId);
      return { acknowledge: false, outcome: "ADMISSION_DEFERRED", reason: grant?.reason ?? "AMBIGUOUS_ADMISSION",
        retryAt: grant?.retryAt ?? null };
    }
    if (typeof grant.admissionId !== "string" || !Number.isFinite(Date.parse(grant.startBefore))
        || !Number.isFinite(grant.reservedCostUsd) || grant.reservedCostUsd <= 0) {
      throw new AwsV0ResearchExecutionError("MARKETROUTE_AWS_V0_ADMISSION_RECEIPT_INVALID", false);
    }
    if (now().getTime() >= Date.parse(grant.startBefore) || performance.now() - admissionStarted >= 1000) {
      throw new AwsV0ResearchExecutionError("MARKETROUTE_AWS_V0_ADMISSION_START_EXPIRED", true);
    }
    invoked = true;
    const execution = await provider.executePrepared(plan);
    providerTelemetry = execution.telemetry;
    if (!measured(providerTelemetry)) throw new AwsV0ResearchExecutionError("MARKETROUTE_AWS_V0_BEDROCK_USAGE_INVALID", false);
    settled = await admission.settle(grant.admissionId, workerId, plan.requestFingerprint, "MEASURED", providerTelemetry);
    if (settled.withinReservation !== true || !Number.isFinite(settled.accountedCostUsd)
        || settled.accountedCostUsd < 0 || settled.accountedCostUsd > envelope.workUnit.costCeilingUsd) {
      throw new AwsV0ResearchExecutionError("MARKETROUTE_AWS_V0_RESEARCH_COST_CEILING_EXCEEDED", false, providerTelemetry);
    }
    const value = parseCompanyUnderstandingOutput(execution.value, input);
    if (!value) throw new AwsV0ResearchExecutionError("MARKETROUTE_AWS_V0_BEDROCK_INVALID_RESPONSE", false, providerTelemetry);
    const result = { contractVersion: AWS_V0_COMPANY_UNDERSTANDING_CONTRACT,
      operation: "ai.companyUnderstanding", canonicalPersistenceAllowed: false,
      truthAuthorityGranted: false, deterministicCommercialAuthorityGranted: false, value };
    const telemetry = { ...providerTelemetry, schemaVersion: "1", executionContractVersion: AWS_V0_RESEARCH_EXECUTION_CONTRACT,
      operationId: "ai.companyUnderstanding", attemptCount: claim.attemptCount, retryCount: Math.max(0, claim.attemptCount - 1),
      admissionContractVersion: "MR-AWS-V0-INFERENCE-ADMISSION-1.0.0", tariffVersion: grant.tariffVersion,
      admissionId: grant.admissionId, currentAttemptCostUsd: settled.attemptCostUsd,
      estimatedEquivalentCostUsd: settled.accountedCostUsd, actualAttributedCostUsd: null,
      creditFunding: "UNKNOWN", economicCostRecordedEvenWhenCreditFunded: true,
      attribution: { product: "MarketRoute", organisationId: envelope.organisationId,
        campaignId: envelope.campaignId, companyId: envelope.companyId, workUnitId: envelope.workUnitId } };
    completionAttempted = true;
    const resultFingerprint = await ledger.complete(envelope.workUnitId, fingerprint, workerId, result, telemetry, now().toISOString());
    completed = true;
    const syncState = await ledger.sync(envelope.workUnitId, fingerprint, resultFingerprint, now().toISOString());
    return { acknowledge: ["SYNCED", "ALREADY_SYNCED"].includes(syncState), outcome: "SUCCEEDED", resultFingerprint, syncState };
  } catch (error) {
    if (completionAttempted && !completed) return { acknowledge: false, outcome: "RESULT_PERSISTENCE_PENDING", errorCode: safeCode(error) };
    if (completed) return { acknowledge: false, outcome: "SYNC_PENDING", errorCode: safeCode(error) };
    if (!claimed || grant?.outcome !== "ADMITTED") {
      if (claimed && admission) await admission.defer(envelope.workUnitId, fingerprint, workerId).catch(() => false);
      return { acknowledge: false, outcome: "ADMISSION_DEFERRED", errorCode: safeCode(error) };
    }
    if (measured(error?.telemetry)) providerTelemetry = error.telemetry;
    if (!settled) {
      const outcome = !invoked ? "NOT_SENT" : measured(providerTelemetry) ? "MEASURED" : "UNKNOWN";
      settled = await admission.settle(grant.admissionId, workerId, plan.requestFingerprint, outcome, providerTelemetry).catch(() => null);
    }
    // A missing settlement keeps its durable reservation; it is never zeroed.
    const telemetry = { ...providerTelemetry, admissionId: grant.admissionId,
      usageState: settled?.usageState ?? "UNSETTLED", accountedCostUsd: settled?.accountedCostUsd ?? null };
    const retryable = error instanceof AwsV0ResearchExecutionError && error.retryable && settled?.withinReservation !== false;
    const state = await ledger.fail(envelope.workUnitId, fingerprint, workerId, safeCode(error), retryable, telemetry, now().toISOString()).catch(() => null);
    if (state === "FAILED_TERMINAL") {
      const syncState = await ledger.syncFailure(envelope.workUnitId, fingerprint, now().toISOString()).catch(() => null);
      return { acknowledge: ["FAILED_SYNCED", "ALREADY_FAILED"].includes(syncState), outcome: "FAILED_TERMINAL", syncState, errorCode: safeCode(error) };
    }
    return { acknowledge: false, outcome: "FAILED_RETRYABLE", errorCode: safeCode(error) };
  } finally {
    provider?.destroy?.(); admission?.destroy?.(); ledger.destroy?.();
  }
}
