import fs from 'node:fs';
const sql=fs.readFileSync(new URL('../supabase/migrations/0023_production_runtime_ambiguity_cost_hotfix.sql',import.meta.url),'utf8');
const checks=[
 ['claim ambiguity fixed',sql.includes('WHERE cel.claim_id = v_claim_id')],
 ['activation ambiguity fixed',sql.includes('attempt_count = j.attempt_count + 1')],
 ['append-only budget not mutated',!/UPDATE\s+public\.genesis_growth_budget_events/i.test(sql)&&!/DELETE\s+FROM\s+public\.genesis_growth_budget_events/i.test(sql)],
 ['effective spend helper present',sql.includes('marketroute_growth_effective_spend_v1')],
 ['growth gate uses effective spend',sql.includes("marketroute_growth_effective_spend_v1(v_day,v_day+interval '1 day')")],
 ['dashboard uses effective spend',sql.includes("'spentTodayUsd',public.marketroute_growth_effective_spend_v1(v_day_start,NULL)")],
 ['historical cost recovery uses mutable action runs',sql.includes('UPDATE public.genesis_growth_action_runs AS ar')],
 ['recovery-first partial-company repair preserved',sql.includes('Recovery-first invariant')&&sql.includes("v_action:='RESEARCH_CORE_PROFILE'")]
];
let failed=0;for(const [name,ok] of checks){console.log(`${ok?'PASS':'FAIL'} ${name}`);if(!ok)failed++;}
if(failed)process.exit(1);console.log(`\n${checks.length}/${checks.length} 0.18.3.2 checks passed.`);
