export interface PostgrestRpcConfig {
  supabaseUrl: string;
  serviceRoleKey: string;
  fetchImpl?: typeof fetch;
}

export class PostgrestRpcError extends Error {
  readonly status: number;
  readonly code: string | null;
  readonly details: unknown;
  readonly functionName: string;

  constructor(message: string, status: number, code: string | null, details: unknown, functionName: string) {
    super(message);
    this.name = "PostgrestRpcError";
    this.status = status;
    this.code = code;
    this.details = details;
    this.functionName = functionName;
  }
}

function diagnosticPart(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalised = value.replace(/\s+/g, " ").trim();
  return normalised || null;
}

export function marketrouteErrorCode(error: unknown, fallback: string): string {
  if (!(error instanceof PostgrestRpcError)) {
    return (error instanceof Error ? error.message : fallback).slice(0, 500);
  }
  const payload = error.details && typeof error.details === "object"
    ? error.details as Record<string, unknown>
    : null;
  return [
    "MARKETROUTE_DATABASE_RPC_FAILED",
    error.functionName,
    error.code ?? String(error.status),
    diagnosticPart(error.message),
    diagnosticPart(payload?.details),
  ].filter((value): value is string => Boolean(value)).join(":").slice(0, 500);
}

function requiredEnvironment(name: "SUPABASE_URL"): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);
  return value;
}

export function supabaseServerKeyFromEnvironment(): string {
  const value = process.env.SUPABASE_SECRET_KEY?.trim() || process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (!value) throw new Error("MARKETROUTE_ENV_REQUIRED:SUPABASE_SECRET_KEY_OR_SUPABASE_SERVICE_ROLE_KEY");
  return value;
}

export function supabasePublicKeyFromEnvironment(): string {
  const value = process.env.SUPABASE_PUBLISHABLE_KEY?.trim() || process.env.SUPABASE_ANON_KEY?.trim();
  if (!value) throw new Error("MARKETROUTE_ENV_REQUIRED:SUPABASE_PUBLISHABLE_KEY_OR_SUPABASE_ANON_KEY");
  return value;
}

export function databaseConfigFromEnvironment(): PostgrestRpcConfig {
  return {
    supabaseUrl: requiredEnvironment("SUPABASE_URL").replace(/\/+$/, ""),
    serviceRoleKey: supabaseServerKeyFromEnvironment(),
  };
}

export class PostgrestRpcClient {
  private readonly config: PostgrestRpcConfig;

  constructor(config: PostgrestRpcConfig) {
    if (!/^https:\/\//i.test(config.supabaseUrl)) throw new Error("MARKETROUTE_SUPABASE_URL_MUST_BE_HTTPS");
    this.config = { ...config, supabaseUrl: config.supabaseUrl.replace(/\/+$/, "") };
  }

  async call<TResult>(functionName: string, payload: Record<string, unknown>): Promise<TResult> {
    if (!/^[a-z0-9_]+$/.test(functionName)) throw new Error("MARKETROUTE_INVALID_RPC_NAME");
    const fetchImpl = this.config.fetchImpl ?? fetch;
    const response = await fetchImpl(`${this.config.supabaseUrl}/rest/v1/rpc/${functionName}`, {
      method: "POST",
      headers: {
        apikey: this.config.serviceRoleKey,
        Authorization: `Bearer ${this.config.serviceRoleKey}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload),
      cache: "no-store",
    });

    const raw = await response.text();
    const parsed = raw ? safeJson(raw) : null;
    if (!response.ok) {
      const object = parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : null;
      throw new PostgrestRpcError(
        typeof object?.message === "string" ? object.message : `MARKETROUTE_DATABASE_RPC_FAILED:${functionName}`,
        response.status,
        typeof object?.code === "string" ? object.code : null,
        parsed,
        functionName,
      );
    }
    return parsed as TResult;
  }
}

function safeJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}
