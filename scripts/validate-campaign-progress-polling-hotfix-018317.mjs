import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const root=path.resolve(import.meta.dirname,"..");
const read=(file)=>fs.readFileSync(path.join(root,file),"utf8");
const progress=read("ui/application/campaign-activation-progress.tsx");
const endpoint=read("app/api/campaigns/activation-status/route.ts");
const session=read("app/app/_lib/session.ts");
const marker=read("NO-SUPABASE-MIGRATION-0.18.3.17.txt");
const migrations=fs.readdirSync(path.join(root,"supabase/migrations")).filter((file)=>/^\d+_/.test(file));
const authorityWrite=/INSERT\s+INTO\s+public\.(?:commercial_reality_r4_records|route_authority_r5_records|contact_authority_r6_records|authority_records)/i;
const checks=[];
const check=(name,fn)=>checks.push([name,fn]);

check("progress polling no longer refreshes the full route on a timer",()=>{
  assert.doesNotMatch(progress,/setInterval/);
  assert.match(progress,/fetch\("\/api\/campaigns\/activation-status"/);
  assert.match(progress,/if\(!isWorking\(next\.status\)\)[\s\S]*router\.refresh\(\)/);
  assert.equal((progress.match(/router\.refresh\(\)/g)??[]).length,1);
});
check("polling is bounded by activation state and tab visibility",()=>{
  assert.match(progress,/status==="RUNNING"\)return 3000/);
  assert.match(progress,/status==="FAILED"\)return 30000/);
  assert.match(progress,/return 12000/);
  assert.match(progress,/document\.visibilityState!=="visible"/);
  assert.match(progress,/window\.setTimeout/);
});
check("session refresh is attempted at most once per mounted progress view",()=>{
  assert.match(progress,/const refreshStarted=useRef\(false\)/);
  assert.match(progress,/response\.status===401/);
  assert.match(progress,/refreshStarted\.current=true/);
  assert.match(progress,/window\.location\.assign\(`\/api\/session\/refresh\?next=/);
});
check("status endpoint is authenticated, dynamic, and never cached",()=>{
  assert.match(endpoint,/export const dynamic="force-dynamic"/);
  assert.match(endpoint,/ACCESS_COOKIE,ORG_COOKIE/);
  assert.match(endpoint,/activationStatus\(accessToken,organisationId\)/);
  assert.match(endpoint,/"Cache-Control":"no-store"/);
  assert.match(endpoint,/status:401/);
});
check("server component session resolution is deduplicated per render",()=>{
  assert.match(session,/import \{ cache \} from "react"/);
  assert.match(session,/workspaceSessionOrRedirect=cache\(resolveWorkspaceSession\)/);
});
check("hotfix is application-only and preserves authority boundaries",()=>{
  assert.match(marker,/application-only/i);
  assert.match(marker,/0036/);
  const maxMigration=Math.max(...migrations.map((file)=>Number(file.slice(0,4))));
  assert(maxMigration>=36&&maxMigration<=37);
  assert(!migrations.some((file)=>/polling/i.test(file)));
  assert(!authorityWrite.test(progress));
  assert(!authorityWrite.test(endpoint));
});

let passed=0;
console.log("\nMarketRoute V2 — Campaign progress polling hotfix 0.18.3.17");
for(const [name,fn] of checks){try{fn();passed++;console.log(`PASS  ${name}`);}catch(error){console.error(`FAIL  ${name}: ${error instanceof Error?error.message:error}`);}}
console.log(`\n${passed}/${checks.length} PASS`);
if(passed!==checks.length)process.exitCode=1;
