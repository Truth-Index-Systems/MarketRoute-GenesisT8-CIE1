import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const requireFile = (relative) => {
  if (!fs.existsSync(path.join(root, relative))) throw new Error(`BUILD5_FILE_MISSING:${relative}`);
  return read(relative);
};

const baselinePath = path.join(root, "database/aws/0001_marketroute_aws_canonical_baseline.sql");
const baselineSha = crypto.createHash("sha256").update(fs.readFileSync(baselinePath)).digest("hex");
if (baselineSha !== "46d9c3aee85d1021d7f514c0384aef036b7f53073a7aa78be4bfabd3266d5e5a") {
  throw new Error(`BUILD5_FROZEN_BASELINE_DRIFT:${baselineSha}`);
}

const stack = requireFile("infrastructure/aws-v0/lib/cognito-stack.ts");
for (const required of [
  "MrAwsV0CognitoStack",
  "CfnUserPool",
  "CfnUserPoolClient",
  'usernameAttributes: ["email"]',
  'autoVerifiedAttributes: ["email"]',
  'mfaConfiguration: "OFF"',
  "generateSecret: false",
  'preventUserExistenceErrors: "ENABLED"',
  '"ALLOW_USER_PASSWORD_AUTH"',
  '"ALLOW_REFRESH_TOKEN_AUTH"',
  "RemovalPolicy.RETAIN",
]) {
  if (!stack.includes(required)) throw new Error(`BUILD5_COGNITO_STACK_SETTING_MISSING:${required}`);
}
for (const forbidden of ["CfnUserPoolDomain", "generateSecret: true", "clientSecret", "SUPABASE_"]) {
  if (stack.includes(forbidden)) throw new Error(`BUILD5_COGNITO_STACK_FORBIDDEN:${forbidden}`);
}

const migration = requireFile("database/aws/0002_marketroute_cognito_identity_mapping.sql");
for (const required of [
  "CREATE TABLE public.marketroute_external_identities",
  "REFERENCES public.marketroute_users(id)",
  "CREATE FUNCTION public.marketroute_resolve_external_identity_v1",
  "pg_advisory_xact_lock",
  "MARKETROUTE_USER_INACTIVE",
  "REVOKE ALL ON TABLE public.marketroute_external_identities FROM PUBLIC",
]) {
  if (!migration.includes(required)) throw new Error(`BUILD5_IDENTITY_MIGRATION_SETTING_MISSING:${required}`);
}
for (const forbidden of ["auth.users", "auth.uid()", "auth.jwt()", "request.jwt", "ENABLE ROW LEVEL SECURITY", "CREATE POLICY"]) {
  if (migration.includes(forbidden)) throw new Error(`BUILD5_IDENTITY_MIGRATION_FORBIDDEN:${forbidden}`);
}

const operations = requireFile("platform/database/aws-data-api-operations.ts");
if (!operations.includes('"identity.resolveActor"')) throw new Error("BUILD5_IDENTITY_OPERATION_MISSING");
const identityBlock = operations.slice(operations.indexOf('"identity.resolveActor": Object.freeze'));
if (!identityBlock.includes('kind: "WRITE"')) throw new Error("BUILD5_IDENTITY_RESOLVER_MUST_BE_WRITE_OPERATION");
for (const parameter of [":provider", ":issuer", ":subject", ":email", ":email_verified"]) {
  if (!identityBlock.includes(parameter)) throw new Error(`BUILD5_IDENTITY_PARAMETER_MISSING:${parameter}`);
}

const auth = requireFile("platform/auth/cognito-auth.ts");
for (const required of [
  'import "server-only"',
  "MARKETROUTE_COGNITO_USER_POOL_ID",
  "MARKETROUTE_COGNITO_USER_POOL_CLIENT_ID",
  'header.alg !== "RS256"',
  "payload.iss !== config.issuer",
  "payload.token_use !== expectedUse",
  "payload.exp <= now",
  "audience !== config.clientId",
  'AuthFlow: "USER_PASSWORD_AUTH"',
  'AuthFlow: "REFRESH_TOKEN_AUTH"',
  '"GlobalSignOut"',
]) {
  if (!auth.includes(required)) throw new Error(`BUILD5_COGNITO_AUTH_SETTING_MISSING:${required}`);
}
for (const forbidden of ["SUPABASE_", "MARKETROUTE_COGNITO_CLIENT_SECRET", "localStorage", "sessionStorage", "document.cookie", "window.", "console.log"]) {
  if (auth.includes(forbidden)) throw new Error(`BUILD5_COGNITO_AUTH_FORBIDDEN:${forbidden}`);
}

const boundary = requireFile("platform/auth/cognito-identity-boundary.ts");
for (const required of [
  'import "server-only"',
  'executeOperation("identity.resolveActor"',
  'provider: "COGNITO"',
  "actorUserId",
  "externalSubject",
]) {
  if (!boundary.includes(required)) throw new Error(`BUILD5_COGNITO_IDENTITY_BOUNDARY_MISSING:${required}`);
}
if (boundary.includes("actorUserId: externalUser.id")) throw new Error("BUILD5_EXTERNAL_SUBJECT_USED_AS_INTERNAL_ACTOR");

const app = requireFile("infrastructure/aws-v0/bin/aws-v0.ts");
if (!app.includes('new MrAwsV0CognitoStack(app, "MrAwsV0CognitoStack"')) throw new Error("BUILD5_COGNITO_STACK_NOT_DECLARED");

const pkg = JSON.parse(requireFile("infrastructure/aws-v0/package.json"));
if (pkg.scripts?.["deploy:cognito"] !== "npm run build && cdk deploy MrAwsV0CognitoStack --require-approval never") {
  throw new Error("BUILD5_COGNITO_DEPLOY_SCRIPT_INVALID");
}

console.log("PASS AWS V0 Build 5 Cognito foundation validation");
