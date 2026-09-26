#!/usr/bin/env python3
"""Actual retirement code against owned PostgreSQL; AWS responses simulated."""
from pathlib import Path
import importlib.util, json, re, subprocess, tempfile, time
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('native',Path(__file__).with_name('aws-v0-build11-zero-budget-db.py'))
n=importlib.util.module_from_spec(spec);spec.loader.exec_module(n)
c,r,l=n.c,n.r,n.l
ROOT=Path(__file__).resolve().parents[2]

class Native(n.Native):
 def cli(self,cmd,**kwargs):
  result=super().cli(cmd,**kwargs)
  if result.returncode==0 and cmd[1:3]==['rds-data','execute-statement']:
   v=json.loads(Path(cmd[cmd.index('--cli-input-json')+1][7:]).read_text())
   if v.get('sql')==c.SQL['retireState']:
    value=json.loads(result.stdout);rows=json.loads(value['formattedRecords'])
    assert rows[0]['database']==r.DB and rows[0]['role']=='postgres'
    rows[0]['database']=c.DB;rows[0]['role']='marketroute_admin'
    value['formattedRecords']=json.dumps(rows)
    return subprocess.CompletedProcess(cmd,0,json.dumps(value),'')
  return result

def main():
 require=r.check
 out=Path(tempfile.mkdtemp(prefix='build11-zero-budget-retirement-'))
 receipt={'checks':[],'liveAws':False,'transport':'SIMULATED_AWS_WITH_NATIVE_POSTGRESQL','status':'NOT_RUN'}
 container=None
 def passed(name):receipt['checks'].append({'name':name,'status':'PASS'});print('PASS',name,flush=True)
 try:
  container=r.run(['docker','run','--detach','--rm','--network','none','--tmpfs','/var/lib/postgresql/data:rw,size=512m','-e','POSTGRES_PASSWORD=test-owned-only','-e','POSTGRES_DB='+r.DB,'postgres:16']).stdout.strip()
  require(re.fullmatch('[a-f0-9]{64}',container),'owned container required')
  meta=json.loads(r.run(['docker','inspect',container]).stdout)[0]
  require(meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig'].get('PortBindings'),'isolated database required')
  lab=r.Lab(container)
  for _ in range(60):
   ready=lab.sql('SELECT current_database();',ok=False)
   proc=r.run(['docker','exec',container,'cat','/proc/1/comm'],must_succeed=False)
   if proc.stdout.strip()=='postgres' and ready.returncode==0 and ready.stdout.strip()==r.DB:break
   time.sleep(.5)
  else:raise RuntimeError('database startup failed')
  for name,h in r.HASHES.items():
   data=(ROOT/'database/aws'/name).read_bytes();require(r.digest(data)==h,'migration bytes changed');lab.sql(data.decode())
  schema=lab.schema();receipt['postgresVersion']=lab.value('SHOW server_version;')
  # Recovery of a committed fixture whose client failed before a worker claim.
  import copy
  from unittest.mock import patch
  h=c.fixture();hf=out/'uninvoked';hf.mkdir();hn=Native(lab,h,hf);hc=c.Cloud(h,hf,run=hn.cli,sleep=lambda _:None)
  hc.prerequisites();hc.seed()
  before=lab.rows()
  try:c.retire_uninvoked(hc)
  except c.Stop as e:require(str(e)=='RETIREMENT_SCOPE_OR_OWNERSHIP_INVALID','wrong nonexpired rejection')
  else:raise AssertionError('unexpired dispatch retired')
  require(lab.rows()==before and not hn.sessions,'nonexpired rejection changed rows')
  passed('retirement rejects unexpired dispatch ownership without changing rows')
  # Only the isolated test changes timestamps to exercise an expired fixture.
  lab.sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET ownership_expires_at=now()-interval '1 second' WHERE work_unit_id='{h['ids']['work']}';")
  before=lab.rows()
  with l.Session(lab) as held:
   held.execute("BEGIN; SELECT pg_advisory_xact_lock(hashtextextended('MR-AWS-V0-RECOVERY|"+h['ids']['work']+"',0));")
   try:c.retire_uninvoked(hc)
   except c.Stop as e:require(str(e)=='WORKER_OR_RECOVERY_BUSY','wrong held-lock rejection')
   else:raise AssertionError('retirement bypassed work lock')
   held.execute('ROLLBACK;')
  require(lab.rows()==before and not hn.sessions,'busy rejection changed rows')
  passed('actual worker/recovery advisory lock excludes retirement')
  # Exact fixture provenance must match rather than merely an arbitrary UUID.
  bad=copy.deepcopy(h);bad['name']='[SYNTHETIC] altered name'
  badc=c.Cloud(bad,hf,run=hn.cli,sleep=lambda _:None)
  try:c.retire_uninvoked(badc)
  except c.Stop:pass
  else:raise AssertionError('mismatched fixture retired')
  require(lab.rows()==before,'mismatch changed rows')
  passed('stored synthetic identity mismatch stops before closure')
  # Simulated transport refusal at the second statement, after a real first write.
  def reject_finish(cmd,**kwargs):
   if cmd[1:3]==['rds-data','execute-statement']:
    v=json.loads(Path(cmd[cmd.index('--cli-input-json')+1][7:]).read_text())
    if v.get('sql')==c.RETIRE[1]:return subprocess.CompletedProcess(cmd,1,'','An error occurred (InjectedTransportRefusal)')
   return hn.cli(cmd,**kwargs)
  interrupted=c.Cloud(h,hf,run=reject_finish,sleep=lambda _:None)
  try:c.retire_uninvoked(interrupted)
  except c.Stop:pass
  else:raise AssertionError('refused closure succeeded')
  require(lab.rows()==before and not hn.sessions,'partial closure survived rollback')
  passed('refusal after job closure rolls back job, budget and scheduler changes together')
  # Exercise the public CLI mode with original failure evidence; not a new seed.
  (hf/'fixture.json').write_text(json.dumps(h))
  (hf/'summary.json').write_text(json.dumps({'status':'STOPPED','errorCode':'ParamValidation','fixtureClosed':False}))
  (hf/'journal.jsonl').write_text(''.join(json.dumps({'event':e})+'\n' for e in ('FIXTURE_COMMIT_ACKNOWLEDGED','LAMBDA_INVOCATION_REQUESTED')))
  originals={p.name:p.read_bytes() for p in hf.iterdir() if p.name in ('fixture.json','summary.json','journal.jsonl')}
  actual_cloud=c.Cloud
  with patch.object(c,'Cloud',side_effect=lambda f,folder:actual_cloud(f,folder,run=hn.cli,sleep=lambda _:None)):
   require(c.retire_existing(hf)==0,'retirement mode failed')
   try:c.retire_existing(hf)
   except FileExistsError:pass
   else:raise AssertionError('second retirement attempt accepted')
  passed('saved-fixture CLI retires the exact original attempt and rejects repeat submission')
  require(all((hf/n).read_bytes()==b for n,b in originals.items()),'historical files changed')
  passed('original failed summary, UUID fixture and journal remain byte-identical')
  final=hc.state()
  require(final['job_state']=='FAILED' and final['run_state']=='CANCELLED' and final['execution_rows']==0,'retirement final state wrong')
  require(hn.invokes==0 and final['inference_rows']==0 and final['artifact_rows']==0 and final['nonzero_budget_events']==0,'retirement invoked research')
  passed('retired job and scheduler retain zero worker executions, inference and nonzero budget records')
  after=lab.rows();changed={k for k in before if before[k]!=after[k]}
  require(changed=={'background_jobs','background_job_attempts','scheduler_runs','research_budget_events','marketroute_aws_v0_recovery_receipts'},'unrelated rows changed '+str(changed))
  passed('only five intended fixture lifecycle tables change; all other table digests remain equal')
  require(lab.schema()==schema and not hn.sessions,'schema or sessions changed')
  passed('retirement preserves schema, append-only guards and closes owned transactions')
  # Lost acknowledgement: commit occurs, but caller must STOP without replay.
  x=c.fixture();xf=out/'retirement-unknown';xf.mkdir();xn=Native(lab,x,xf);xc=c.Cloud(x,xf,run=xn.cli,sleep=lambda _:None)
  xc.seed();lab.sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET ownership_expires_at=now()-interval '1 second' WHERE work_unit_id='{x['ids']['work']}';")
  commits=[]
  def discard_commit(cmd,**kwargs):
   result=xn.cli(cmd,**kwargs)
   if cmd[1:3]==['rds-data','commit-transaction']:
    commits.append(1);raise subprocess.TimeoutExpired('aws',35)
   return result
  xc.run_process=discard_commit
  try:c.retire_uninvoked(xc)
  except c.Stop as e:require(str(e)=='API_RESPONSE_UNKNOWN','unknown response hidden')
  else:raise AssertionError('unknown commit treated as success')
  require(len(commits)==1 and xc.tx is not None and not xn.sessions,'commit retried or uncertainty erased')
  reread=c.Cloud(x,xf,run=xn.cli,sleep=lambda _:None).state()
  require(reread['job_state']=='FAILED' and reread['run_state']=='CANCELLED','durable closure missing')
  passed('discarded commit acknowledgement stays uncertain; fresh read observes closure without replay')
  # A previously claimed/deferred fixture must not use the unexecuted branch.
  y=c.fixture();yf=out/'retirement-executed';yf.mkdir();yn=Native(lab,y,yf);yc=c.Cloud(y,yf,run=yn.cli,sleep=lambda _:None)
  yc.seed();yc.invoke();lab.sql(f"UPDATE public.marketroute_aws_v0_research_dispatches SET ownership_expires_at=now()-interval '1 second' WHERE work_unit_id='{y['ids']['work']}';")
  before_y=lab.rows()
  try:c.retire_uninvoked(yc)
  except c.Stop as e:require(str(e)=='RETIREMENT_REQUIRES_UNEXECUTED_ZERO_BUDGET','wrong executed rejection')
  else:raise AssertionError('executed fixture retired as unexecuted')
  require(lab.rows()==before_y,'executed rejection changed rows');yc.close_fixture();yn.close()
  passed('existing worker execution is rejected by retirement without erasing its evidence')

  receipt['status']='PASS'
 except BaseException as e:receipt.update(status='FAIL',failure=str(e));raise
 finally:
  if container and re.fullmatch('[a-f0-9]{64}',container):receipt['ownedContainerRemoved']=r.run(['docker','rm','--force',container],must_succeed=False).returncode==0
  receipt['assertionGroups']=len(receipt['checks']);(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
  print('Receipt:',out/'receipt.json',flush=True)
if __name__=='__main__':main()
