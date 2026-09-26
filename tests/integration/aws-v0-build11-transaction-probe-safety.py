#!/usr/bin/env python3
"""Credential-free safety tests for the fixed read-only collector. No AWS calls."""
from pathlib import Path
import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'infrastructure/aws-v0/scripts/build11-data-api-transaction-probe.py'
spec=importlib.util.spec_from_file_location('transaction_probe',SCRIPT)
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
SECRET=f'arn:aws:secretsmanager:{p.REGION}:{p.ACCOUNT}:secret:marketroute/aws-v0/database/admin-SyntheticTest'
BASE={'resourceArn':p.CLUSTER,'secretArn':SECRET}


def row(value):
    return {'numberOfRecordsUpdated':0,'formattedRecords':json.dumps([{'result_json':json.dumps(value)}])}


class FakeWire:
    """Only simulates API responses; not a database or endpoint certificate."""
    def __init__(self):
        self.calls=[];self.active={};self.counter=0;self.lock_owner=None
        self.override=None
    def __call__(self,s,a,v):
        self.calls.append((s,a,copy.deepcopy(v)))
        if self.override:
            result=self.override(s,a,v)
            if result is not None:return result
        if s=='sts':return {'Account':p.ACCOUNT,'Arn':f'arn:aws:sts::{p.ACCOUNT}:assumed-role/MarketRouteV0Administrator/probe-test'}
        if s=='cloudformation':return {'Stacks':[{'StackName':p.STACK,'StackStatus':'UPDATE_COMPLETE','Outputs':[
            {'OutputKey':key,'OutputValue':value} for key,value in
            {'ClusterArn':p.CLUSTER,'SecretArn':SECRET,'DatabaseName':p.DATABASE}.items()]}]}
        if a=='begin-transaction':
            self.counter+=1;tx=f'SENSITIVE-TX-ID-{self.counter}'
            self.active[tx]={'database':p.DATABASE,'role':p.DB_ROLE,'sessionRole':p.DB_ROLE,
                'serverVersion':'16.8','backendPid':self.counter+100,'isolation':'read committed','readOnly':'off','marker':None}
            return {'transactionId':tx}
        tx=v['transactionId']
        if tx not in self.active:raise p.ProbeError('TransactionNotFoundException')
        state=self.active[tx]
        if a in p.ENDS:
            if self.lock_owner==tx:self.lock_owner=None
            del self.active[tx]
            # Independent API fixtures: do not derive a simulated response from
            # the production validator's own expected value.
            return {'transactionStatus':{'commit-transaction':'Transaction Committed',
                                         'rollback-transaction':'Rollback Complete'}[a]}
        sql=v['sql']
        if sql==p.SQL['readOnly']:state['readOnly']='on';return {}
        if sql==p.SQL['timeout']:return {}
        if sql==p.SQL['state']:return row(copy.deepcopy(state))
        if sql==p.SQL['marker']:
            state['marker']=v['parameters'][0]['value']['stringValue'];return row({'marker':state['marker']})
        if sql==p.SQL['lock']:
            result=self.lock_owner in (None,tx)
            if result:self.lock_owner=tx
            return row({'acquired':result})
        raise AssertionError('unexpected fake SQL')


class Safety(unittest.TestCase):
    def run_probe(self,wire=None):
        wire=wire or FakeWire()
        report=p.Probe(wire,sleep=lambda _:None).run()
        return report,wire
    def execution(self,name='state'):
        return dict(BASE,database=p.DATABASE,transactionId='owned-test-tx',sql=p.SQL[name],parameters=[],formatRecordsAs='JSON')
    def test_success_and_retained_gates(self):
        r,w=self.run_probe();self.assertEqual(r['transportReadOnlyProof'],'PASS');self.assertEqual(len(r['checks']),7)
        self.assertEqual(r['productionActivation'],'BLOCKED');self.assertEqual(r['migrationApproval'],'NOT_GRANTED')
        self.assertFalse(w.active);self.assertFalse(r['unverifiedTransactionClosures'])
    def test_no_tokens_or_payloads_in_receipt(self):
        r,w=self.run_probe();text=json.dumps(r)
        for tx in ('SENSITIVE-TX-ID-1','SENSITIVE-TX-ID-2','SENSITIVE-TX-ID-3'):self.assertNotIn(tx,text)
        self.assertNotIn(SECRET,text);self.assertNotIn('set_config',text)
    def test_no_autocommit_sql(self):
        r,w=self.run_probe()
        for s,a,v in w.calls:
            if a=='execute-statement':self.assertTrue(v['transactionId']);self.assertIn(v['sql'],p.SQL.values())
    def test_mutating_apis_denied(self):
        for s,a in [('bedrock-runtime','invoke-model'),('rds-data','batch-execute-statement'),('iam','put-role-policy'),('sqs','send-message')]:
            with self.subTest(a=a),self.assertRaises(p.ProbeError):p.validate_request(s,a,{})
    def test_arbitrary_sql_denied(self):
        for sql in ['SELECT 1','CREATE TABLE x(id int)','DELETE FROM companies','SELECT 1; SELECT 2','SET TRANSACTION READ WRITE']:
            with self.subTest(sql=sql),self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',dict(self.execution(),sql=sql))
    def test_absent_transaction_denied(self):
        v=self.execution();del v['transactionId']
        with self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',v)
    def test_wrong_targets_denied(self):
        for k,value in [('resourceArn',p.CLUSTER+'-other'),('database','postgres'),('secretArn','arn:wrong')]:
            with self.subTest(k=k),self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',dict(self.execution(),**{k:value}))
    def test_extra_wire_options_denied(self):
        for k,v in [('continueAfterTimeout',True),('schema','public'),('unknown',1)]:
            with self.subTest(k=k),self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',dict(self.execution(),**{k:v}))
    def test_marker_injection_denied(self):
        v=self.execution('marker');v['parameters']=[{'name':'marker','value':{'stringValue':"'; DROP SCHEMA public;--"}}]
        with self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',v)
    def test_lock_namespace_and_types_denied(self):
        for n,key in [(110011,7),(p.LOCK_NAMESPACE,True),(p.LOCK_NAMESPACE,0),(p.LOCK_NAMESPACE,2147483648)]:
            v=self.execution('lock');v['parameters']=[{'name':'namespace','value':{'longValue':n}},{'name':'key','value':{'longValue':key}}]
            with self.subTest(n=n,key=key),self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',v)
    def test_read_only_without_parameters(self):
        v=self.execution();v['parameters']=[{'name':'surprise','value':{'longValue':1}}]
        with self.assertRaises(p.ProbeError):p.validate_request('rds-data','execute-statement',v)
    def test_wrong_aws_identity_stops_first(self):
        for arn,account in [(f'arn:aws:iam::{p.ACCOUNT}:root',p.ACCOUNT),('arn:aws:sts::000000000000:assumed-role/Other/x','000000000000'),(f'arn:aws:sts::{p.ACCOUNT}:assumed-role/Other/x',p.ACCOUNT)]:
            w=FakeWire();w.override=lambda s,a,v:{'Account':account,'Arn':arn} if s=='sts' else None
            r,_=self.run_probe(w);self.assertEqual(len(w.calls),1);self.assertEqual(r['errorCode'],'WRONG_ACCOUNT_OR_ROLE')
    def test_stack_mismatch_prevents_database_calls(self):
        w=FakeWire();w.override=lambda s,a,v:{'Stacks':[]} if s=='cloudformation' else None
        r,_=self.run_probe(w);self.assertEqual(len(w.calls),2);self.assertEqual(r['errorCode'],'DATABASE_STACK_UNVERIFIED')
    def test_resume_only_retry_before_transaction(self):
        w=FakeWire();attempts=[]
        def override(s,a,v):
            if a=='begin-transaction':
                attempts.append(a)
                if len(attempts)<3:raise p.ProbeError('DatabaseResumingException')
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['transportReadOnlyProof'],'PASS');self.assertEqual(len(attempts),5)
    def test_resume_retry_is_bounded(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='begin-transaction':raise p.ProbeError('DatabaseResumingException')
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(sum(a=='begin-transaction' for _,a,_ in w.calls),3);self.assertEqual(r['transportReadOnlyProof'],'BLOCKED')
    def test_unknown_begin_does_not_retry(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='begin-transaction':raise p.ProbeError('AWS_RESPONSE_UNKNOWN_TIMEOUT')
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(sum(a=='begin-transaction' for _,a,_ in w.calls),1);self.assertEqual(r['transportReadOnlyProof'],'BLOCKED')
    def test_denied_mode_rolls_back(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='execute-statement' and v['sql']==p.SQL['readOnly']:raise p.ProbeError('AccessDeniedException')
        w.override=override;r,_=self.run_probe(w)
        self.assertFalse(w.active);self.assertEqual(r['cleanup'][0]['status'],'ROLLBACK_ACKNOWLEDGED')
    def test_wrong_database_identity_rolls_back(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='execute-statement' and v['sql']==p.SQL['state']:
                x=copy.deepcopy(w.active[v['transactionId']]);x['role']='postgres';return row(x)
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['errorCode'],'DATABASE_IDENTITY_MISMATCH');self.assertFalse(w.active)
    def test_read_only_mode_must_be_observed(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='execute-statement' and v['sql']==p.SQL['state']:
                x=copy.deepcopy(w.active[v['transactionId']]);x['readOnly']='off';return row(x)
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['errorCode'],'READ_ONLY_NOT_ESTABLISHED');self.assertFalse(w.active)
    def test_backend_switch_detected(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='execute-statement' and v['sql']==p.SQL['state'] and w.active[v['transactionId']]['marker']:
                x=copy.deepcopy(w.active[v['transactionId']]);x['backendPid']+=1000;return row(x)
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['errorCode'],'TRANSACTION_CONTINUITY_FAILED');self.assertFalse(w.active)
    def test_lock_exclusivity_required(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='execute-statement' and v['sql']==p.SQL['lock'] and len(w.active)==2:return row({'acquired':True})
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['errorCode'],'EXCLUSIVE_LOCK_NOT_ENFORCED');self.assertFalse(w.active)
    def test_unknown_commit_stops_without_retry(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='commit-transaction':raise p.ProbeError('AWS_RESPONSE_UNKNOWN_TIMEOUT')
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(sum(a=='commit-transaction' for _,a,_ in w.calls),1)
        self.assertEqual(r['transportReadOnlyProof'],'BLOCKED');self.assertFalse(w.active)
    def test_committed_but_lost_response_remains_unverified(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='commit-transaction':
                del w.active[v['transactionId']];w.lock_owner=None
                raise p.ProbeError('AWS_RESPONSE_UNKNOWN_TIMEOUT')
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['transportReadOnlyProof'],'BLOCKED');self.assertIn('B',r['unverifiedTransactionClosures'])
        self.assertEqual(r['cleanup'][0]['status'],'UNVERIFIED')
    def test_missing_end_status_not_success(self):
        w=FakeWire();w.override=lambda s,a,v:{} if a=='commit-transaction' else None
        r,_=self.run_probe(w);self.assertEqual(r['errorCode'],'END_RESPONSE_UNVERIFIED');self.assertFalse(w.active)
    def test_empty_end_status_is_valid_service_shape(self):
        class EmptyStatusWire(FakeWire):
            def __call__(self,service,action,payload):
                value=super().__call__(service,action,payload)
                return {'transactionStatus':''} if action in p.ENDS else value
        r,w=self.run_probe(EmptyStatusWire())
        self.assertEqual(r['transportReadOnlyProof'],'PASS');self.assertEqual(len(r['checks']),7)
        self.assertFalse(w.active);self.assertEqual(len(r['transactionEndResponses']),3)
        self.assertTrue(all(d['statusClass']=='EMPTY_STRING' for d in r['transactionEndResponses']))
        self.assertTrue(all(d['acknowledgement']=='API_SUCCESS_RESPONSE' for d in r['transactionEndResponses']))
    def test_other_bounded_end_text_is_not_an_enum_and_is_not_logged(self):
        for text in ['Transaction rolled back','success','X'*128,'SENSITIVE-TX-ID-IN-STATUS']:
            with self.subTest(length=len(text)):
                class TextWire(FakeWire):
                    def __call__(self,service,action,payload):
                        value=super().__call__(service,action,payload)
                        return {'transactionStatus':text} if action in p.ENDS else value
                r,w=self.run_probe(TextWire());self.assertEqual(r['transportReadOnlyProof'],'PASS')
                self.assertTrue(all(d['statusClass']=='OTHER_STRING' for d in r['transactionEndResponses']))
                self.assertNotIn(text,json.dumps(r));self.assertFalse(w.active)
    def test_invalid_end_shapes_remain_blocked(self):
        for value in [None,False,1,[],{},'X'*129]:
            with self.subTest(value=value):
                w=FakeWire();w.override=lambda s,a,v:{'transactionStatus':value} if a=='commit-transaction' else None
                r,_=self.run_probe(w);self.assertEqual(r['errorCode'],'END_RESPONSE_UNVERIFIED')
                d=next(d for d in r['transactionEndResponses'] if d['action']=='commit-transaction')
                self.assertFalse(d['statusShapeValid']);self.assertEqual(d['acknowledgement'],'UNVERIFIED')
    def test_empty_rollback_response_does_not_bypass_lock_release(self):
        w=FakeWire()
        w.override=lambda s,a,v:{'transactionStatus':''} if a=='rollback-transaction' else None
        r,_=self.run_probe(w)
        self.assertEqual(r['transportReadOnlyProof'],'BLOCKED')
        self.assertEqual(r['errorCode'],'ROLLBACK_LOCK_RELEASE_UNVERIFIED')
    def test_empty_commit_response_does_not_bypass_lock_release(self):
        w=FakeWire()
        w.override=lambda s,a,v:{'transactionStatus':''} if a=='commit-transaction' else None
        r,_=self.run_probe(w)
        self.assertEqual(r['transportReadOnlyProof'],'BLOCKED')
        self.assertEqual(r['errorCode'],'COMMIT_LOCK_RELEASE_UNVERIFIED')
    def test_cli_failure_with_success_looking_stdout_is_rejected(self):
        result=subprocess.CompletedProcess([],1,'{"transactionStatus":"Rollback Complete"}',
            'An error occurred (ServiceUnavailableError) SECRET-DO-NOT-LOG')
        with patch.object(p.subprocess,'run',return_value=result),self.assertRaises(p.ProbeError) as c:
            p.AwsCli()('rds-data','rollback-transaction',dict(BASE,transactionId='owned-test-tx'))
        self.assertEqual(c.exception.code,'ServiceUnavailableError')
    def test_missing_status_is_recorded_not_promoted(self):
        w=FakeWire();w.override=lambda s,a,v:{} if a=='commit-transaction' else None
        r,_=self.run_probe(w)
        d=next(d for d in r['transactionEndResponses'] if d['action']=='commit-transaction')
        self.assertFalse(d['statusFieldPresent']);self.assertFalse(d['statusShapeValid'])
        self.assertEqual(r['transportReadOnlyProof'],'BLOCKED')
    def test_cleanup_accepts_valid_empty_ack_without_enabling_proof(self):
        class CleanupWire(FakeWire):
            def __call__(self,service,action,payload):
                if action=='execute-statement' and payload['sql']==p.SQL['marker']:
                    raise p.ProbeError('DatabaseErrorException')
                value=super().__call__(service,action,payload)
                return {'transactionStatus':''} if action in p.ENDS else value
        r,w=self.run_probe(CleanupWire())
        self.assertEqual(r['transportReadOnlyProof'],'BLOCKED');self.assertEqual(r['errorCode'],'DatabaseErrorException')
        self.assertEqual(r['cleanup'],[{'transaction':'A','status':'ROLLBACK_ACKNOWLEDGED'}])
        self.assertFalse(r['unverifiedTransactionClosures']);self.assertFalse(w.active)
        self.assertTrue(r['transactionEndResponses'][0]['cleanup'])
    def test_cleanup_failure_preserved(self):
        w=FakeWire()
        def override(s,a,v):
            if a=='execute-statement' and v['sql']==p.SQL['marker']:raise p.ProbeError('DatabaseErrorException')
            if a=='rollback-transaction':raise p.ProbeError('ServiceUnavailableError')
        w.override=override;r,_=self.run_probe(w)
        self.assertEqual(r['unverifiedTransactionClosures'],['A']);self.assertEqual(len(r['cleanup']),1)
    def test_malformed_rows_fail_closed(self):
        for v in [{},{'formattedRecords':'null'},{'formattedRecords':'[]'},row([]),dict(row({}),numberOfRecordsUpdated=1)]:
            with self.subTest(v=v),self.assertRaises(p.ProbeError):p.parse_row(v)
    def test_cli_pins_target_and_hides_body_file(self):
        seen=[]
        def fake(command,**kwargs):
            env=kwargs['env'];self.assertEqual(env['AWS_MAX_ATTEMPTS'],'1');self.assertTrue(kwargs['timeout']<=30)
            target=Path(command[command.index('--cli-input-json')+1][7:]);self.assertEqual(target.stat().st_mode&0o777,0o600)
            seen.append(target);self.assertEqual(command[command.index('--endpoint-url')+1],f'https://sts.{p.REGION}.amazonaws.com')
            return subprocess.CompletedProcess(command,0,'{}','')
        with patch.object(p.subprocess,'run',side_effect=fake):p.AwsCli()('sts','get-caller-identity',{})
        self.assertFalse(seen[0].exists())
    def test_cli_error_redaction(self):
        result=subprocess.CompletedProcess([],1,'','An error occurred (AccessDeniedException) SECRET-DO-NOT-LOG')
        with patch.object(p.subprocess,'run',return_value=result),self.assertRaises(p.ProbeError) as c:p.AwsCli()('sts','get-caller-identity',{})
        self.assertEqual(str(c.exception),'AccessDeniedException')
    def test_default_entry_makes_no_calls(self):
        with patch('sys.argv',[str(SCRIPT)]),patch.object(p.subprocess,'run') as wire:self.assertEqual(p.main(),0);wire.assert_not_called()
    def test_receipt_overwrite_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            target=Path(d)/'receipt.json';target.write_text('original');alias=Path(d)/'alias';alias.symlink_to(target)
            for path in [target,alias]:
                with patch('sys.argv',[str(SCRIPT),'--run-read-only','--out',str(path)]),patch.object(p.subprocess,'run') as wire,self.assertRaises(FileExistsError):p.main()
                wire.assert_not_called()
            self.assertEqual(target.read_text(),'original')


if __name__=='__main__':unittest.main(verbosity=2)
