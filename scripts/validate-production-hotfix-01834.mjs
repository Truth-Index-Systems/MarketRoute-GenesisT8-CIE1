import fs from 'node:fs';
const growth=fs.readFileSync(new URL('../platform/ai/openai-growth-provider.ts',import.meta.url),'utf8');
const research=fs.readFileSync(new URL('../platform/ai/openai-research-provider.ts',import.meta.url),'utf8');
const service=fs.readFileSync(new URL('../application/growth/service.ts',import.meta.url),'utf8');
const canonical=fs.readFileSync(new URL('../core/evidence/canonical.ts',import.meta.url),'utf8');
const checks=[
 ['growth grounding derives publisher from consulted URL',growth.includes('sourceUrl:matched,publisherDomain:domain(matched)')],
 ['growth grounding does not trust model publisher metadata',!growth.includes('publisherDomain:row.publisherDomain||domain(matched)')],
 ['campaign research grounding derives publisher from consulted URL',research.includes('sourceUrl:matched,publisherDomain:domainOf(matched)')],
 ['campaign source persistence re-derives URL publisher',research.includes('publisherDomain:domainOf(row.sourceUrl)')],
 ['growth persistence re-derives publisher from source URL',service.includes('publisher=new URL(row.sourceUrl).hostname.toLowerCase().replace(/^www\\./,"")')],
 ['canonical mismatch guard retained',canonical.includes('MARKETROUTE_PUBLISHER_DOMAIN_URL_MISMATCH')],
 ['canonical mismatch guard still compares supplied and URL domains',canonical.includes('if (urlDomain && suppliedDomain && urlDomain !== suppliedDomain)')],
 ['no authority semantics added to provider',!/(R4|R5|R6).*?(authority_status|INSERT INTO public\.commercial_reality_decisions|UPDATE public\.commercial_reality_decisions)/is.test(growth+research)]
];
let failed=0;for(const [name,ok] of checks){console.log(`${ok?'PASS':'FAIL'} ${name}`);if(!ok)failed++;}
if(failed)process.exit(1);console.log(`\n${checks.length}/${checks.length} 0.18.3.4 checks passed.`);
