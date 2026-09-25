"""Build 11 disposable PostgreSQL harness. Never connects to AWS or production.

The service container is created by the credential-free Build 11 PR workflow.
Restore the actual AWS baseline and forward migrations, not mock ledger methods.
"""
from pathlib import Path
import hashlib
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CONTAINER = os.environ.get('BUILD11_POSTGRES_CONTAINER', '')
if not re.fullmatch(r'[a-f0-9]{12,64}', CONTAINER):
    raise SystemExit('A disposable Build 11 Docker service container is required')
CMD = ['docker', 'exec', '-i', CONTAINER, 'psql', '-X', '-v', 'ON_ERROR_STOP=1',
       '-U', 'postgres', '-d', 'marketroute_build11_test', '-At']


def sql(text):
    result = subprocess.run(CMD, input=text, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


for name in ['0001_marketroute_aws_canonical_baseline.sql',
             '0002_marketroute_cognito_identity_mapping.sql',
             '0003_marketroute_aws_build9_research_execution.sql',
             '0004_marketroute_aws_build10_research_orchestration.sql']:
    data = (ROOT / 'database/aws' / name).read_bytes()
    sql(data.decode())
    print('PASS restored', name, hashlib.sha256(data).hexdigest(), flush=True)

# Record actual dependency shapes for a reproducible, constrained fixture.
print(sql("""SELECT table_name || '.' || column_name || ' ' || data_type ||
    ' nullable=' || is_nullable || ' default=' || COALESCE(column_default, '<none>')
FROM information_schema.columns WHERE table_schema='public' AND table_name IN
('organisations','companies','campaigns','scheduler_runs','background_jobs',
 'research_work_units','research_plans','marketroute_users','seller_businesses')
ORDER BY table_name, ordinal_position;"""), flush=True)
print('PASS baseline and Build 9/10 migration compatibility; lifecycle assertions follow in Build 11 patch', flush=True)
