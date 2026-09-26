#!/usr/bin/env python3
"""Offline boundary tests for retirement of an unexecuted canary fixture."""
from pathlib import Path
import importlib.util, json, tempfile, unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('canary',ROOT/'infrastructure/aws-v0/worker-db-canary/canary.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)

class RetirementSafety(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.folder=Path(self.tmp.name);self.f=c.fixture()
        self.state={'work_rows':1,'campaign_state':'PAUSED','policy_enabled':False,'execution_rows':0,
                    'inference_rows':0,'artifact_rows':0,'nonzero_budget_events':0,'job_state':'RUNNING','run_state':'RUNNING'}
        self.detail={'database':c.DB,'role':'marketroute_admin','fixture_matches_expired':True,'no_other_work':True,
                     'dispatch_rows':1,'job_attempt_rows':1,'job_attempt_state':'RUNNING','original_owner':True,
                     'budget_rows':0,'recovery_rows':0}
    def saved(self):
        (self.folder/'fixture.json').write_text(json.dumps(self.f))
        (self.folder/'summary.json').write_text(json.dumps({'status':'STOPPED','errorCode':'ParamValidation','fixtureClosed':False}))
        (self.folder/'journal.jsonl').write_text(''.join(json.dumps({'event':x})+'\n' for x in
            ('FIXTURE_COMMIT_ACKNOWLEDGED','LAMBDA_INVOCATION_REQUESTED')))
    def test_unexecuted_state_accepted(self):c.verify_uninvoked_retirement(self.state,self.detail)
    def test_executed_or_monetary_state_rejected(self):
        for key in ('execution_rows','inference_rows','artifact_rows','nonzero_budget_events'):
            with self.subTest(key=key),self.assertRaises(c.Stop):c.verify_uninvoked_retirement(dict(self.state,**{key:1}),self.detail)
    def test_changed_or_live_scope_rejected(self):
        for key in ('fixture_matches_expired','no_other_work','original_owner'):
            with self.subTest(key=key),self.assertRaises(c.Stop):c.verify_uninvoked_retirement(self.state,dict(self.detail,**{key:False}))
    def test_existing_budget_or_recovery_rejected(self):
        for key in ('budget_rows','recovery_rows','dispatch_rows','job_attempt_rows'):
            with self.subTest(key=key),self.assertRaises(c.Stop):c.verify_uninvoked_retirement(self.state,dict(self.detail,**{key:2}))
    def test_terminal_postcondition_requires_retirement_receipts(self):
        s=dict(self.state,job_state='FAILED',run_state='CANCELLED')
        d=dict(self.detail,job_error=c.RETIRE_ERROR,job_attempt_state='FAILED',budget_rows=1,
               retirement_release_rows=1,recovery_rows=1,retirement_recovery_rows=1)
        c.verify_uninvoked_retirement(s,d,closed=True)
        with self.assertRaises(c.Stop):c.verify_uninvoked_retirement(s,dict(d,retirement_release_rows=0),closed=True)
    def test_wrong_database_identity_rejected(self):
        with self.assertRaises(c.Stop):c.verify_uninvoked_retirement(self.state,dict(self.detail,role='other'))
    def test_unsupported_failed_receipt_stops_before_cloud(self):
        self.saved();(self.folder/'summary.json').write_text(json.dumps({'status':'STOPPED','errorCode':'API_RESPONSE_UNKNOWN','fixtureClosed':False}))
        with patch.object(c,'Cloud') as cloud,self.assertRaises(c.Stop):c.retire_existing(self.folder)
        cloud.assert_not_called()
    def test_received_lambda_response_stops_before_cloud(self):
        self.saved()
        with (self.folder/'journal.jsonl').open('a') as f:f.write(json.dumps({'event':'LAMBDA_RESPONSE_RECEIVED'})+'\n')
        with patch.object(c,'Cloud') as cloud,self.assertRaises(c.Stop):c.retire_existing(self.folder)
        cloud.assert_not_called()
    def test_saved_symlink_rejected(self):
        self.saved();p=self.folder/'summary.json';p.rename(self.folder/'other.json');p.symlink_to(self.folder/'other.json')
        with patch.object(c,'Cloud') as cloud,self.assertRaises(c.Stop):c.retire_existing(self.folder)
        cloud.assert_not_called()
    def test_original_receipt_preserved_and_second_attempt_blocked(self):
        self.saved();before={n:(self.folder/n).read_bytes() for n in ('fixture.json','summary.json','journal.jsonl')}
        with patch.object(c,'Cloud') as cls,patch.object(c,'retire_uninvoked',return_value={}) as retire:
            cls.return_value.tx=None;cls.return_value.begin_unknown=False
            self.assertEqual(c.retire_existing(self.folder),0)
            cls.return_value.seed.assert_not_called();cls.return_value.invoke.assert_not_called()
            with self.assertRaises(FileExistsError):c.retire_existing(self.folder)
            self.assertEqual(retire.call_count,1)
        self.assertEqual(before,{n:(self.folder/n).read_bytes() for n in before})
    def test_retirement_has_no_research_activation_or_arbitrary_update(self):
        for sql in c.RETIRE:
            self.assertNotRegex(sql,r'(?i)^(CREATE|ALTER|DROP|TRUNCATE|UPDATE|DELETE)\b')
            self.assertIn(':fixture',sql)
            self.assertNotIn('ownership_expires_at',sql)
        self.assertIn("'MR-AWS-V0-RECOVERY|'",c.SQL['retireWorkLock'])
    def test_retirement_cli_mode_cannot_seed_or_invoke(self):
        with patch('sys.argv',['canary.py','--close-uninvoked-existing',str(self.folder)]),patch.object(c,'retire_existing',return_value=0) as retire,patch.object(c,'Cloud') as cls:
            self.assertEqual(c.main(),0);retire.assert_called_once_with(self.folder);cls.assert_not_called()

if __name__=='__main__':unittest.main(verbosity=2)
