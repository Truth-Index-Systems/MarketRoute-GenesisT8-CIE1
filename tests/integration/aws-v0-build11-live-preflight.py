"""Offline safety proof for the operator preflight. Never calls AWS."""
from pathlib import Path
import base64
import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'infrastructure/aws-v0/scripts/build11-live-preflight.py'
spec = importlib.util.spec_from_file_location('live', SCRIPT)
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
REQUEST = (ROOT / 'infrastructure/aws-v0/proof/build11-live-native-request.json').read_bytes()
SECRET = 'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-TEST01'
ROLE = 'arn:aws:iam::801132668416:role/MrAwsV0ResearchStack-ResearchWorkerRole-TEST'
CATALOG = {'database': 'marketroute', 'serverVersion': '16.15',
           'routines': [{'signature': 'f(uuid)', 'definitionMd5': '1'*32, 'securityDefiner': True, 'publicExecute': False}],
           'tables': ['marketroute_aws_v0_inference_scopes', 'marketroute_aws_v0_recovery_control']}
CONTROLS = {'scopes': [{'scopeKey': live.SCOPE, 'enabled': False, 'profiles': [live.PROFILE],
                       'inputUsdPerMillion': 3.3, 'outputUsdPerMillion': 16.5}],
            'recovery': [{'enabled': False, 'maxRepublishes': 3}]}


class Fake:
    def __init__(self):
        self.calls = []
        self.overrides = {}

    def __call__(self, service, action, args=()):
        self.calls.append((service, action, list(args)))
        key = (service, action)
        assert key in live.ALLOWED
        if key in self.overrides:
            value = self.overrides[key]
            if isinstance(value, Exception):
                raise value
            return copy.deepcopy(value)
        if service == 'sts':
            return {'Account': live.ACCOUNT, 'Arn': f'arn:aws:sts::{live.ACCOUNT}:assumed-role/MarketRouteV0Administrator/test'}
        if action == 'get-inference-profile':
            return {'inferenceProfileArn': live.PROFILE, 'status': 'ACTIVE', 'type': 'APPLICATION',
                    'models': [{'modelArn': a} for a in live.MODELS]}
        if action == 'get-foundation-model':
            return {'modelDetails': {'modelId': live.MODEL, 'modelLifecycle': {'status': 'ACTIVE'}}}
        if service == 'service-quotas':
            code = args[args.index('--quota-code') + 1]
            return {'Quota': {'QuotaCode': code, 'Value': 10 if code == live.QUOTAS['requestsPerMinute'] else 5000000}}
        if action == 'describe-stacks':
            stack = args[1]
            outputs = {'ClusterArn': live.CLUSTER, 'SecretArn': SECRET, 'DatabaseName': 'marketroute'} if 'Database' in stack else {'BuildStatus': 'BUILD11'}
            return {'Stacks': [{'StackName': stack, 'StackStatus': 'UPDATE_COMPLETE',
                               'Outputs': [{'OutputKey': k, 'OutputValue': v} for k, v in outputs.items()]}]}
        if action == 'list-stack-resources':
            return {'StackResourceSummaries': []}
        if action == 'describe-db-clusters':
            return {'DBClusters': [{'DBClusterArn': live.CLUSTER, 'HttpEndpointEnabled': True, 'Engine': 'aurora-postgresql'}]}
        if action == 'get-function-configuration':
            return {'Runtime': 'nodejs22.x', 'Architectures': ['arm64'], 'Handler': 'index.handler',
                    'State': 'Active', 'LastUpdateStatus': 'Successful', 'Role': ROLE,
                    'CodeSha256': base64.b64encode(bytes.fromhex(live.PACKAGE_SHA)).decode(),
                    'Environment': {'Variables': {'UNRELATED_SECRET': 'DO-NOT-RETAIN-THIS',
                        'MARKETROUTE_AWS_RDS_CLUSTER_ARN': live.CLUSTER, 'MARKETROUTE_AWS_RDS_SECRET_ARN': SECRET,
                        'MARKETROUTE_AWS_RDS_DATABASE': 'marketroute',
                        'MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN': live.PROFILE,
                        'MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED': 'true'}}}
        if action == 'list-role-policies':
            return {'PolicyNames': ['WorkerPolicy']}
        if action == 'get-role-policy':
            return {'PolicyDocument': {'Version': '2012-10-17', 'Statement': []}}
        if action == 'list-attached-role-policies':
            return {'AttachedPolicies': []}
        if action == 'list-event-source-mappings':
            return {'EventSourceMappings': [{'State': 'Disabled', 'UUID': 'synthetic', 'EventSourceArn': 'synthetic'}]}
        if action == 'count-tokens':
            path = args[args.index('--input')+1].removeprefix('file://')
            body = json.loads(Path(path).read_text())['invokeModel']['body'].encode()
            assert body == REQUEST
            assert Path(path).stat().st_mode & 0o777 == 0o600
            return {'inputTokens': 850}
        if service == 'rds-data':
            sql = args[args.index('--sql') + 1]
            assert sql in (live.CATALOG_SQL, live.CONTROL_SQL)
            value = CATALOG if sql == live.CATALOG_SQL else CONTROLS
            return {'formattedRecords': json.dumps([{'result_json': json.dumps(value)}])}
        raise AssertionError((service, action))


class Proof(unittest.TestCase):
    def setUp(self):
        self.fake = Fake()

    def collect(self, read=True, expected=CATALOG):
        return live.collect(self.fake, REQUEST, read, expected)

    def override(self, service, action, mutate):
        value = self.fake(service, action, ['--function-name', live.FUNCTION])
        mutate(value)
        self.fake.overrides[(service, action)] = value
        self.fake.calls.clear()

    def test_happy_collection_never_certifies_live(self):
        r = self.collect()
        self.assertEqual(r['paidInferenceCalls'], 0)
        self.assertEqual(r['productionActivation'], 'BLOCKED')
        self.assertEqual(len(r['blockers']), 3)
        self.assertEqual(r['liveWorkerProof'], 'NOT_RUN')
        digest = r.pop('receiptSha256')
        self.assertEqual(digest, live.sha(live.canonical(r)))

    def test_no_paid_inference_or_writes(self):
        self.collect()
        forbidden = ('invoke', 'create', 'update', 'delete', 'send', 'receive', 'get-secret-value', 'put')
        self.assertFalse(any(a.startswith(forbidden) for _, a, _ in self.fake.calls))

    def test_identity_wrong_account_stops(self):
        self.fake.overrides[('sts', 'get-caller-identity')] = {'Account': '123456789012', 'Arn': 'wrong'}
        self.assertIn('WRONG_ACCOUNT_OR_NOT_ROLE_SESSION', self.collect()['blockers'])
        self.assertEqual(len(self.fake.calls), 1)

    def test_root_and_static_user_rejected(self):
        for arn in [f'arn:aws:iam::{live.ACCOUNT}:root', f'arn:aws:iam::{live.ACCOUNT}:user/name']:
            self.fake = Fake()
            self.fake.overrides[('sts', 'get-caller-identity')] = {'Account': live.ACCOUNT, 'Arn': arn}
            self.assertIn('WRONG_ACCOUNT_OR_NOT_ROLE_SESSION', self.collect()['blockers'])
            self.assertEqual(len(self.fake.calls), 1)

    def test_identity_permission_failure_stops(self):
        self.fake.overrides[('sts', 'get-caller-identity')] = live.PreflightError('AccessDenied')
        self.assertIn('IDENTITY_UNVERIFIED', self.collect()['blockers'])
        self.assertEqual(len(self.fake.calls), 1)

    def test_unrelated_environment_secret_not_saved(self):
        self.assertNotIn('DO-NOT-RETAIN-THIS', json.dumps(self.collect()))
        self.assertNotIn('UNRELATED_SECRET', json.dumps(self.collect()))

    def test_model_route_mismatch_skips_count(self):
        self.override('bedrock', 'get-inference-profile', lambda v: v['models'].append({'modelArn': 'arn:aws:bedrock:us-east-1::foundation-model/'+live.MODEL}))
        self.assertIn('PROFILE_MODEL_OR_ROUTE_MISMATCH', self.collect()['blockers'])
        self.assertFalse(any(a == 'count-tokens' for _, a, _ in self.fake.calls))

    def test_zero_quotas_do_not_pass(self):
        self.fake.overrides[('service-quotas', 'get-service-quota')] = {'Quota': {'QuotaCode': 'wrong', 'Value': 0}}
        self.assertIn('REQUESTSPERMINUTE_UNUSABLE', self.collect()['blockers'])

    def test_invalid_token_count_not_passed(self):
        for value in [0, -1, True, 198601, None, '100']:
            self.fake.overrides[('bedrock-runtime', 'count-tokens')] = {'inputTokens': value}
            self.assertIn('TOKEN_COUNT_INVALID', self.collect()['blockers'])

    def test_counter_failure_no_fallback(self):
        self.fake.overrides[('bedrock-runtime', 'count-tokens')] = live.PreflightError('ValidationException')
        self.assertIn('TOKENCOUNT_UNVERIFIED', self.collect()['blockers'])
        self.assertEqual(sum(a == 'count-tokens' for _, a, _ in self.fake.calls), 1)

    def test_missing_worker_is_blocker_not_creation(self):
        self.fake.overrides[('lambda', 'get-function-configuration')] = live.PreflightError('ResourceNotFoundException')
        r = self.collect()
        self.assertIn('WORKER_UNVERIFIED', r['blockers'])
        self.assertEqual(r['evidence']['worker']['errorCode'], 'ResourceNotFoundException')
        self.assertTrue(any(s == 'rds-data' for s, _, _ in self.fake.calls))

    def test_wrong_package_and_layers_rejected(self):
        for key, value in [('CodeSha256', 'wrong'), ('Layers', [{'Arn': 'unexpected'}])]:
            self.fake = Fake()
            self.override('lambda', 'get-function-configuration', lambda v: v.update({key: value}))
            self.assertIn('WORKER_PACKAGE_OR_CONFIGURATION_MISMATCH', self.collect()['blockers'])

    def test_enabled_or_missing_queue_mapping_rejected(self):
        for mappings in [[], [{'State': 'Enabled'}], [{'State': 'Enabling'}]]:
            self.fake.overrides[('lambda', 'list-event-source-mappings')] = {'EventSourceMappings': mappings}
            self.assertIn('QUEUE_MAPPING_NOT_VERIFIED_DISABLED', self.collect()['blockers'])

    def test_database_opt_in_required(self):
        r = self.collect(read=False)
        self.assertFalse(any(s == 'rds-data' for s, _, _ in self.fake.calls))
        self.assertIn('DATA_API_SCHEMA_AND_CONTROLS_UNVERIFIED', r['blockers'])

    def test_database_target_mismatch_no_query(self):
        self.fake.overrides[('cloudformation', 'describe-stacks')] = {'Stacks': [{'StackStatus': 'UPDATE_COMPLETE', 'Outputs': []}]}
        self.assertIn('DATABASE_TARGET_OUTPUTS_MISMATCH', self.collect()['blockers'])
        self.assertFalse(any(s == 'rds-data' for s, _, _ in self.fake.calls))

    def test_missing_reference_not_passed(self):
        self.assertIn('EXPECTED_DATABASE_CONTRACT_MISSING', self.collect(expected=None)['blockers'])

    def test_definition_and_public_execute_drift_rejected(self):
        for field, value in [('definitionMd5', '2'*32), ('publicExecute', True)]:
            expected = copy.deepcopy(CATALOG)
            expected['routines'][0][field] = value
            self.assertFalse(live.compare_catalog(CATALOG, expected))
        self.assertFalse(live.compare_catalog(CATALOG, {'routines': [], 'tables': CATALOG['tables']}))

    def test_receipt_ignores_pg_version_not_function_drift(self):
        expected = dict(CATALOG, serverVersion='16.8', database='marketroute_build11_test')
        self.assertTrue(live.compare_catalog(CATALOG, expected))
        self.assertFalse(live.compare_catalog(dict(CATALOG, database='wrong'), expected))

    def test_malformed_db_response_is_unknown(self):
        self.fake.overrides[('rds-data', 'execute-statement')] = {'formattedRecords': '[]'}
        self.assertIn('DATABASECATALOG_UNVERIFIED', self.collect()['blockers'])

    def test_unknown_database_controls_not_passed(self):
        original = self.fake
        def call(service, action, args=()):
            if service == 'rds-data' and live.CONTROL_SQL in args:
                return {'formattedRecords': json.dumps([{'result_json': json.dumps({'scopes': [], 'recovery': []})}])}
            return original(service, action, args)
        self.fake = call
        r = self.collect()
        self.assertIn('MODEL_SCOPES_NOT_VERIFIED_DISABLED', r['blockers'])
        self.assertIn('RECOVERY_NOT_VERIFIED_DISABLED', r['blockers'])

    def test_modified_synthetic_request_never_calls_aws(self):
        with self.assertRaises(live.PreflightError):
            live.collect(self.fake, REQUEST+b' ')
        self.assertEqual(self.fake.calls, [])

    def test_real_wrapper_rejects_mutation_and_arbitrary_sql(self):
        with patch.object(live.subprocess, 'run') as run:
            for action in [('lambda', 'invoke', []), ('rds-data', 'execute-statement', ['--sql', 'DELETE FROM public.campaigns'])]:
                with self.assertRaises(live.PreflightError):
                    live.aws_call(*action)
            run.assert_not_called()

    def test_real_wrapper_pins_endpoint_and_retries(self):
        with patch.object(live.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{}', '')) as run:
            live.aws_call('sts', 'get-caller-identity')
            args, options = run.call_args
            self.assertIn('https://sts.eu-west-2.amazonaws.com', args[0])
            self.assertEqual(options['env']['AWS_MAX_ATTEMPTS'], '1')
            self.assertEqual(options['env']['AWS_IGNORE_CONFIGURED_ENDPOINT_URLS'], 'true')
            self.assertFalse(options.get('shell', False))

    def test_real_wrapper_redacts_aws_errors(self):
        response = subprocess.CompletedProcess([], 1, '', 'An error occurred (AccessDeniedException) secret-data')
        with patch.object(live.subprocess, 'run', return_value=response):
            with self.assertRaises(live.PreflightError) as raised:
                live.aws_call('sts', 'get-caller-identity')
            self.assertEqual(str(raised.exception), 'AccessDeniedException')

    def test_real_wrapper_rejects_bearer_auth(self):
        with patch.dict(os.environ, {'AWS_BEARER_TOKEN_BEDROCK': 'synthetic'}), patch.object(live.subprocess, 'run') as run:
            with self.assertRaises(live.PreflightError):
                live.aws_call('sts', 'get-caller-identity')
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
