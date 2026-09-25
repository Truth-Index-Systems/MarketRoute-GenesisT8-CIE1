"""Actual PostgreSQL claim/replay tests against the complete AWS schema.

Only a disposable Docker service named by BUILD11_POSTGRES_CONTAINER is accepted.
The fixture seeds canonical-shaped ledger states with all constraints enabled.
It does NOT mock SQL, call Bedrock, or certify the full planner/synchronizer path.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
CONTAINER = os.environ.get('BUILD11_POSTGRES_CONTAINER', '')
if not re.fullmatch(r'[a-f0-9]{12,64}', CONTAINER):
    raise SystemExit('A disposable Build 11 Docker service container is required')
CMD = ['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-v', 'ON_ERROR_STOP=1',
       '-U', 'postgres', '-d', 'marketroute_build11_test', '-Atq']


def run(text):
    return subprocess.run(CMD, input=text, text=True, capture_output=True, timeout=120)


def sql(text):
    result = run(text)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def js(value):
    return literal(json.dumps(value, separators=(',', ':'), sort_keys=True)) + '::jsonb'


def rejected(statement, code):
    result = run(statement)
    assert result.returncode != 0 and code in result.stderr, (code, result.stdout, result.stderr)


for name in ['0001_marketroute_aws_canonical_baseline.sql',
             '0002_marketroute_cognito_identity_mapping.sql',
             '0003_marketroute_aws_build9_research_execution.sql',
             '0004_marketroute_aws_build10_research_orchestration.sql']:
    data = (ROOT / 'database/aws' / name).read_bytes()
    sql(data.decode())
    print('PASS restored', name, hashlib.sha256(data).hexdigest(), flush=True)


def fixture(job_state='SUCCEEDED', dispatch_state='SYNCED', execution_state='SUCCEEDED', expired=False):
    ids = {key: str(uuid.uuid4()) for key in ('org', 'seller', 'company', 'campaign', 'plan', 'run', 'job', 'work', 'evidence')}
    dedupe = hashlib.sha256(ids['work'].encode()).hexdigest()
    now = datetime.now(timezone.utc).isoformat()
    payload = {'metadata': {
        'awsV0SyncContractVersion': 'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0',
        'awsV0Executor': {'contractVersion': 'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0',
            'operation': 'ai.companyUnderstanding', 'input': {'companyName': 'Build 11 synthetic company',
            'evidence': [{'evidenceId': ids['evidence'], 'sourceType': 'WEBSITE',
                         'statement': 'Synthetic execution fixture only.', 'observedAt': now}]}}},
        'researchOrigin': 'CUSTOMER_CAMPAIGN'}
    envelope = {'schemaVersion': '1', 'transport': 'AWS_SQS', 'workUnitId': ids['work'],
        'enqueuedAt': now, 'organisationId': ids['org'], 'campaignId': ids['campaign'],
        'companyId': ids['company'], 'researchOrigin': 'CUSTOMER_CAMPAIGN', 'dedupeKey': dedupe,
        'workUnit': {'ordinal': 1, 'gapKey': 'semantic:company-understanding', 'layer': 'R4',
            'tier': 'ENRICHMENT', 'action': 'SYNTHESIZE_COMPANY_UNDERSTANDING',
            'subjectType': 'COMPANY', 'subjectId': ids['company'], 'claimKey': None,
            'reasonCode': 'COMPANY_UNDERSTANDING_REFRESH', 'queryHints': [], 'costCeilingUsd': 0.1,
            'dedupeKey': dedupe, 'payload': payload}}
    fp = hashlib.sha256(('MR-AWS-V0-RESEARCH-ENVELOPE-1.0.0|' +
        json.dumps(envelope, separators=(',', ':'), sort_keys=True)).encode()).hexdigest()
    result = {'contractVersion': 'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0',
        'operation': 'ai.companyUnderstanding', 'canonicalPersistenceAllowed': False,
        'truthAuthorityGranted': False, 'deterministicCommercialAuthorityGranted': False,
        'value': {'overview': {'text': 'Synthetic fixture.', 'evidenceIds': [ids['evidence']]}}}
    result_fp = hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()
    q = {k: literal(v) for k, v in ids.items()}
    sql(f"""
    INSERT INTO public.organisations(id,name,slug) VALUES({q['org']},'Build 11 fixture',{q['org']});
    INSERT INTO public.seller_businesses(id,organisation_id,name) VALUES({q['seller']},{q['org']},'Synthetic seller');
    INSERT INTO public.companies(id,canonical_name) VALUES({q['company']},'Synthetic company');
    INSERT INTO public.campaigns(id,organisation_id,seller_business_id,name)
      VALUES({q['campaign']},{q['org']},{q['seller']},'Build 11 fixture');
    INSERT INTO public.scheduler_runs(id,runner_key) VALUES({q['run']},'GENESIS_RESEARCH_V1');
    INSERT INTO public.research_plan_runs(id,organisation_id,campaign_id,company_id,reference_time,
      lifecycle_state,authority_envelope_fingerprint,planner_version,semantics_version,
      gap_set_fingerprint,gap_context_json,work_units_json,budget_policy_snapshot_json,budget_snapshot_json,plan_fingerprint)
      VALUES({q['plan']},{q['org']},{q['campaign']},{q['company']},now(),'COMMERCIAL_RESEARCH_REQUIRED',
        '{dedupe}','MRV2-RESEARCH-1.0.0','MRV2-RESEARCH-1.0.0','{dedupe}','{{}}','[]','{{}}','{{}}','{dedupe}');
    INSERT INTO public.background_jobs(id,organisation_id,campaign_id,job_type,dedupe_key,status,
      reserved_by_run_id,reserved_at,attempt_count)
      VALUES({q['job']},{q['org']},{q['campaign']},'GENESIS_RESEARCH_V1','{dedupe}',{literal(job_state)},
        {q['run'] if job_state == 'RUNNING' else 'NULL'},now(),1);
    INSERT INTO public.research_work_units(id,plan_id,organisation_id,campaign_id,company_id,ordinal,gap_key,
      layer,tier,action,subject_type,subject_id,reason_code,query_hints_json,payload_json,cost_ceiling_usd,dedupe_key,background_job_id)
      VALUES({q['work']},{q['plan']},{q['org']},{q['campaign']},{q['company']},1,'semantic:company-understanding',
        'R4','ENRICHMENT','SYNTHESIZE_COMPANY_UNDERSTANDING','COMPANY',{q['company']},
        'COMPANY_UNDERSTANDING_REFRESH','[]',{js(payload)},0.1,'{dedupe}',{q['job']});
    INSERT INTO public.marketroute_aws_v0_research_dispatches(work_unit_id,canonical_attempt_number,
      scheduler_run_id,state,envelope_json,envelope_fingerprint,sqs_message_id,ownership_expires_at,
      prepared_at,sent_at,updated_at)
      VALUES({q['work']},1,{q['run']},{literal(dispatch_state)},{js(envelope)},'{fp}','synthetic-message',
        now()+interval '{'-1 minute' if expired else '130 minutes'}',now(),now(),now());
    """)
    if execution_state:
        sql(f"""INSERT INTO public.marketroute_aws_v0_research_executions(work_unit_id,dedupe_key,
          envelope_fingerprint,state,worker_id,attempt_count,lease_expires_at,result_json,result_fingerprint,
          telemetry_json,last_error_code)
          VALUES({q['work']},'{dedupe}','{fp}',{literal(execution_state)},'fixture-owner',1,
            now()+interval '210 seconds',{js(result)},'{result_fp}',
            '{{"estimatedEquivalentCostUsd":0.001}}','SYNTHETIC_FAILURE');""")
    if dispatch_state == 'SYNCED':
        sql(f"""INSERT INTO public.marketroute_aws_v0_company_understanding_artifacts(work_unit_id,
          canonical_attempt_number,organisation_id,campaign_id,company_id,result_json,result_fingerprint,
          evidence_item_ids,created_at) VALUES({q['work']},1,{q['org']},{q['campaign']},{q['company']},
          {js(result)},'{result_fp}',ARRAY[{q['evidence']}::uuid],now());""")
    if job_state in ('SUCCEEDED', 'FAILED'):
        sql(f"""INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,
          scheduler_run_id,attempt_number,event_type,amount_usd) VALUES({q['org']},{q['campaign']},
          {q['work']},{q['run']},1,'COMMIT',0.001);""")
    return {'ids': ids, 'envelope': envelope, 'fp': fp, 'result_fp': result_fp}


def claim(f, worker='build11-test', envelope=None, fingerprint=None):
    return f"SELECT public.marketroute_claim_aws_v0_research_execution_v2({js(envelope or f['envelope'])}," \
        f"{literal(fingerprint or f['fp'])},{literal(worker)},now())->>'outcome';"


success = fixture()
failure = fixture('FAILED', 'FAILED', 'FAILED_TERMINAL')
for name, f in [('completed success', success), ('settled terminal failure', failure)]:
    rejected(claim(f), 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID')
    print('REPRODUCED Build 10 rejects redelivery after', name, flush=True)

migration = ROOT / 'database/aws/0005_marketroute_aws_build11_terminal_replay.sql'
sql(migration.read_text())
print('PASS applied forward repair', hashlib.sha256(migration.read_bytes()).hexdigest(), flush=True)

count = 0

def passed(name):
    global count
    count += 1
    print('PASS', name, flush=True)


before = sql('SELECT count(*) || \'|\' || sum(amount_usd)::text FROM public.research_budget_events;')
for _ in range(3):
    assert sql(claim(success)) == 'DEDUPLICATED'
    assert sql(claim(failure)) == 'TERMINAL'
    assert sql(f"SELECT public.marketroute_sync_aws_v0_research_execution_v1('{success['ids']['work']}', '{success['fp']}', '{success['result_fp']}', now());") == 'ALREADY_SYNCED'
    assert sql(f"SELECT public.marketroute_sync_aws_v0_research_failure_v1('{failure['ids']['work']}', '{failure['fp']}', now());") == 'ALREADY_FAILED'
assert before == sql('SELECT count(*) || \'|\' || sum(amount_usd)::text FROM public.research_budget_events;')
passed('success/failure redelivery uses durable receipts; synchronization and budget settlement are not repeated')

altered = json.loads(json.dumps(success['envelope']))
altered['organisationId'] = str(uuid.uuid4())
rejected(claim(success, envelope=altered), 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_OR_ATTEMPT_MISMATCH')
passed('cross-tenant envelope rejected')
altered = json.loads(json.dumps(success['envelope']))
altered['workUnit']['payload']['researchOrigin'] = 'SYSTEM_RETRY'
rejected(claim(success, envelope=altered), 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_OR_ATTEMPT_MISMATCH')
passed('altered immutable payload rejected')
rejected(claim(success, fingerprint='f' * 64), 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_OR_ATTEMPT_MISMATCH')
passed('wrong envelope fingerprint rejected')

active = fixture('RUNNING', 'SENT', None)
with ThreadPoolExecutor(max_workers=2) as pool:
    outcomes = list(pool.map(lambda worker: sql(claim(active, worker)), ['worker-a', 'worker-b']))
assert sorted(outcomes) == ['BUSY', 'CLAIMED'], outcomes
passed('concurrent first delivery yields exactly one CLAIMED and one BUSY')
assert sql(claim(active)) == 'BUSY'
passed('live execution lease prevents another claim')

pending_sync = fixture('RUNNING', 'SENT', 'SUCCEEDED')
assert sql(claim(pending_sync)) == 'DEDUPLICATED'
passed('persisted result awaiting synchronization does not need provider re-execution')
expired = fixture('RUNNING', 'SENT', None, expired=True)
rejected(claim(expired), 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID')
passed('expired unfinished dispatch rejected')
null_lease = fixture('RUNNING', 'SENT', None)
sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET ownership_expires_at=NULL WHERE work_unit_id='{null_lease['ids']['work']}';")
rejected(claim(null_lease), 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID')
passed('missing ownership deadline fails closed')
prepared = fixture('RUNNING', 'PREPARED', None)
rejected(claim(prepared), 'MARKETROUTE_AWS_V0_RESEARCH_DISPATCH_OWNERSHIP_INVALID')
passed('unconfirmed send cannot start provider execution')

late = fixture()
sql(f"UPDATE public.background_jobs SET attempt_count=2 WHERE id='{late['ids']['job']}';")
rejected(claim(late), 'MARKETROUTE_AWS_V0_RESEARCH_ENVELOPE_OR_ATTEMPT_MISMATCH')
passed('older canonical attempt cannot acknowledge or settle a later attempt')
missing_artifact = fixture()
sql(f"DELETE FROM public.marketroute_aws_v0_company_understanding_artifacts WHERE work_unit_id='{missing_artifact['ids']['work']}';")
rejected(claim(missing_artifact), 'MARKETROUTE_AWS_V0_RESEARCH_TERMINAL_RECEIPT_INVALID')
passed('missing synchronized artifact cannot masquerade as completed receipt')
terminal_expired = fixture(expired=True)
assert sql(claim(terminal_expired)) == 'DEDUPLICATED'
passed('already settled receipt remains replayable after former dispatch deadline')

sql('CREATE ROLE build11_untrusted; GRANT USAGE ON SCHEMA public TO build11_untrusted;')
rejected('SET ROLE build11_untrusted; ' + claim(success), 'permission denied for function')
passed('public caller cannot execute the privileged claim routine')
print(f'{count}/{count} PostgreSQL replay/ownership checks passed. Live AWS gate remains CLOSED.', flush=True)
