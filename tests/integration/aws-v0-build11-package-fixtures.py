"""Fresh synthetic fixtures for the packaged/default-SDK PostgreSQL proof only."""
from pathlib import Path
import importlib.util
import json
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('build11_fixture', HERE / 'aws-v0-build11-db.py')
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)  # Fixture functions only; guarded baseline tests do not rerun.
sql, q = f.sql, f.literal


def ready(budget=0.2, evidence=True):
    item = f.fixture('RUNNING', 'SENT', None)
    x = item['ids']
    sql(f"""UPDATE public.campaigns SET workflow_state='ACTIVE' WHERE id={q(x['campaign'])};
      INSERT INTO public.research_budget_policies(organisation_id,campaign_id,daily_budget_usd,
        max_job_cost_usd,max_concurrent_jobs,max_work_units_per_plan,refresh_horizon_hours)
      VALUES({q(x['org'])},{q(x['campaign'])},{budget},{min(budget,0.1)},2,2,24);
      INSERT INTO public.research_budget_events(organisation_id,campaign_id,work_unit_id,
        scheduler_run_id,attempt_number,event_type,amount_usd)
      VALUES({q(x['org'])},{q(x['campaign'])},{q(x['work'])},{q(x['run'])},1,'RESERVE',0.1);""")
    if evidence:
        src, acquisition = str(uuid.uuid4()), str(uuid.uuid4())
        e = item['envelope']['workUnit']['payload']['metadata']['awsV0Executor']['input']['evidence'][0]
        fp = item['fp']
        sql(f"""INSERT INTO public.source_records(id,source_kind,source_identity_fingerprint,
          stable_locator,dependence_family_key,normalisation_version)
          VALUES({q(src)},'WEB','{fp}',{q('https://example.test/'+src)},{q(src)},'BUILD11-SYNTHETIC');
          INSERT INTO public.source_acquisitions(id,source_id,acquisition_method)
          VALUES({q(acquisition)},{q(src)},'IMPORT');
          INSERT INTO public.evidence_items(id,acquisition_id,tenant_scope_organisation_id,
            subject_type,subject_id,evidence_kind,excerpt_text,observed_at,extraction_method,
            evidence_fingerprint,source_identity_fingerprint,dependence_family_key,fingerprint_version)
          VALUES({q(x['evidence'])},{q(acquisition)},{q(x['org'])},'COMPANY',{q(x['company'])},'OBSERVATION',
            {q(e['statement'])},{q(e['observedAt'])}::timestamptz,'DETERMINISTIC',
            '{fp}','{fp}',{q(src)},'BUILD11-SYNTHETIC');""")
    return item


p = Path('/tmp/marketroute-build11-admission-fixtures.json')
fixtures = json.loads(p.read_text())
fixtures.update({name: ready(**options) for name, options in {
    'packagedSuccess': {}, 'packagedInvalid': {},
    'packagedNoBudget': {'budget': 0.05}, 'packagedNoEvidence': {'evidence': False},
}.items()})
p.write_text(json.dumps(fixtures))
print('Prepared four fresh packaged-worker fixtures in disposable PostgreSQL; no AWS access')
