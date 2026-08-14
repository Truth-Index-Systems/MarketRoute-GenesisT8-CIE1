import fs from 'node:fs';
const sql=fs.readFileSync(new URL('../supabase/migrations/0024_truth_entity_snapshot_ambiguity_hotfix.sql',import.meta.url),'utf8');
const base=fs.readFileSync(new URL('../supabase/migrations/0007_truth_engine_v2.sql',import.meta.url),'utf8');
const apply=fs.readFileSync(new URL('../APPLY-IN-SUPABASE-MARKETROUTE-V2-BUILD4.sql',import.meta.url),'utf8');
const safe=`FROM public.truth_entity_snapshots AS tes\n  WHERE tes.tenant_scope_organisation_id IS NOT DISTINCT FROM p_tenant_scope_organisation_id\n    AND tes.subject_type = p_subject_type\n    AND tes.subject_id = p_subject_id\n    AND tes.profile_key = p_profile_key\n    AND tes.input_fingerprint = v_input_fingerprint`;
const checks=[
 ['entity truth function replaced',sql.includes('CREATE OR REPLACE FUNCTION public.marketroute_persist_entity_truth_v1')],
 ['ambiguous fingerprint predicate removed',!sql.includes('\n    AND input_fingerprint = v_input_fingerprint;')],
 ['entity snapshot lookup fully qualified',sql.includes(safe)],
 ['canonical migration repaired',base.includes(safe)],
 ['standalone Build4 SQL repaired',apply.includes(safe)],
 ['service-role execution preserved',sql.includes('GRANT EXECUTE ON FUNCTION public.marketroute_persist_entity_truth_v1')],
 ['no authority mutation introduced',!/(commercial_reality_decisions|relationship_authority_decisions|contact_authority_decisions).*?(insert|update|delete)/is.test(sql)],
 ['no append-only budget mutation introduced',!/UPDATE\s+public\.genesis_growth_budget_events/i.test(sql)&&!/DELETE\s+FROM\s+public\.genesis_growth_budget_events/i.test(sql)]
];
let failed=0;for(const [name,ok] of checks){console.log(`${ok?'PASS':'FAIL'} ${name}`);if(!ok)failed++;}
if(failed)process.exit(1);console.log(`\n${checks.length}/${checks.length} 0.18.3.3 checks passed.`);
