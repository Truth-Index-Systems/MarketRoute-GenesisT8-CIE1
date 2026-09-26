#!/usr/bin/env python3
"""Credential-free tests of the zero-budget operator; AWS responses simulated."""
from pathlib import Path
import copy, importlib.util, json, subprocess, tempfile, unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('canary',ROOT/'infrastructure/aws-v0/worker-db-canary/canary.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)

class Safety(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.f=c.fixture();self.folder=Path(self.tmp.name)
        self.calls=[]
        def run(cmd,**kwargs):
            self.calls.append(cmd)
            return subprocess.CompletedProcess(cmd,0,'{}','')
        self.cloud=c.Cloud(self.f,self.folder,run=run,sleep=lambda _:None)
    def test_fixture_envelope_and_hash(self):
        c.validate_fixture(self.f);self.assertEqual(self.f['envelope']['workUnit']['costCeilingUsd'],0)
    def test_fixture_ids_distinct(self):self.assertEqual(len(set(self.f['ids'].values())),12)
    def test_changed_fingerprint(self):
        self.f['fingerprint']='a'*64
        with self.assertRaises(c.Stop):c.validate_fixture(self.f)
    def test_changed_budget(self):
        self.f['envelope']['workUnit']['costCeilingUsd']=1
        self.f['fingerprint']=c.sha('MR-AWS-V0-RESEARCH-ENVELOPE-1.0.0|'+c.canonical(self.f['envelope']))
        with self.assertRaises(c.Stop):c.validate_fixture(self.f)
    def test_no_aws_without_optin(self):
        with patch('sys.argv',['canary.py']),patch.object(c.subprocess,'run') as r:
            self.assertEqual(c.main(),0);r.assert_not_called()
    def test_forbidden_actions(self):
        for s,a in [('bedrock-runtime','invoke-model'),('sqs','send-message'),('iam','put-role-policy'),('lambda','update-function-configuration')]:
            with self.subTest(a=a),self.assertRaises(c.Stop):self.cloud.call(s,a,{})
        self.assertFalse(self.calls)
    def test_no_model_control_writes(self):
        for sql in c.SEED+c.CLOSE:
            self.assertNotRegex(sql,r'(?i)(?:update|insert into|delete from)\s+public\.marketroute_aws_v0_(?:inference_scopes|recovery_control)')
    def test_no_schema_statements(self):
        for sql in c.ALLOWED:self.assertNotRegex(sql,r'(?i)^(?:create|alter|drop|truncate)\b')
    def test_no_mutation_autocommit(self):
        with self.assertRaises(c.Stop):self.cloud.sql(c.SEED[0])
        self.assertFalse(self.calls)
    def test_no_arbitrary_sql(self):
        self.cloud.tx='owned'
        with self.assertRaises(c.Stop):self.cloud.sql('DELETE FROM public.companies')
        self.assertFalse(self.calls)
    def test_wrong_worker_version(self):
        with self.assertRaises(c.Stop):self.cloud.call('lambda','get-function-configuration',{'FunctionName':c.FUNCTION,'Qualifier':'2'})
    def test_wrong_cluster(self):
        with self.assertRaises(c.Stop):self.cloud.call('rds-data','begin-transaction',{'resourceArn':c.CLUSTER+'x','secretArn':c.SECRET,'database':c.DB})
    def test_no_retry_unknown_begin(self):
        def run(*a,**k):raise subprocess.TimeoutExpired('aws',35)
        self.cloud.run_process=run
        with self.assertRaises(c.Stop):self.cloud.begin()
        self.assertEqual(self.cloud.calls,1)
    def test_error_redaction(self):
        self.cloud.run_process=lambda *a,**k:subprocess.CompletedProcess([],1,'','An error occurred (AccessDeniedException) sensitive text')
        with self.assertRaises(c.Stop) as e:self.cloud.call('sts','get-caller-identity',{})
        self.assertEqual(str(e.exception),'AccessDeniedException')
    def test_cli_credentials_pinning(self):
        def run(cmd,**k):
            self.assertEqual(k['env']['AWS_MAX_ATTEMPTS'],'1')
            self.assertEqual(cmd[cmd.index('--endpoint-url')+1],'https://sts.eu-west-2.amazonaws.com')
            p=Path(cmd[cmd.index('--cli-input-json')+1][7:]);self.assertEqual(p.stat().st_mode&0o777,0o600)
            return subprocess.CompletedProcess(cmd,0,'{}','')
        self.cloud.run_process=run;self.cloud.call('sts','get-caller-identity',{})
    def test_false_database_pass_rejected(self):
        for s in [{},{'execution_rows':0},{'execution_rows':1,'execution_state':'SUCCEEDED'}]:
            with self.assertRaises(c.Stop):c.verify_deferred(self.f,s)
    def test_matching_database_evidence(self):
        s={'execution_rows':1,'execution_state':'FAILED_RETRYABLE','execution_attempts':0,
           'execution_error':'MARKETROUTE_AWS_V0_ADMISSION_DEFERRED','envelope_fingerprint':self.f['fingerprint'],
           'inference_rows':0,'artifact_rows':0,'nonzero_budget_events':0,'campaign_state':'PAUSED','policy_enabled':False}
        c.verify_deferred(self.f,s)
        for k,v in [('inference_rows',1),('envelope_fingerprint','different'),('policy_enabled',True),('execution_attempts',1)]:
            with self.subTest(k=k),self.assertRaises(c.Stop):c.verify_deferred(self.f,dict(s,**{k:v}))
    def test_payload_cannot_be_empty(self):
        with self.assertRaises(c.Stop):self.cloud.call('lambda','invoke',{'FunctionName':c.FUNCTION,'Qualifier':'1','Payload':'{}'},self.folder/'handler-response.json')
    def test_journal_flushed_before_invocation(self):
        self.cloud.journal('LAMBDA_INVOCATION_REQUESTED',version='1')
        self.assertEqual(json.loads((self.folder/'journal.jsonl').read_text())['event'],'LAMBDA_INVOCATION_REQUESTED')
    def test_changed_receipt_parameters(self):
        self.cloud.tx='owned'
        v=dict(self.cloud.base(),transactionId='owned',sql=c.SEED[0],parameters=[],formatRecordsAs='JSON')
        with self.assertRaises(c.Stop):self.cloud.call('rds-data','execute-statement',v)
    def test_readiness_never_replaces_transaction(self):
        self.cloud.tx='owned'
        v=dict(self.cloud.base(),sql=c.SQL['ready'],parameters=[],formatRecordsAs='JSON')
        with self.assertRaises(c.Stop):self.cloud.call('rds-data','execute-statement',v)
    def test_budget_and_pause_present_in_seed(self):
        self.assertIn("'PAUSED'",c.SEED[4]);self.assertIn(',0,0,0,0,0,false',c.SEED[12])
    def test_fixture_not_external_lead(self):
        self.assertIn("'ARCHIVED'",c.SEED[3]);self.assertIn("'INTERNAL'",c.SEED[9])
        self.assertIn('Fictional',self.f['evidence']['statement'])
    def test_status_is_not_reinvocation(self):
        self.assertNotIn('invoke',c.SQL['state'].lower())

if __name__=='__main__':unittest.main(verbosity=2)
