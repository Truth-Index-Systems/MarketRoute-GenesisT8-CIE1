#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const exporterPath = path.join(root, "scripts/migration/export-v1-factual-bundle.mjs");
const profilePath = path.join(root, "migration/v1/source-profile.forensic-build8.json");
const exporter = fs.readFileSync(exporterPath, "utf8");
const profile = JSON.parse(fs.readFileSync(profilePath, "utf8"));

const checks = [];
function check(name, condition) { checks.push({ name, pass: Boolean(condition) }); }

check("concrete Forensic Build 8 source profile is pinned", profile.profileVersion === "MRV2-V1-SOURCE-PROFILE-FORENSIC-BUILD8-1.0.0" && profile.schemaThroughMigration.startsWith("0158_"));
check("exporter is explicitly GET-only", /method:\s*"GET"/.test(exporter));
check("exporter has no V1 RPC calls", !/\/rest\/v1\/rpc\//.test(exporter));
check("V1 table reads are statically whitelisted", /const READ_TABLES = Object\.freeze\(\[/.test(exporter) && /assertReadTable\(table\)/.test(exporter));
check("legacy decision tables are blocked by source profile", ["cie_r4_commercial_decisions","cie_r5_route_decisions","cie_r6_contact_decisions","opportunities","commercial_routes","genesis_g8_truth_snapshots"].every((name) => profile.neverExportTables.includes(name)));
check("campaign target identities are exported", /table: "companies"/.test(exporter) && /table: "company_evidence"/.test(exporter));
check("contact identities and evidence are exported", /table: "contacts"/.test(exporter) && /table: "contact_evidence"/.test(exporter));
check("contact channels are identity-only inputs", /table: "company_contact_channels"/.test(exporter) && /No channel-to-person\/company authority edge is imported/.test(exporter));
check("seller identity is exported without legacy numeric assessment", /table: "business_profiles"/.test(exporter) && /companyName: nonempty\(row\.company_name\)/.test(exporter));
check("dense Genesis shared evidence store is exported", /table: "genesis_g8_intelligence_entities"/.test(exporter) && /table: "genesis_g8_intelligence_evidence"/.test(exporter));
check("Genesis Truth snapshots are never read", !/table:\s*"genesis_g8_truth_snapshots"/.test(exporter) && !/table:\s*"genesis_g8_truth_v2_snapshots"/.test(exporter));
check("legacy numeric evidence assessment columns are not selected", !/select:\s*"[^"]*(strength|traceability|independence|truth_index|confidence|fit_score|routing_score|response_likelihood)[^"]*"/i.test(exporter));
check("legacy route topology is not read", !/table:\s*"commercial_routes"/.test(exporter) && !/table:\s*"route_intelligence_snapshots"/.test(exporter));
check("route-source evidence is reattached to company rather than imported as topology", /entity\.entity_type === "route"/.test(exporter) && /companyRefByDomain\.get\(domain\)/.test(exporter));
check("export is validated against the same frozen contract before writing", /validateBundle\(output\)/.test(exporter));

const failed = checks.filter((item) => !item.pass);
for (const item of checks) console.log(`${item.pass ? "PASS" : "FAIL"} ${item.name}`);
console.log(`Build 17 V1 exporter: ${checks.length - failed.length}/${checks.length} checks passed.`);
if (failed.length) process.exit(1);
