import "server-only";

import { createPublicKey, verify as verifySignature } from "node:crypto";

export interface CognitoAuthenticatedUser {
  id: string;
  email: string | null;
  emailVerified: boolean;
}

export interface CognitoAuthSession {
  accessToken: string;
  idToken: string;
  refreshToken: string;
  expiresIn: number;
  user: CognitoAuthenticatedUser;
}

export interface CognitoSignUpResult {
  user: CognitoAuthenticatedUser;
  confirmed: boolean;
}

export interface CognitoConfig {
  region: string;
  userPoolId: string;
  clientId: string;
  issuer: string;
  jwksUrl: string;
}

type CognitoTokenUse = "access" | "id";

interface CognitoJwtClaims {
  sub: string;
  iss: string;
  exp: number;
  iat?: number;
  token_use: CognitoTokenUse;
  client_id?: string;
  aud?: string;
  email?: string;
  email_verified?: boolean | string;
  [key: string]: unknown;
}

interface CognitoJwk {
  kid: string;
  kty: string;
  alg?: string;
  use?: string;
  n?: string;
  e?: string;
}

const JWKS_CACHE_MS = 10 * 60 * 1000;
let jwksCache: { url: string; expiresAt: number; keys: Map<string, CognitoJwk> } | null = null;

function requiredEnvironment(name: "AWS_REGION" | "MARKETROUTE_COGNITO_USER_POOL_ID" | "MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID"): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`MARKETROUTE_ENV_REQUIRED:${name}`);
  return value;
}

export function cognitoConfigFromEnvironment(): CognitoConfig {
  const region = requiredEnvironment("AWS_REGION");
  const userPoolId = requiredEnvironment("MARKETROUTE_COGNITO_USER_POOL_ID");
  const clientId = requiredEnvironment("MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID");
  if (!/^[a-z0-9-]+_[A-Za-z0-9]+$/.test(userPoolId) || !userPoolId.startsWith(`${region}_`)) {
    throw new Error("MARKETROUTE_COGNITO_USER_POOL_ID_INVALID");
  }
  if (!/^[A-Za-z0-9]{8,128}$/.test(clientId)) throw new Error("MARKETROUTE_COGNITO_CLIENT_ID_INVALID");
  const issuer = `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`;
  return { region, userPoolId, clientId, issuer, jwksUrl: `${issuer}/.well-known/jwks.json` };
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("MARKETROUTE_COGNITO_RESPONSE_INVALID");
  return value as Record<string, unknown>;
}

function providerErrorCode(value: unknown): string {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const object = value as Record<string, unknown>;
    for (const candidate of [object.__type, object.code, object.name]) {
      if (typeof candidate === "string") {
        const clean = candidate.split("#").pop()?.trim() ?? "";
        if (/^[A-Za-z0-9_.-]{1,120}$/.test(clean)) return clean;
      }
    }
  }
  return "UNKNOWN";
}

async function cognitoPublicRequest(config: CognitoConfig, action: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  if (!/^[A-Za-z][A-Za-z0-9]{1,80}$/.test(action)) throw new Error("MARKETROUTE_COGNITO_ACTION_INVALID");
  const response = await fetch(`https://cognito-idp.${config.region}.amazonaws.com/`, {
    method: "POST",
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-target": `AWSCognitoIdentityProviderService.${action}`,
    },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  const raw = await response.text();
  let value: unknown = {};
  try { value = raw ? JSON.parse(raw) : {}; }
  catch { value = {}; }
  if (!response.ok) throw new Error(`MARKETROUTE_COGNITO_REQUEST_FAILED:${action}:${providerErrorCode(value)}`);
  return asRecord(value);
}

function decodeJsonSegment(segment: string): Record<string, unknown> {
  try {
    return asRecord(JSON.parse(Buffer.from(segment, "base64url").toString("utf8")));
  } catch {
    throw new Error("MARKETROUTE_COGNITO_TOKEN_INVALID");
  }
}

async function loadJwks(config: CognitoConfig): Promise<Map<string, CognitoJwk>> {
  const now = Date.now();
  if (jwksCache?.url === config.jwksUrl && jwksCache.expiresAt > now) return jwksCache.keys;
  const response = await fetch(config.jwksUrl, { cache: "no-store" });
  if (!response.ok) throw new Error(`MARKETROUTE_COGNITO_JWKS_FAILED:${response.status}`);
  const value = asRecord(await response.json());
  if (!Array.isArray(value.keys)) throw new Error("MARKETROUTE_COGNITO_JWKS_INVALID");
  const keys = new Map<string, CognitoJwk>();
  for (const candidate of value.keys) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) continue;
    const key = candidate as Record<string, unknown>;
    if (typeof key.kid !== "string" || typeof key.kty !== "string") continue;
    keys.set(key.kid, {
      kid: key.kid,
      kty: key.kty,
      ...(typeof key.alg === "string" ? { alg: key.alg } : {}),
      ...(typeof key.use === "string" ? { use: key.use } : {}),
      ...(typeof key.n === "string" ? { n: key.n } : {}),
      ...(typeof key.e === "string" ? { e: key.e } : {}),
    });
  }
  if (keys.size === 0) throw new Error("MARKETROUTE_COGNITO_JWKS_EMPTY");
  jwksCache = { url: config.jwksUrl, expiresAt: now + JWKS_CACHE_MS, keys };
  return keys;
}

export async function verifyCognitoJwt(token: string, expectedUse: CognitoTokenUse, config = cognitoConfigFromEnvironment()): Promise<CognitoJwtClaims> {
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some(part => !part)) throw new Error("MARKETROUTE_COGNITO_TOKEN_INVALID");
  const [encodedHeader, encodedPayload, encodedSignature] = parts;
  const header = decodeJsonSegment(encodedHeader);
  const payload = decodeJsonSegment(encodedPayload) as unknown as CognitoJwtClaims;
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw new Error("MARKETROUTE_COGNITO_TOKEN_ALGORITHM_INVALID");
  const key = (await loadJwks(config)).get(header.kid);
  if (!key || key.kty !== "RSA" || (key.alg && key.alg !== "RS256")) throw new Error("MARKETROUTE_COGNITO_TOKEN_KEY_INVALID");
  const publicKey = createPublicKey({ key: key as JsonWebKey, format: "jwk" });
  const validSignature = verifySignature(
    "RSA-SHA256",
    Buffer.from(`${encodedHeader}.${encodedPayload}`),
    publicKey,
    Buffer.from(encodedSignature, "base64url"),
  );
  if (!validSignature) throw new Error("MARKETROUTE_COGNITO_TOKEN_SIGNATURE_INVALID");
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.sub !== "string" || !payload.sub.trim()) throw new Error("MARKETROUTE_COGNITO_TOKEN_SUBJECT_INVALID");
  if (payload.iss !== config.issuer) throw new Error("MARKETROUTE_COGNITO_TOKEN_ISSUER_INVALID");
  if (payload.token_use !== expectedUse) throw new Error("MARKETROUTE_COGNITO_TOKEN_USE_INVALID");
  if (!Number.isFinite(payload.exp) || payload.exp <= now) throw new Error("MARKETROUTE_COGNITO_TOKEN_EXPIRED");
  const audience = expectedUse === "access" ? payload.client_id : payload.aud;
  if (audience !== config.clientId) throw new Error("MARKETROUTE_COGNITO_TOKEN_AUDIENCE_INVALID");
  return payload;
}

function userFromAttributes(value: unknown): CognitoAuthenticatedUser {
  if (!Array.isArray(value)) throw new Error("MARKETROUTE_COGNITO_USER_ATTRIBUTES_INVALID");
  const attributes = new Map<string, string>();
  for (const candidate of value) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) continue;
    const row = candidate as Record<string, unknown>;
    if (typeof row.Name === "string" && typeof row.Value === "string") attributes.set(row.Name, row.Value);
  }
  const id = attributes.get("sub")?.trim();
  if (!id) throw new Error("MARKETROUTE_COGNITO_USER_SUBJECT_MISSING");
  return {
    id,
    email: attributes.get("email")?.trim().toLowerCase() || null,
    emailVerified: attributes.get("email_verified") === "true",
  };
}

function authenticationResult(value: unknown, refreshTokenFallback?: string): { accessToken: string; idToken: string; refreshToken: string; expiresIn: number } {
  const result = asRecord(value);
  const accessToken = typeof result.AccessToken === "string" ? result.AccessToken : "";
  const idToken = typeof result.IdToken === "string" ? result.IdToken : "";
  const refreshToken = typeof result.RefreshToken === "string" ? result.RefreshToken : (refreshTokenFallback ?? "");
  const expiresIn = typeof result.ExpiresIn === "number" ? result.ExpiresIn : 0;
  if (!accessToken || !idToken || !refreshToken || !Number.isFinite(expiresIn) || expiresIn <= 0) {
    throw new Error("MARKETROUTE_COGNITO_AUTH_RESULT_INVALID");
  }
  return { accessToken, idToken, refreshToken, expiresIn };
}

export class CognitoAuthClient {
  public constructor(private readonly config: CognitoConfig = cognitoConfigFromEnvironment()) {}

  async signUpWithPassword(email: string, password: string): Promise<CognitoSignUpResult> {
    const cleanEmail = email.trim().toLowerCase();
    const value = await cognitoPublicRequest(this.config, "SignUp", {
      ClientId: this.config.clientId,
      Username: cleanEmail,
      Password: password,
      UserAttributes: [{ Name: "email", Value: cleanEmail }],
    });
    const id = typeof value.UserSub === "string" ? value.UserSub.trim() : "";
    if (!id) throw new Error("MARKETROUTE_COGNITO_SIGNUP_SUBJECT_MISSING");
    return { user: { id, email: cleanEmail, emailVerified: false }, confirmed: value.UserConfirmed === true };
  }

  async confirmSignUp(email: string, code: string): Promise<void> {
    await cognitoPublicRequest(this.config, "ConfirmSignUp", {
      ClientId: this.config.clientId,
      Username: email.trim().toLowerCase(),
      ConfirmationCode: code.trim(),
    });
  }

  async signInWithPassword(email: string, password: string): Promise<CognitoAuthSession> {
    const value = await cognitoPublicRequest(this.config, "InitiateAuth", {
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: this.config.clientId,
      AuthParameters: { USERNAME: email.trim().toLowerCase(), PASSWORD: password },
    });
    if (typeof value.ChallengeName === "string" && value.ChallengeName) {
      throw new Error(`MARKETROUTE_COGNITO_CHALLENGE_REQUIRED:${value.ChallengeName.replace(/[^A-Za-z0-9_]/g, "")}`);
    }
    const tokens = authenticationResult(value.AuthenticationResult);
    await verifyCognitoJwt(tokens.accessToken, "access", this.config);
    await verifyCognitoJwt(tokens.idToken, "id", this.config);
    const user = await this.user(tokens.accessToken);
    return { ...tokens, user };
  }

  async refresh(refreshToken: string): Promise<CognitoAuthSession> {
    const value = await cognitoPublicRequest(this.config, "InitiateAuth", {
      AuthFlow: "REFRESH_TOKEN_AUTH",
      ClientId: this.config.clientId,
      AuthParameters: { REFRESH_TOKEN: refreshToken },
    });
    if (typeof value.ChallengeName === "string" && value.ChallengeName) {
      throw new Error(`MARKETROUTE_COGNITO_CHALLENGE_REQUIRED:${value.ChallengeName.replace(/[^A-Za-z0-9_]/g, "")}`);
    }
    const tokens = authenticationResult(value.AuthenticationResult, refreshToken);
    await verifyCognitoJwt(tokens.accessToken, "access", this.config);
    await verifyCognitoJwt(tokens.idToken, "id", this.config);
    const user = await this.user(tokens.accessToken);
    return { ...tokens, user };
  }

  async user(accessToken: string): Promise<CognitoAuthenticatedUser> {
    const claims = await verifyCognitoJwt(accessToken, "access", this.config);
    const value = await cognitoPublicRequest(this.config, "GetUser", { AccessToken: accessToken });
    const user = userFromAttributes(value.UserAttributes);
    if (user.id !== claims.sub) throw new Error("MARKETROUTE_COGNITO_USER_SUBJECT_MISMATCH");
    return user;
  }

  async requestPasswordReset(email: string): Promise<void> {
    await cognitoPublicRequest(this.config, "ForgotPassword", {
      ClientId: this.config.clientId,
      Username: email.trim().toLowerCase(),
    });
  }

  async confirmPasswordReset(email: string, confirmationCode: string, newPassword: string): Promise<void> {
    await cognitoPublicRequest(this.config, "ConfirmForgotPassword", {
      ClientId: this.config.clientId,
      Username: email.trim().toLowerCase(),
      ConfirmationCode: confirmationCode.trim(),
      Password: newPassword,
    });
  }

  async signOut(accessToken: string): Promise<void> {
    await verifyCognitoJwt(accessToken, "access", this.config);
    await cognitoPublicRequest(this.config, "GlobalSignOut", { AccessToken: accessToken });
  }
}

export function cognitoAuthClientFromEnvironment(): CognitoAuthClient {
  return new CognitoAuthClient(cognitoConfigFromEnvironment());
}
