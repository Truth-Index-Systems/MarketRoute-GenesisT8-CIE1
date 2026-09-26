#!/usr/bin/env python3
"""Offline boundary tests. No AWS connection, credential lookup or live database."""
import copy
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'infrastructure/aws-v0/migration-runner'))
import contract as c
import run_migrations as op


def package_stub():
    return SimpleNamespace(allowed_sql=set(c.SQL.values())|set(c.BOOTSTRAP),
        names={int(k[:4]):k for k in c.HASHES},plan_sha='a'*64,hashes={str(i):str(i)*64 for i in range(2,8)})

class Safety(unittest.TestCase):
    def cloud(self):
        cloud=op.Cloud(package_stub(),run=lambda *a,**k:None,sleep=lambda _:None)
        cloud.secret=f'arn:aws:secretsmanager:{c.REGION}:{c.ACCOUNT}:secret:marketroute/aws-v0/database/admin-Synthetic'
        cloud.known.add('owned-tx');return cloud
    def payload(self,sql=None):
        cloud=self.cloud();return dict(cloud.base(),transactionId='owned-tx',sql=sql or c.SQL['catalog'],parameters=[],formatRecordsAs='JSON')
    def test_default_invocation_no_calls(self):
        with patch.object(sys,'argv',['runner']),patch.object(op,'Cloud') as cloud,patch.object(op,'Package') as pkg,contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(op.main(),0);cloud.assert_not_called();pkg.assert_not_called()
    def test_pinned_files_statement_counts(self):
        expected=[10,23,2,15,18]
        self.assertEqual([len(c.pinned_body(n,(ROOT/'database/aws'/n).read_bytes())) for n in c.HASHES],expected)
    def test_changed_bytes_rejected(self):
        for n in c.HASHES:
            with self.subTest(n=n),self.assertRaisesRegex(c.GateError,'HASH_MISMATCH'):
                c.pinned_body(n,(ROOT/'database/aws'/n).read_bytes()+b' ')
    def test_baseline_not_in_executable_plan(self):
        for n in ('0001_marketroute_aws_canonical_baseline.sql','0002_marketroute_cognito_identity_mapping.sql','other.sql'):
            with self.assertRaises(c.GateError):c.pinned_body(n,b'BEGIN; COMMIT;')
    def test_segmentation_preserves_quoted_semicolons(self):
        examples=["SELECT ';';",'SELECT "a;b";',"DO $$ BEGIN PERFORM 1; END $$;", "DO $tag$ BEGIN PERFORM ';'; END $tag$;", "SELECT 'a'';b';",r"SELECT E'a\';b';"]
        for sql in examples:
            with self.subTest(sql=sql):self.assertEqual(len(c.split_sql(sql+'\n')),1)
    def test_nested_comments(self):
        text='/* outer; /* inner; */ done; */ SELECT 1; -- tail;\nSELECT 2;\n'
        self.assertEqual(len(c.split_sql(text)),2)
    def test_unterminated_tokens_rejected(self):
        for sql in ["SELECT 'x;",'DO $$ BEGIN;', '/* unfinished', 'SELECT "x;', 'SELECT 1; SELECT 2']:
            with self.subTest(sql=sql),self.assertRaises(c.GateError):c.split_sql(sql)
    def test_arbitrary_api_denied(self):
        cloud=self.cloud()
        for s,a in [('iam','put-role-policy'),('sqs','send-message'),('bedrock-runtime','invoke-model'),('rds','delete-db-cluster'),('rds-data','batch-execute-statement')]:
            with self.subTest(a=a),self.assertRaisesRegex(c.GateError,'API_ACTION_NOT_ALLOWED'):cloud.call(s,a,{})
    def test_arbitrary_sql_denied(self):
        cloud=self.cloud()
        for sql in ['DROP SCHEMA public CASCADE','SELECT * FROM companies','SELECT 1; SELECT 2','BEGIN','COMMIT']:
            with self.subTest(sql=sql),self.assertRaisesRegex(c.GateError,'SQL_NOT_IN_CLOSED_PLAN'):
                cloud.validate('rds-data','execute-statement',self.payload(sql))
    def test_no_autocommit_mutation(self):
        cloud=self.cloud();v=self.payload(c.BOOTSTRAP[0]);del v['transactionId']
        with self.assertRaisesRegex(c.GateError,'TRANSACTION_NOT_OWNED'):cloud.validate('rds-data','execute-statement',v)
    def test_unowned_transaction(self):
        cloud=self.cloud();v=self.payload();v['transactionId']='foreign'
        with self.assertRaises(c.GateError):cloud.validate('rds-data','execute-statement',v)
    def test_wrong_database_targets(self):
        cloud=self.cloud()
        for key,value in [('database','other'),('resourceArn',c.CLUSTER+'-other'),('secretArn','not-approved')]:
            with self.subTest(key=key),self.assertRaises(c.GateError):cloud.validate('rds-data','execute-statement',dict(self.payload(),**{key:value}))
    def test_extra_options_fail(self):
        cloud=self.cloud()
        for key,value in [('continueAfterTimeout',True),('schema','public'),('arbitrary',1)]:
            with self.subTest(key=key),self.assertRaises(c.GateError):cloud.validate('rds-data','execute-statement',dict(self.payload(),**{key:value}))
    def test_readiness_never_in_active_transaction(self):
        cloud=self.cloud();v=dict(cloud.base(),sql=c.SQL['ready'],parameters=[],formatRecordsAs='JSON')
        with self.assertRaisesRegex(c.GateError,'READINESS_WITH_ACTIVE'):cloud.validate('rds-data','execute-statement',v)
    def test_parameter_injection_rejected(self):
        cloud=self.cloud();v=self.payload();v['parameters']=[{'name':'x','value':{'stringValue':"'; DROP TABLE x;"}}]
        with self.assertRaises(c.GateError):cloud.validate('rds-data','execute-statement',v)
    def test_receipt_values_bound_to_exact_plan(self):
        cloud=self.cloud();n=3;pkg=cloud.package
        record={'ordinal':n,'filename':pkg.names[n],'file_sha256':c.HASHES[pkg.names[n]],'plan_sha256':pkg.plan_sha,'before_sha256':pkg.hashes['2'],'after_sha256':pkg.hashes['3'],'run_id':'11111111-1111-4111-8111-111111111111'}
        v=self.payload(c.SQL['insertReceipt']);v['parameters']=[{'name':'receipt','value':{'stringValue':c.canonical(record)}}]
        cloud.validate('rds-data','execute-statement',v)
        for key in ('file_sha256','plan_sha256','before_sha256','after_sha256'):
            altered=dict(record,**{key:'f'*64});v['parameters'][0]['value']['stringValue']=c.canonical(altered)
            with self.assertRaises(c.GateError):cloud.validate('rds-data','execute-statement',v)
    def test_cli_private_file_pinned_endpoint_and_no_retries(self):
        cloud=self.cloud();paths=[]
        def fake(cmd,**kwargs):
            path=Path(cmd[cmd.index('--cli-input-json')+1][7:]);paths.append(path)
            self.assertEqual(path.stat().st_mode&0o777,0o600)
            self.assertEqual(kwargs['env']['AWS_MAX_ATTEMPTS'],'1')
            self.assertEqual(cmd[cmd.index('--endpoint-url')+1],f'https://sts.{c.REGION}.amazonaws.com')
            return subprocess.CompletedProcess(cmd,0,'{}','')
        cloud.run=fake;cloud.call('sts','get-caller-identity',{})
        self.assertFalse(paths[0].exists())
    def test_api_error_redaction(self):
        cloud=self.cloud();cloud.run=lambda cmd,**kwargs:subprocess.CompletedProcess(cmd,1,'','An error occurred (Denied) SECRET-DO-NOT-LOG')
        with self.assertRaisesRegex(c.GateError,'^Denied$'):cloud.call('sts','get-caller-identity',{})
        self.assertNotIn('SECRET-DO-NOT-LOG',json.dumps(cloud.operations))
    def test_nonzero_exit_not_success(self):
        cloud=self.cloud();cloud.run=lambda cmd,**kwargs:subprocess.CompletedProcess(cmd,1,'{"transactionStatus":"ok"}','')
        with self.assertRaises(c.GateError):cloud.commit('owned-tx')
        self.assertIn('owned-tx',cloud.known)
    def test_end_status_uses_shape_not_example(self):
        for value in ('','other','Transaction Committed'):
            cloud=self.cloud();cloud.run=lambda cmd,**kwargs:subprocess.CompletedProcess(cmd,0,json.dumps({'transactionStatus':value}),'')
            cloud.commit('owned-tx');self.assertFalse(cloud.known)
        for value in (None,42,'x'*129):
            cloud=self.cloud();cloud.run=lambda cmd,**kwargs:subprocess.CompletedProcess(cmd,0,json.dumps({'transactionStatus':value}),'')
            with self.assertRaises(c.GateError):cloud.commit('owned-tx')
    def test_approval_requires_exact_hash_target_and_expiry(self):
        pkg=package_stub();now=1000
        plan={'format':c.FORMAT,'packagePlanSha256':pkg.plan_sha,'target':{'account':c.ACCOUNT,'region':c.REGION,'clusterArn':c.CLUSTER,'snapshot':op.SNAPSHOT},'initialTip':2,'initialCatalogSha256':pkg.hashes['2'],'expiresAt':now+3600}
        plan['planSha256']=c.fingerprint(plan)
        op.validate_approval(plan,pkg,plan['planSha256'],now)
        with self.assertRaises(c.GateError):op.validate_approval(plan,pkg,'wrong',now)
        with self.assertRaises(c.GateError):op.validate_approval(plan,pkg,plan['planSha256'],now+3601)
        altered=copy.deepcopy(plan);altered['target']['account']='000000000000';altered.pop('planSha256');altered['planSha256']=c.fingerprint(altered)
        with self.assertRaises(c.GateError):op.validate_approval(altered,pkg,altered['planSha256'],now)
    def test_missing_approval_prevents_cloud_construction(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'plan.json';path.write_text('{}')
            with patch.object(sys,'argv',['runner','--apply-plan',str(path)]),patch.object(op,'Package',return_value=package_stub()),patch.object(op,'Cloud') as cloud:
                with self.assertRaises(c.GateError):op.main()
                cloud.assert_not_called()
    def test_output_overwrite_rejected_before_aws(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'exists.json';p.write_text('keep')
            with patch.object(sys,'argv',['runner','--inspect','--out',str(p)]),patch.object(op,'Package',return_value=package_stub()),patch.object(op,'Cloud') as cloud:
                with self.assertRaises(FileExistsError):op.main()
                cloud.assert_not_called()
            self.assertEqual(p.read_text(),'keep')

if __name__=='__main__':unittest.main(verbosity=2)
