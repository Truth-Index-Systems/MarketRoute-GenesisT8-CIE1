#!/usr/bin/env python3
"""Actual executor/CLI adapter against owned offline PostgreSQL; no AWS requests."""
from contextlib import contextmanager
from datetime import datetime, timezone
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
CODE=ROOT/'infrastructure/aws-v0/migration-runner'
sys.path.insert(0,str(CODE))
import contract as c
import engine as e
import run_migrations as op

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
r=load('rehearsal',Path(__file__).with_name('aws-v0-build11-migration-rehearsal.py'))
l=load('ledger',Path(__file__).with_name('aws-v0-build11-migration-ledger.py'))

class Lab(r.Lab):
    def __init__(self,container,database=c.DATABASE):
        super().__init__(container)
        self.database=database
        self.cmd=['docker','exec','-i',container,'psql','-X','-v','ON_ERROR_STOP=1','-U',c.DB_ROLE,'-d',database,'-Atq']
    def schema(self):
        text=r.run(['docker','exec',self.container,'pg_dump','--schema-only','-U',c.DB_ROLE,'-d',self.database]).stdout
        return c.sha('\n'.join(x for x in text.splitlines() if not re.match(r'^\\(?:un)?restrict\b',x)))

class Native:
    """Wire semantics over real sessions; AWS envelopes and metadata simulated."""
    def __init__(self,lab):self.lab=lab;self.sessions={};self.next=0;self.fault=None;self.calls=[]
    def begin(self):
        s=l.Session(self.lab);s.execute('BEGIN;');self.next+=1;tx=f'test-transaction-{self.next}';self.sessions[tx]=s;return tx
    def execute(self,tx,sql,params):
        if self.fault:self.fault('execute',tx,sql)
        text=sql.strip().rstrip(';')
        if params:
            c.require(sql==c.SQL['insertReceipt'],'TEST_PARAMETER_REJECTED')
            text=text.replace(':receipt',"'"+params[0]['value']['stringValue'].replace("'","''")+"'")
        self.calls.append(sql)
        if re.match(r'^(SELECT|WITH)\b',text,re.I):
            result=self.sessions[tx].execute("SELECT COALESCE(jsonb_agg(to_jsonb(q)),'[]'::jsonb)::text FROM ("+text+') q;')
            return json.loads(result)
        self.sessions[tx].execute(text+';');return []
    def end(self,tx,commit):
        if self.fault:self.fault('commit-before' if commit else 'rollback-before',tx,None)
        s=self.sessions.pop(tx);s.execute('COMMIT;' if commit else 'ROLLBACK;');s.close()
        if commit and self.fault:self.fault('commit-after',tx,None)
    def cli(self,command,**kwargs):
        # Called by the real Cloud adapter with its actual private JSON file.
        service,action=command[1:3]
        payload=json.loads(Path(command[command.index('--cli-input-json')+1][7:]).read_text())
        assert kwargs['env']['AWS_MAX_ATTEMPTS']=='1'
        assert command[command.index('--endpoint-url')+1]==f'https://{service}.{c.REGION}.amazonaws.com'
        try:
            if service=='sts':value={'Account':c.ACCOUNT,'Arn':f'arn:aws:sts::{c.ACCOUNT}:assumed-role/MarketRouteV0Administrator/offline-executor-test'}
            elif service=='cloudformation':value={'Stacks':[{'StackName':'MrAwsV0DatabaseStack','StackStatus':'UPDATE_COMPLETE','Outputs':[
                {'OutputKey':k,'OutputValue':v} for k,v in {'ClusterArn':c.CLUSTER,'DatabaseName':c.DATABASE,
                'SecretArn':f'arn:aws:secretsmanager:{c.REGION}:{c.ACCOUNT}:secret:marketroute/aws-v0/database/admin-Synthetic'}.items()]}]}
            elif action=='describe-db-clusters':value={'DBClusters':[{'DBClusterArn':c.CLUSTER,'Engine':'aurora-postgresql','EngineVersion':'16.8','HttpEndpointEnabled':True}]}
            elif action=='describe-db-cluster-snapshots':value={'DBClusterSnapshots':[{'DBClusterIdentifier':'marketroute-aws-v0','Status':'available','StorageEncrypted':True,'DBClusterSnapshotArn':f'arn:aws:rds:{c.REGION}:{c.ACCOUNT}:cluster-snapshot:{op.SNAPSHOT}'}]}
            elif service=='lambda':raise c.GateError('ResourceNotFoundException')
            elif action=='begin-transaction':value={'transactionId':self.begin()}
            elif action=='execute-statement':
                if 'transactionId' not in payload:
                    assert payload['sql']==c.SQL['ready'];value={'formattedRecords':'[{"ready":1}]'}
                else:value={'formattedRecords':json.dumps(self.execute(payload['transactionId'],payload['sql'],payload['parameters']))}
            elif action in ('commit-transaction','rollback-transaction'):
                self.end(payload['transactionId'],action=='commit-transaction');value={'transactionStatus':'Transaction Committed' if action=='commit-transaction' else 'Rolled back'}
            else:raise AssertionError('Unexpected API in offline test')
            return subprocess.CompletedProcess(command,0,json.dumps(value),'')
        except Exception as exc:
            if isinstance(exc,subprocess.TimeoutExpired):raise
            code=str(exc) if isinstance(exc,c.GateError) else 'DatabaseErrorException'
            return subprocess.CompletedProcess(command,1,'',f'An error occurred ({code})')
    def close(self):
        for s in self.sessions.values():s.close()
        self.sessions.clear()


def build_package(out,reference):
    (out/'migration-runner').mkdir();(out/'migrations').mkdir()
    for f in CODE.glob('*.py'):shutil.copy2(f,out/'migration-runner'/f.name)
    for name in c.HASHES:shutil.copy2(ROOT/'database/aws'/name,out/'migrations'/name)
    (out/'reference.json').write_text(json.dumps(reference,indent=2,sort_keys=True)+'\n')
    shutil.copy2(ROOT/'infrastructure/aws-v0/BUILD11-MIGRATION-EXECUTOR.md',out/'BUILD11-MIGRATION-EXECUTOR.md')
    return c.Package(out)


def capture(lab):
    with l.Session(lab) as s:
        data=s.execute("SELECT COALESCE(jsonb_agg(to_jsonb(q)),'[]'::jsonb)::text FROM ("+c.SQL['catalog']+') q;')
        return c.object_map(json.loads(data))


def exercise(lab,out,receipt):
    def passed(name):receipt['checks'].append({'name':name,'status':'PASS'});print('PASS',name,flush=True)
    def reject(fn,expected):
        try:fn()
        except Exception as exc:assert expected in str(exc),(expected,str(exc))
        else:raise AssertionError('Rejection missing: '+expected)
    # The baseline goes ONLY into this newly owned database. Strip psql's client
    # restriction directives for older PG16 clients; the SQL bytes stay pinned.
    for name in list(r.HASHES)[:2]:
        raw=(ROOT/'database/aws'/name).read_bytes();assert c.sha(raw)==r.HASHES[name]
        text=raw.decode();text='\n'.join(x for x in text.splitlines() if not re.match(r'^\\(?:un)?restrict\b',x))
        lab.sql(text)
    ids=r.seed(lab)
    lab.sql(f"UPDATE public.background_jobs SET status='SUCCEEDED' WHERE id='{ids['job']}';")
    baseline_names=lab.names();baseline_rows=lab.rows()
    lab.sql('CREATE DATABASE marketroute_baseline WITH TEMPLATE marketroute;')
    lab.sql('CREATE DATABASE marketroute_reference WITH TEMPLATE marketroute;')
    ref=Lab(lab.container,'marketroute_reference')
    stages={'2':capture(ref)}
    for name in c.HASHES:
        ref.sql((ROOT/'database/aws'/name).read_text());stages[name[:4].lstrip('0')]=capture(ref)
    with l.Session(ref) as s:
        for stmt in c.BOOTSTRAP:s.execute(stmt+';')
        control=c.object_map(json.loads(s.execute("SELECT jsonb_agg(to_jsonb(q))::text FROM ("+c.SQL['historyCatalog']+') q;')))
    reference={'format':c.FORMAT,'migrationSha256':c.HASHES,'stages':stages,'historyContract':control,
               'serverVersion':lab.value('SHOW server_version;')}
    reference['planSha256']=c.fingerprint({'format':c.FORMAT,'files':c.HASHES,'stages':{k:c.fingerprint(v) for k,v in stages.items()},'historyContract':control})
    bundle=out/'kit';bundle.mkdir();package=build_package(bundle,reference)
    native=Native(lab);cloud=op.Cloud(package,run=native.cli,sleep=lambda _:None);engine=e.Engine(package,cloud)
    target=cloud.prerequisites();cloud.readiness();assert engine.inspect()['tip']==2
    passed('actual Cloud CLI request adapter recognises the baseline through native sessions')
    assert not any(k.startswith('namespace:'+c.HISTORY) for k in stages['2'])
    passed('inspection performs no schema/history installation')
    original=copy.deepcopy(package.bodies)
    # The source bodies were segmented outside dollar quotes, not at every semicolon.
    assert sum(len(v) for v in package.bodies.values())==68
    passed('68 exact approved SQL statements segmented and verified before execution')
    reject(lambda:engine.stage(4),'MIGRATION_PREDECESSOR_MISSING')
    passed('out-of-order migration blocked before DDL')
    for ordinal in range(3,8):
        assert not native.sessions
        cloud=op.Cloud(package,run=native.cli,sleep=lambda _:None);cloud.prerequisites()
        engine=e.Engine(package,cloud)
        before=lab.schema();history_before=lab.value(f"SELECT to_regnamespace('{c.HISTORY}') IS NOT NULL;")
        tx=engine.stage(ordinal)
        # The exact executor has written its receipt, but no COMMIT yet.
        engine.close(tx)
        assert lab.schema()==before
        passed(f'{ordinal:04d} explicit rollback reverses schema and receipt together')
        tx=engine.stage(ordinal)
        # A genuinely competing backend cannot inspect a partly applied stage.
        reject(engine.inspect,'MIGRATION_BUSY')
        engine.close(tx)
        passed(f'{ordinal:04d} competing coordinator cannot see an absent uncommitted receipt as permission')
        tx=engine.stage(ordinal)
        # Close actual backend session to model pre-commit connection loss.
        native.sessions.pop(tx).close();engine.active.discard(tx);cloud.known.discard(tx)
        assert lab.schema()==before
        passed(f'{ordinal:04d} disconnect before commit rolls back schema and history')
        assert engine.apply_one(ordinal)=='COMMITTED_AND_VERIFIED'
        assert lab.rows(baseline_names)==baseline_rows
        passed(f'{ordinal:04d} real executor ordered commit preserves original public rows')
        assert engine.apply_one(ordinal)=='ALREADY_APPLIED_VERIFIED'
        passed(f'{ordinal:04d} recorded migration is skipped after latest-state verification')
    assert engine.inspect()['tip']==7 and len(engine.inspect()['history'])==5
    passed('all five receipts exist and the final schema is verified')
    # Preserve current claim function when an older migration is requested.
    claim=lab.value("SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE proname='marketroute_claim_aws_v0_research_execution_v2';")
    assert re.fullmatch('[a-f0-9]{32}',claim)
    engine.apply_one(5)
    assert lab.value("SELECT md5(pg_get_functiondef(oid)) FROM pg_proc WHERE proname='marketroute_claim_aws_v0_research_execution_v2';")==claim
    passed('0005 cannot replace the 0007 claim function through the executor')
    assert cloud.known==set() and engine.active==set() and not native.sessions
    passed('all normal-path transactions are closed')
    # Restore another disposable database from the seeded baseline. Control uses
    # postgres only inside this test-owned network-disabled server.
    control_lab=Lab(lab.container,'postgres')
    control_lab.sql('ALTER DATABASE marketroute RENAME TO marketroute_finished;')
    control_lab.sql('CREATE DATABASE marketroute WITH TEMPLATE marketroute_baseline;')
    fresh=Lab(lab.container)
    native2=Native(fresh); cloud2=op.Cloud(package,run=native2.cli,sleep=lambda _:None)
    cloud2.prerequisites(); engine2=e.Engine(package,cloud2)
    fired=[]
    def lost_after(kind,tx,sql):
        if kind=='commit-after' and not fired:
            fired.append(True);raise c.GateError('CLI_RESPONSE_UNKNOWN')
    native2.fault=lost_after
    reject(lambda:engine2.apply_one(3),'COMMIT_UNCERTAIN_COMMITTED_BATCH_STOPPED')
    assert engine2.inspect()['tip']==3 and len(engine2.inspect()['history'])==1
    assert sum(s in package.bodies[3] for s in native2.calls)==len(package.bodies[3])
    assert not engine2.active and not cloud2.known
    passed('lost post-commit response reconciles durable receipt without replay and stops the batch')
    native2.fault=None
    assert engine2.apply_one(3)=='ALREADY_APPLIED_VERIFIED'
    passed('operator resumption skips the already committed stage')
    def lost_before(kind,tx,sql):
        if kind=='commit-before':raise c.GateError('CLI_RESPONSE_UNKNOWN')
    native2.fault=lost_before
    reject(lambda:engine2.apply_one(4),'COMMIT_UNCERTAIN_UNKNOWN_BATCH_STOPPED')
    assert len(engine2.uncertain)==1
    passed('unknown still-active commit retains uncertainty while its migration lock is held')
    native2.fault=None;native2.close()  # Simulate eventual server rollback after connection closure.
    native3=Native(fresh);cloud3=op.Cloud(package,run=native3.cli,sleep=lambda _:None)
    cloud3.prerequisites();engine3=e.Engine(package,cloud3)
    assert engine3.inspect()['tip']==3
    passed('fresh locked read after rollback identifies the last committed stage')
    wrong=package.expected['4'].copy();package.expected['4']['table:research_work_units']='0'*32
    reject(lambda:engine3.stage(4),'MIGRATION_POSTCONDITION_MISMATCH')
    package.expected['4']=wrong
    assert engine3.inspect()['tip']==3
    passed('incorrect successor catalogue rolls back both DDL and history')
    final=engine3.apply_remaining();assert final['tip']==7
    assert fresh.rows(baseline_names)==baseline_rows
    passed('resume applies only the remaining stages and preserves baseline rows')
    for stmt in [f'UPDATE {c.HISTORY}.history SET ordinal=ordinal',f'DELETE FROM {c.HISTORY}.history',f'TRUNCATE {c.HISTORY}.history']:
        result=fresh.sql(stmt,ok=False);assert result.returncode and 'IMMUTABLE_MIGRATION_HISTORY' in result.stderr
    passed('database rejects history update deletion and truncation')
    fresh.sql(f'ALTER TABLE {c.HISTORY}.history DISABLE TRIGGER history_no_truncate;')
    reject(engine3.inspect,'HISTORY_STRUCTURE_OR_PRIVILEGE_DRIFT')
    fresh.sql(f'ALTER TABLE {c.HISTORY}.history ENABLE TRIGGER history_no_truncate;')
    passed('history protection drift is detected rather than silently repaired')
    fresh.sql('UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true;')
    reject(engine3.inspect,'MODEL_ADMISSION_NOT_DISABLED')
    fresh.sql('UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=false;')
    passed('enabled research admission blocks the executor')
    assert not native3.sessions and not engine3.active
    receipt['baselineRowsPreserved']=fresh.rows(baseline_names)==baseline_rows
    receipt['referencePlanSha256']=package.plan_sha
    receipt['statementCounts']={str(k):len(v) for k,v in package.bodies.items()}
    receipt['limits']='Native PostgreSQL through actual executor and actual CLI request-building code; AWS responses and control-plane metadata simulated. Commit response faults are injected, not real AWS network faults.'
    (bundle/'README.md').write_text('Build 11 migration executor candidate. See BUILD11-MIGRATION-EXECUTOR.md. Default entry makes no AWS calls. Inspect before explicit plan approval. No deployment or research activation.\n')
    for path in sorted(bundle.rglob('*')):
        if path.is_file() and path.name!='SHA256SUMS':
            with (bundle/'SHA256SUMS').open('a') as output:output.write(c.sha(path.read_bytes())+'  '+path.relative_to(bundle).as_posix()+'\n')
    return package


def main():
    assert len(sys.argv)==1,'Test accepts no live connection or execution arguments'
    out=Path(tempfile.mkdtemp(prefix='build11-executor-'));container=None
    receipt={'checks':[],'status':'RUNNING','liveAwsCalls':0,'liveDatabaseMutations':0,'liveMigration':'NOT_RUN','productionActivation':'BLOCKED'}
    try:
        container=r.run(['docker','run','--detach','--network','none','--memory','1g','--tmpfs','/var/lib/postgresql/data:rw,size=768m',
            '-e','POSTGRES_USER='+c.DB_ROLE,'-e','POSTGRES_PASSWORD=offline-test-only','-e','POSTGRES_DB='+c.DATABASE,'postgres:16']).stdout.strip()
        assert re.fullmatch('[a-f0-9]{64}',container)
        meta=json.loads(r.run(['docker','inspect',container]).stdout)[0]
        assert meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig'].get('PortBindings')
        lab=Lab(container)
        for _ in range(60):
            process=r.run(['docker','exec',container,'cat','/proc/1/comm'],must_succeed=False)
            if process.stdout.strip()=='postgres':
                ready=lab.sql('SELECT current_database();',ok=False)
                if ready.returncode==0 and ready.stdout.strip()==c.DATABASE:break
            time.sleep(.5)
        else:raise RuntimeError('Test database startup failed')
        receipt['serverVersion']=lab.value('SHOW server_version;');receipt['imageId']=meta['Image']
        exercise(lab,out,receipt)
        receipt['status']='PASS'
    except BaseException as exc:
        receipt['status']='FAIL';receipt['error']=str(exc);raise
    finally:
        if container:receipt['ownedContainerRemoved']=r.run(['docker','rm','-f',container],must_succeed=False).returncode==0
        receipt['assertionGroups']=len(receipt['checks']);receipt['receiptSha256']=c.fingerprint(receipt)
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
        print('Executor receipt:',out/'receipt.json',flush=True)

if __name__=='__main__':main()
