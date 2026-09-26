// A bounded controller iteration. Build 13 must wire/deploy its scheduler and
// least-privilege publisher before the disabled database control can be enabled.
// Never auto-redrive the whole DLQ: recover the canonical stored envelope instead.
import { envelopeFingerprint, parseCompanyUnderstandingInput } from '../../infrastructure/aws-v0/runtime/research-worker/executor.mjs';

export async function runAwsV0RecoveryCycle({ ledger, publisher, coordinator, limit = 5, now = () => new Date() }) {
  if (typeof coordinator !== 'string' || !coordinator.trim() || coordinator.length > 200
    || !Number.isInteger(limit) || limit < 1 || limit > 20) throw new Error('MARKETROUTE_RECOVERY_INPUT_INVALID');
  const candidates = await ledger.candidates(limit);
  if (!Array.isArray(candidates) || candidates.length > limit) throw new Error('MARKETROUTE_RECOVERY_BATCH_INVALID');
  const results = [];
  for (const item of candidates) {
    const envelope = item?.envelope;
    try {
      parseCompanyUnderstandingInput(envelope);
      const fingerprint = envelopeFingerprint(envelope);
      const started = performance.now();
      const permission = await ledger.prepare(envelope, fingerprint, coordinator);
      if (permission?.outcome !== 'REDELIVER') {
        results.push({ workUnitId: envelope.workUnitId, outcome: permission?.outcome ?? 'UNKNOWN' });
        continue;
      }
      if (envelopeFingerprint(permission.envelope) !== fingerprint
        || typeof permission.leaseToken !== 'string'
        || !Number.isInteger(permission.canonicalAttempt) || permission.canonicalAttempt <= 0
        || !Number.isFinite(Date.parse(permission.startBefore))
        || now().getTime() >= Date.parse(permission.startBefore) || performance.now() - started >= 60000) {
        throw new Error('MARKETROUTE_RECOVERY_PERMIT_INVALID');
      }
      // No in-process retry. Ambiguous send/confirmation leaves the bounded lease
      // and republish counter committed for a later controller iteration.
      const sent = await publisher.publish(JSON.stringify(permission.envelope));
      if (typeof sent?.messageId !== 'string' || !sent.messageId.trim() || sent.messageId.length > 256) {
        throw new Error('MARKETROUTE_RECOVERY_SEND_UNKNOWN');
      }
      const confirmed = await ledger.confirm(envelope.workUnitId, permission.canonicalAttempt,
        permission.leaseToken, coordinator, fingerprint, sent.messageId);
      if (!['CONFIRMED','ALREADY_CONFIRMED'].includes(confirmed?.outcome)) throw new Error('MARKETROUTE_RECOVERY_CONFIRM_UNKNOWN');
      results.push({ workUnitId: envelope.workUnitId, outcome: 'REPUBLISHED' });
    } catch {
      results.push({ workUnitId: envelope?.workUnitId ?? null, outcome: 'RECOVERY_PENDING' });
    }
  }
  return results;
}
