#!/usr/bin/env python3
"""Run the fixed read-only probe through native PostgreSQL, NOT the AWS endpoint.

Starts only its own network-disabled disposable container. No live mode,
credentials, remote Docker config, database URL, or arbitrary target accepted.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import re
import select
import subprocess
import sys
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
if len(sys.argv)!=1:raise SystemExit('No command-line arguments accepted')
spec=importlib.util.spec_from_file_location('probe_safety',Path(__file__).with_name('aws-v0-build11-transaction-probe-safety.py'))
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
p=s.p
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'HOME':'/tmp','LANG':'C.UTF-8','DOCKER_HOST':'unix:///var/run/docker.sock'}


def run(command,timeout=90):
    value=subprocess.run(command,capture_output=True,text=True,env=ENV,timeout=timeout)
    if value.returncode:raise RuntimeError(value.stderr[-1500:])
    return value.stdout.strip()


class Session:
    def __init__(self,cid):
        self.p=subprocess.Popen(['docker','exec','-i',cid,'psql','-X','-Atq','-v','ON_ERROR_STOP=1',
            '-U',p.DB_ROLE,'-d',p.DATABASE],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=ENV,bufsize=0)
        self.pending=b''
    def sql(self,sql):
        marker=('READONLY_END_'+uuid.uuid4().hex).encode()
        self.p.stdin.write(sql.encode()+b';\n\\echo '+marker+b'\n');self.p.stdin.flush()
        deadline=time.monotonic()+20;lines=[]
        while True:
            while b'\n' in self.pending:
                line,self.pending=self.pending.split(b'\n',1)
                if line==marker:return b'\n'.join(lines).decode()
                lines.append(line)
            remaining=deadline-time.monotonic()
            if remaining<=0 or not select.select([self.p.stdout],[],[],remaining)[0]:raise RuntimeError('LOCAL_RESPONSE_TIMEOUT')
            chunk=os.read(self.p.stdout.fileno(),65536)
            if not chunk:raise RuntimeError(self.p.stderr.read().decode()[-1500:])
            self.pending+=chunk
    def close(self):
        try:
            if not self.p.stdin.closed:self.p.stdin.close()
            self.p.wait(timeout=5)
        except (BrokenPipeError,subprocess.TimeoutExpired):
            self.p.terminate();self.p.wait(timeout=5)
        finally:self.p.stdout.close();self.p.stderr.close()


class NativeWire(s.FakeWire):
    def __init__(self,cid,lose_commit=False,end_style='example'):
        super().__init__();self.cid=cid;self.sessions={};self.lose_commit=lose_commit;self.end_style=end_style
    def __call__(self,service,action,payload):
        p.validate_request(service,action,payload)
        if service!='rds-data':return super().__call__(service,action,payload)
        self.calls.append((service,action,payload))
        if action=='begin-transaction':
            session=Session(self.cid);tx=uuid.uuid4().hex
            self.sessions[tx]=session;session.sql('BEGIN')
            return {'transactionId':tx}
        tx=payload['transactionId']
        if tx not in self.sessions:raise p.ProbeError('TransactionNotFoundException')
        session=self.sessions[tx]
        if action in p.ENDS:
            session.sql('COMMIT' if action=='commit-transaction' else 'ROLLBACK')
            session.close();del self.sessions[tx]
            if action=='commit-transaction' and self.lose_commit:raise p.ProbeError('AWS_RESPONSE_UNKNOWN_TIMEOUT')
            # Successful API envelopes are simulated, independently of p.ENDS.
            if self.end_style=='empty':return {'transactionStatus':''}
            if self.end_style=='other':return {'transactionStatus':'Completed successfully'}
            return {'transactionStatus':{'commit-transaction':'Transaction Committed',
                                         'rollback-transaction':'Rollback Complete'}[action]}
        sql=payload['sql']
        # Test-only conversion of strictly validated parameters for native psql.
        for parameter in payload['parameters']:
            v=parameter['value']
            literal=str(v['longValue']) if 'longValue' in v else "'"+v['stringValue']+"'"
            sql=sql.replace(':'+parameter['name'],literal)
        output=session.sql(sql)
        return s.row(json.loads(output)) if output else {'numberOfRecordsUpdated':0}
    def close(self):
        for session in self.sessions.values():session.close()
        self.sessions.clear()


def schema_hash(cid):
    value=run(['docker','exec',cid,'pg_dump','--schema-only','-U',p.DB_ROLE,'-d',p.DATABASE])
    value='\n'.join(line for line in value.splitlines() if not re.match(r'^\\(?:un)?restrict\b',line))
    return hashlib.sha256(value.encode()).hexdigest()


def main():
    output=Path(tempfile.mkdtemp(prefix='build11-transaction-probe-offline-'))
    receipt={'schemaVersion':1,'status':'FAIL','liveAwsCalls':0,'liveDatabaseMutations':0,
             'transport':'native psql with simulated AWS control/response envelopes',
             'actualDataApi':'NOT_RUN','checks':[],'testedCommit':os.environ.get('GITHUB_SHA'),
             'sourceHead':os.environ.get('SOURCE_HEAD'),'containerRemoved':False}
    cid=None
    try:
        run(['docker','pull','postgres:16'])
        cid=run(['docker','run','-d','--network','none','--label','marketroute-build11-readonly-probe=true',
                 '--tmpfs','/var/lib/postgresql/data:rw','-e','POSTGRES_HOST_AUTH_METHOD=trust',
                 '-e','POSTGRES_USER='+p.DB_ROLE,'-e','POSTGRES_DB='+p.DATABASE,'postgres:16'])
        if not re.fullmatch('[a-f0-9]{64}',cid):raise RuntimeError('OWNED_CONTAINER_INVALID')
        for attempt in range(60):
            try:
                proc=run(['docker','exec',cid,'cat','/proc/1/comm'])
                ok=run(['docker','exec',cid,'psql','-X','-Atq','-U',p.DB_ROLE,'-d',p.DATABASE,'-c','SELECT 1'])
                if proc=='postgres' and ok=='1':break
            except RuntimeError:pass
            time.sleep(0.5)
        else:raise RuntimeError('OWNED_POSTGRES_NOT_READY')
        receipt['serverVersion']=run(['docker','exec',cid,'psql','-X','-Atq','-U',p.DB_ROLE,'-d',p.DATABASE,'-c','SHOW server_version'])
        before=schema_hash(cid)
        for lose_commit,end_style in ((False,'example'),(False,'empty'),(False,'other'),(True,'empty')):
            wire=NativeWire(cid,lose_commit,end_style)
            try:
                result=p.Probe(wire,sleep=lambda _:None).run()
                if not lose_commit:
                    assert result['transportReadOnlyProof']=='PASS',result
                    assert len(result['checks'])==7
                    receipt['checks'].append({'name':'complete fixed probe observes transaction identity, exclusion and rollback/commit release ('+end_style+')','status':'PASS'})
                else:
                    assert result['transportReadOnlyProof']=='BLOCKED',result
                    assert result['errorCode']=='AWS_RESPONSE_UNKNOWN_TIMEOUT'
                    assert result['unverifiedTransactionClosures']==['B']
                    assert sum(a=='commit-transaction' for _,a,_ in wire.calls)==1
                    receipt['checks'].append({'name':'discarded local commit acknowledgement remains unverified; no commit retry','status':'PASS'})
                assert not wire.sessions
                assert schema_hash(cid)==before
                receipt['checks'].append({'name':'owned database schema unchanged; all native sessions closed ('+str(lose_commit)+','+end_style+')','status':'PASS'})
                if not lose_commit:receipt.setdefault('normalProbes',{})[end_style]=result
            finally:wire.close()
        receipt.update(status='PASS',schemaBefore=before,schemaAfter=schema_hash(cid))
    finally:
        if cid:
            run(['docker','rm','-f',cid]);receipt['containerRemoved']=True
        receipt['receiptSha256']=p.fingerprint(receipt)
        (output/'receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
        print('Receipt:',output/'receipt.json')
        print(f"{len(receipt['checks'])} native PostgreSQL assertion groups; status={receipt['status']}; actual Data API NOT_RUN")


if __name__=='__main__':main()
