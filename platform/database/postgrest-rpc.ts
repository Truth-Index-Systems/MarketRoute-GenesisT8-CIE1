export interface PostgrestRpcConfig {
  supabaseUrl: string;
  serviceRoleKey: string;
  fetchImpl?: typeof fetch;
}

export class PostgrestRpcError extends Error {
  readonly status: number;
  readonly code: string | null;
  readonly details: unknown;

  constructor(message: string, status: number, code: string | null, details: unknown) {
    super(message);
    this.name = "PostgrestRpcError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function requiredEnvironment(name: "SUPABASE_URL" | "SUPABASE_SERVICE_ROLE_KEY"): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);
  return value;
}

export function databaseConfigFromEnvironment(): PostgrestRpcConfig {
  return {
    supabaseUrl: requiredEnvironment("SUPABASE_URL").replace(/\/+$/, ""),
    serviceRoleKey: requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
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
