import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const stack = read("infrastructure/aws-v0/lib/cognito-stack.ts");
const auth = read("platform/auth/cognito-auth.ts");
const boundary = read("platform/auth/cognito-identity-boundary.ts");
const migration = read("database/aws/0002_marketroute_cognito_identity_mapping.sql");
const operations = read("platform/database/aws-data-api-operations.ts");

if (!stack.includes("generateSecret: false")) throw new Error("ADVERSARIAL_BUILD5_PUBLIC_CLIENT_SECRET_BOUNDARY_FAILED");
if (stack.includes("CfnUserPoolDomain")) throw new Error("ADVERSARIAL_BUILD5_HOSTED_UI_UNEXPECTED");
if (!auth.startsWith('import "server-only"')) throw new Error("ADVERSARIAL_BUILD5_AUTH_NOT_SERVER_ONLY");
if (!boundary.startsWith('import "server-only"')) throw new Error("ADVERSARIAL_BUILD5_IDENTITY_BOUNDARY_NOT_SERVER_ONLY");
for (const source of [auth, boundary]) {
  for (const leak of ["SUPABASE_", "localStorage", "sessionStorage", "document.cookie", "MARKETROUTE_COGNITO_CLIENT_SECRET"]) {
    if (source.includes(leak)) throw new Error(`ADVERSARIAL_BUILD5_SECRET_OR_BROWSER_LEAK:${leak}`);
  }
}
if (!auth.includes('header.alg !== "RS256"')) throw new Error("ADVERSARIAL_BUILD5_ALGORITHM_CONFUSION_GUARD_MISSING");
if (!auth.includes("payload.iss !== config.issuer")) throw new Error("ADVERSARIAL_BUILD5_ISSUER_GUARD_MISSING");
if (!auth.includes("audience !== config.clientId")) throw new Error("ADVERSARIAL_BUILD5_AUDIENCE_GUARD_MISSING");
if (!auth.includes("payload.exp <= now")) throw new Error("ADVERSARIAL_BUILD5_EXPIRY_GUARD_MISSING");
if (!migration.includes("PRIMARY KEY (provider, issuer, subject)")) throw new Error("ADVERSARIAL_BUILD5_EXTERNAL_IDENTITY_UNIQUENESS_MISSING");
if (!migration.includes("UNIQUE (provider, issuer, user_id)")) throw new Error("ADVERSARIAL_BUILD5_INTERNAL_BINDING_UNIQUENESS_MISSING");
if (!migration.includes("pg_advisory_xact_lock")) throw new Error("ADVERSARIAL_BUILD5_FIRST_BIND_RACE_GUARD_MISSING");
if (migration.includes("auth.uid()") || migration.includes("auth.users")) throw new Error("ADVERSARIAL_BUILD5_SUPABASE_IDENTITY_LEAK");
const identityOperation = operations.slice(operations.indexOf('"identity.resolveActor": Object.freeze'));
if (!identityOperation.includes('kind: "WRITE"')) throw new Error("ADVERSARIAL_BUILD5_UNCERTAIN_WRITE_GUARD_BYPASSED");
if (!boundary.includes('subject: externalUser.id')) throw new Error("ADVERSARIAL_BUILD5_EXTERNAL_SUBJECT_NOT_MAPPED");
if (boundary.includes("actorUserId: externalUser.id")) throw new Error("ADVERSARIAL_BUILD5_EXTERNAL_SUBJECT_BECAME_DOMAIN_IDENTITY");

console.log("PASS AWS V0 Build 5 adversarial Cognito boundary checks");
