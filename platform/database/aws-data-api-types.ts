export type AwsDataApiOperationKind = "READ" | "WRITE";
export type AwsDataApiTypeHint = "DATE" | "DECIMAL" | "JSON" | "TIME" | "TIMESTAMP" | "UUID";

export type AwsDataApiParameterValue =
  | string
  | number
  | bigint
  | boolean
  | Date
  | Uint8Array
  | Record<string, unknown>
  | unknown[]
  | null;

export interface AwsDataApiSqlParameter {
  readonly name: string;
  readonly value: AwsDataApiParameterValue;
  readonly typeHint?: AwsDataApiTypeHint;
}

export interface AwsDataApiOperationDefinition {
  readonly name: string;
  readonly kind: AwsDataApiOperationKind;
  readonly sql: string;
  readonly parameterNames: readonly string[];
  readonly typeHints?: Readonly<Record<string, AwsDataApiTypeHint>>;
  readonly jsonColumns?: readonly string[];
  readonly maxRows: number;
}

export interface AwsDataApiFieldLike {
  readonly isNull?: boolean;
  readonly stringValue?: string;
  readonly longValue?: number;
  readonly doubleValue?: number;
  readonly booleanValue?: boolean;
  readonly blobValue?: Uint8Array;
  readonly arrayValue?: {
    readonly stringValues?: readonly string[];
    readonly longValues?: readonly number[];
    readonly doubleValues?: readonly number[];
    readonly booleanValues?: readonly boolean[];
    readonly arrayValues?: readonly AwsDataApiFieldLike["arrayValue"][];
  };
}

export interface AwsDataApiColumnMetadataLike {
  readonly name?: string;
}

export interface AwsDataApiEncodedParameter {
  readonly name: string;
  readonly value: {
    readonly isNull?: boolean;
    readonly stringValue?: string;
    readonly longValue?: number;
    readonly doubleValue?: number;
    readonly booleanValue?: boolean;
    readonly blobValue?: Uint8Array;
  };
  readonly typeHint?: AwsDataApiTypeHint;
}

export interface AwsDataApiExecuteInput {
  readonly resourceArn: string;
  readonly secretArn: string;
  readonly database: string;
  readonly sql: string;
  readonly parameters?: readonly AwsDataApiEncodedParameter[];
  readonly includeResultMetadata: true;
  readonly continueAfterTimeout: false;
  readonly transactionId?: string;
}

export interface AwsDataApiExecuteResultLike {
  readonly columnMetadata?: readonly AwsDataApiColumnMetadataLike[];
  readonly records?: readonly (readonly AwsDataApiFieldLike[])[];
  readonly numberOfRecordsUpdated?: number;
}

export interface AwsDataApiTransactionInput {
  readonly resourceArn: string;
  readonly secretArn: string;
  readonly database: string;
  readonly transactionId?: string;
}

export interface AwsDataApiTransactionResultLike {
  readonly transactionId?: string;
}

export interface AwsDataApiDriver {
  execute(input: AwsDataApiExecuteInput): Promise<AwsDataApiExecuteResultLike>;
  begin(input: AwsDataApiTransactionInput): Promise<AwsDataApiTransactionResultLike>;
  commit(input: AwsDataApiTransactionInput): Promise<void>;
  rollback(input: AwsDataApiTransactionInput): Promise<void>;
}

export interface AwsDataApiConfig {
  readonly region: string;
  readonly clusterArn: string;
  readonly secretArn: string;
  readonly database: string;
  readonly readRetryLimit?: number;
  readonly readRetryBaseDelayMs?: number;
}

export interface AwsDataApiResultRow {
  readonly [columnName: string]: unknown;
}

export interface AwsDataApiOperationResult<TRow extends AwsDataApiResultRow = AwsDataApiResultRow> {
  readonly rows: readonly TRow[];
  readonly numberOfRecordsUpdated: number;
}
