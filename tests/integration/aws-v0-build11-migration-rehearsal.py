#!/usr/bin/env python3
"""Test-only rehearsal: starts its own network-disabled disposable PostgreSQL 16.

NO AWS SDK/CLI, no URL/DSN/host argument, no existing-database target and no live
migration mode. It never reads credentials or connects to the user's Aurora.
The previously blocked operator-runner publication is NOT retried by this test.
"""
from contextlib import contextmanager
from pathlib import Path
import hashlib
import json
import os
import re
import selectors
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
DB = 'marketroute_build11_rehearsal'
IMAGE = 'postgres:16'
HASHES = {
    '0001_marketroute_aws_canonical_baseline.sql': '46d9c3aee85d1021d7f514c0384aef036b7f53073a7aa78be4bfabd3266d5e5a',
    '0002_marketroute_cognito_identity_mapping.sql': '869c9ad138c1edf31507a21093c085f99059e3a0078db9e532790fb5cbcaafeb',
    '0003_marketroute_aws_build9_research_execution.sql': '5008514cc7a2caa4d07221a067ef4251fec5c89802c048955330c4bf05133800',
    '0004_marketroute_aws_build10_research_orchestration.sql': 'ab060054228bc056b79cb857817bc84e61d185b595d968611e28b556b4aa58cb',
    '0005_marketroute_aws_build11_terminal_replay.sql': '32f3e11b0cc1171bc0e068fbfe24f70f39fe7cbf98b37131283542f530e32ed2',
    '0006_marketroute_aws_build11_inference_admission.sql': '3f11ea6dc909dd0896e5aca703e6033b8ac1e4e65af61e27dce42fc1100ef7f3',
    '0007_marketroute_aws_build11_recovery.sql': 'ca2b19022dd4cfa1866802c4fd88fdb97a48e8f6f0265312c231163719258b8c',
}


def digest(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def run(command, text=None, must_succeed=True, timeout=120):
    # No subprocess receives the parent shell's AWS/PG/DOCKER connection settings.
    env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': '/tmp',
           'LANG': 'C.UTF-8', 'DOCKER_HOST': 'unix:///var/run/docker.sock'}
    result = subprocess.run(command, input=text, text=True, capture_output=True,
                            timeout=timeout, env=env, check=False)
    if must_succeed and result.returncode:
        raise RuntimeError(result.stderr[-3000:])
    return result


def migration_prefix(text):
    # This is NOT a general SQL splitter. Only exact hash-pinned files are used.
    check(len(re.findall(r'^BEGIN;$', text, re.M)) == 1, 'unexpected BEGIN boundary')
    matches = list(re.finditer(r'^COMMIT;\s*\Z', text, re.M))
    check(len(matches) == 1, 'unexpected final COMMIT boundary')
    return text[:matches[0].start()]


class Lab:
    def __init__(self, container):
        check(re.fullmatch(r'[a-f0-9]{64}', container) is not None, 'invalid owned container ID')
        self.container = container
        self.cmd = ['docker', 'exec', '-i', container, 'psql', '-X', '-v', 'ON_ERROR_STOP=1',
                    '-U', 'postgres', '-d', DB, '-Atq']

    def sql(self, text, ok=True):
        return run(self.cmd, text, must_succeed=ok)

    def value(self, text):
        return self.sql(text).stdout.strip()

    def names(self):
        return self.value("SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                          "WHERE n.nspname='public' AND c.relkind='r' ORDER BY relname;").splitlines()

    def rows(self, names=None):
        queries = []
        for name in names if names is not None else self.names():
            check(re.fullmatch(r'[a-z][a-z0-9_]*', name) is not None, 'unexpected table identifier')
            queries.append(f"SELECT '{name}' AS name,jsonb_build_object('count',count(*),"
                           "'digest',md5(COALESCE(string_agg(to_jsonb(t)::text,E'\\n' "
                           f"ORDER BY to_jsonb(t)::text),''))) AS value FROM public.\"{name}\" t")
        return json.loads(self.value("SELECT jsonb_object_agg(name,value ORDER BY name)::text FROM (" +
                                     ' UNION ALL '.join(queries) + ') q;'))

    def schema(self):
        text = run(['docker', 'exec', self.container, 'pg_dump', '--schema-only',
                    '-U', 'postgres', '-d', DB]).stdout
        # New pg_dump patches add a random client-side restriction nonce.
        stable = '\n'.join(x for x in text.splitlines()
                           if not re.match(r'^\\(?:un)?restrict\b', x))
        return digest(stable)

    def state(self):
        return {'schemaSha256': self.schema(), 'rows': self.rows()}

    def functions(self):
        return json.loads(self.value("""SELECT jsonb_object_agg(
          p.proname||'('||oidvectortypes(p.proargtypes)||')',
          jsonb_build_object('definition',md5(pg_get_functiondef(p.oid)),
          'acl',p.proacl::text,'definer',p.prosecdef,'settings',p.proconfig))::text
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.prokind='f';"""))

    @contextmanager
    def locked_work_table(self):
        # A second connection inside this owned network-disabled container only.
        p = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True,
                             env={'PATH': os.environ.get('PATH','/usr/bin:/bin'), 'HOME':'/tmp',
                                  'DOCKER_HOST':'unix:///var/run/docker.sock'})
        try:
            p.stdin.write("BEGIN; LOCK public.research_work_units IN ACCESS EXCLUSIVE MODE;\n"
                          "SELECT 'REHEARSAL_LOCK_READY';\n")
            p.stdin.flush()
            with selectors.DefaultSelector() as s:
                s.register(p.stdout, selectors.EVENT_READ)
                check(bool(s.select(10)), 'lock session did not become ready')
                check(p.stdout.readline().strip() == 'REHEARSAL_LOCK_READY', 'unexpected lock response')
            yield
        finally:
            if p.stdin and not p.stdin.closed:
                p.stdin.close()  # No COMMIT: PostgreSQL rolls back on disconnect.
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.terminate()
                p.wait(timeout=5)


def seed(lab):
    ids = {key: str(uuid.uuid4()) for key in
           ('user','org','seller','company','campaign','plan','run','job','work','source','acquisition','evidence')}
    fp = digest(ids['work'])
    q = {k: "'"+v+"'" for k,v in ids.items()}
    lab.sql(f"""
      INSERT INTO public.marketroute_users(id) VALUES({q['user']});
      INSERT INTO public.marketroute_external_identities(provider,issuer,subject,user_id)
        VALUES('COGNITO','https://synthetic.example.invalid', {q['user']},{q['user']});
      INSERT INTO public.organisations(id,name,slug,created_by)
        VALUES({q['org']},'Migration rehearsal only',{q['org']},{q['user']});
      INSERT INTO public.seller_businesses(id,organisation_id,name,created_by)
        VALUES({q['seller']},{q['org']},'Synthetic seller',{q['user']});
      INSERT INTO public.companies(id,canonical_name) VALUES({q['company']},'Synthetic company');
      INSERT INTO public.campaigns(id,organisation_id,seller_business_id,name,created_by)
        VALUES({q['campaign']},{q['org']},{q['seller']},'Migration rehearsal only',{q['user']});
      INSERT INTO public.scheduler_runs(id,runner_key) VALUES({q['run']},'GENESIS_RESEARCH_V1');
      INSERT INTO public.research_plan_runs(id,organisation_id,campaign_id,company_id,reference_time,
        lifecycle_state,authority_envelope_fingerprint,planner_version,semantics_version,
        gap_set_fingerprint,gap_context_json,work_units_json,budget_policy_snapshot_json,budget_snapshot_json,plan_fingerprint)
        VALUES({q['plan']},{q['org']},{q['campaign']},{q['company']},now(),'COMMERCIAL_RESEARCH_REQUIRED',
          '{fp}','MRV2-RESEARCH-1.0.0','MRV2-RESEARCH-1.0.0','{fp}','{{}}','[]','{{}}','{{}}','{fp}');
      INSERT INTO public.background_jobs(id,organisation_id,campaign_id,job_type,dedupe_key,status,
        reserved_by_run_id,reserved_at,attempt_count)
        VALUES({q['job']},{q['org']},{q['campaign']},'GENESIS_RESEARCH_V1','{fp}','RUNNING',{q['run']},now(),1);
      INSERT INTO public.background_job_attempts(job_id,scheduler_run_id,attempt_number,status)
        VALUES({q['job']},{q['run']},1,'RUNNING');
      INSERT INTO public.research_work_units(id,plan_id,organisation_id,campaign_id,company_id,ordinal,gap_key,
        layer,tier,action,subject_type,subject_id,reason_code,query_hints_json,payload_json,cost_ceiling_usd,dedupe_key,background_job_id)
        VALUES({q['work']},{q['plan']},{q['org']},{q['campaign']},{q['company']},1,'migration-rehearsal',
          'R4','ENRICHMENT','ACQUIRE_CLAIM_EVIDENCE','COMPANY',{q['company']},
          'SYNTHETIC_TEST','[]','{{"researchOrigin":"CUSTOMER_CAMPAIGN"}}',0.1,'{fp}',{q['job']});
      INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,max_job_cost_usd,
        max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours,enabled)
        VALUES({q['org']},{q['campaign']},1,0.1,1,1,24,false);
      INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,scheduler_run_id,
        attempt_number,event_type,amount_usd) VALUES({q['org']},{q['campaign']},{q['work']},{q['run']},1,'RESERVE',0.1);
      INSERT INTO public.source_records(id,source_kind,source_identity_fingerprint,stable_locator,dependence_family_key,normalisation_version)
        VALUES({q['source']},'INTERNAL','{fp}','migration:synthetic','migration:synthetic','TEST');
      INSERT INTO public.source_acquisitions(id,source_id,acquisition_method)
        VALUES({q['acquisition']},{q['source']},'MANUAL');
      INSERT INTO public.evidence_items(id,acquisition_id,tenant_scope_organisation_id,subject_type,subject_id,
        evidence_kind,excerpt_text,extraction_method,evidence_fingerprint,source_identity_fingerprint,dependence_family_key,fingerprint_version)
        VALUES({q['evidence']},{q['acquisition']},{q['org']},'COMPANY',{q['company']},'OBSERVATION',
          'Synthetic migration sentinel only.','DETERMINISTIC','{fp}','{fp}','migration:synthetic','TEST');
    """)
    return ids


def exercise(lab, files, receipt):
    checks = receipt['checks']

    def passed(name, **details):
        checks.append({'name':name,'status':'PASS',**details})
        print('PASS', name, flush=True)

    check(lab.value('SHOW server_version_num;').startswith('16'), 'PostgreSQL 16 required')
    receipt['serverVersion'] = lab.value('SHOW server_version;')
    for name in list(HASHES)[:2]:
        lab.sql(files[name])
    ids = seed(lab)
    baseline_names = lab.names()
    baseline_rows = lab.rows(baseline_names)
    baseline_functions = lab.functions()
    passed('baseline restored with synthetic identity, evidence, active job and held budget',
           baselineTables=len(baseline_names), nonemptyTables=sum(v['count']>0 for v in baseline_rows.values()))
    stages = []
    for name in list(HASHES)[2:]:
        raw = files[name]
        prefix = migration_prefix(raw)
        before = lab.state()
        for fault, suffix, error in (
            ('statement_error',"SELECT 1/0;\nCOMMIT;\n",'division by zero'),
            ('statement_timeout',"SET LOCAL statement_timeout='25ms'; SELECT pg_sleep(1);\nCOMMIT;\n",'statement timeout'),
            ('disconnect_before_commit','',None),
        ):
            result = lab.sql(prefix + suffix, ok=False)
            if error:
                check(result.returncode != 0 and error in result.stderr, f'{name} fault did not occur: {result.stderr}')
            else:
                check(result.returncode == 0, result.stderr)
            check(lab.state() == before, f'{name} {fault}: schema or rows escaped rollback')
            passed(f'{name[:4]} {fault}: exact pre-migration schema and rows restored')
        if name.startswith('0004'):
            with lab.locked_work_table():
                contested = prefix.replace('BEGIN;',"BEGIN; SET LOCAL lock_timeout='100ms';",1) + 'COMMIT;\n'
                result = lab.sql(contested, ok=False)
                check(result.returncode != 0 and 'lock timeout' in result.stderr, result.stderr)
            check(lab.state() == before, 'lock timeout left partial schema changes')
            passed('0004 competing table lock: bounded failure preserves prior committed 0003')
        lab.sql(raw)  # The ORIGINAL checksum-pinned file, including its own BEGIN/COMMIT.
        check(lab.rows(baseline_names) == baseline_rows, f'{name} changed baseline rows')
        stages.append({'migration':name,'sha256':HASHES[name], 'schemaBefore':before['schemaSha256'],
                       'schemaAfter':lab.schema(),'baselineRowsPreserved':True})
        passed(f'{name[:4]} ordered commit preserves all original table-row digests')
    receipt['stages'] = stages
    receipt['baselineRows'] = baseline_rows

    expected_tables = sorted(['marketroute_aws_v0_'+n for n in (
        'research_executions','research_dispatches','company_understanding_artifacts',
        'inference_scopes','inference_attempts','recovery_control','recovery_receipts')])
    check(sorted(set(lab.names())-set(baseline_names)) == expected_tables,'unexpected table delta')
    passed('only the seven expected research tables are added')
    check(lab.value('SELECT count(*)=1 AND bool_and(NOT enabled) FROM public.marketroute_aws_v0_inference_scopes;')=='t', 'model control not off')
    check(lab.value('SELECT count(*)=1 AND bool_and(NOT enabled) FROM public.marketroute_aws_v0_recovery_control;')=='t','recovery control not off')
    passed('model admission and recovery both remain disabled after commit')
    after_functions = lab.functions()
    exception = 'marketroute_recover_abandoned_research_work_v1(uuid, timestamp with time zone)'
    check(all(after_functions.get(k)==v for k,v in baseline_functions.items() if k!=exception), 'unrelated routine changed')
    passed('baseline routine definitions and ACLs preserved except the intentionally replaced reaper')
    unsafe = lab.value("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public' AND (position('aws_v0' in p.proname)>0 OR p.proname='marketroute_recover_abandoned_research_work_v1')
      AND EXISTS(SELECT 1 FROM aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) a
                 WHERE a.grantee=0 AND a.privilege_type='EXECUTE');""")
    check(unsafe=='0','PUBLIC execution remains on a research routine')
    passed('new research routines and replaced reaper do not grant PUBLIC execution')
    for table,key in [('research_work_units','work'),('research_budget_events',None),('evidence_items','evidence')]:
        where = "work_unit_id='"+ids['work']+"'" if key is None else "id='"+ids[key]+"'"
        result=lab.sql(f'DELETE FROM public.{table} WHERE {where};',ok=False)
        check(result.returncode!=0,'append-only trigger allowed deletion')
    check(lab.rows(baseline_names)==baseline_rows,'append-only probe changed rows')
    passed('work, budget and evidence append-only protections still reject mutation')

    final = lab.state()
    for name in (list(HASHES)[2],list(HASHES)[3],list(HASHES)[5],list(HASHES)[6]):
        result=lab.sql(files[name],ok=False)
        check(result.returncode!=0,'unexpected replay success for '+name)
        check(lab.state()==final,'failed replay damaged completed schema')
    passed('replaying 0003/0004/0006/0007 fails rather than forming a safe resume protocol')
    # Demonstrate the hazardous success case, always ROLLBACK it in this test DB.
    signature='public.marketroute_claim_aws_v0_research_execution_v2(jsonb,text,text,timestamptz)'
    latest_hash=lab.value(f"SELECT md5(pg_get_functiondef('{signature}'::regprocedure));")
    old=lab.value(migration_prefix(files[list(HASHES)[4]])+
                  f"SELECT md5(pg_get_functiondef('{signature}'::regprocedure));\nROLLBACK;")
    check(old!=latest_hash,'expected out-of-order overwrite was not demonstrated')
    check(lab.state()==final,'out-of-order probe was not rolled back')
    passed('0005 replay after 0007 can silently downgrade claim routine; demonstration rolled back',
           currentDefinitionMd5=latest_hash,replayedDefinitionMd5=old)
    # The source migrations do not supply an application/migration history ledger.
    check(lab.rows(['marketroute_schema_releases'])=={'marketroute_schema_releases':baseline_rows['marketroute_schema_releases']},'history changed unexpectedly')
    passed('existing schema-release history is untouched: a separate live resume ledger is still required')
    receipt['finalSchemaSha256'] = final['schemaSha256']
    receipt['newTables'] = expected_tables


def main():
    check(len(sys.argv)==1, 'This test accepts no arguments or live-database target')
    files = {}
    for name,expected in HASHES.items():
        raw=(ROOT/'database/aws'/name).read_bytes()
        check(digest(raw)==expected,'source checksum changed: '+name)
        files[name]=raw.decode()
    out=Path(tempfile.mkdtemp(prefix='build11-migration-rehearsal-'))
    receipt={'schemaVersion':1,'mode':'DISPOSABLE_POSTGRESQL_16_ONLY','checks':[],
             'migrationSha256':HASHES,'liveDatabaseMutations':0,'liveAwsCalls':0,
             'liveMigrationRunner':'NOT_TESTED_OR_PUBLISHED','productionActivation':'BLOCKED',
             'snapshotRestore':'NOT_TESTED','status':'RUNNING'}
    try:
        receipt['testedGitCommit']=run(['git','-C',str(ROOT),'rev-parse','HEAD']).stdout.strip()
    except RuntimeError:
        receipt['testedGitCommit']='LOCAL_SOURCE_WITHOUT_GIT'
    container=None
    try:
        container=run(['docker','run','--detach','--network','none','--memory','768m',
            '--tmpfs','/var/lib/postgresql/data:rw,size=512m',
            '--label','marketroute.build11.rehearsal=true',
            '-e','POSTGRES_PASSWORD=disposable-migration-rehearsal-only',
            '-e','POSTGRES_DB='+DB,IMAGE]).stdout.strip()
        check(re.fullmatch('[a-f0-9]{64}',container) is not None,'invalid owned container ID')
        meta=json.loads(run(['docker','inspect',container]).stdout)[0]
        check(meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig'].get('PortBindings'),
              'test database must be network-disabled without published ports')
        receipt['networkMode']='none'
        receipt['postgresImageId']=meta['Image']
        for _ in range(40):
            ready=run(['docker','exec',container,'pg_isready','-U','postgres','-d',DB],must_succeed=False)
            if ready.returncode==0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError('disposable PostgreSQL failed to start')
        exercise(Lab(container),files,receipt)
        receipt['status']='PASS'
    except BaseException as exc:
        receipt['status']='FAIL'
        receipt['failure']=str(exc)
        raise
    finally:
        if container and re.fullmatch('[a-f0-9]{64}',container):
            cleaned=run(['docker','rm','--force',container],must_succeed=False)
            receipt['ownedContainerRemoved']=cleaned.returncode==0
        receipt['assertionGroups']=len(receipt['checks'])
        path=out/'receipt.json'
        path.write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
        (out/'SHA256SUMS').write_text(digest(path.read_bytes())+'  receipt.json\n')
        print('Rehearsal receipt:',path,flush=True)
        print(f"{len(receipt['checks'])} rehearsal groups; status={receipt['status']}; live migration NOT certified",flush=True)


if __name__=='__main__':
    main()
