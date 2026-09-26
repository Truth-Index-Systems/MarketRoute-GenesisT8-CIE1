#!/usr/bin/env python3
"""Fixed read-only Data API transport probe; NOT a migration executor.

No SQL/file/endpoint/DSN input, DDL/DML, business-table query, secret-value read,
Bedrock call, queue action, or permission change. Transient transaction-local
settings and a probe-only advisory lock are used. Explicit opt-in is required.
"""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import secrets
import subprocess
import tempfile
import time
import uuid

ACCOUNT = '801132668416'
REGION = 'eu-west-2'
CLUSTER = f'arn:aws:rds:{REGION}:{ACCOUNT}:cluster:marketroute-aws-v0'
DATABASE = 'marketroute'
DB_ROLE = 'marketroute_admin'
STACK = 'MrAwsV0DatabaseStack'
SECRET_RE = r'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-[A-Za-z0-9]+'
ROLE_RE = r'arn:aws:sts::801132668416:assumed-role/MarketRouteV0Administrator/[^/]+'
LOCK_NAMESPACE = 1297241168  # Probe-only namespace, NOT the migration lock.
SQL = {
    'readOnly': 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED, READ ONLY',
    'timeout': "SET LOCAL statement_timeout = '5s'",
    'state': """SELECT jsonb_build_object(
      'database',current_database(),'role',current_user,'sessionRole',session_user,
      'serverVersion',current_setting('server_version'),
      'backendPid',pg_backend_pid(),'isolation',current_setting('transaction_isolation'),
      'readOnly',current_setting('transaction_read_only'),
      'marker',current_setting('marketroute.build11_transport_probe',true)
    )::text AS result_json""",
    'marker': """SELECT jsonb_build_object('marker',
      set_config('marketroute.build11_transport_probe',:marker,true))::text AS result_json""",
    'lock': """SELECT jsonb_build_object('acquired',
      pg_try_advisory_xact_lock(CAST(:namespace AS integer),CAST(:key AS integer)))::text AS result_json""",
}
ACTIONS = {('sts','get-caller-identity'), ('cloudformation','describe-stacks'),
           ('rds-data','begin-transaction'), ('rds-data','execute-statement'),
           ('rds-data','commit-transaction'), ('rds-data','rollback-transaction')}
ENDS = {'commit-transaction': 'Transaction Committed', 'rollback-transaction': 'Rollback Complete'}


class ProbeError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(ok, code):
    if not ok:
        raise ProbeError(code)


def fingerprint(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def validate_request(service, action, payload):
    """Validate the entire wire request, not only its service/action name."""
    require((service,action) in ACTIONS, 'ACTION_FORBIDDEN')
    require(isinstance(payload,dict), 'PAYLOAD_INVALID')
    if service == 'sts':
        require(payload == {}, 'IDENTITY_ARGUMENTS_FORBIDDEN')
        return
    if service == 'cloudformation':
        require(payload == {'StackName':STACK}, 'STACK_ARGUMENTS_FORBIDDEN')
        return
    require(payload.get('resourceArn') == CLUSTER, 'CLUSTER_FORBIDDEN')
    require(isinstance(payload.get('secretArn'),str) and
            re.fullmatch(SECRET_RE,payload['secretArn']), 'SECRET_REFERENCE_FORBIDDEN')
    fields = {'resourceArn','secretArn'}
    if action in ('begin-transaction','execute-statement'):
        fields.add('database')
        require(payload.get('database') == DATABASE, 'DATABASE_FORBIDDEN')
    if action != 'begin-transaction':
        fields.add('transactionId')
        tx = payload.get('transactionId')
        require(isinstance(tx,str) and 0 < len(tx) <= 192 and
                all(ord(c)>=32 and ord(c)!=127 for c in tx), 'TRANSACTION_REQUIRED')
    if action == 'execute-statement':
        fields |= {'sql','parameters','formatRecordsAs'}
        require(payload.get('sql') in SQL.values(), 'SQL_FORBIDDEN')
        require(payload.get('formatRecordsAs') == 'JSON', 'FORMAT_FORBIDDEN')
        params = payload.get('parameters')
        require(isinstance(params,list), 'PARAMETERS_INVALID')
        if payload['sql'] == SQL['marker']:
            require(len(params)==1 and isinstance(params[0],dict) and set(params[0])=={'name','value'} and
                    params[0]['name']=='marker' and isinstance(params[0]['value'],dict) and
                    set(params[0]['value'])=={'stringValue'} and
                    isinstance(params[0]['value']['stringValue'],str) and
                    re.fullmatch(r'[a-f0-9]{32}',params[0]['value']['stringValue']), 'MARKER_INVALID')
        elif payload['sql'] == SQL['lock']:
            require(len(params)==2, 'LOCK_PARAMETERS_INVALID')
            for item, name in zip(params, ('namespace','key')):
                require(isinstance(item,dict) and set(item)=={'name','value'} and
                        item['name']==name and isinstance(item['value'],dict) and
                        set(item['value'])=={'longValue'} and
                        type(item['value']['longValue']) is int, 'LOCK_PARAMETERS_INVALID')
            require(params[0]['value']['longValue']==LOCK_NAMESPACE and
                    1 <= params[1]['value']['longValue'] <= 2147483647, 'LOCK_SCOPE_FORBIDDEN')
        else:
            require(params==[], 'UNEXPECTED_PARAMETERS')
    require(set(payload)==fields, 'EXTRA_ARGUMENTS_FORBIDDEN')


class AwsCli:
    """Uses only authenticated CLI calls to pinned official HTTPS endpoints."""
    def __call__(self, service, action, payload):
        validate_request(service,action,payload)
        env = dict(os.environ, AWS_PAGER='', AWS_CLI_AUTO_PROMPT='off',
                   AWS_MAX_ATTEMPTS='1', AWS_RETRY_MODE='standard',
                   AWS_IGNORE_CONFIGURED_ENDPOINT_URLS='true')
        endpoint = f'https://{service}.{REGION}.amazonaws.com'
        with tempfile.TemporaryDirectory(prefix='build11-readonly-wire-') as d:
            path = Path(d)/'request.json'
            fd = os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
            with os.fdopen(fd,'w') as f:
                json.dump(payload,f)
            command = ['aws',service,action,'--cli-input-json','file://'+str(path),
                       '--region',REGION,'--endpoint-url',endpoint,'--output','json',
                       '--no-cli-pager','--cli-connect-timeout','5','--cli-read-timeout','20']
            try:
                result = subprocess.run(command,env=env,capture_output=True,text=True,
                                        timeout=30,check=False)
            except FileNotFoundError:
                raise ProbeError('AWS_CLI_NOT_FOUND') from None
            except subprocess.TimeoutExpired:
                raise ProbeError('AWS_RESPONSE_UNKNOWN_TIMEOUT') from None
        if result.returncode:
            match = re.search(r'An error occurred \(([A-Za-z0-9_.-]+)\)',result.stderr)
            raise ProbeError(match.group(1) if match else 'AWS_CLI_FAILED')
        require(len(result.stdout)<=100000,'AWS_RESPONSE_TOO_LARGE')
        try:
            value = json.loads(result.stdout)
        except (ValueError,TypeError):
            raise ProbeError('AWS_RESPONSE_INVALID') from None
        require(isinstance(value,dict),'AWS_RESPONSE_INVALID')
        return value


def parse_row(response):
    require(response.get('numberOfRecordsUpdated',0)==0,'UNEXPECTED_ROW_WRITE')
    try:
        rows=json.loads(response['formattedRecords'])
        require(isinstance(rows,list) and len(rows)==1 and isinstance(rows[0],dict) and
                set(rows[0])=={'result_json'},'ROW_SHAPE_INVALID')
        row=json.loads(rows[0]['result_json'])
        require(isinstance(row,dict),'ROW_SHAPE_INVALID')
        return row
    except (KeyError,ValueError,TypeError):
        raise ProbeError('ROW_SHAPE_INVALID') from None


class Probe:
    def __init__(self, wire, sleep=time.sleep):
        self.wire,self.sleep=wire,sleep
        self.active={}
        self.secret=None
        self.key=secrets.randbelow(2147483647)+1
        self.started=time.monotonic()
        self.report={'schemaVersion':1,'mode':'FIXED_READ_ONLY_TRANSACTION_PROBE',
                     'collectedAt':datetime.now(timezone.utc).isoformat(),
                     'account':ACCOUNT,'region':REGION,'clusterArn':CLUSTER,
                     'transportReadOnlyProof':'NOT_RUN','migrationApproval':'NOT_GRANTED',
                     'liveMigrationExecutor':'NOT_PROVIDED','liveWorkerProof':'NOT_RUN',
                     'productionActivation':'BLOCKED','schemaChanges':0,'businessRowWrites':0,
                     'paidInferenceCalls':0,'transientTransactionStateUsed':True,'unidentifiedTransactionMayExist':False,
                     'checks':[],'operations':[],'cleanup':[],
                     'limits':'Not DDL, migration-history durability, unknown-write-commit, snapshot restore, worker or billing certification.'}

    def call(self, service, action, payload, cleanup=False):
        if not cleanup:
            require(time.monotonic()-self.started<150,'PROBE_DURATION_LIMIT')
            require(len(self.report['operations'])<45,'PROBE_CALL_LIMIT')
        validate_request(service,action,payload)
        # Neither payloads, transaction IDs, SQL results nor arbitrary errors are logged.
        op={'service':service,'action':action,'status':'STARTED'}
        self.report['operations'].append(op)
        try:
            value=self.wire(service,action,payload)
            op['status']='RETURNED'
            return value
        except ProbeError as exc:
            op.update(status='ERROR',errorCode=exc.code)
            raise

    def base(self):
        return {'resourceArn':CLUSTER,'secretArn':self.secret}

    def begin(self, label):
        for attempt in range(3):
            self.report['unidentifiedTransactionMayExist']=True
            try:
                value=self.call('rds-data','begin-transaction',dict(self.base(),database=DATABASE))
                break
            except ProbeError as exc:
                if exc.code in ('DatabaseResumingException','AccessDeniedException','ForbiddenException'):
                    self.report['unidentifiedTransactionMayExist']=False
                # Resume-only retry is allowed only before any probe transaction exists.
                if exc.code!='DatabaseResumingException' or self.active or attempt==2:
                    raise
                self.sleep(10)
        tx=value.get('transactionId')
        require(isinstance(tx,str) and 0<len(tx)<=192,'BEGIN_RESPONSE_INVALID')
        require(tx not in (x['id'] for x in self.active.values()),'TRANSACTION_ID_REUSED')
        self.active[label]={'id':tx,'readOnly':False}
        self.report['unidentifiedTransactionMayExist']=False
        self.execute(label,'readOnly')
        self.execute(label,'timeout')
        state=self.state(label)
        self.active[label]['readOnly']=True
        return state

    def execute(self,label,name,parameters=()):
        require(label in self.active,'TRANSACTION_NOT_OWNED')
        value=self.call('rds-data','execute-statement',dict(self.base(),database=DATABASE,
             transactionId=self.active[label]['id'],sql=SQL[name],parameters=list(parameters),formatRecordsAs='JSON'))
        require(value.get('numberOfRecordsUpdated',0)==0,'UNEXPECTED_ROW_WRITE')
        return value

    def state(self,label):
        state=parse_row(self.execute(label,'state'))
        require(set(state)=={'database','role','sessionRole','serverVersion','backendPid','isolation','readOnly','marker'},'STATE_SHAPE_INVALID')
        require(state['database']==DATABASE and state['role']==DB_ROLE and
                state['sessionRole']==DB_ROLE,'DATABASE_IDENTITY_MISMATCH')
        require(isinstance(state['serverVersion'],str) and state['serverVersion'].startswith('16.'),'DATABASE_VERSION_MISMATCH')
        require(state['isolation']=='read committed' and state['readOnly']=='on','READ_ONLY_NOT_ESTABLISHED')
        require(type(state['backendPid']) is int and state['backendPid']>0,'BACKEND_ID_INVALID')
        return state

    def marker(self,label):
        marker=uuid.uuid4().hex
        row=parse_row(self.execute(label,'marker',[{'name':'marker','value':{'stringValue':marker}}]))
        require(row=={'marker':marker},'LOCAL_MARKER_NOT_SET')
        return marker

    def lock(self,label):
        row=parse_row(self.execute(label,'lock',[{'name':'namespace','value':{'longValue':LOCK_NAMESPACE}},
                                                {'name':'key','value':{'longValue':self.key}}]))
        require(set(row)=={'acquired'} and type(row['acquired']) is bool,'LOCK_RESPONSE_INVALID')
        return row['acquired']

    def end(self,label,action,cleanup=False):
        tx=self.active[label]
        require(action in ENDS,'TRANSACTION_END_FORBIDDEN')
        if action=='commit-transaction':
            require(tx['readOnly'],'UNVERIFIED_TRANSACTION_CANNOT_COMMIT')
        value=self.call('rds-data',action,dict(self.base(),transactionId=tx['id']),cleanup)
        require(value.get('transactionStatus')==ENDS[action],'END_RESPONSE_UNVERIFIED')
        del self.active[label]

    def passed(self,name,**metadata):
        self.report['checks'].append(dict(name=name,status='PASS',**metadata))

    def run(self):
        try:
            identity=self.call('sts','get-caller-identity',{})
            require(identity.get('Account')==ACCOUNT and isinstance(identity.get('Arn'),str) and
                    re.fullmatch(ROLE_RE.strip(),identity['Arn']),'WRONG_ACCOUNT_OR_ROLE')
            self.report['callerArn']=identity['Arn']
            result=self.call('cloudformation','describe-stacks',{'StackName':STACK})
            stacks=result.get('Stacks',[])
            require(len(stacks)==1 and stacks[0].get('StackName')==STACK and
                    stacks[0].get('StackStatus') in ('CREATE_COMPLETE','UPDATE_COMPLETE'),'DATABASE_STACK_UNVERIFIED')
            outputs={x['OutputKey']:x.get('OutputValue') for x in stacks[0].get('Outputs',[])}
            require(outputs.get('ClusterArn')==CLUSTER and outputs.get('DatabaseName')==DATABASE and
                    re.fullmatch(SECRET_RE,outputs.get('SecretArn','')),'DATABASE_TARGET_MISMATCH')
            self.secret=outputs['SecretArn']
            self.passed('expected role session and database target')
            a=self.begin('A')
            require(a['marker'] in (None,''),'PREEXISTING_LOCAL_MARKER')
            marker_a=self.marker('A')
            require(self.lock('A'),'PROBE_LOCK_ALREADY_HELD')
            again=self.state('A')
            require(again['backendPid']==a['backendPid'] and again['marker']==marker_a,'TRANSACTION_CONTINUITY_FAILED')
            self.passed('transaction A retains read-only mode, backend and local marker',backendPid=a['backendPid'],serverVersion=a['serverVersion'])
            b=self.begin('B')
            require(b['backendPid']!=a['backendPid'] and b['marker'] in (None,''),'TRANSACTIONS_NOT_ISOLATED')
            require(not self.lock('B'),'EXCLUSIVE_LOCK_NOT_ENFORCED')
            self.passed('transaction B cannot acquire A probe lock')
            self.end('A','rollback-transaction')
            require(self.lock('B'),'ROLLBACK_LOCK_RELEASE_UNVERIFIED')
            marker_b=self.marker('B')
            again=self.state('B')
            require(again['backendPid']==b['backendPid'] and again['marker']==marker_b,'TRANSACTION_CONTINUITY_FAILED')
            self.passed('rollback releases A lock; B retains its own transaction')
            c=self.begin('C')
            require(c['backendPid']!=b['backendPid'] and c['marker'] in (None,''),'TRANSACTIONS_NOT_ISOLATED')
            require(not self.lock('C'),'EXCLUSIVE_LOCK_NOT_ENFORCED')
            self.passed('fresh transaction has no prior local marker and cannot acquire B lock')
            self.end('B','commit-transaction')  # No writes occurred: only SELECT/SET statements.
            require(self.lock('C'),'COMMIT_LOCK_RELEASE_UNVERIFIED')
            self.passed('read-only commit releases B lock')
            self.end('C','rollback-transaction')
            self.passed('all three owned transactions explicitly ended')
            self.report['transportReadOnlyProof']='PASS'
        except ProbeError as exc:
            self.report.update(transportReadOnlyProof='BLOCKED',errorCode=exc.code)
        except KeyboardInterrupt:
            self.report.update(transportReadOnlyProof='BLOCKED',errorCode='OPERATOR_INTERRUPTED')
        except Exception:
            self.report.update(transportReadOnlyProof='BLOCKED',errorCode='UNEXPECTED_RESPONSE_OR_LOCAL_ERROR')
        finally:
            for label in list(self.active):
                try:
                    self.end(label,'rollback-transaction',cleanup=True)
                    self.report['cleanup'].append({'transaction':label,'status':'ROLLBACK_ACKNOWLEDGED'})
                except ProbeError as exc:
                    # NotFound does not establish the earlier commit outcome.
                    self.report['cleanup'].append({'transaction':label,'status':'UNVERIFIED','errorCode':exc.code})
                except Exception:
                    self.report['cleanup'].append({'transaction':label,'status':'UNVERIFIED','errorCode':'CLEANUP_RESPONSE_UNKNOWN'})
            self.report['unverifiedTransactionClosures']=list(self.active)
            self.report['receiptSha256']=fingerprint(self.report)
        return self.report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-read-only',action='store_true',help='Run fixed transaction checks; Aurora/Data API charges may apply.')
    parser.add_argument('--out',type=Path,help='New receipt path; existing files and symlinks are rejected.')
    args=parser.parse_args()
    if not args.run_read_only:
        parser.print_help()
        return 0
    out=args.out or Path('build11-data-api-transaction-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json')
    fd=os.open(out,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        report=Probe(AwsCli()).run()
        report.pop('receiptSha256',None)
        report['collectorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report['receiptSha256']=fingerprint(report)
        json.dump(report,f,indent=2,sort_keys=True)
        f.write('\n');f.flush();os.fsync(f.fileno())
    print(json.dumps({'report':str(out.resolve()),'transportReadOnlyProof':report['transportReadOnlyProof'],
                      'checksPassed':len(report['checks']),'errorCode':report.get('errorCode'),
                      'unverifiedTransactionClosures':report['unverifiedTransactionClosures'],
                      'migrationApproval':'NOT_GRANTED','schemaChanges':0,'businessRowWrites':0,
                      'paidInferenceCalls':0,'productionActivation':'BLOCKED'},indent=2))
    return 0 if report['transportReadOnlyProof']=='PASS' else 2


if __name__=='__main__':
    raise SystemExit(main())
