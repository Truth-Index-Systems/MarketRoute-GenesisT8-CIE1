import { assert, check, importDecision, layerForImport, normaliseImport, printResults, readJson } from "../../scripts/lib/constitution.mjs";

const rules = readJson("constitution/layer-rules.json");
const permit = (source, target) => importDecision(source, target, rules).allowed;

const results = [
  check("core -> core is allowed", () => assert(permit("core/truth/a.ts", "@/core/relationships/b") === true, "core peer import rejected")),
  check("core -> constitution is allowed", () => assert(permit("core/truth/a.ts", "@/constitution/version") === true, "constitution import rejected")),
  check("core -> platform is rejected", () => assert(permit("core/truth/a.ts", "@/platform/database/client") === false, "core reached platform")),
  check("core -> application is rejected", () => assert(permit("core/truth/a.ts", "@/application/opportunities/service") === false, "core reached application")),
  check("core -> UI is rejected", () => assert(permit("core/truth/a.ts", "@/ui/card") === false, "core reached UI")),
  check("authority -> AI is rejected", () => assert(permit("core/authority/a.ts", "@/platform/ai/client") === false, "authority reached AI")),
  check("platform -> core is allowed", () => assert(permit("platform/database/a.ts", "@/core/truth/contracts") === true, "platform/core rejected")),
  check("platform -> application is rejected", () => assert(permit("platform/database/a.ts", "@/application/companies/usecase") === false, "platform reached application")),
  check("application -> platform is allowed", () => assert(permit("application/companies/a.ts", "@/platform/database/client") === true, "application/platform rejected")),
  check("application -> core is allowed", () => assert(permit("application/companies/a.ts", "@/core/truth/contracts") === true, "application/core rejected")),
  check("UI -> application is allowed", () => assert(permit("ui/card.tsx", "@/application/opportunities/read-model") === true, "UI/application rejected")),
  check("UI -> core authority is rejected", () => assert(permit("ui/card.tsx", "@/core/authority/runtime") === false, "UI reached authority")),
  check("UI -> database is rejected", () => assert(permit("ui/card.tsx", "@/platform/database/client") === false, "UI reached database")),
  check("app -> application is allowed", () => assert(permit("app/api/x.ts", "@/application/campaigns/use-case") === true, "app/application rejected")),
  check("app -> core is rejected", () => assert(permit("app/api/x.ts", "@/core/authority/runtime") === false, "route bypassed application")),
  check("relative imports resolve across layers", () => assert(normaliseImport("core/authority/a.ts", "../../platform/ai/client") === "platform/ai/client", "relative normalisation failed")),
  check("external packages are not mistaken for internal layers", () => assert(layerForImport("app/page.tsx", "react") === null, "external import misclassified")),
  check("dot-relative core import stays core", () => assert(layerForImport("core/truth/a.ts", "./b") === "core", "core relative import failed")),
];

printResults("MarketRoute V2 Build 1 — adversarial constitution fixtures", results);
