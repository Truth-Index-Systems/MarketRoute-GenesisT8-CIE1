"""Real PostgreSQL admission, budget, rate and evidence checks; no AWS calls."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('build11_fixture', HERE / 'aws-v0-build11-db.py')
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)
sql, q, js = f.sql, f.literal, f.js
PROFILE = 'arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/1t6o6h9xl4qb'
SCOPE = '801132668416:eu-west-2:EU:anthropic.claude-sonnet-4-5-20250929-v1:0'
REQUEST = 'b' * 64
sql((f.ROOT / 'database/aws/0006_marketroute_aws_build11_inference_admission.sql').read_text())
assert sql('SELECT enabled FROM public.marketroute_aws_v0_inference_scopes;') == 'f'
print('PASS migration leaves model-scope admission disabled', flush=True)
sql('UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true;')


def reset_rate():
    sql("UPDATE public.marketroute_aws_v0_inference_scopes SET next_start_at='-infinity';")


def ready(worker='admission-test', reserve=True, budget=0.2, evidence=True, wrong_excerpt=False, prior_day=False):
    item = f.fixture('RUNNING', 'SENT', None)
    x = item['ids']
    sql(f"""UPDATE public.campaigns SET workflow_state='ACTIVE' WHERE id={q(x['campaign'])};
      INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,
        max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours)
      VALUES({q(x['org'])},{q(x['campaign'])},{budget},{min(budget,0.1)},2,2,24);""")
    if reserve:
        at = "now()-interval '1 day'" if prior_day else 'now()'
        sql(f"""INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,
          scheduler_run_id,attempt_number,event_type,amount_usd,occurred_at)
          VALUES({q(x['org'])},{q(x['campaign'])},{q(x['work'])},{q(x['run'])},1,'RESERVE',0.1,{at});""")
    if evidence:
        src, acquisition = str(uuid.uuid4()), str(uuid.uuid4())
        evidence_input = item['envelope']['workUnit']['payload']['metadata']['awsV0Executor']['input']['evidence'][0]
        excerpt = 'Does not match canonical input' if wrong_excerpt else evidence_input['statement']
        fp = item['fp']
        sql(f"""INSERT INTO public.source_records(id,source_kind,source_identity_fingerprint,
          stable_locator,dependence_family_key,normalisation_version)
          VALUES({q(src)},'WEB','{fp}',{q('https://example.test/'+src)},{q(src)},'BUILD11-SYNTHETIC');
          INSERT INTO public.source_acquisitions(id,source_id,acquisition_method)
          VALUES({q(acquisition)},{q(src)},'IMPORT');
          INSERT INTO public.evidence_items(id,acquisition_id,tenant_scope_organisation_id,
            subject_type,subject_id,evidence_kind,excerpt_text,observed_at,extraction_method,
            evidence_fingerprint,source_identity_fingerprint,dependence_family_key,fingerprint_version)
          VALUES({q(x['evidence'])},{q(acquisition)},{q(x['org'])},'COMPANY',{q(x['company'])},'OBSERVATION',
            {q(excerpt)},{q(evidence_input['observedAt'])}::timestamptz,'DETERMINISTIC',
            '{fp}','{fp}',{q(src)},'BUILD11-SYNTHETIC');""")
    if worker:
        assert sql(f.claim(item, worker)) == 'CLAIMED'
    return item


def preflight(item, worker='admission-test'):
    return f"SELECT public.marketroute_preflight_aws_v0_inference_v1({q(item['ids']['work'])},{q(item['fp'])},{q(worker)});"


def admit(item, worker='admission-test', tokens=1000, profile=PROFILE, request=REQUEST):
    return f"SELECT public.marketroute_admit_aws_v0_inference_v1({q(item['ids']['work'])},{q(item['fp'])},{q(worker)},{q(request)},{q(profile)},{tokens},1400);"


def grant(item, **kw):
    return json.loads(sql(admit(item, **kw)))


def defer(item, worker='admission-test'):
    return sql(f"SELECT public.marketroute_defer_aws_v0_inference_v1({q(item['ids']['work'])},{q(item['fp'])},{q(worker)});")


def settle(g, outcome='MEASURED', worker='admission-test', inp=1000, out=100):
    i, o = (str(inp), str(out)) if outcome == 'MEASURED' else ('NULL', 'NULL')
    return json.loads(sql(f"SELECT public.marketroute_settle_aws_v0_inference_v1({q(g['admissionId'])},{q(worker)},'{REQUEST}',{q(outcome)},{i},{o},'{{}}');"))


def retry(item, old='admission-test', new='retry-test'):
    sql(f"SELECT public.marketroute_fail_aws_v0_research_execution_v1({q(item['ids']['work'])},{q(item['fp'])},{q(old)},'SYNTHETIC_RETRY',true,'{{}}',now());")
    assert sql(f.claim(item, new)) == 'CLAIMED'
    reset_rate()


count = 1

def passed(name):
    global count
    count += 1
    print('PASS', name, flush=True)


no_reserve = ready(reserve=False)
assert grant(no_reserve)['reason'] == 'CANONICAL_RESERVATION_REQUIRED'
passed('inference requires an outstanding canonical budget reservation')
low_budget = ready(budget=0.05)
assert grant(low_budget)['reason'] == 'DAILY_BUDGET_EXHAUSTED'
passed('daily budget denial creates no provider reservation')
prior = ready(budget=0.05, prior_day=True)
assert grant(prior)['reason'] == 'DAILY_BUDGET_EXHAUSTED'
passed('unsettled reservations from yesterday cannot disappear at midnight')
missing = ready(evidence=False)
f.rejected(preflight(missing), 'ADMISSION_EVIDENCE_SCOPE_OR_CONTENT_INVALID')
wrong = ready(wrong_excerpt=True)
f.rejected(preflight(wrong), 'ADMISSION_EVIDENCE_SCOPE_OR_CONTENT_INVALID')
passed('missing and altered canonical evidence fails before token counting')
paused = ready()
sql(f"UPDATE public.campaigns SET workflow_state='PAUSED' WHERE id={q(paused['ids']['campaign'])};")
assert json.loads(sql(preflight(paused)))['reason'] == 'CAMPAIGN_NOT_ACTIVE'
passed('paused campaign cannot start model preflight')
valid = ready()
f.rejected(admit(valid, profile=PROFILE+'different'), 'ADMISSION_PROFILE_FORBIDDEN')
f.rejected(admit(valid, worker='wrong-worker'), 'ADMISSION_OWNERSHIP_INVALID')
f.rejected(admit(valid, tokens=200000), 'ADMISSION_INPUT_INVALID')
passed('wrong profile, owner and long-context requests fail closed')

legacy = ready()
sql(f"UPDATE public.marketroute_aws_v0_research_executions SET attempt_count=2 WHERE work_unit_id={q(legacy['ids']['work'])};")
assert grant(legacy)['reason'] == 'LEGACY_ATTEMPT_ACCOUNTING_REQUIRED'
passed('unaccounted legacy attempts cannot masquerade as free retries')

reset_rate()
with ThreadPoolExecutor(max_workers=2) as pool:
    raced = list(pool.map(lambda _: grant(valid), range(2)))
assert sorted(g['outcome'] for g in raced) == ['ADMITTED', 'ALREADY_ADMITTED'], raced
g = next(g for g in raced if g['outcome'] == 'ADMITTED')
assert g['reservedCostUsd'] == 0.0264
passed('concurrent duplicate admissions issue one permit and one reservation')
f.rejected(admit(valid, request='c'*64), 'ADMISSION_COLLISION')
assert defer(valid) == 'f'
passed('admitted request cannot be changed or have its execution attempt refunded')
one = settle(g)
assert one['accountedCostUsd'] == 0.00495 and one['withinReservation']
assert settle(g) == one
f.rejected(f"SELECT public.marketroute_settle_aws_v0_inference_v1({q(g['admissionId'])},'admission-test','{REQUEST}','MEASURED',1000,101,'{{}}');", 'SETTLEMENT_COLLISION')
passed('measured settlement is idempotent and conflicting replay is rejected')
retry(valid)
g2 = grant(valid, worker='retry-test')
assert g2['outcome'] == 'ADMITTED'
assert settle(g2, worker='retry-test')['accountedCostUsd'] == 0.0099
passed('retry costs accumulate across provider attempts')

reset_rate()
unknown = ready()
u = grant(unknown, tokens=19000)
assert u['reservedCostUsd'] == 0.0858
assert settle(u, outcome='UNKNOWN')['accountedCostUsd'] == 0.0858
retry(unknown)
assert grant(unknown, worker='retry-test', tokens=19000)['reason'] == 'WORK_BUDGET_EXHAUSTED'
passed('unknown outcome retains its reservation and prevents unaffordable retry')
assert defer(unknown, worker='retry-test') == 't'
assert sql(f"SELECT attempt_count FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={q(unknown['ids']['work'])};") == '1'
passed('denied retry does not consume another execution attempt')

reset_rate()
a, b = ready('worker-a'), ready('worker-b')
with ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(lambda pair: grant(pair[0], worker=pair[1]), [(a,'worker-a'),(b,'worker-b')]))
assert sorted(x['outcome'] for x in results) == ['ADMITTED','DEFERRED'], results
assert next(x for x in results if x['outcome']=='DEFERRED')['reason'] == 'REQUEST_RATE_LIMIT'
assert sql("SELECT minimum_interval_seconds FROM public.marketroute_aws_v0_inference_scopes;") == '11'
passed('different organisations and workers share one model/account/Region rate gate')
loser, worker = (a,'worker-a') if results[0]['outcome']=='DEFERRED' else (b,'worker-b')
assert defer(loser, worker) == 't'
assert sql(f.claim(loser, worker)) == 'CLAIMED'
assert sql(f"SELECT attempt_count FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={q(loser['ids']['work'])};") == '1'
passed('rate deferral preserves attempt budget and permits later re-claim')

reset_rate()
unsent = ready(); unsent_g = grant(unsent)
assert settle(unsent_g, outcome='NOT_SENT')['accountedCostUsd'] == 0
passed('provably unused permit settles zero without reusing its rate slot')
reset_rate()
breach = ready(); breach_g = grant(breach)
actual = settle(breach_g, inp=10000, out=1400)
assert actual['accountedCostUsd'] == 0.0561 and not actual['withinReservation']
assert sql("SELECT enabled FROM public.marketroute_aws_v0_inference_scopes;") == 'f'
passed('reservation breach retains measured cost and disables subsequent admissions')
sql("UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true, next_start_at='-infinity';")
for statement in [preflight(valid), admit(valid),
    f"SELECT public.marketroute_settle_aws_v0_inference_v1({q(g['admissionId'])},'admission-test','{REQUEST}','MEASURED',1000,100,'{{}}');"]:
    f.rejected('SET ROLE build11_untrusted; '+statement, 'permission denied for function')
passed('untrusted role cannot preflight, admit or settle inference')

# Unclaimed, evidence-backed synthetic fixtures for the actual entry/SQL proof.
fixtures = {name: ready(worker=None, **options) for name, options in {
    'success': {}, 'invalid': {}, 'unknown': {}, 'noBudget': {'budget':0.05},
    'noEvidence': {'evidence':False}, 'rateA': {}, 'rateB': {},
}.items()}
Path('/tmp/marketroute-build11-admission-fixtures.json').write_text(json.dumps(fixtures))
print(f'{count}/{count} PostgreSQL admission assertion groups passed; no AWS invocation', flush=True)
