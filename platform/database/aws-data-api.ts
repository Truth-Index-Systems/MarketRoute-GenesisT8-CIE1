import "server-only";

import {
  awsDataApiOperationDefinition,
  type AwsDataApiOperationInputMap,
  type AwsDataApiOperationName,
} from "./aws-data-api-operations";
import type {
  AwsDataApiConfig,
  AwsDataApiDriver,
  AwsDataApiEncodedParameter,
  AwsDataApiExecuteInput,
  AwsDataApiFieldLike,
  AwsDataApiOperationDefinition,
  AwsDataApiOperationResult,
  AwsDataApiParameterValue,
  AwsDataApiResultRow,
  AwsDataApiSqlParameter,
  AwsDataApiTransactionInput,
} from "./aws-data-api-types";

const AWS_RDS_DATA_PACKAGE = "@aws-sdk/client-rds-data";
const DEFAULT_READ_RETRY_LIMIT = 2;
const DEFAULT_READ_RETRY_BASE_DELAY_MS = 250;

interface AwsSdkRdsDataModule {
  RDSDataClient: new (config: { region: string }) => { send(command: unknown): Promise<unknown> };
  ExecuteStatementCommand: new (input: AwsDataApiExecuteInput) => unknown;
  BeginTransactionCommand: new (input: AwsDataApiTransactionInput) => unknown;
  CommitTransactionCommand: new (input: AwsDataApiTransactionInput) => unknown;
  RollbackTransactionCommand: new (input: AwsDataApiTransactionInput) => unknown;
}

function requiredEnvironment(name: "AWS_REGION" | "MARKETROUTE_AWS_RDS_CLUSTER_ARN" | "MARKETROUTE_AWS_RDS_SECRET_ARN" | "MARKETROUTE_AWS_RDS_DATABASE"): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);
  return value;
}

export function awsDataApiConfigFromEnvironment(): AwsDataApiConfig {
  return {
    region: requiredEnvironment("AWS_REGION"),
    clusterArn: requiredEnvironment("MARKETROUTE_AWS_RDS_CLUSTER_ARN"),
    secretArn: requiredEnvironment("MARKETROUTE_AWS_RDS_SECRET_ARN"),
    database: requiredEnvironment("MARKETROUTE_AWS_RDS_DATABASE"),
  };
}

async function loadAwsSdkRdsData(): Promise<AwsSdkRdsDataModule> {
  // Build 4 keeps the application dependency graph unchanged. Build 6 pins the SDK
  // dependency when this adapter becomes the live application transport.
  const dynamicImport = new Function("specifier", "return import(specifier)") as (specifier: string) => Promise<unknown>;
  const loaded = await dynamicImport(AWS_RDS_DATA_PACKAGE);
  if (!loaded || typeof loaded !== "object") throw new Error("MARKETROUTE_AWS_RDS_DATA_SDK_LOAD_FAILED");
  const module = loaded as Partial<AwsSdkRdsDataModule>;
  if (!module.RDSDataClient || !module.ExecuteStatementCommand || !module.BeginTransactionCommand || !module.CommitTransactionCommand || !module.RollbackTransactionCommand) {
    throw new Error("MARKETROUTE_AWS_RDS_DATA_SDK_INVALID");
  }
  return module as AwsSdkRdsDataModule;
}

export async function awsSdkRdsDataDriver(region: string): Promise<AwsDataApiDriver> {
  const sdk = await loadAwsSdkRdsData();
  const client = new sdk.RDSDataClient({ region });
  return {
    async execute(input) {
      return await client.send(new sdk.ExecuteStatementCommand(input)) as Awaited<ReturnType<AwsDataApiDriver["execute"]>>;
    },
    async begin(input) {
      return await client.send(new sdk.BeginTransactionCommand(input)) as Awaited<ReturnType<AwsDataApiDriver["begin"]>>;
    },
    async commit(input) {
      await client.send(new sdk.CommitTransactionCommand(input));
    },
    async rollback(input) {
      await client.send(new sdk.RollbackTransactionCommand(input));
    },
  };
}

export class AwsDataApiError extends Error {
  readonly operationName: string;
  readonly providerCode: string;
  readonly retryable: boolean;
  readonly uncertainWrite: boolean;

  constructor(input: { operationName: string; providerCode: string; retryable: boolean; uncertainWrite: boolean; cause?: unknown }) {
    super(`MARKETROUTE_AWS_DATA_API_FAILED:${input.operationName}:${input.providerCode}`, { cause: input.cause });
    this.name = "AwsDataApiError";
    this.operationName = input.operationName;
    this.providerCode = input.providerCode;
    this.retryable = input.retryable;
    this.uncertainWrite = input.uncertainWrite;
  }
}

function providerCode(error: unknown): string {
  if (error && typeof error === "object") {
    const value = error as { name?: unknown; Code?: unknown; code?: unknown };
    for (const candidate of [value.name, value.Code, value.code]) {
      if (typeof candidate === "string" && /^[A-Za-z0-9_.-]{1,120}$/.test(candidate)) return candidate;
    }
  }
  return "UNKNOWN";
}

function isSafeReadRetryCode(code: string): boolean {
  return new Set([
    "DatabaseResumingException",
    "DatabaseUnavailableException",
    "ServiceUnavailableError",
    "ServiceUnavailableException",
    "ThrottlingException",
    "InternalServerErrorException",
  ]).has(code);
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function normaliseInputKey(value: string): string {
  return value.replace(/[A-Z]/g, character => `_${character.toLowerCase()}`);
}

function jsonParameter(value: Record<string, unknown> | unknown[]): string {
  return JSON.stringify(value);
}

function encodeParameter(parameter: AwsDataApiSqlParameter): AwsDataApiEncodedParameter {
  const value = parameter.value;
  const encodedValue = value === null
    ? { isNull: true }
    : typeof value === "string"
      ? { stringValue: value }
      : typeof value === "boolean"
        ? { booleanValue: value }
        : typeof value === "bigint"
          ? { stringValue: value.toString() }
          : typeof value === "number"
            ? Number.isInteger(value) && Number.isSafeInteger(value)
              ? { longValue: value }
              : { doubleValue: value }
            : value instanceof Date
              ? { stringValue: value.toISOString() }
              : value instanceof Uint8Array
                ? { blobValue: value }
                : Array.isArray(value) || (value && typeof value === "object")
                  ? { stringValue: jsonParameter(value as Record<string, unknown> | unknown[]) }
                  : (() => { throw new Error(`MARKETROUTE_AWS_DATA_API_PARAMETER_UNSUPPORTED:${parameter.name}`); })();
  return { name: parameter.name, value: encodedValue, ...(parameter.typeHint ? { typeHint: parameter.typeHint } : {}) };
}

function parametersForOperation<TName extends AwsDataApiOperationName>(
  definition: AwsDataApiOperationDefinition,
  input: AwsDataApiOperationInputMap[TName],
): readonly AwsDataApiEncodedParameter[] {
  const source = input as Record<string, AwsDataApiParameterValue>;
  const supplied = Object.keys(source).map(normaliseInputKey).sort();
  const expected = [...definition.parameterNames].sort();
  if (supplied.length !== expected.length || supplied.some((key, index) => key !== expected[index])) {
    throw new Error(`MARKETROUTE_AWS_DATA_API_OPERATION_INPUT_INVALID:${definition.name}`);
  }
  return definition.parameterNames.map(name => {
    const camel = name.replace(/_([a-z])/g, (_match, character: string) => character.toUpperCase());
    return encodeParameter({ name, value: source[camel] ?? source[name] ?? null, typeHint: definition.typeHints?.[name] });
  });
}

function decodeArray(field: AwsDataApiFieldLike): unknown[] | null {
  const value = field.arrayValue;
  if (!value) return null;
  if (value.stringValues) return [...value.stringValues];
  if (value.longValues) return [...value.longValues];
  if (value.doubleValues) return [...value.doubleValues];
  if (value.booleanValues) return [...value.booleanValues];
  if (value.arrayValues) return value.arrayValues.map(arrayValue => decodeArray({ arrayValue }) ?? []);
  return [];
}

function decodeField(field: AwsDataApiFieldLike): unknown {
  if (field.isNull) return null;
  if (field.stringValue !== undefined) return field.stringValue;
  if (field.longValue !== undefined) return field.longValue;
  if (field.doubleValue !== undefined) return field.doubleValue;
  if (field.booleanValue !== undefined) return field.booleanValue;
  if (field.blobValue !== undefined) return field.blobValue;
  if (field.arrayValue !== undefined) return decodeArray(field);
  return null;
}

function decodeRows(definition: AwsDataApiOperationDefinition, result: Awaited<ReturnType<AwsDataApiDriver["execute"]>>): readonly AwsDataApiResultRow[] {
  const records = result.records ?? [];
  if (records.length > definition.maxRows) throw new Error(`MARKETROUTE_AWS_DATA_API_RESULT_LIMIT_EXCEEDED:${definition.name}:${records.length}`);
  const columns = (result.columnMetadata ?? []).map((metadata, index) => metadata.name?.trim() || `column_${index}`);
  const jsonColumns = new Set(definition.jsonColumns ?? []);
  return records.map(record => {
    const row: Record<string, unknown> = {};
    record.forEach((field, index) => {
      const name = columns[index] ?? `column_${index}`;
      const value = decodeField(field);
      if (jsonColumns.has(name) && typeof value === "string") {
        try { row[name] = JSON.parse(value); }
        catch { throw new Error(`MARKETROUTE_AWS_DATA_API_JSON_DECODE_FAILED:${definition.name}:${name}`); }
      } else {
        row[name] = value;
      }
    });
    return row;
  });
}

export interface AwsDataApiTransaction {
  executeOperation<TName extends AwsDataApiOperationName>(
    name: TName,
    input: AwsDataApiOperationInputMap[TName],
  ): Promise<AwsDataApiOperationResult>;
}

export class AwsDataApi {
  private readonly config: Required<Pick<AwsDataApiConfig, "region" | "clusterArn" | "secretArn" | "database">> & Pick<AwsDataApiConfig, "readRetryLimit" | "readRetryBaseDelayMs">;

  constructor(config: AwsDataApiConfig, private readonly driver: AwsDataApiDriver) {
    if (!config.region.trim() || !config.clusterArn.trim() || !config.secretArn.trim() || !config.database.trim()) {
      throw new Error("MARKETROUTE_AWS_DATA_API_CONFIG_INVALID");
    }
    this.config = {
      ...config,
      region: config.region.trim(),
      clusterArn: config.clusterArn.trim(),
      secretArn: config.secretArn.trim(),
      database: config.database.trim(),
      readRetryLimit: Math.max(0, Math.min(config.readRetryLimit ?? DEFAULT_READ_RETRY_LIMIT, 5)),
      readRetryBaseDelayMs: Math.max(25, Math.min(config.readRetryBaseDelayMs ?? DEFAULT_READ_RETRY_BASE_DELAY_MS, 5000)),
    };
  }

  async executeOperation<TName extends AwsDataApiOperationName>(
    name: TName,
    input: AwsDataApiOperationInputMap[TName],
  ): Promise<AwsDataApiOperationResult> {
    return this.executeNamed(name, input, undefined);
  }

  async withTransaction<T>(work: (transaction: AwsDataApiTransaction) => Promise<T>): Promise<T> {
    const base = this.transactionInput();
    const begun = await this.driver.begin(base);
    const transactionId = begun.transactionId?.trim();
    if (!transactionId) throw new Error("MARKETROUTE_AWS_DATA_API_TRANSACTION_ID_MISSING");
    let inFlight = false;
    const transaction: AwsDataApiTransaction = {
      executeOperation: async <TName extends AwsDataApiOperationName>(name: TName, input: AwsDataApiOperationInputMap[TName]) => {
        if (inFlight) throw new Error("MARKETROUTE_AWS_DATA_API_TRANSACTION_CONCURRENT_EXECUTION_FORBIDDEN");
        inFlight = true;
        try { return await this.executeNamed(name, input, transactionId); }
        finally { inFlight = false; }
      },
    };
    try {
      const value = await work(transaction);
      await this.driver.commit({ ...base, transactionId });
      return value;
    } catch (error) {
      await this.driver.rollback({ ...base, transactionId }).catch(() => undefined);
      throw error;
    }
  }

  private transactionInput(): AwsDataApiTransactionInput {
    return {
      resourceArn: this.config.clusterArn,
      secretArn: this.config.secretArn,
      database: this.config.database,
    };
  }

  private async executeNamed<TName extends AwsDataApiOperationName>(
    name: TName,
    input: AwsDataApiOperationInputMap[TName],
    transactionId: string | undefined,
  ): Promise<AwsDataApiOperationResult> {
    const definition = awsDataApiOperationDefinition(name);
    const parameters = parametersForOperation(definition, input);
    const request: AwsDataApiExecuteInput = {
      ...this.transactionInput(),
      sql: definition.sql,
      ...(parameters.length ? { parameters } : {}),
      includeResultMetadata: true,
      continueAfterTimeout: false,
      ...(transactionId ? { transactionId } : {}),
    };
    const retryLimit = definition.kind === "READ" && !transactionId ? (this.config.readRetryLimit ?? DEFAULT_READ_RETRY_LIMIT) : 0;
    for (let attempt = 0; ; attempt += 1) {
      try {
        const result = await this.driver.execute(request);
        return {
          rows: decodeRows(definition, result),
          numberOfRecordsUpdated: Math.max(0, result.numberOfRecordsUpdated ?? 0),
        };
      } catch (error) {
        const code = providerCode(error);
        const safeRetry = definition.kind === "READ" && !transactionId && isSafeReadRetryCode(code) && attempt < retryLimit;
        if (!safeRetry) {
          throw new AwsDataApiError({
            operationName: definition.name,
            providerCode: code,
            retryable: definition.kind === "READ" && isSafeReadRetryCode(code),
            uncertainWrite: definition.kind === "WRITE",
            cause: error,
          });
        }
        const delay = (this.config.readRetryBaseDelayMs ?? DEFAULT_READ_RETRY_BASE_DELAY_MS) * (2 ** attempt);
        await sleep(delay);
      }
    }
  }
}

export async function awsDataApiFromEnvironment(): Promise<AwsDataApi> {
  const config = awsDataApiConfigFromEnvironment();
  return new AwsDataApi(config, await awsSdkRdsDataDriver(config.region));
}
