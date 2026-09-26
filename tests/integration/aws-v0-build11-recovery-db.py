"""Actual recovery SQL, finite redelivery and crash states in disposable PostgreSQL.
No live queue, model request, clock waiting or AWS identity is used.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import uuid

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('packaged_fixture',HERE/'aws-v0-build11-package-fixtures.py')
g=importlib.util.module_from_spec(spec);spec.loader.exec_module(g)
f=g.f; sql,q,js=f.sql,f.literal,f.js
PROFILE='arn:aws:bedrock:eu-west-2:801132668416:application-inference-profile/1t6o6h9xl4qb'
REQUEST='b'*64
sql((f.ROOT/'database/aws/0007_marketroute_aws_build11_recovery.sql').read_text())
count=0

def passed(name):
    global count
    count+=1;print('PASS',name,flush=True)

def recover(item,owner='recovery-test'):
    return json.loads(sql(f"SELECT public.marketroute_prepare_aws_v0_recovery_v1({js(item['envelope'])},{q(item['fp'])},{q(owner)});"))

def confirm(item,permit,message='synthetic-sqs',owner='recovery-test'):
    return f"SELECT public.marketroute_confirm_aws_v0_recovery_send_v1({q(item['ids']['work'])},{permit['canonicalAttempt']},{q(permit['leaseToken'])},{q(owner)},{q(item['fp'])},{q(message)});"

def due(item):
    sql(f"UPDATE public.marketroute_aws_v0_recovery_receipts SET not_before=now()-interval '1 minute',lease_until=now()-interval '1 minute' WHERE work_unit_id={q(item['ids']['work'])};")

def expire(item):
    sql(f"UPDATE public.marketroute_aws_v0_research_executions SET lease_expires_at=now()-interval '70 seconds' WHERE work_unit_id={q(item['ids']['work'])};")

def totals(item):
    return sql(f"SELECT json_build_object('events',(SELECT count(*) FROM public.research_budget_events WHERE work_unit_id={q(item['ids']['work'])}),'cost',(SELECT sum(amount_usd) FROM public.research_budget_events WHERE work_unit_id={q(item['ids']['work'])}),'canonicalAttempt',(SELECT attempt_count FROM public.background_jobs WHERE id={q(item['ids']['job'])}));")

def admitted(item,worker='provider-owner'):
    sql("UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true,next_start_at='-infinity';")
    assert sql(f.claim(item,worker))=='CLAIMED'
    return json.loads(sql(f"SELECT public.marketroute_admit_aws_v0_inference_v1({q(item['ids']['work'])},{q(item['fp'])},{q(worker)},'{REQUEST}',{q(PROFILE)},1000,1400);"))

def measure(grant):
    return sql(f"SELECT public.marketroute_settle_aws_v0_inference_v1({q(grant['admissionId'])},'provider-owner','{REQUEST}','MEASURED',1000,100,'{{}}');")

def valid_result(item):
    e=item['envelope']['workUnit']['payload']['metadata']['awsV0Executor']['input']['evidence'][0]
    return {'contractVersion':'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0','operation':'ai.companyUnderstanding',
      'canonicalPersistenceAllowed':False,'truthAuthorityGranted':False,'deterministicCommercialAuthorityGranted':False,
      'value':{'overview':{'text':e['statement'],'evidenceIds':[e['evidenceId']]},'businessActivities':[],
        'offerings':[],'customerTypes':[],'operatingSignals':[],'uncertainty':'medium','unresolvedQuestions':[]}}

assert sql('SELECT enabled FROM public.marketroute_aws_v0_recovery_control;')=='f'
assert sql('SELECT public.marketroute_list_aws_v0_recovery_candidates_v1(5);')=='[]'
item=g.ready();assert recover(item)['outcome']=='DISABLED'
passed('recovery control defaults off; candidates and mutation remain disabled')
sql('UPDATE public.marketroute_aws_v0_recovery_control SET enabled=true;')

prepared=g.ready();before=totals(prepared)
sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET state='PREPARED',envelope_fingerprint=NULL,sqs_message_id=NULL,ownership_expires_at=NULL WHERE work_unit_id={q(prepared['ids']['work'])};")
permit=recover(prepared);assert permit['outcome']=='REDELIVER'
assert permit['envelope']==prepared['envelope']
f.rejected(f.claim(prepared),'DISPATCH_OWNERSHIP_INVALID')
assert json.loads(sql(confirm(prepared,permit)))['outcome']=='CONFIRMED'
assert json.loads(sql(confirm(prepared,permit)))['outcome']=='ALREADY_CONFIRMED'
assert before==totals(prepared)
passed('ambiguous initial send republishes immutable envelope without a new canonical attempt or budget')
f.rejected(confirm(prepared,permit,message='different-message'),'RECOVERY_CONFIRM_COLLISION')
passed('conflicting send confirmation is rejected')

racing=g.ready()
with ThreadPoolExecutor(max_workers=2) as pool:
    outcomes=list(pool.map(lambda who:recover(racing,who)['outcome'],['coordinator-a','coordinator-b']))
assert sorted(outcomes)==['BUSY','REDELIVER'],outcomes
passed('competing controllers receive one exclusive publication lease')

crash=g.ready();assert sql(f.claim(crash,'crashed-before-admission'))=='CLAIMED';expire(crash)
assert sql(f.claim(crash,'late-message'))=='BUSY'
before=totals(crash);permit=recover(crash)
assert permit['outcome']=='REDELIVER'
assert sql(f"SELECT attempt_count FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={q(crash['ids']['work'])};")=='0'
assert before==totals(crash)
assert sql(f.claim(crash,'recovered-worker'))=='CLAIMED'
passed('crash before admission is recoverable without consuming provider attempt or requeueing canonical job')

live=g.ready();assert sql(f.claim(live,'still-live'))=='CLAIMED'
assert recover(live)['outcome']=='BUSY'
sql(f"UPDATE public.marketroute_aws_v0_research_executions SET lease_expires_at=now()-interval '5 seconds' WHERE work_unit_id={q(live['ids']['work'])};")
assert recover(live)['outcome']=='BUSY'
passed('active invocation and post-lease safety grace cannot be recovered concurrently')

for mode in ('RESERVED','MEASURED'):
    unknown=g.ready();grant=admitted(unknown)
    if mode=='MEASURED':measure(grant)
    expire(unknown);before=totals(unknown)
    result=recover(unknown)
    assert result=={'outcome':'REVIEW_REQUIRED','reason':'PROVIDER_OUTCOME_REQUIRES_REVIEW'},result
    assert sql(f.claim(unknown,'repeat-must-not-invoke'))=='BUSY'
    assert before==totals(unknown)
    assert sql(f"SELECT state FROM public.marketroute_aws_v0_inference_attempts WHERE id={q(grant['admissionId'])};")==mode
    passed(f'{mode} provider receipt without stored result stops for review; cost and canonical reservation retained')

unknown_retry=g.ready();grant=admitted(unknown_retry)
sql(f"SELECT public.marketroute_settle_aws_v0_inference_v1({q(grant['admissionId'])},'provider-owner','{REQUEST}','UNKNOWN',NULL,NULL,'{{}}');")
sql(f"SELECT public.marketroute_fail_aws_v0_research_execution_v1({q(unknown_retry['ids']['work'])},{q(unknown_retry['fp'])},'provider-owner','SYNTHETIC_RETRY',true,'{{}}',now());")
assert sql(f.claim(unknown_retry,'no-blind-retry'))=='BUSY'
assert recover(unknown_retry)['outcome']=='REVIEW_REQUIRED'
passed('UNKNOWN failure cannot automatically start a second paid attempt')

stored=g.ready();grant=admitted(stored);measure(grant)
resultfp=sql(f"SELECT public.marketroute_complete_aws_v0_research_execution_v1({q(stored['ids']['work'])},{q(stored['fp'])},'provider-owner',{js(valid_result(stored))},'{{\"estimatedEquivalentCostUsd\":0.00495}}',now());")
sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET ownership_expires_at=now()-interval '1 minute' WHERE work_unit_id={q(stored['ids']['work'])};")
assert sql(f.claim(stored))=='DEDUPLICATED'
assert recover(stored)['outcome']=='RESOLVED'
before=totals(stored);assert recover(stored)['outcome']=='RESOLVED';assert before==totals(stored)
assert float(sql(f"SELECT sum(amount_usd) FROM public.research_budget_events WHERE work_unit_id={q(stored['ids']['work'])} AND event_type='COMMIT';"))==0.00495
passed('lost completion response or expired dispatch synchronizes stored success once without inference')

failed=g.ready();grant=admitted(failed);measure(grant)
sql(f"SELECT public.marketroute_fail_aws_v0_research_execution_v1({q(failed['ids']['work'])},{q(failed['fp'])},'provider-owner','SYNTHETIC_TERMINAL',false,'{{}}',now());")
sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET ownership_expires_at=now()-interval '1 minute' WHERE work_unit_id={q(failed['ids']['work'])};")
assert sql(f.claim(failed))=='TERMINAL'
assert recover(failed)['outcome']=='RESOLVED'
before=totals(failed);assert recover(failed)['outcome']=='RESOLVED';assert before==totals(failed)
passed('persisted terminal failure settles measured cost once after transport expiry')

old=g.ready();sql(f"UPDATE public.background_jobs SET attempt_count=2 WHERE id={q(old['ids']['job'])};")
before=totals(old);assert recover(old)['outcome']=='REVIEW_REQUIRED';assert before==totals(old)
passed('advanced canonical attempt is never rewound or assigned old result/cost')

limit=g.ready();permit=recover(limit)
sql(f"UPDATE public.marketroute_aws_v0_recovery_receipts SET republish_count=3 WHERE work_unit_id={q(limit['ids']['work'])};")
due(limit);assert recover(limit)['reason']=='RECOVERY_LIMIT_REQUIRES_REVIEW'
passed('automatic recovery publication ceiling is durable and finite')

paused=g.ready();sql(f"UPDATE public.campaigns SET workflow_state='PAUSED' WHERE id={q(paused['ids']['campaign'])};")
assert recover(paused)['outcome']=='WAITING'
assert sql(f"SELECT republish_count FROM public.marketroute_aws_v0_recovery_receipts WHERE work_unit_id={q(paused['ids']['work'])};")=='0'
passed('paused campaign is not republished and consumes no recovery publication')

queue=g.ready();before=totals(queue)
for n in (1,2,3,4,5):
    note=json.loads(sql(f"SELECT public.marketroute_note_aws_v0_transport_failure_v1({js(queue['envelope'])},{q(queue['fp'])},{n},'ADMISSION_DEFERRED');"))
    assert note['acknowledge'] is False
assert sql(f"SELECT highest_receive_count FROM public.marketroute_aws_v0_recovery_receipts WHERE work_unit_id={q(queue['ids']['work'])};")=='5'
due(queue)
candidates=json.loads(sql('SELECT public.marketroute_list_aws_v0_recovery_candidates_v1(20);'))
assert queue['envelope'] in [c['envelope'] for c in candidates]
assert recover(queue)['envelope']==queue['envelope'];assert before==totals(queue)
passed('work remains discoverable and recoverable independently of exhausted/deleted SQS message')

# The legacy scheduler must not create new canonical attempts for AWS work.
run=str(uuid.uuid4());sql(f"INSERT INTO public.scheduler_runs(id,runner_key) VALUES('{run}','GENESIS_RESEARCH_V1'); INSERT INTO public.scheduler_leases(lease_key,owner_run_id,acquired_at,expires_at,heartbeat_at) VALUES('GENESIS_RESEARCH_V1','{run}',now(),now()+interval '5 minutes',now());")
assert sql(f"SELECT public.marketroute_recover_abandoned_research_work_v1('{run}',now());")=='0'
passed('legacy abandoned-job reaper excludes prepared, expired and review-held AWS dispatches')

wrong=json.loads(json.dumps(prepared));wrong['envelope']['organisationId']=str(uuid.uuid4())
f.rejected(f"SELECT public.marketroute_prepare_aws_v0_recovery_v1({js(wrong['envelope'])},{q(wrong['fp'])},'test');",'RECOVERY_ENVELOPE_INVALID')
for query in ('SELECT public.marketroute_list_aws_v0_recovery_candidates_v1(5);',
              f"SELECT public.marketroute_prepare_aws_v0_recovery_v1({js(prepared['envelope'])},{q(prepared['fp'])},'test');"):
    f.rejected('SET ROLE build11_untrusted; '+query,'permission denied for function')
passed('tampered envelopes and untrusted recovery callers are rejected')

# Fresh inputs consumed by the actual-handler recovery tests.
fixtures={name:g.ready() for name in ('completionLost','completionNotStored','sendLost','rate','receiveLimit')}
Path('/tmp/marketroute-build11-recovery-fixtures.json').write_text(json.dumps(fixtures))
print(f'{count}/{count} PostgreSQL recovery assertion groups passed; live controller remains undeployed',flush=True)
