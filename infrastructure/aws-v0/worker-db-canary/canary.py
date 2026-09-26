#!/usr/bin/env python3
"""One zero-budget, paused-campaign worker/database canary. No schema/model writes.

--run-zero-budget creates retained synthetic records and invokes version 1 once.
No production research activation, model API, queue send/receive, or migrations.
"""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import uuid

ACCOUNT='801132668416'; REGION='eu-west-2'; DB='marketroute'
CLUSTER=f'arn:aws:rds:{REGION}:{ACCOUNT}:cluster:marketroute-aws-v0'
SECRET=f'arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:marketroute/aws-v0/database/admin-pXxyUD'
FUNCTION=f'arn:aws:lambda:{REGION}:{ACCOUNT}:function:marketroute-aws-v0-research-worker'
ROLE=f'arn:aws:iam::{ACCOUNT}:role/MrAwsV0ResearchStack-ResearchWorkerRoleD09BA88E-TyWviMnuEcM4'
PROFILE=f'arn:aws:bedrock:{REGION}:{ACCOUNT}:application-inference-profile/1t6o6h9xl4qb'
QUEUE=f'arn:aws:sqs:{REGION}:{ACCOUNT}:marketroute-aws-v0-research-work'
ZIP_HASH='KvZ3Yydi0Uw06k7E/Ze4UNQ7co/5WJPHp4ty6s8e8RM='
SCOPE=f'{ACCOUNT}:{REGION}:EU:anthropic.claude-sonnet-4-5-20250929-v1:0'
LABEL='BUILD11-ZERO-BUDGET-DB-CANARY-1'
IDS=('user','org','seller','company','campaign','plan','run','job','work','source','acquisition','evidence')

class Stop(Exception): pass

def require(condition,code):
    if not condition: raise Stop(code)

def canonical(value): return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)
def sha(value): return hashlib.sha256(value.encode()).hexdigest()

def fixture():
    ids={k:str(uuid.uuid4()) for k in IDS}
    at=datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
    fp=sha(ids['work']); name='[SYNTHETIC] Build 11 database canary '+ids['work']
    evidence={'evidenceId':ids['evidence'],'sourceType':'OTHER',
              'statement':'Fictional software-test company. This record is not a real lead or external evidence.', 'observedAt':at}
    payload={'researchOrigin':'CUSTOMER_CAMPAIGN','metadata':{'syntheticTest':LABEL,
      'awsV0SyncContractVersion':'MR-AWS-V0-COMPANY-UNDERSTANDING-SYNC-1.0.0',
      'awsV0Executor':{'contractVersion':'MR-AWS-V0-COMPANY-UNDERSTANDING-1.0.0',
      'operation':'ai.companyUnderstanding','input':{'companyName':name,'evidence':[evidence]}}}}
    env={'schemaVersion':'1','transport':'AWS_SQS','workUnitId':ids['work'],'enqueuedAt':at,
         'organisationId':ids['org'],'campaignId':ids['campaign'],'companyId':ids['company'],
         'researchOrigin':'CUSTOMER_CAMPAIGN','dedupeKey':fp,'workUnit':{
         'ordinal':1,'gapKey':'synthetic:build11-zero-budget-db-canary','layer':'R4','tier':'ENRICHMENT',
         'action':'SYNTHESIZE_COMPANY_UNDERSTANDING','subjectType':'COMPANY','subjectId':ids['company'],
         'claimKey':None,'reasonCode':'SYNTHETIC_DATABASE_TEST','queryHints':[],'costCeilingUsd':0,
         'dedupeKey':fp,'payload':payload}}
    return {'label':LABEL,'ids':ids,'at':at,'name':name,'dedupe':fp,'payload':payload,'evidence':evidence,
            'envelope':env,'fingerprint':sha('MR-AWS-V0-RESEARCH-ENVELOPE-1.0.0|'+canonical(env)),
            'messageId':'build11-zero-budget-'+ids['work']}

def validate_fixture(f):
    require(isinstance(f,dict) and set(f)=={'label','ids','at','name','dedupe','payload','evidence','envelope','fingerprint','messageId'},'FIXTURE_SHAPE_INVALID')
    require(f['label']==LABEL and set(f['ids'])==set(IDS),'FIXTURE_LABEL_INVALID')
    for v in f['ids'].values(): require(str(uuid.UUID(v))==v and uuid.UUID(v).version==4,'FIXTURE_ID_INVALID')
    require(len(set(f['ids'].values()))==len(IDS),'FIXTURE_ID_COLLISION')
    require(f['dedupe']==sha(f['ids']['work']) and f['fingerprint']==sha('MR-AWS-V0-RESEARCH-ENVELOPE-1.0.0|'+canonical(f['envelope'])),'FIXTURE_HASH_INVALID')
    env=f['envelope']; work=env['workUnit']
    require(env['workUnitId']==f['ids']['work'] and env['organisationId']==f['ids']['org'] and
            env['campaignId']==f['ids']['campaign'] and env['companyId']==f['ids']['company'] and
            work['costCeilingUsd']==0 and work['payload']==f['payload'] and work['dedupeKey']==f['dedupe'], 'FIXTURE_SCOPE_INVALID')
    require(f['name'].startswith('[SYNTHETIC] ') and f['evidence']['sourceType']=='OTHER' and
            f['evidence']['evidenceId']==f['ids']['evidence'] and
            f['payload']['metadata']['syntheticTest']==LABEL,'FIXTURE_PROVENANCE_INVALID')

# Every SQL statement is fixed. The entire fixture is bound as data, never SQL.
P="WITH f AS (SELECT CAST(:fixture AS jsonb) AS v) "
I=lambda k: "CAST(v#>>'{ids,"+k+"}' AS uuid)"
SEED=[
 P+f"INSERT INTO public.marketroute_users(id) SELECT {I('user')} FROM f",
 P+f"INSERT INTO public.organisations(id,name,slug,created_by) SELECT {I('org')},v->>'name',v#>>'{{ids,org}}',{I('user')} FROM f",
 P+f"INSERT INTO public.seller_businesses(id,organisation_id,name,created_by) SELECT {I('seller')},{I('org')},v->>'name',{I('user')} FROM f",
 P+f"INSERT INTO public.companies(id,canonical_name,lifecycle_state) SELECT {I('company')},v->>'name','ARCHIVED' FROM f",
 P+f"INSERT INTO public.campaigns(id,organisation_id,seller_business_id,name,created_by,workflow_state) SELECT {I('campaign')},{I('org')},{I('seller')},v->>'name',{I('user')},'PAUSED' FROM f",
 P+f"INSERT INTO public.scheduler_runs(id,runner_key,metadata_json) SELECT {I('run')},'GENESIS_RESEARCH_V1',jsonb_build_object('syntheticTest',v->>'label') FROM f",
 P+f"INSERT INTO public.research_plan_runs(id,organisation_id,campaign_id,company_id,reference_time,lifecycle_state,authority_envelope_fingerprint,planner_version,semantics_version,gap_set_fingerprint,gap_context_json,work_units_json,budget_policy_snapshot_json,budget_snapshot_json,plan_fingerprint) SELECT {I('plan')},{I('org')},{I('campaign')},{I('company')},now(),'COMMERCIAL_RESEARCH_REQUIRED',v->>'dedupe','MRV2-RESEARCH-1.0.0','MRV2-RESEARCH-1.0.0',v->>'dedupe',jsonb_build_object('syntheticTest',v->>'label'),'[]'::jsonb,'{{}}'::jsonb,'{{}}'::jsonb,v->>'dedupe' FROM f",
 P+f"INSERT INTO public.background_jobs(id,organisation_id,campaign_id,job_type,dedupe_key,status,reserved_by_run_id,reserved_at,attempt_count,max_attempts,payload_json) SELECT {I('job')},{I('org')},{I('campaign')},'GENESIS_RESEARCH_V1',v->>'dedupe','RUNNING',{I('run')},now(),1,1,jsonb_build_object('syntheticTest',v->>'label') FROM f",
 P+f"INSERT INTO public.background_job_attempts(job_id,scheduler_run_id,attempt_number,status) SELECT {I('job')},{I('run')},1,'RUNNING' FROM f",
 P+f"INSERT INTO public.source_records(id,source_kind,source_identity_fingerprint,stable_locator,dependence_family_key,normalisation_version,metadata_json) SELECT {I('source')},'INTERNAL',v->>'dedupe','synthetic:'||(v#>>'{{ids,work}}'),'synthetic:'||(v#>>'{{ids,work}}'),v->>'label',jsonb_build_object('syntheticTest',v->>'label') FROM f",
 P+f"INSERT INTO public.source_acquisitions(id,source_id,acquisition_method,metadata_json) SELECT {I('acquisition')},{I('source')},'MANUAL',jsonb_build_object('syntheticTest',v->>'label') FROM f",
 P+f"INSERT INTO public.evidence_items(id,acquisition_id,tenant_scope_organisation_id,subject_type,subject_id,evidence_kind,excerpt_text,observed_at,extraction_method,evidence_fingerprint,source_identity_fingerprint,dependence_family_key,fingerprint_version) SELECT {I('evidence')},{I('acquisition')},{I('org')},'COMPANY',{I('company')},'OTHER',v#>>'{{evidence,statement}}',CAST(v#>>'{{evidence,observedAt}}' AS timestamptz),'USER_PROVIDED',v->>'dedupe',v->>'dedupe','synthetic:'||(v#>>'{{ids,work}}'),v->>'label' FROM f",
 P+f"INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled) SELECT {I('org')},{I('campaign')},0,0,0,0,0,false FROM f",
 P+f"INSERT INTO public.research_work_units(id,plan_id,organisation_id,campaign_id,company_id,ordinal,gap_key,layer,tier,action,subject_type,subject_id,reason_code,query_hints_json,payload_json,cost_ceiling_usd,dedupe_key,background_job_id) SELECT {I('work')},{I('plan')},{I('org')},{I('campaign')},{I('company')},1,'synthetic:build11-zero-budget-db-canary','R4','ENRICHMENT','SYNTHESIZE_COMPANY_UNDERSTANDING','COMPANY',v#>>'{{ids,company}}','SYNTHETIC_DATABASE_TEST','[]'::jsonb,v->'payload',0,v->>'dedupe',{I('job')} FROM f",
 # This is explicitly a simulated transport fixture. No SQS delivery is claimed.
 P+f"INSERT INTO public.marketroute_aws_v0_research_dispatches(work_unit_id,canonical_attempt_number,scheduler_run_id,state,envelope_json,envelope_fingerprint,sqs_message_id,ownership_expires_at,prepared_at,sent_at,updated_at) SELECT {I('work')},1,{I('run')},'SENT',v->'envelope',v->>'fingerprint','SIMULATED-DIRECT-INVOKE:'||(v#>>'{{ids,work}}'),now()+interval '15 minutes',now(),now(),now() FROM f",
]
SQL={
 'ready':'SELECT 1 AS ready',
 'readonly':'SET TRANSACTION READ ONLY',
 'timeout':"SET LOCAL statement_timeout='10s'",
 'locktimeout':"SET LOCAL lock_timeout='1s'",
 'lock':'SELECT pg_try_advisory_xact_lock(110011, 711) AS acquired',
 'guards':f"""SELECT current_database() AS database,current_user AS role,
   (SELECT count(*)=1 AND bool_and(NOT enabled) FROM public.marketroute_aws_v0_inference_scopes) AS model_off,
   (SELECT count(*)=1 AND bool_and(NOT enabled) FROM public.marketroute_aws_v0_recovery_control) AS recovery_off,
   EXISTS(SELECT 1 FROM public.background_jobs WHERE job_type='GENESIS_RESEARCH_V1' AND status IN('RUNNING','RESERVED')) AS busy,
   EXISTS(SELECT 1 FROM public.scheduler_leases WHERE lease_key='GENESIS_RESEARCH_V1' AND expires_at>now()) AS scheduler_busy""",
 'state': P+f"""SELECT (SELECT count(*) FROM public.research_work_units WHERE id={I('work')}) AS work_rows,
   (SELECT workflow_state FROM public.campaigns WHERE id={I('campaign')}) AS campaign_state,
   (SELECT status FROM public.background_jobs WHERE id={I('job')}) AS job_state,
   (SELECT status FROM public.scheduler_runs WHERE id={I('run')}) AS run_state,
   (SELECT enabled FROM public.research_budget_policies WHERE campaign_id={I('campaign')} AND organisation_id={I('org')}) AS policy_enabled,
   (SELECT count(*) FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={I('work')}) AS execution_rows,
   (SELECT state FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={I('work')}) AS execution_state,
   (SELECT attempt_count FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={I('work')}) AS execution_attempts,
   (SELECT last_error_code FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={I('work')}) AS execution_error,
   (SELECT envelope_fingerprint FROM public.marketroute_aws_v0_research_executions WHERE work_unit_id={I('work')}) AS envelope_fingerprint,
   (SELECT count(*) FROM public.marketroute_aws_v0_inference_attempts WHERE work_unit_id={I('work')}) AS inference_rows,
   (SELECT count(*) FROM public.marketroute_aws_v0_company_understanding_artifacts WHERE work_unit_id={I('work')}) AS artifact_rows,
   (SELECT count(*) FROM public.research_budget_events WHERE work_unit_id={I('work')} AND amount_usd<>0) AS nonzero_budget_events
 FROM f""",
}
CLOSE=[
 P+f"SELECT public.marketroute_fail_research_work_v1({I('work')},{I('run')},'BUILD11_ZERO_BUDGET_CANARY_CLOSED',0,false,now()) IS NULL AS operation_returned FROM f",
 P+f"SELECT public.marketroute_finish_research_scheduler_run_v1({I('run')},'CANCELLED',jsonb_build_object('syntheticTest',v->>'label','closed',true),now()) IS NULL AS operation_returned FROM f",
 P+f"INSERT INTO public.marketroute_aws_v0_recovery_receipts(work_unit_id,canonical_attempt_number,state,reason) SELECT {I('work')},1,'RESOLVED','SYNTHETIC_ZERO_BUDGET_CANARY_CLOSED' FROM f",
]
ALLOWED=set(SQL.values())|set(SEED)|set(CLOSE)

class Cloud:
    def __init__(self,f,folder,run=subprocess.run,sleep=time.sleep):
        self.f=f;self.folder=folder;self.run_process=run;self.sleep=sleep;self.tx=None;self.events=[]
        self.started=time.monotonic();self.calls=0;self.begin_unknown=False
    def journal(self,kind,**data):
        entry={'at':datetime.now(timezone.utc).isoformat(),'event':kind,**data};self.events.append(entry)
        with (self.folder/'journal.jsonl').open('a',encoding='utf8') as out:
            out.write(canonical(entry)+'\n');out.flush();os.fsync(out.fileno())
        print(kind,flush=True)
    def call(self,s,a,v,output=None):
        self.calls+=1
        require(self.calls<=90 and time.monotonic()-self.started<600,'CANARY_OPERATOR_LIMIT')
        allowed={('sts','get-caller-identity'),('lambda','get-function-configuration'),('lambda','list-event-source-mappings'),
                 ('lambda','invoke'),('rds-data','execute-statement'),('rds-data','begin-transaction'),
                 ('rds-data','commit-transaction'),('rds-data','rollback-transaction')}
        require((s,a) in allowed,'API_NOT_ALLOWED')
        if s=='sts':require(v=={},'IDENTITY_ARGUMENTS_INVALID')
        elif s=='lambda':
            if a=='get-function-configuration':require(v=={'FunctionName':FUNCTION,'Qualifier':'1'},'FUNCTION_TARGET_INVALID')
            elif a=='list-event-source-mappings':require(v=={'FunctionName':FUNCTION},'MAPPING_TARGET_INVALID')
            else: require(v=={'FunctionName':FUNCTION,'Qualifier':'1','InvocationType':'RequestResponse','LogType':'Tail',
                             'Payload':canonical({'Records':[{'messageId':self.f['messageId'],'body':canonical(self.f['envelope'])}]})}
                          and output==self.folder/'handler-response.json','INVOKE_PAYLOAD_INVALID')
        else:
            require(v.get('resourceArn')==CLUSTER and v.get('secretArn')==SECRET,'DATABASE_TARGET_INVALID')
            keys={'resourceArn','secretArn'}
            if a in ('begin-transaction','execute-statement'):keys.add('database');require(v.get('database')==DB,'DATABASE_INVALID')
            if a!='begin-transaction':
                if a=='execute-statement' and v.get('sql')==SQL['ready'] and self.tx is None:pass
                else: keys.add('transactionId');require(self.tx is not None and v.get('transactionId')==self.tx,'TRANSACTION_INVALID')
            if a=='execute-statement':
                keys|={'sql','parameters','formatRecordsAs'}
                require(v.get('sql') in ALLOWED and v.get('formatRecordsAs')=='JSON','SQL_NOT_ALLOWED')
                require(v.get('parameters')==([{'name':'fixture','value':{'stringValue':canonical(self.f)}}] if ':fixture' in v['sql'] else []),'PARAMETERS_INVALID')
            require(set(v)==keys,'EXTRA_REQUEST_FIELDS')
        with tempfile.TemporaryDirectory(prefix='mr-db-canary-') as directory:
            path=Path(directory)/'request.json'
            cmd=['aws',s,a]
            if (s,a)==('lambda','invoke'):
                # Streaming-output commands do not support --cli-input-json.
                # Keep the validated event bytes in a private binary payload file;
                # fileb:// is independent of the caller's cli-binary-format setting.
                path.write_bytes(v['Payload'].encode('utf-8'));path.chmod(0o600)
                cmd+=['--function-name',v['FunctionName'],'--qualifier',v['Qualifier'],
                      '--invocation-type',v['InvocationType'],'--log-type',v['LogType'],
                      '--payload','fileb://'+str(path),str(output)]
            else:
                path.write_text(canonical(v));path.chmod(0o600)
                cmd+=['--cli-input-json','file://'+str(path)]
            cmd+=['--region',REGION,'--endpoint-url',f'https://{s}.{REGION}.amazonaws.com',
                  '--output','json','--no-cli-pager','--cli-connect-timeout','5','--cli-read-timeout','270' if a=='invoke' else '25']
            env=dict(os.environ,AWS_PAGER='',AWS_CLI_AUTO_PROMPT='off',AWS_MAX_ATTEMPTS='1',AWS_RETRY_MODE='standard',AWS_IGNORE_CONFIGURED_ENDPOINT_URLS='true')
            try:r=self.run_process(cmd,env=env,capture_output=True,text=True,timeout=280 if a=='invoke' else 35,check=False)
            except (OSError,subprocess.TimeoutExpired):raise Stop('API_RESPONSE_UNKNOWN') from None
        if r.returncode:
            match=re.search(r'An error occurred \(([A-Za-z0-9_.-]+)\)',r.stderr)
            raise Stop(match.group(1) if match else 'CLI_FAILED')
        try:value=json.loads(r.stdout)
        except ValueError:raise Stop('API_RESPONSE_INVALID') from None
        require(isinstance(value,dict),'API_RESPONSE_INVALID');return value
    def base(self):return {'resourceArn':CLUSTER,'secretArn':SECRET,'database':DB}
    def sql(self,text):
        v=dict(self.base(),sql=text,parameters=[{'name':'fixture','value':{'stringValue':canonical(self.f)}}] if ':fixture' in text else [],formatRecordsAs='JSON')
        if self.tx:v['transactionId']=self.tx
        value=self.call('rds-data','execute-statement',v)
        if 'formattedRecords' not in value:return []
        rows=json.loads(value['formattedRecords']);require(isinstance(rows,list),'DB_RESPONSE_INVALID');return rows
    def begin(self,readonly=False):
        require(self.tx is None,'TRANSACTION_ALREADY_ACTIVE')
        self.begin_unknown=True
        value=self.call('rds-data','begin-transaction',self.base());tx=value.get('transactionId')
        require(isinstance(tx,str) and 0<len(tx)<=192,'BEGIN_UNVERIFIED');self.tx=tx;self.begin_unknown=False
        if readonly:self.sql(SQL['readonly'])
        self.sql(SQL['timeout']);self.sql(SQL['locktimeout'])
    def end(self,commit=False):
        a='commit-transaction' if commit else 'rollback-transaction'
        value=self.call('rds-data',a,{'resourceArn':CLUSTER,'secretArn':SECRET,'transactionId':self.tx})
        require(isinstance(value.get('transactionStatus'),str) and len(value['transactionStatus'])<=128,'TRANSACTION_END_UNVERIFIED');self.tx=None
    def guards(self):
        rows=self.sql(SQL['guards']);require(len(rows)==1,'GUARD_SHAPE_INVALID');g=rows[0]
        require(g['database']==DB and g['role']=='marketroute_admin','DB_IDENTITY_INVALID')
        require(g['model_off'] is True and g['recovery_off'] is True,'MODEL_OR_RECOVERY_NOT_DISABLED')
        require(g['busy'] is False and g['scheduler_busy'] is False,'OTHER_RESEARCH_ACTIVE')
    def state(self):
        self.begin(readonly=True)
        try:r=self.sql(SQL['state']);require(len(r)==1,'STATE_INVALID');return r[0]
        finally:
            if self.tx:self.end()
    def prerequisites(self):
        identity=self.call('sts','get-caller-identity',{})
        require(identity.get('Account')==ACCOUNT and re.fullmatch(rf'arn:aws:sts::{ACCOUNT}:assumed-role/MarketRouteV0Administrator/[^/]+',identity.get('Arn','')),'WRONG_IDENTITY')
        config=self.call('lambda','get-function-configuration',{'FunctionName':FUNCTION,'Qualifier':'1'})
        require(config.get('CodeSha256')==ZIP_HASH and config.get('Version')=='1' and config.get('State')=='Active' and config.get('Role')==ROLE,'WORKER_VERSION_MISMATCH')
        env=config.get('Environment',{}).get('Variables',{})
        for k,v in {'MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED':'true','MARKETROUTE_AWS_RDS_CLUSTER_ARN':CLUSTER,'MARKETROUTE_AWS_RDS_SECRET_ARN':SECRET,'MARKETROUTE_AWS_RDS_DATABASE':DB,'MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN':PROFILE}.items():require(env.get(k)==v,'WORKER_CONFIGURATION_MISMATCH')
        result=self.call('lambda','list-event-source-mappings',{'FunctionName':FUNCTION})
        mappings=result.get('EventSourceMappings',[])
        require(not result.get('NextMarker') and len(mappings)==1 and mappings[0].get('EventSourceArn')==QUEUE and mappings[0].get('State')=='Disabled','QUEUE_NOT_DISABLED')
        for n,delay in enumerate((0,15,30,60)):
            if delay:self.sleep(delay)
            try:require(self.sql(SQL['ready'])==[{'ready':1}],'DATABASE_NOT_READY');break
            except Stop as exc:
                if str(exc) not in ('DatabaseResumingException','ThrottlingException') or n==3:raise
        self.journal('TARGET_AND_VERSION_VERIFIED')
    def seed(self):
        self.begin()
        try:
            require(self.sql(SQL['lock'])==[{'acquired':True}],'CANARY_BUSY');self.guards()
            for s in SEED:self.sql(s)
            rows=self.sql(SQL['state']);require(rows[0]['execution_rows']==0 and rows[0]['work_rows']==1 and rows[0]['campaign_state']=='PAUSED' and rows[0]['policy_enabled'] is False,'FIXTURE_POSTCONDITION_FAILED')
            self.journal('FIXTURE_COMMIT_REQUESTED')
            self.end(commit=True);self.journal('FIXTURE_COMMIT_ACKNOWLEDGED')
        except BaseException:
            # A commit with an unknown outcome is not retried. Read-only inspection
            # of this saved fixture is required before further activity.
            if self.tx and not any(x['event']=='FIXTURE_COMMIT_REQUESTED' for x in self.events):self.end()
            raise
    def invoke(self):
        before=self.state();require(before['execution_rows']==0 and before['campaign_state']=='PAUSED' and before['policy_enabled'] is False,'CANARY_ALREADY_EXECUTED_OR_CHANGED')
        require(not any(x['event']=='LAMBDA_INVOCATION_REQUESTED' for x in self.events),'INVOCATION_ALREADY_ATTEMPTED')
        self.journal('LAMBDA_INVOCATION_REQUESTED',version='1',messageId=self.f['messageId'])
        meta=self.call('lambda','invoke',{'FunctionName':FUNCTION,'Qualifier':'1','InvocationType':'RequestResponse','LogType':'Tail',
           'Payload':canonical({'Records':[{'messageId':self.f['messageId'],'body':canonical(self.f['envelope'])}]})},self.folder/'handler-response.json')
        (self.folder/'invoke-metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
        response=json.loads((self.folder/'handler-response.json').read_text())
        require(meta.get('StatusCode')==200 and meta.get('ExecutedVersion')=='1' and 'FunctionError' not in meta and
          response=={'batchItemFailures':[{'itemIdentifier':self.f['messageId']}]},'LAMBDA_RESPONSE_NOT_EXPECTED')
        self.journal('LAMBDA_RESPONSE_RECEIVED')
        state=self.state();verify_deferred(self.f,state)
        self.journal('WORKER_DATABASE_CLAIM_AND_DEFER_OBSERVED',databaseState=state)
        return state
    def close_fixture(self):
        self.begin()
        try:
            state=self.sql(SQL['state'])[0];verify_deferred(self.f,state)
            for s in CLOSE:self.sql(s)
            state=self.sql(SQL['state'])[0]
            require(state['job_state']=='FAILED' and state['run_state']=='CANCELLED' and state['nonzero_budget_events']==0,'FIXTURE_CLOSE_UNVERIFIED')
            self.journal('FIXTURE_CLOSE_COMMIT_REQUESTED');self.end(commit=True)
            self.journal('FIXTURE_CLOSED_NO_RESEARCH_ACTIVATED')
        except BaseException:
            if self.tx and not any(x['event']=='FIXTURE_CLOSE_COMMIT_REQUESTED' for x in self.events):self.end()
            raise

def verify_deferred(f,s):
    require(s.get('execution_rows')==1 and s.get('execution_state')=='FAILED_RETRYABLE' and
            s.get('execution_attempts')==0 and s.get('execution_error')=='MARKETROUTE_AWS_V0_ADMISSION_DEFERRED' and
            s.get('envelope_fingerprint')==f['fingerprint'] and s.get('inference_rows')==0 and s.get('artifact_rows')==0 and
            s.get('nonzero_budget_events')==0 and s.get('campaign_state')=='PAUSED' and s.get('policy_enabled') is False,'DATABASE_CANARY_NOT_PROVEN')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--run-zero-budget',action='store_true',help='Creates retained synthetic DB records and invokes worker version 1 once; no model calls.')
    mode.add_argument('--inspect-existing',type=Path,help='Read state for a saved canary folder; never invokes or repairs.')
    args=parser.parse_args()
    if not args.run_zero_budget and not args.inspect_existing:parser.print_help();return 0
    os.umask(0o077)
    if args.inspect_existing:
        folder=args.inspect_existing.resolve();f=json.loads((folder/'fixture.json').read_text());validate_fixture(f)
        cloud=Cloud(f,folder);cloud.prerequisites();print(json.dumps(cloud.state(),indent=2));return 0
    marker=Path(__file__).resolve().parent/'zero-budget-canary-requested.json'
    fd=os.open(marker,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    folder=Path(tempfile.mkdtemp(prefix='build11-zero-budget-',dir=Path(__file__).resolve().parent))
    with os.fdopen(fd,'w') as out:json.dump({'folder':str(folder)},out);out.flush();os.fsync(out.fileno())
    f=fixture();validate_fixture(f);(folder/'fixture.json').write_text(json.dumps(f,indent=2)+'\n')
    cloud=Cloud(f,folder)
    result={'status':'NOT_RUN','evidenceFolder':str(folder),'bedrockExecutionProven':False,'productionActivation':'BLOCKED',
            'scope':'Worker database claim/defer only; synthetic paused campaign, zero budget; not live SQS/planner/evidence-admission/model proof.'}
    print('Evidence folder: '+str(folder),flush=True)
    try:
        cloud.prerequisites();cloud.seed();state=cloud.invoke();cloud.close_fixture()
        result.update(status='VERSION_1_ZERO_BUDGET_DATABASE_CANARY_PASS',databaseClaimDeferProven=True,observedDatabaseState=state,fixtureClosed=True)
    except BaseException as exc:
        result.update(status='STOPPED',errorCode=str(exc) if isinstance(exc,Stop) else 'LOCAL_OR_RESPONSE_ERROR',fixtureClosed=False)
    result['transactionClosureUnverified']=cloud.tx is not None
    result['unidentifiedTransactionMayExist']=cloud.begin_unknown
    (folder/'summary.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    return 0 if result['status']=='VERSION_1_ZERO_BUDGET_DATABASE_CANARY_PASS' else 2

if __name__=='__main__':raise SystemExit(main())
