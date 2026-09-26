#!/usr/bin/env python3
"""Build 11 operator: inspect first; an explicit matching plan is required to apply.

No AWS calls by default. Fixed account, database, snapshot and migration set.
This never deploys resources, changes IAM, starts research or invokes a model.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from contract import ACCOUNT, REGION, CLUSTER, DATABASE, FORMAT, HASHES, SQL, Package, GateError, canonical, fingerprint, require
from engine import Engine

ROOT=Path(__file__).resolve().parents[1]
SNAPSHOT='marketroute-build11-before-schema-20260926-063505'
SECRET_RE=rf'arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:marketroute/aws-v0/database/admin-[A-Za-z0-9]+'
ROLE_RE=rf'arn:aws:sts::{ACCOUNT}:assumed-role/MarketRouteV0Administrator/[^/]+'
ACTIONS={('sts','get-caller-identity'),('cloudformation','describe-stacks'),
         ('rds','describe-db-cluster-snapshots'),('rds','describe-db-clusters'),
         ('lambda','get-function-configuration'),('rds-data','begin-transaction'),
         ('rds-data','execute-statement'),('rds-data','commit-transaction'),('rds-data','rollback-transaction')}


class Cloud:
    def __init__(self, package, run=subprocess.run, sleep=time.sleep):
        self.package=package; self.run=run; self.sleep=sleep
        self.secret=None; self.operations=[]; self.known=set(); self.begin_unknown=False
        self.started=time.monotonic()

    def call(self, service, action, payload):
        require((service,action) in ACTIONS,'API_ACTION_NOT_ALLOWED')
        cleanup = service=='rds-data' and action=='rollback-transaction'
        require((cleanup and len(self.operations)<520) or (len(self.operations)<500 and time.monotonic()-self.started<1200),'OPERATOR_BOUND_EXCEEDED')
        self.validate(service,action,payload)
        env=dict(os.environ,AWS_PAGER='',AWS_CLI_AUTO_PROMPT='off',AWS_MAX_ATTEMPTS='1',
            AWS_RETRY_MODE='standard',AWS_IGNORE_CONFIGURED_ENDPOINT_URLS='true')
        op={'service':service,'action':action,'status':'STARTED'};self.operations.append(op)
        with tempfile.TemporaryDirectory(prefix='mr-build11-wire-') as directory:
            path=Path(directory)/'request.json'
            fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
            with os.fdopen(fd,'w') as f: json.dump(payload,f)
            command=['aws',service,action,'--cli-input-json','file://'+str(path),'--region',REGION,
                '--endpoint-url',f'https://{service}.{REGION}.amazonaws.com','--output','json','--no-cli-pager',
                '--cli-connect-timeout','5','--cli-read-timeout','55']
            try: response=self.run(command,env=env,text=True,capture_output=True,timeout=65,check=False)
            except (FileNotFoundError,subprocess.TimeoutExpired):
                op.update(status='UNKNOWN',errorCode='CLI_RESPONSE_UNKNOWN');raise GateError('CLI_RESPONSE_UNKNOWN') from None
        if response.returncode:
            match=re.search(r'An error occurred \(([A-Za-z0-9_.-]+)\)',response.stderr)
            code=match.group(1) if match else 'CLI_FAILED'
            op.update(status='ERROR',errorCode=code);raise GateError(code)
        require(len(response.stdout)<1_000_000,'RESPONSE_TOO_LARGE')
        try: value=json.loads(response.stdout)
        except (ValueError,TypeError): raise GateError('RESPONSE_NOT_JSON') from None
        require(isinstance(value,dict),'RESPONSE_NOT_OBJECT');op['status']='RETURNED'
        return value

    def validate(self,s,a,v):
        require(isinstance(v,dict),'REQUEST_INVALID')
        if s=='sts': require(v=={},'IDENTITY_ARGUMENTS_INVALID');return
        if s=='cloudformation': require(v=={'StackName':'MrAwsV0DatabaseStack'},'STACK_TARGET_INVALID');return
        if s=='rds':
            wanted={'DBClusterSnapshotIdentifier':SNAPSHOT} if a=='describe-db-cluster-snapshots' else {'DBClusterIdentifier':'marketroute-aws-v0'}
            require(v==wanted,'RDS_TARGET_INVALID');return
        if s=='lambda': require(v=={'FunctionName':'marketroute-aws-v0-research-worker'},'LAMBDA_TARGET_INVALID');return
        require(v.get('resourceArn')==CLUSTER and self.secret is not None and v.get('secretArn')==self.secret,'DATABASE_TARGET_INVALID')
        fields={'resourceArn','secretArn'}
        if a in ('begin-transaction','execute-statement'):
            fields.add('database');require(v.get('database')==DATABASE,'DATABASE_NAME_INVALID')
        if a!='begin-transaction':
            if a=='execute-statement' and v.get('sql')==SQL['ready'] and 'transactionId' not in v:
                require(not self.known,'READINESS_WITH_ACTIVE_TRANSACTION')
            else:
                fields.add('transactionId');require(v.get('transactionId') in self.known,'TRANSACTION_NOT_OWNED')
        if a=='execute-statement':
            fields|={'sql','parameters','formatRecordsAs'}
            require(v.get('sql') in self.package.allowed_sql and v.get('formatRecordsAs')=='JSON','SQL_NOT_IN_CLOSED_PLAN')
            if v['sql']==SQL['insertReceipt']:
                params=v.get('parameters');require(isinstance(params,list) and len(params)==1,'RECEIPT_PARAMETER_INVALID')
                item=params[0];require(isinstance(item,dict) and set(item)=={'name','value'} and item['name']=='receipt','RECEIPT_PARAMETER_INVALID')
                require(isinstance(item['value'],dict) and set(item['value'])=={'stringValue'} and
                        isinstance(item['value']['stringValue'],str) and len(item['value']['stringValue'])<2000,'RECEIPT_PARAMETER_INVALID')
                try: receipt=json.loads(item['value']['stringValue'])
                except ValueError: raise GateError('RECEIPT_PARAMETER_INVALID') from None
                require(set(receipt)=={'ordinal','filename','file_sha256','plan_sha256','before_sha256','after_sha256','run_id'},'RECEIPT_PARAMETER_INVALID')
                ordinal=receipt['ordinal'];require(type(ordinal) is int and ordinal in range(3,8),'RECEIPT_PARAMETER_INVALID')
                name=self.package.names[ordinal]
                require(receipt['filename']==name and receipt['file_sha256']==HASHES[name] and
                        receipt['plan_sha256']==self.package.plan_sha and
                        receipt['before_sha256']==self.package.hashes[str(ordinal-1)] and
                        receipt['after_sha256']==self.package.hashes[str(ordinal)],'RECEIPT_CONTRACT_MISMATCH')
            else: require(v.get('parameters')==[],'UNEXPECTED_SQL_PARAMETERS')
        require(set(v)==fields,'UNEXPECTED_REQUEST_FIELDS')

    def prerequisites(self):
        identity=self.call('sts','get-caller-identity',{})
        require(identity.get('Account')==ACCOUNT and re.fullmatch(ROLE_RE,identity.get('Arn','')),'WRONG_ACCOUNT_OR_ROLE')
        stacks=self.call('cloudformation','describe-stacks',{'StackName':'MrAwsV0DatabaseStack'}).get('Stacks',[])
        require(len(stacks)==1 and stacks[0].get('StackStatus') in ('CREATE_COMPLETE','UPDATE_COMPLETE'),'DATABASE_STACK_INVALID')
        outputs={r['OutputKey']:r.get('OutputValue') for r in stacks[0].get('Outputs',[])}
        require(outputs.get('ClusterArn')==CLUSTER and outputs.get('DatabaseName')==DATABASE and
                re.fullmatch(SECRET_RE,outputs.get('SecretArn','')),'DATABASE_STACK_TARGET_INVALID')
        self.secret=outputs['SecretArn']
        clusters=self.call('rds','describe-db-clusters',{'DBClusterIdentifier':'marketroute-aws-v0'}).get('DBClusters',[])
        require(len(clusters)==1 and clusters[0].get('DBClusterArn')==CLUSTER and
                clusters[0].get('Engine')=='aurora-postgresql' and str(clusters[0].get('EngineVersion','')).startswith('16.') and
                clusters[0].get('HttpEndpointEnabled') is True,'AURORA_CONFIGURATION_INVALID')
        snapshots=self.call('rds','describe-db-cluster-snapshots',{'DBClusterSnapshotIdentifier':SNAPSHOT}).get('DBClusterSnapshots',[])
        require(len(snapshots)==1 and snapshots[0].get('DBClusterIdentifier')=='marketroute-aws-v0' and
                snapshots[0].get('Status')=='available' and snapshots[0].get('StorageEncrypted') is True,'BACKUP_NOT_AVAILABLE')
        # This rollout must precede worker deployment; a changed topology stops it.
        try: self.call('lambda','get-function-configuration',{'FunctionName':'marketroute-aws-v0-research-worker'})
        except GateError as exc:
            require(str(exc)=='ResourceNotFoundException','WORKER_ABSENCE_UNVERIFIED')
        else: raise GateError('WORKER_ALREADY_DEPLOYED_REVIEW_REQUIRED')
        return {'account':ACCOUNT,'region':REGION,'clusterArn':CLUSTER,'snapshot':SNAPSHOT,
                'snapshotArn':snapshots[0].get('DBClusterSnapshotArn'),'callerRole':'MarketRouteV0Administrator'}

    def base(self): return {'resourceArn':CLUSTER,'secretArn':self.secret,'database':DATABASE}

    def readiness(self):
        for index,delay in enumerate((0,15,30,60)):
            if delay:self.sleep(delay)
            try:
                value=self.call('rds-data','execute-statement',dict(self.base(),sql=SQL['ready'],parameters=[],formatRecordsAs='JSON'))
                require(self.rows(value)==[{'ready':1}],'READINESS_RESPONSE_INVALID');return
            except GateError as exc:
                if str(exc) not in ('DatabaseResumingException','ThrottlingException') or index==3: raise

    def begin(self):
        self.begin_unknown=True
        value=self.call('rds-data','begin-transaction',self.base())
        tx=value.get('transactionId')
        require(isinstance(tx,str) and 0<len(tx)<=192 and tx not in self.known,'BEGIN_RESPONSE_INVALID')
        self.known.add(tx);self.begin_unknown=False;return tx

    @staticmethod
    def rows(value):
        if 'formattedRecords' not in value:
            require(value.get('numberOfRecordsUpdated',0) in (0,1),'ROW_UPDATE_COUNT_UNEXPECTED');return []
        try: rows=json.loads(value['formattedRecords'])
        except (ValueError,TypeError):raise GateError('DATA_API_ROWS_INVALID') from None
        require(isinstance(rows,list) and all(isinstance(r,dict) for r in rows),'DATA_API_ROWS_INVALID')
        return rows

    def execute(self,tx,sql,params):
        return self.rows(self.call('rds-data','execute-statement',dict(self.base(),transactionId=tx,sql=sql,parameters=params,formatRecordsAs='JSON')))

    def end(self,tx,action):
        value=self.call('rds-data',action,{'resourceArn':CLUSTER,'secretArn':self.secret,'transactionId':tx})
        status=value.get('transactionStatus')
        require(isinstance(status,str) and len(status)<=128,'TRANSACTION_END_RESPONSE_UNKNOWN')
        self.known.remove(tx)

    def commit(self,tx):self.end(tx,'commit-transaction')
    def rollback(self,tx):self.end(tx,'rollback-transaction')
    def forget_reconciled(self,tx):self.known.discard(tx)


def validate_approval(plan, package, confirmation, now):
    require(isinstance(plan,dict),'APPROVAL_PLAN_INVALID')
    expected={'format','packagePlanSha256','target','initialTip','initialCatalogSha256','expiresAt','planSha256'}
    require(set(plan)==expected,'APPROVAL_PLAN_INVALID')
    body={k:v for k,v in plan.items() if k!='planSha256'}
    require(plan['planSha256']==fingerprint(body)==confirmation,'APPROVAL_FINGERPRINT_MISMATCH')
    require(plan['format']==FORMAT and plan['packagePlanSha256']==package.plan_sha,'APPROVAL_PACKAGE_MISMATCH')
    require(type(plan['initialTip']) is int and plan['initialTip'] in range(2,8) and
            plan['initialCatalogSha256']==package.hashes[str(plan['initialTip'])],'APPROVAL_SCHEMA_MISMATCH')
    require(type(plan['expiresAt']) in (int,float) and now<=plan['expiresAt']<=now+3600,'APPROVAL_EXPIRED_OR_INVALID')
    target=plan['target'];require(isinstance(target,dict) and target.get('account')==ACCOUNT and
        target.get('region')==REGION and target.get('clusterArn')==CLUSTER and target.get('snapshot')==SNAPSHOT,'APPROVAL_TARGET_MISMATCH')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group()
    mode.add_argument('--inspect',action='store_true',help='Read-only prerequisite/history inspection; generates a one-hour approval plan, not an approval.')
    mode.add_argument('--apply-plan',type=Path,help='Apply only remaining pinned migrations using an inspected plan. Changes the database.')
    parser.add_argument('--confirm-plan-sha256',help='Explicit confirmation of the complete inspected plan fingerprint.')
    parser.add_argument('--out',type=Path,help='New report path. Existing files/symlinks are rejected.')
    args=parser.parse_args()
    if not args.inspect and not args.apply_plan:parser.print_help();return 0
    package=Package(ROOT)
    plan=None
    if args.apply_plan:
        plan=json.loads(args.apply_plan.read_text())
        validate_approval(plan,package,args.confirm_plan_sha256,time.time())
    else:require(args.confirm_plan_sha256 is None,'UNEXPECTED_APPROVAL')
    out=args.out or Path('build11-migration-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json')
    fd=os.open(out,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    report={'format':FORMAT,'collectedAt':datetime.now(timezone.utc).isoformat(),'mode':'APPLY' if plan else 'INSPECT',
            'packagePlanSha256':package.plan_sha,'status':'STARTED','productionActivation':'BLOCKED',
            'liveWorkerProof':'NOT_RUN','paidInferenceCalls':0}
    cloud=Cloud(package);engine=Engine(package,cloud)
    try:
        target=cloud.prerequisites();cloud.readiness()
        state=engine.inspect();report['initialTip']=state['tip'];report['target']=target
        if plan:
            require(plan['target']==target and state['tip']>=plan['initialTip'],'APPROVAL_TARGET_OR_STATE_CHANGED')
            # Recheck approval after readiness, immediately before the write path.
            validate_approval(plan,package,args.confirm_plan_sha256,time.time())
            final=engine.apply_remaining();report['finalTip']=final['tip'];report['status']='MIGRATIONS_COMMITTED_AND_VERIFIED'
        else:
            approval={'format':FORMAT,'packagePlanSha256':package.plan_sha,'target':target,
                      'initialTip':state['tip'],'initialCatalogSha256':state['catalogSha256'],'expiresAt':int(time.time())+3600}
            approval['planSha256']=fingerprint(approval)
            plan_path=out.with_name(out.stem+'-plan.json')
            pfd=os.open(plan_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(pfd,'w') as f:json.dump(approval,f,indent=2,sort_keys=True);f.write('\n');f.flush();os.fsync(f.fileno())
            report.update(status='INSPECTION_COMPLETE_NO_MIGRATIONS_APPLIED',planFile=str(plan_path.resolve()),planSha256=approval['planSha256'],pendingMigrations=list(range(state['tip']+1,8)))
    except BaseException as exc:
        report.update(status='STOPPED',errorCode=str(exc) if isinstance(exc,GateError) else 'LOCAL_OR_TRANSPORT_ERROR')
    finally:
        for tx in list(engine.active):engine.rollback_known(tx)
        report.update(events=engine.events,operations=cloud.operations,unverifiedTransactionCount=len(engine.active),
                      unidentifiedTransactionMayExist=cloud.begin_unknown,catalogDifference=engine.catalog_difference)
        report['receiptSha256']=fingerprint(report)
        with os.fdopen(fd,'w') as f:json.dump(report,f,indent=2,sort_keys=True);f.write('\n');f.flush();os.fsync(f.fileno())
    print(json.dumps({'report':str(out.resolve()),**{k:report[k] for k in ('status','errorCode','initialTip','finalTip','planFile','planSha256','pendingMigrations','productionActivation','unverifiedTransactionCount') if k in report}},indent=2))
    return 2 if report['status']=='STOPPED' else 0


if __name__=='__main__':raise SystemExit(main())
