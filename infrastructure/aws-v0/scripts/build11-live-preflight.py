#!/usr/bin/env python3
"""Read-only Build 11 AWS evidence collector. Never invokes a generative model.

Python 3.10+ and authenticated AWS CLI v2. All endpoints/account/model targets
are pinned. --read-database performs catalog/config SELECTs and may wake Aurora.
No deploy, DDL, IAM mutation, queue receive/send, secret-value read or inference.
A successful collection is NOT worker IAM, billing or production certification.
"""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone

ACCOUNT = '801132668416'
REGION = 'eu-west-2'
MODEL = 'anthropic.claude-sonnet-4-5-20250929-v1:0'
PROFILE_ID = '1t6o6h9xl4qb'
PROFILE = f'arn:aws:bedrock:{REGION}:{ACCOUNT}:application-inference-profile/{PROFILE_ID}'
CLUSTER = f'arn:aws:rds:{REGION}:{ACCOUNT}:cluster:marketroute-aws-v0'
FUNCTION = 'marketroute-aws-v0-research-worker'
PACKAGE_SHA = '2af677632762d14c34ea4ec4fd97b850d43b728ff95893c7a78b72eacf1ef113'
REQUEST_SHA = 'd8047cd6750502642d1637a7ad18c1887c152508a36526a9ce0122a43c2e5e46'
REGIONS = ('eu-central-1', 'eu-north-1', 'eu-south-1', 'eu-south-2', 'eu-west-1', 'eu-west-2', 'eu-west-3')
MODELS = sorted(f'arn:aws:bedrock:{r}::foundation-model/{MODEL}' for r in REGIONS)
SCOPE = f'{ACCOUNT}:{REGION}:EU:{MODEL}'
QUOTAS = {'requestsPerMinute': 'L-4A6BFAB1', 'tokensPerMinute': 'L-F4DDD3EB'}
ALLOWED = {
    ('sts', 'get-caller-identity'), ('bedrock', 'get-inference-profile'),
    ('bedrock', 'get-foundation-model'), ('bedrock-runtime', 'count-tokens'),
    ('service-quotas', 'get-service-quota'), ('cloudformation', 'describe-stacks'),
    ('cloudformation', 'list-stack-resources'), ('rds', 'describe-db-clusters'),
    ('rds-data', 'execute-statement'), ('lambda', 'get-function-configuration'),
    ('lambda', 'list-event-source-mappings'), ('iam', 'get-role'),
    ('iam', 'list-role-policies'), ('iam', 'get-role-policy'),
    ('iam', 'list-attached-role-policies'),
}
ENDPOINTS = {s: f'https://{s}.{REGION}.amazonaws.com' for s, _ in ALLOWED}
ENDPOINTS.update({'service-quotas': f'https://servicequotas.{REGION}.amazonaws.com',
                  'iam': 'https://iam.amazonaws.com'})
# Only catalog metadata is read here. No function body, customer data or SQL from
# the caller is returned. Definition hashes allow comparison with disposable PG.
CATALOG_SQL = """SELECT jsonb_build_object(
 'database',current_database(),'serverVersion',current_setting('server_version'),
 'routines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'signature',p.proname||'('||oidvectortypes(p.proargtypes)||')',
    'definitionMd5',md5(pg_get_functiondef(p.oid)),
    'securityDefiner',p.prosecdef,
    'publicExecute',EXISTS(SELECT 1 FROM aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
       WHERE a.grantee=0 AND a.privilege_type='EXECUTE')) ORDER BY p.proname,oidvectortypes(p.proargtypes))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.prokind='f'
    AND (position('aws_v0' in p.proname)>0 OR p.proname='marketroute_recover_abandoned_research_work_v1')),'[]'::jsonb),
 'tables',COALESCE((SELECT jsonb_agg(c.relname ORDER BY c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind='r' AND position('marketroute_aws_v0_' in c.relname)=1),'[]'::jsonb)
)::text AS result_json"""
CONTROL_SQL = """SELECT jsonb_build_object(
 'scopes',(SELECT jsonb_agg(jsonb_build_object('scopeKey',scope_key,'enabled',enabled,
    'profiles',profile_arns,'intervalSeconds',minimum_interval_seconds,
    'inputUsdPerMillion',input_usd_per_million,'outputUsdPerMillion',output_usd_per_million,
    'tariffVersion',tariff_version,'haltReason',last_halt_reason) ORDER BY scope_key)
  FROM public.marketroute_aws_v0_inference_scopes),
 'recovery',(SELECT jsonb_agg(jsonb_build_object('enabled',enabled,'maxRepublishes',max_republishes))
  FROM public.marketroute_aws_v0_recovery_control)
)::text AS result_json"""


class PreflightError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def aws_call(service, action, arguments=()):
    if (service, action) not in ALLOWED:
        raise PreflightError('ACTION_NOT_ALLOWED')
    if service == 'rds-data':
        args = list(arguments)
        if '--sql' not in args or args[args.index('--sql') + 1] not in (CATALOG_SQL, CONTROL_SQL):
            raise PreflightError('DATABASE_QUERY_NOT_ALLOWED')
    env = dict(os.environ, AWS_PAGER='', AWS_CLI_AUTO_PROMPT='off', AWS_MAX_ATTEMPTS='1',
               AWS_RETRY_MODE='standard', AWS_IGNORE_CONFIGURED_ENDPOINT_URLS='true')
    if env.get('AWS_BEARER_TOKEN_BEDROCK'):
        raise PreflightError('BEDROCK_BEARER_TOKEN_MUST_BE_UNSET')
    command = ['aws', service, action, *arguments, '--region', REGION,
               '--endpoint-url', ENDPOINTS[service], '--output', 'json', '--no-cli-pager',
               '--cli-connect-timeout', '5', '--cli-read-timeout', '25']
    try:
        p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40, check=False)
    except FileNotFoundError:
        raise PreflightError('AWS_CLI_NOT_FOUND') from None
    except subprocess.TimeoutExpired:
        raise PreflightError('AWS_CALL_TIMED_OUT') from None
    if p.returncode:
        # AWS error messages can contain request data. Preserve only the code.
        match = re.search(r'An error occurred \(([A-Za-z0-9_.-]+)\)', p.stderr)
        raise PreflightError(match.group(1) if match else 'AWS_CLI_FAILED')
    try:
        value = json.loads(p.stdout)
    except (ValueError, TypeError):
        raise PreflightError('AWS_RESPONSE_NOT_JSON') from None
    if not isinstance(value, dict):
        raise PreflightError('AWS_RESPONSE_NOT_OBJECT')
    return value


def parse_data_api(value):
    try:
        rows = json.loads(value['formattedRecords'])
        if len(rows) != 1 or set(rows[0]) != {'result_json'}:
            raise ValueError()
        result = json.loads(rows[0]['result_json'])
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except (KeyError, ValueError, TypeError):
        raise PreflightError('DATABASE_RESPONSE_INVALID') from None


def compare_catalog(actual, expected):
    if actual.get('database') != 'marketroute':
        return False
    # Intentionally exact: a PG-version rendering difference also requires review;
    # matching names alone must not masquerade as migration evidence.
    return (actual.get('routines') == expected.get('routines') and
            actual.get('tables') == expected.get('tables') and bool(expected.get('routines')))


def collect(call, request, read_database=False, expected_catalog=None):
    if sha(request) != REQUEST_SHA:
        raise PreflightError('SYNTHETIC_REQUEST_HASH_MISMATCH')
    report = {'schemaVersion': 1, 'collectedAt': datetime.now(timezone.utc).isoformat(),
              'targetAccount': ACCOUNT, 'region': REGION, 'evidence': {}, 'blockers': [],
              'mode': 'READ_ONLY_PREFLIGHT_WITH_TOKEN_COUNT', 'paidInferenceCalls': 0,
              'liveWorkerProof': 'NOT_RUN', 'liveBillingReconciliation': 'NOT_RUN',
              'productionActivation': 'BLOCKED', 'expectedWorkerZipSha256': PACKAGE_SHA,
              'syntheticRequestSha256': REQUEST_SHA}
    evidence, blockers = report['evidence'], report['blockers']

    def get(label, service, action, args=()):
        try:
            return call(service, action, args)
        except PreflightError as exc:
            evidence[label] = {'status': 'UNKNOWN', 'errorCode': exc.code}
            blockers.append(label.upper() + '_UNVERIFIED')
            return None

    identity = get('identity', 'sts', 'get-caller-identity')
    if not identity:
        return finish(report)
    arn = identity.get('Arn', '')
    if identity.get('Account') != ACCOUNT or not arn.startswith(f'arn:aws:sts::{ACCOUNT}:assumed-role/'):
        evidence['identity'] = {'status': 'REJECTED', 'reason': 'EXPECTED_ACCOUNT_AND_ROLE_SESSION_REQUIRED'}
        blockers.append('WRONG_ACCOUNT_OR_NOT_ROLE_SESSION')
        return finish(report)  # No AWS call after identity failure.
    evidence['identity'] = {'account': ACCOUNT, 'callerArn': arn,
                            'scope': 'SHELL_IDENTITY_ONLY_NOT_WORKER_IDENTITY'}

    profile = get('profile', 'bedrock', 'get-inference-profile',
                  ('--inference-profile-identifier', PROFILE_ID))
    profile_ok = False
    if profile:
        model_arns = sorted(x.get('modelArn', '') for x in profile.get('models', []))
        profile_ok = (profile.get('inferenceProfileArn') == PROFILE and profile.get('type') == 'APPLICATION'
                      and profile.get('status') == 'ACTIVE' and model_arns == MODELS)
        evidence['profile'] = {'arn': profile.get('inferenceProfileArn'), 'type': profile.get('type'),
            'status': profile.get('status'), 'models': model_arns, 'matchesReviewedRoute': profile_ok}
        if not profile_ok:
            blockers.append('PROFILE_MODEL_OR_ROUTE_MISMATCH')
    model = get('model', 'bedrock', 'get-foundation-model', ('--model-identifier', MODEL))
    if model:
        m = model.get('modelDetails', {})
        evidence['model'] = {k: m.get(k) for k in ('modelId', 'modelLifecycle', 'inferenceTypesSupported')}
        if m.get('modelId') != MODEL or m.get('modelLifecycle', {}).get('status') != 'ACTIVE':
            blockers.append('MODEL_LIFECYCLE_REVIEW_REQUIRED')
    for name, code in QUOTAS.items():
        q = get(name, 'service-quotas', 'get-service-quota', ('--service-code', 'bedrock', '--quota-code', code))
        if q:
            v = q.get('Quota', {})
            evidence[name] = {k: v.get(k) for k in ('QuotaName', 'QuotaCode', 'Value', 'Adjustable')}
            if v.get('QuotaCode') != code or not isinstance(v.get('Value'), (int, float)) or v['Value'] <= 0:
                blockers.append(name.upper() + '_UNUSABLE')

    secret = None
    for stack, label in [('MrAwsV0DatabaseStack', 'databaseStack'), ('MrAwsV0ResearchStack', 'researchStack')]:
        value = get(label, 'cloudformation', 'describe-stacks', ('--stack-name', stack))
        if value:
            stacks = value.get('Stacks', [])
            if len(stacks) != 1:
                blockers.append(label.upper() + '_AMBIGUOUS')
                continue
            s = stacks[0]
            outputs = {x['OutputKey']: x.get('OutputValue') for x in s.get('Outputs', [])}
            permitted = ('BuildStatus', 'ClusterArn', 'SecretArn', 'DatabaseName',
                         'ResearchWorkerArn', 'ResearchWorkerPackageSha256', 'ResearchEventSourceStatus')
            evidence[label] = {'name': s.get('StackName'), 'status': s.get('StackStatus'),
                               'outputs': {k: outputs[k] for k in permitted if k in outputs}}
            if s.get('StackStatus') not in ('CREATE_COMPLETE', 'UPDATE_COMPLETE'):
                blockers.append(label.upper() + '_REVIEW_REQUIRED')
            if label == 'databaseStack':
                candidate = outputs.get('SecretArn', '')
                if (outputs.get('ClusterArn') == CLUSTER and outputs.get('DatabaseName') == 'marketroute'
                        and re.fullmatch(r'arn:aws:secretsmanager:eu-west-2:801132668416:secret:marketroute/aws-v0/database/admin-[A-Za-z0-9]+', candidate)):
                    secret = candidate
                else:
                    blockers.append('DATABASE_TARGET_OUTPUTS_MISMATCH')
    resources = get('researchResources', 'cloudformation', 'list-stack-resources',
                    ('--stack-name', 'MrAwsV0ResearchStack'))
    if resources:
        evidence['researchResources'] = [{k: x.get(k) for k in ('LogicalResourceId', 'ResourceType',
            'PhysicalResourceId', 'ResourceStatus')} for x in resources.get('StackResourceSummaries', [])]
    cluster = get('cluster', 'rds', 'describe-db-clusters', ('--db-cluster-identifier', 'marketroute-aws-v0'))
    db_ready = False
    if cluster:
        records = cluster.get('DBClusters', [])
        if len(records) == 1:
            c = records[0]
            evidence['cluster'] = {k: c.get(k) for k in ('DBClusterArn', 'Status', 'Engine', 'EngineVersion',
                'HttpEndpointEnabled', 'StorageEncrypted', 'DeletionProtection', 'BackupRetentionPeriod',
                'ServerlessV2ScalingConfiguration')}
            db_ready = c.get('DBClusterArn') == CLUSTER and c.get('HttpEndpointEnabled') is True
            if not db_ready:
                blockers.append('DATA_API_TARGET_UNAVAILABLE')
        else:
            blockers.append('CLUSTER_RESPONSE_AMBIGUOUS')

    worker = get('worker', 'lambda', 'get-function-configuration', ('--function-name', FUNCTION))
    if worker:
        settings = worker.get('Environment', {}).get('Variables', {})
        evidence['worker'] = {k: worker.get(k) for k in ('FunctionArn', 'Runtime', 'Architectures', 'Handler',
            'CodeSha256', 'RevisionId', 'Role', 'State', 'LastUpdateStatus', 'Version')}
        evidence['worker']['layers'] = [x.get('Arn') for x in worker.get('Layers', [])]
        expected_b64 = base64.b64encode(bytes.fromhex(PACKAGE_SHA)).decode()
        matches = (worker.get('CodeSha256') == expected_b64 and worker.get('Runtime') == 'nodejs22.x'
            and worker.get('Architectures') == ['arm64'] and worker.get('Handler') == 'index.handler'
            and not worker.get('Layers') and worker.get('State') == 'Active'
            and worker.get('LastUpdateStatus') == 'Successful'
            and settings.get('MARKETROUTE_AWS_RDS_CLUSTER_ARN') == CLUSTER
            and secret is not None and settings.get('MARKETROUTE_AWS_RDS_SECRET_ARN') == secret
            and settings.get('MARKETROUTE_AWS_RDS_DATABASE') == 'marketroute'
            and settings.get('MARKETROUTE_AWS_BEDROCK_INFERENCE_PROFILE_ARN') == PROFILE)
        evidence['worker']['configurationMatchesCandidate'] = matches
        evidence['worker']['executorSwitch'] = settings.get('MARKETROUTE_AWS_RESEARCH_EXECUTOR_ENABLED')
        # No other environment values are persisted (they may be secrets).
        if not matches:
            blockers.append('WORKER_PACKAGE_OR_CONFIGURATION_MISMATCH')
        role = worker.get('Role', '')
        if re.fullmatch(r'arn:aws:iam::801132668416:role/[A-Za-z0-9+=,.@_/-]+', role):
            role_name = role.rsplit('/', 1)[-1]
            policy_list = get('workerInlinePolicyList', 'iam', 'list-role-policies', ('--role-name', role_name))
            if policy_list:
                evidence['workerInlinePolicies'] = []
                for name in policy_list.get('PolicyNames', []):
                    policy = get('workerPolicy_' + name, 'iam', 'get-role-policy',
                                 ('--role-name', role_name, '--policy-name', name))
                    if policy:
                        evidence['workerInlinePolicies'].append({'name': name,
                            'sha256': sha(canonical(policy.get('PolicyDocument', {}))),
                            'document': policy.get('PolicyDocument')})
            attached = get('workerManagedPolicies', 'iam', 'list-attached-role-policies', ('--role-name', role_name))
            if attached:
                evidence['workerManagedPolicies'] = attached.get('AttachedPolicies', [])
                if attached.get('AttachedPolicies'):
                    blockers.append('WORKER_MANAGED_POLICIES_REQUIRE_REVIEW')
        mappings = get('queueMappings', 'lambda', 'list-event-source-mappings', ('--function-name', FUNCTION))
        if mappings is not None:
            evidence['queueMappings'] = [{k: v.get(k) for k in ('UUID', 'State', 'EventSourceArn', 'FunctionArn')}
                for v in mappings.get('EventSourceMappings', [])]
            # Empty is not a verified disabled trigger: it may be missing infrastructure.
            if not evidence['queueMappings'] or any(v.get('State') != 'Disabled' for v in evidence['queueMappings']):
                blockers.append('QUEUE_MAPPING_NOT_VERIFIED_DISABLED')

    if profile_ok:
        with tempfile.TemporaryDirectory(prefix='marketroute-count-') as d:
            payload = Path(d) / 'input.json'
            payload.write_text(json.dumps({'invokeModel': {'body': request.decode()}}))
            os.chmod(payload, 0o600)
            counted = get('tokenCount', 'bedrock-runtime', 'count-tokens',
                          ('--model-id', MODEL, '--input', 'file://' + str(payload),
                           '--cli-binary-format', 'raw-in-base64-out'))
        if counted:
            tokens = counted.get('inputTokens')
            ok = isinstance(tokens, int) and not isinstance(tokens, bool) and 0 < tokens <= 198600
            evidence['tokenCount'] = {'inputTokens': tokens, 'valid': ok,
                'requestSha256': REQUEST_SHA, 'identityScope': 'SHELL_NOT_WORKER'}
            if not ok:
                blockers.append('TOKEN_COUNT_INVALID')
    else:
        evidence['tokenCount'] = {'status': 'SKIPPED', 'reason': 'PROFILE_NOT_VERIFIED'}

    if read_database and secret and db_ready:
        def query(label, sql):
            value = get(label, 'rds-data', 'execute-statement', ('--resource-arn', CLUSTER,
                '--secret-arn', secret, '--database', 'marketroute', '--sql', sql, '--format-records-as', 'JSON'))
            if value is None:
                return None
            try:
                return parse_data_api(value)
            except PreflightError as exc:
                evidence[label] = {'status': 'UNKNOWN', 'errorCode': exc.code}
                blockers.append(label.upper() + '_UNVERIFIED')
                return None
        catalog = query('databaseCatalog', CATALOG_SQL)
        if catalog:
            evidence['databaseCatalog'] = catalog
            if not expected_catalog:
                blockers.append('EXPECTED_DATABASE_CONTRACT_MISSING')
            elif not compare_catalog(catalog, expected_catalog):
                blockers.append('DATABASE_ROUTINE_CONTRACT_MISMATCH')
            needed = {'marketroute_aws_v0_inference_scopes', 'marketroute_aws_v0_recovery_control'}
            if needed.issubset(set(catalog.get('tables', []))):
                controls = query('databaseControls', CONTROL_SQL)
                if controls:
                    evidence['databaseControls'] = controls
                    scopes, recovery = controls.get('scopes') or [], controls.get('recovery') or []
                    target = [s for s in scopes if s.get('scopeKey') == SCOPE]
                    if len(target) != 1 or target[0].get('enabled') is not False or any(s.get('enabled') is not False for s in scopes):
                        blockers.append('MODEL_SCOPES_NOT_VERIFIED_DISABLED')
                    if len(recovery) != 1 or recovery[0].get('enabled') is not False:
                        blockers.append('RECOVERY_NOT_VERIFIED_DISABLED')
                    if len(target) == 1 and (target[0].get('profiles') != [PROFILE] or
                            target[0].get('inputUsdPerMillion') != 3.3 or target[0].get('outputUsdPerMillion') != 16.5):
                        blockers.append('ACCOUNTING_TARIFF_OR_PROFILE_DRIFT')
            else:
                blockers.append('BUILD11_DATABASE_CONTROLS_MISSING')
    else:
        evidence['databaseCatalog'] = {'status': 'NOT_READ', 'reason':
            'EXPLICIT_READ_DATABASE_FLAG_REQUIRED' if not read_database else 'DATABASE_TARGET_NOT_VERIFIED'}
        blockers.append('DATA_API_SCHEMA_AND_CONTROLS_UNVERIFIED')
    return finish(report)


def finish(report):
    report['blockers'] = sorted(set(report['blockers'] + [
        'RESTRICTED_WORKER_LIVE_PROOF_NOT_RUN', 'LIVE_BILLING_TARIFF_NOT_RECONCILED',
        'RECOVERY_SCHEDULE_AND_LIVE_SQS_PROOF_OUTSTANDING']))
    report['receiptSha256'] = sha(canonical(report))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--read-database', action='store_true', help='Read catalog/control metadata; may wake Aurora and incur compute/Data API charges.')
    parser.add_argument('--out', type=Path, default=Path('build11-live-preflight.json'))
    args = parser.parse_args()
    proof = Path(__file__).resolve().parents[1] / 'proof'
    request = (proof / 'build11-live-native-request.json').read_bytes()
    expected_path = proof / 'build11-expected-database.json'
    expected = json.loads(expected_path.read_text()) if expected_path.is_file() else None
    if expected is not None and (expected.get('schemaVersion') != 1 or
            expected.get('expectedWorkerZipSha256') != PACKAGE_SHA or
            expected.get('requestSha256') != REQUEST_SHA):
        raise SystemExit('Expected database reference does not match this worker/request candidate')
    # Refuse to overwrite evidence or follow a symlink; repeated runs need a new path.
    with args.out.open('x', encoding='utf-8') as output:
        os.chmod(args.out, 0o600)
        try:
            report = collect(aws_call, request, args.read_database, expected)
        except PreflightError as exc:
            report = finish({'schemaVersion': 1, 'fatalError': exc.code, 'blockers': [],
                             'productionActivation': 'BLOCKED', 'paidInferenceCalls': 0})
        output.write(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'receipt': str(args.out.resolve()), 'receiptSha256': report['receiptSha256'],
                      'paidInferenceCalls': 0, 'productionActivation': 'BLOCKED',
                      'blockers': report['blockers']}, indent=2))
    return 2 if report.get('fatalError') or 'WRONG_ACCOUNT_OR_NOT_ROLE_SESSION' in report['blockers'] else 0


if __name__ == '__main__':
    raise SystemExit(main())
