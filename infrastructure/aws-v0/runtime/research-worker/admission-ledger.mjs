// Named, parameterized Data API calls only. No arbitrary SQL input surface.
export async function createInferenceAdmissionLedger() {
  const required = (key) => {
    const value = process.env[key]?.trim();
    if (!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${key}`);
    return value;
  };
  const region = required("AWS_REGION");
  if (region !== "eu-west-2") throw new Error("MARKETROUTE_AWS_V0_ADMISSION_REGION_INVALID");
  const base = { resourceArn: required("MARKETROUTE_AWS_RDS_CLUSTER_ARN"),
    secretArn: required("MARKETROUTE_AWS_RDS_SECRET_ARN"), database: required("MARKETROUTE_AWS_RDS_DATABASE") };
  const sdk = await import("@aws-sdk/client-rds-data");
  const client = new sdk.RDSDataClient({ region, maxAttempts: 1 });
  const parameter = (name, value) => ({ name, value: value === null ? { isNull: true } : { stringValue: String(value) } });
  async function call(sql, args) {
    const response = await client.send(new sdk.ExecuteStatementCommand({ ...base, sql,
      parameters: Object.entries(args).map(([key, value]) => parameter(key, value)),
      formatRecordsAs: "JSON", continueAfterTimeout: false }));
    const rows = JSON.parse(response.formattedRecords ?? "null");
    if (!Array.isArray(rows) || rows.length !== 1 || typeof rows[0].result_json !== "string") {
      throw new Error("MARKETROUTE_AWS_V0_ADMISSION_RECEIPT_INVALID");
    }
    return JSON.parse(rows[0].result_json);
  }
  return {
    preflight(work, fingerprint, worker) {
      return call(`SELECT public.marketroute_preflight_aws_v0_inference_v1(
        CAST(:work AS uuid),:envelope,:worker)::text AS result_json`, { work, envelope: fingerprint, worker });
    },
    admit(envelope, fingerprint, workerId, plan) {
      return call(`SELECT public.marketroute_admit_aws_v0_inference_v1(
        CAST(:work AS uuid),:envelope,:worker,:request,:profile,CAST(:input AS bigint),CAST(:output AS integer))::text AS result_json`,
      { work: envelope.workUnitId, envelope: fingerprint, worker: workerId,
        request: plan.requestFingerprint, profile: plan.profileArn, input: plan.inputTokens, output: plan.maxOutputTokens });
    },
    defer(work, fingerprint, worker) {
      return call(`SELECT to_jsonb(public.marketroute_defer_aws_v0_inference_v1(
        CAST(:work AS uuid),:envelope,:worker))::text AS result_json`, { work, envelope: fingerprint, worker });
    },
    settle(id, worker, request, outcome, telemetry = {}) {
      return call(`SELECT public.marketroute_settle_aws_v0_inference_v1(
        CAST(:id AS uuid),:worker,:request,:outcome,CAST(:input AS bigint),CAST(:output AS bigint),CAST(:telemetry AS jsonb))::text AS result_json`,
      { id, worker, request, outcome, input: outcome === "MEASURED" ? telemetry.inputUnits : null,
        output: outcome === "MEASURED" ? telemetry.outputUnits : null, telemetry: JSON.stringify(telemetry) });
    },
    destroy() { client.destroy(); },
  };
}
// Recovery storage only. These named operations cannot invoke Bedrock or send SQS.
export async function createRecoveryLedger() {
  const required = key => {
    const value = process.env[key]?.trim();
    if (!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${key}`);
    return value;
  };
  const region = required('AWS_REGION');
  if (region !== 'eu-west-2') throw new Error('MARKETROUTE_AWS_V0_RECOVERY_REGION_INVALID');
  const base = { resourceArn: required('MARKETROUTE_AWS_RDS_CLUSTER_ARN'),
    secretArn: required('MARKETROUTE_AWS_RDS_SECRET_ARN'), database: required('MARKETROUTE_AWS_RDS_DATABASE') };
  const sdk = await import('@aws-sdk/client-rds-data');
  const client = new sdk.RDSDataClient({ region, maxAttempts: 1 });
  const call = async (sql, args) => {
    const response = await client.send(new sdk.ExecuteStatementCommand({ ...base, sql,
      parameters: Object.entries(args).map(([name, value]) => ({ name, value: { stringValue: String(value) } })),
      formatRecordsAs: 'JSON', continueAfterTimeout: false }));
    const rows = JSON.parse(response.formattedRecords ?? 'null');
    if (!Array.isArray(rows) || rows.length !== 1 || typeof rows[0].result_json !== 'string') {
      throw new Error('MARKETROUTE_AWS_V0_RECOVERY_RECEIPT_INVALID');
    }
    return JSON.parse(rows[0].result_json);
  };
  return {
    note(envelope, fingerprint, count, reason) {
      return call(`SELECT public.marketroute_note_aws_v0_transport_failure_v1(
        CAST(:envelope AS jsonb),:fingerprint,CAST(:count AS integer),:reason)::text AS result_json`,
      { envelope: JSON.stringify(envelope), fingerprint, count, reason });
    },
    candidates(limit = 5) {
      return call('SELECT public.marketroute_list_aws_v0_recovery_candidates_v1(CAST(:limit AS integer))::text AS result_json', { limit });
    },
    prepare(envelope, fingerprint, coordinator) {
      return call(`SELECT public.marketroute_prepare_aws_v0_recovery_v1(
        CAST(:envelope AS jsonb),:fingerprint,:coordinator)::text AS result_json`,
      { envelope: JSON.stringify(envelope), fingerprint, coordinator });
    },
    confirm(work, attempt, token, coordinator, fingerprint, message) {
      return call(`SELECT public.marketroute_confirm_aws_v0_recovery_send_v1(
        CAST(:work AS uuid),CAST(:attempt AS integer),CAST(:token AS uuid),:coordinator,:fingerprint,:message)::text AS result_json`,
      { work, attempt, token, coordinator, fingerprint, message });
    },
    destroy() { client.destroy(); },
  };
}
