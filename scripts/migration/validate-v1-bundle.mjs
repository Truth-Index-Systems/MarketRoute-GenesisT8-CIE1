#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { validateBundle } from "./v1-contract.mjs";

const file = process.argv[2];
if (!file) {
  console.error("Usage: node scripts/migration/validate-v1-bundle.mjs <bundle.json>");
  process.exit(2);
}
const absolute = path.resolve(process.cwd(), file);
const bundle = JSON.parse(fs.readFileSync(absolute, "utf8"));
const result = validateBundle(bundle);
console.log(JSON.stringify({ ok: true, file: absolute, ...result }, null, 2));
