import fs from 'node:fs';
const sql=fs.readFileSync(new URL('../supabase/migrations/0023_production_runtime_ambiguity_cost_hotfix.sql',import.meta.url),'utf8');
const growth=fs.readFileSync(new URL('../application/growth/service.ts',import.meta.url),'utf8');
const checks=[
 ['claim link uses named conflict constraint',sql.includes('ON CONFLICT ON CONSTRAINT claim_evidence_links_claim_id_evidence_item_id_polarity_key DO NOTHING')],
 ['claim lookup qualifies claim_id',sql.includes('WHERE cel.claim_id = v_claim_id')],
 ['activation attempt_count qualified',sql.includes('attempt_count = j.attempt_count + 1')],
 ['failed growth spend recovery present',sql.includes("request_kind = 'GENESIS_GROWTH_DISCOVERY'")&&sql.includes('marketroute_growth_effective_spend_v1')],
 ['growth budget ledger remains append only',!sql.match(/UPDATE\s+public\.genesis_growth_budget_events/i)&&!sql.match(/DELETE\s+FROM\s+public\.genesis_growth_budget_events/i)],
 ['partial seed shells are repaired before more breadth',sql.includes('Recovery-first invariant')&&sql.includes("v_action:='RESEARCH_CORE_PROFILE'")],
 ['paid execution failure carries cost',growth.includes('class GrowthActionExecutionFailure extends Error')],
 ['failed action records incurred cost',growth.includes('incurredCostUsd=Math.max(incurredCostUsd,failureCost(error))')&&growth.includes('this.repo.fail(next.actionRunId,errorCode(error),incurredCostUsd')],
 ['all four AI growth paths wrap post-AI persistence failures',growth.split('throw new GrowthActionExecutionFailure(result.usage.estimatedCostUsd,error)').length-1===4],
];
let failed=0;for(const [name,ok] of checks){console.log(`${ok?'PASS':'FAIL'} ${name}`);if(!ok)failed++;}
if(failed)process.exit(1);console.log(`\n${checks.length}/${checks.length} production hotfix checks passed.`);
