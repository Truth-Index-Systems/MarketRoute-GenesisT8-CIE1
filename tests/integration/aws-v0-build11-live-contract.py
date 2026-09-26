"""Build operator kit from actual disposable PostgreSQL plus verified worker ZIP.

Runs after migrations 0001-0007 and package tests in credential-free CI. It does
not change the schema or call AWS. Expected routine hashes are observations,
not an assertion that production has applied the migrations.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

f = load('db', ROOT/'tests/integration/aws-v0-build11-db.py')
p = load('preflight', ROOT/'infrastructure/aws-v0/scripts/build11-live-preflight.py')
before = f.sql("SELECT count(*)||'|'||COALESCE(sum(amount_usd),0)::text FROM public.research_budget_events")
catalog = json.loads(f.sql(p.CATALOG_SQL))
assert len(catalog['routines']) >= 15
assert any(r['signature'].startswith('marketroute_recover_abandoned_research_work_v1(') for r in catalog['routines'])
assert set(['marketroute_aws_v0_inference_scopes','marketroute_aws_v0_recovery_control']).issubset(catalog['tables'])
controls = json.loads(f.sql(p.CONTROL_SQL))
assert controls['scopes'] and controls['recovery']  # Test controls only; never copied as live state.
assert before == f.sql("SELECT count(*)||'|'||COALESCE(sum(amount_usd),0)::text FROM public.research_budget_events")
assert p.compare_catalog(dict(catalog,database='marketroute'),catalog)
changed = json.loads(json.dumps(catalog)); changed['routines'][0]['definitionMd5']='0'*32
assert not p.compare_catalog(dict(catalog,database='marketroute'),changed)

manifest = json.loads((ROOT/'infrastructure/aws-v0/artifacts/research-worker.manifest.json').read_text())
assert manifest['archiveSha256'] == p.PACKAGE_SHA
assert hashlib.sha256((ROOT/'infrastructure/aws-v0/artifacts/research-worker.zip').read_bytes()).hexdigest() == p.PACKAGE_SHA
out = Path('/tmp/build11-live-validation-kit')
if out.exists():
    shutil.rmtree(out)
(out/'scripts').mkdir(parents=True)
(out/'proof').mkdir()
shutil.copyfile(ROOT/'infrastructure/aws-v0/scripts/build11-live-preflight.py',out/'scripts/build11-live-preflight.py')
for name in ['build11-live-input.json','build11-live-native-request.json']:
    shutil.copyfile(ROOT/'infrastructure/aws-v0/proof'/name,out/'proof'/name)
shutil.copyfile(ROOT/'infrastructure/aws-v0/BUILD11-LIVE-VALIDATION.md',out/'README.md')
# No runtime .env, AWS configuration, npm credentials, customer data or secrets.
catalog.update({'schemaVersion':1,'evidenceSource':'DISPOSABLE_POSTGRESQL_NOT_LIVE_AURORA',
    'testedGitCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
    'prHeadSha':os.environ.get('BUILD11_PR_HEAD_SHA'),
    'expectedWorkerZipSha256':p.PACKAGE_SHA,'requestSha256':p.REQUEST_SHA,
    'migrationSha256':{file.name:hashlib.sha256(file.read_bytes()).hexdigest()
                       for file in sorted((ROOT/'database/aws').glob('000[1-7]_*.sql'))}})
assert len(catalog['migrationSha256']) == 7
(out/'proof/build11-expected-database.json').write_text(json.dumps(catalog,sort_keys=True,indent=2)+'\n')
files={str(file.relative_to(out)):hashlib.sha256(file.read_bytes()).hexdigest()
       for file in sorted(out.rglob('*')) if file.is_file()}
(out/'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name,digest in files.items()))
print(f'PASS read-only catalog/control SQL on actual PostgreSQL: {len(catalog["routines"])} routines; no budget mutation')
print('PASS changed routine definition fails comparison; original worker archive remains identical')
print('PASS operator kit binds synthetic request, observed routine contract, migration hashes and tested commit')
print('LIVE_AWS_PROOF=NOT_RUN; no AWS credentials are used by this job')
