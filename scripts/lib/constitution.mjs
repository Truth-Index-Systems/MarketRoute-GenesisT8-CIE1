import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const THIS_FILE = fileURLToPath(import.meta.url);
export const ROOT = path.resolve(path.dirname(THIS_FILE), "../..");

export const SOURCE_EXTENSIONS = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]);
export const LAYERS = ["constitution", "core", "platform", "application", "ui", "app"];

export function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(ROOT, relativePath), "utf8"));
}

export function walk(dir = ROOT) {
  const ignored = new Set(["node_modules", ".next", ".git", "coverage", "out"]);
  const results = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ignored.has(entry.name)) continue;
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) results.push(...walk(absolute));
    else results.push(absolute);
  }
  return results;
}

export function relative(absolute) {
  return path.relative(ROOT, absolute).replaceAll(path.sep, "/");
}

export function topLayer(relativePath) {
  const first = relativePath.split("/")[0];
  return LAYERS.includes(first) ? first : null;
}

export function importsFromText(text) {
  const imports = [];
  const patterns = [
    /(?:import|export)\s+(?:[^"']*?\s+from\s+)?["']([^"']+)["']/g,
    /require\(\s*["']([^"']+)["']\s*\)/g,
    /import\(\s*["']([^"']+)["']\s*\)/g,
  ];
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) imports.push(match[1]);
  }
  return imports;
}

export function normaliseImport(sourceRelative, specifier) {
  if (specifier.startsWith("@/")) return specifier.slice(2);
  if (specifier.startsWith("./") || specifier.startsWith("../")) {
    const sourceDir = path.posix.dirname(sourceRelative);
    return path.posix.normalize(path.posix.join(sourceDir, specifier));
  }
  return null;
}

export function layerForImport(sourceRelative, specifier) {
  const normalised = normaliseImport(sourceRelative, specifier);
  if (!normalised) return null;
  return topLayer(normalised);
}


export function importDecision(sourceRelative, specifier, rules) {
  const sourceLayer = topLayer(sourceRelative);
  const targetLayer = layerForImport(sourceRelative, specifier);
  if (!sourceLayer || !targetLayer) return { internal: false, allowed: true, reason: "external-or-unclassified" };
  const allowedLayers = rules.layers[sourceLayer]?.mayImport ?? [];
  if (!allowedLayers.includes(targetLayer)) {
    return { internal: true, allowed: false, reason: `${sourceLayer}-cannot-import-${targetLayer}` };
  }
  for (const [prefix, rule] of Object.entries(rules.specialRules ?? {})) {
    if (!sourceRelative.startsWith(prefix)) continue;
    for (const fragment of rule.forbidImportsContaining ?? []) {
      if (specifier.includes(fragment)) {
        return { internal: true, allowed: false, reason: `forbidden-fragment:${fragment}` };
      }
    }
  }
  return { internal: true, allowed: true, reason: "allowed" };
}

export function sourceFiles() {
  return walk().filter((file) => SOURCE_EXTENSIONS.has(path.extname(file)));
}

export function assert(condition, message) {
  if (!condition) throw new Error(message);
}

export function check(name, fn) {
  try {
    fn();
    return { name, ok: true };
  } catch (error) {
    return { name, ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

export function printResults(title, results) {
  let passed = 0;
  console.log(`\n${title}`);
  for (const result of results) {
    if (result.ok) {
      passed += 1;
      console.log(`PASS  ${result.name}`);
    } else {
      console.error(`FAIL  ${result.name}: ${result.error}`);
    }
  }
  console.log(`\n${passed}/${results.length} PASS`);
  if (passed !== results.length) process.exitCode = 1;
}
