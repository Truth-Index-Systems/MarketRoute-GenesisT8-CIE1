#!/usr/bin/env python3
"""Actual zero-budget operator and source worker over owned offline PostgreSQL.
AWS control responses and Lambda transport are simulated. No live cloud access.
"""
from pathlib import Path
import base64, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, time
ROOT=Path(__file__).resolve().parents[2]
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
c=load('canary',ROOT/'infrastructure/aws-v0/worker-db-canary/canary.py')
r=load('rehearsal',Path(__file__).with_name('aws-v0-build11-migration-rehearsal.py'))
l=load('ledger',Path(__file__).with_name('aws-v0-build11-migration-ledger.py'))

class Native:
 def __init__(self,lab,f,folder):self.lab=lab;self.f=f;self.folder=folder;self.sessions={};self.n=0;self.invokes=0
 def cli(self,cmd,**kwargs):
  service,action=cmd[1:3]
  if (service,action)==('lambda','invoke'):
   assert '--cli-input-json' not in cmd
   value=lambda flag:cmd[cmd.index(flag)+1]
   payload=value('--payload');assert payload.startswith('fileb://')
   v={'FunctionName':value('--function-name'),'Qualifier':value('--qualifier'),
      'InvocationType':value('--invocation-type'),'LogType':value('--log-type'),
      'Payload':Path(payload[8:]).read_bytes().decode('utf-8')}
   assert v['FunctionName']==c.FUNCTION and v['Qualifier']=='1' and v['InvocationType']=='RequestResponse' and v['LogType']=='Tail'
   outfile=cmd[cmd.index('--payload')+2]
   assert Path(outfile)==self.folder/'handler-response.json'
  else:v=json.loads(Path(cmd[cmd.index('--cli-input-json')+1][7:]).read_text())
  assert kwargs['env']['AWS_MAX_ATTEMPTS']=='1'
  try:
   if service=='sts':value={'Account':c.ACCOUNT,'Arn':f'arn:aws:sts::{c.ACCOUNT}:assumed-role/MarketRouteV0Administrator/offline-canary'}
   elif action=='get-function-configuration':value={'CodeSha256':c.ZIP_HASH,'Version':'1','State':'Active','Role':c.ROLE,'Environment':{'Variables':{
    'MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED':'true','MARKETROUTE_AWS_RDS_CLUSTER_ARN':c.CLUSTER,
    'MARKETROUTE_AWS_RDS_SECRET_ARN':c.SECRET,'MARKETROUTE_AWS_RDS_DATABASE':c.DB,'MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN':c.PROFILE}}}
   elif action=='list-event-source-mappings':value={'EventSourceMappings':[{'EventSourceArn':c.QUEUE,'State':'Disabled'}]}
   elif action=='begin-transaction':
    self.n+=1;tx=f'offline-{self.n}';s=l.Session(self.lab);s.execute('BEGIN;');self.sessions[tx]=s;value={'transactionId':tx}
   elif action=='execute-statement':
    sql=v['sql']
    if 'transactionId' not in v:
     assert sql==c.SQL['ready'];value={'formattedRecords':'[{"ready":1}]'}
    else:
     for p in v['parameters']:
      assert p['name']=='fixture';sql=sql.replace(':fixture',"'"+p['value']['stringValue'].replace("'","''")+"'")
     # Test database has a fixed name and postgres owner; only the returned
     # identity envelope is adapted. SQL itself always executes unmodified.
     s=self.sessions[v['transactionId']]
     if re.search(r'\bINSERT INTO\b',sql,re.I) or sql.startswith('SET '):s.execute(sql+';');rows=[]
     else:
      rows=json.loads(s.execute("SELECT COALESCE(jsonb_agg(to_jsonb(q)),'[]'::jsonb)::text FROM ("+sql+') q;'))
     if v['sql']==c.SQL['guards']:
      assert rows[0]['database']==r.DB and rows[0]['role']=='postgres';rows[0]['database']=c.DB;rows[0]['role']='marketroute_admin'
     value={'formattedRecords':json.dumps(rows)}
   elif action in ('commit-transaction','rollback-transaction'):
    s=self.sessions.pop(v['transactionId']);s.execute('COMMIT;' if action=='commit-transaction' else 'ROLLBACK;');s.close();value={'transactionStatus':'complete'}
   elif action=='invoke':
    self.invokes+=1;assert self.invokes==1
    assert json.loads(v['Payload'])=={'Records':[{'messageId':self.f['messageId'],'body':c.canonical(self.f['envelope'])}]}
    fixturepath=self.folder/'native-input.json';fixturepath.write_text(json.dumps({'fixture':self.f,'container':self.lab.container,'database':r.DB}))
    node=r.run(['node',str(ROOT/'tests/integration/aws-v0-build11-zero-budget-worker.mjs'),str(fixturepath)])
    self.worker=json.loads(node.stdout);Path(outfile).write_text(json.dumps(self.worker['response']))
    value={'StatusCode':200,'ExecutedVersion':'1','LogResult':base64.b64encode(b'offline stub, not Lambda logs').decode()}
   else:raise AssertionError('unexpected command '+action)
   return subprocess.CompletedProcess(cmd,0,json.dumps(value),'')
  except Exception as e:return subprocess.CompletedProcess(cmd,1,'',f'An error occurred (OfflineTestFailure) {e}')
 def close(self):
  for s in self.sessions.values():s.close()
  self.sessions.clear()

def main():
 require=lambda x,m: r.check(x,m)
 out=Path(tempfile.mkdtemp(prefix='build11-zero-budget-proof-'));receipt={'checks':[],'liveAws':False,'awsEnvelopes':'SIMULATED','worker':'ACTUAL_SOURCE_HANDLER_INJECTED_DATABASE_LEDGERS','status':'NOT_RUN'}
 container=None;native=None
 def passed(name):receipt['checks'].append({'name':name,'status':'PASS'});print('PASS',name,flush=True)
 try:
  container=r.run(['docker','run','--detach','--rm','--network','none','--tmpfs','/var/lib/postgresql/data:rw,size=512m','-e','POSTGRES_PASSWORD=test-owned-only','-e','POSTGRES_DB='+r.DB,'postgres:16']).stdout.strip()
  require(re.fullmatch('[a-f0-9]{64}',container),'owned container required')
  meta=json.loads(r.run(['docker','inspect',container]).stdout)[0];require(meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig'].get('PortBindings'),'isolated database required')
  lab=r.Lab(container)
  for _ in range(60):
   ready=lab.sql('SELECT current_database();',ok=False)
   proc=r.run(['docker','exec',container,'cat','/proc/1/comm'],must_succeed=False)
   if proc.stdout.strip()=='postgres' and ready.returncode==0 and ready.stdout.strip()==r.DB:break
   time.sleep(.5)
  else:raise RuntimeError('database startup failed')
  for name,h in r.HASHES.items():
   data=(ROOT/'database/aws'/name).read_bytes();require(r.digest(data)==h,'migration bytes changed');lab.sql(data.decode())
  schema=lab.schema();tables=lab.names()
  receipt['postgresVersion']=lab.value('SHOW server_version;');passed('unchanged baseline and all migrations restored into owned PostgreSQL')
  f=c.fixture();c.validate_fixture(f);folder=out/'run';folder.mkdir();native=Native(lab,f,folder);cloud=c.Cloud(f,folder,run=native.cli,sleep=lambda _:None)
  cloud.prerequisites();passed('actual operator request adapter validates pinned AWS envelope metadata')
  cloud.seed();state=cloud.state();require(state['execution_rows']==0 and state['inference_rows']==0,'unexpected pre-invocation activity');passed('synthetic fixture commits with paused campaign and disabled zero-dollar budget')
  require(lab.schema()==schema,'DDL not allowed');passed('fixture does not change schema, grants, functions or triggers')
  state=cloud.invoke();c.verify_deferred(f,state);passed('actual source handler claims and defers work through real PostgreSQL')
  require(native.worker['providerCalls']==0,'provider reached');passed('paused campaign blocks the prepared provider and model path')
  require(state['execution_attempts']==0 and state['inference_rows']==0 and state['artifact_rows']==0 and state['nonzero_budget_events']==0,'cost or result created');passed('database result proves no inference receipt, semantic artifact or paid attempt')
  try:cloud.invoke()
  except c.Stop:pass
  else:raise AssertionError('duplicate invocation allowed')
  require(native.invokes==1,'duplicate reached Lambda transport');passed('same fixture cannot be invoked a second time by the operator')
  cloud.close_fixture();final=cloud.state();require(final['job_state']=='FAILED' and final['run_state']=='CANCELLED','open fixture');passed('canonical failure/closure routines close only synthetic work; zero-valued release retained')
  require(lab.value('SELECT bool_and(NOT enabled) FROM public.marketroute_aws_v0_inference_scopes;')=='t','model enabled')
  require(lab.value('SELECT bool_and(NOT enabled) FROM public.marketroute_aws_v0_recovery_control;')=='t','recovery enabled');passed('model and recovery switches remain disabled')
  require(lab.value("SELECT count(*) FROM public.marketroute_aws_v0_recovery_receipts WHERE state='RESOLVED';")=='1','fixture recovery not closed');passed('synthetic dispatch is excluded from future recovery polling')
  require(lab.schema()==schema,'schema changed');require(not native.sessions and cloud.tx is None,'sessions open');passed('all operator transactions closed and schema unchanged')
  # Failure before commit: a second fixture collision rolls back inserted parents.
  g=c.fixture();g['ids']['source']=f['ids']['source'];gfolder=out/'collision';gfolder.mkdir()
  n2=Native(lab,g,gfolder);c2=c.Cloud(g,gfolder,run=n2.cli,sleep=lambda _:None);before=lab.rows()
  try:c2.seed()
  except c.Stop:pass
  else:raise AssertionError('collision accepted')
  require(lab.rows()==before and not n2.sessions,'partial fixture survived');passed('setup error rolls back newly inserted fixture parents')
  # Independent post-closure immutable work/evidence trigger checks.
  for table,key in [('research_work_units','work'),('evidence_items','evidence')]:
   q=lab.sql(f"UPDATE public.{table} SET id=id WHERE id='{f['ids'][key]}';",ok=False)
   require(q.returncode!=0,'append-only trigger lost')
  passed('append-only work and evidence protections remain intact')
  kit=out/'kit';kit.mkdir();shutil.copy2(ROOT/'infrastructure/aws-v0/worker-db-canary/canary.py',kit/'canary.py')
  shutil.copy2(ROOT/'infrastructure/aws-v0/worker-db-canary/README.md',kit/'README.md')
  receipt['status']='PASS'
 except BaseException as e:receipt.update(status='FAIL',failure=str(e));raise
 finally:
  if native:native.close()
  if container and re.fullmatch('[a-f0-9]{64}',container):receipt['ownedContainerRemoved']=r.run(['docker','rm','--force',container],must_succeed=False).returncode==0
  receipt['assertionGroups']=len(receipt['checks']);(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
  if receipt['status']=='PASS':
   shutil.copy2(out/'receipt.json',out/'kit/offline-receipt.json')
   (out/'kit/SHA256SUMS').write_text(''.join(r.digest(p.read_bytes())+'  '+p.name+'\n' for p in sorted((out/'kit').iterdir()) if p.is_file()))
  print('Receipt:',out/'receipt.json',flush=True)
if __name__=='__main__':main()
