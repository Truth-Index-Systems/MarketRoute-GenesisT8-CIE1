#!/usr/bin/env python3
"""TEST ONLY: migration receipt/resume protocol in a newly owned offline database.

No AWS client, credentials, existing container, DSN, endpoint, or live mode.
This does not publish or replace the previously blocked live operator runner.
"""
from contextlib import contextmanager
from pathlib import Path
import copy
import importlib.util
import json
import os
import re
import select
import subprocess
import sys
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location('rehearsal', Path(__file__).with_name('aws-v0-build11-migration-rehearsal.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
ROOT, DB = r.ROOT, r.DB
CONTROL = 'build11_ledger_lab'
REFERENCE_DB = 'marketroute_build11_reference'
LOCK = '110011, 7'
ENV = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': '/tmp',
       'LANG': 'C.UTF-8', 'DOCKER_HOST': 'unix:///var/run/docker.sock'}

# Canonical metadata, not OIDs, row contents or pg_dump order. Includes privileges
# and every ordinary table/function in the selected schema. This is not a full
# PostgreSQL object/security audit (roles, extensions, policies and views omitted).
CATALOG = """SELECT jsonb_build_object(
 'tables',COALESCE((SELECT jsonb_agg(jsonb_build_object(
  'name',c.relname,'owner',pg_get_userbyid(c.relowner),'acl',c.relacl::text,
  'rls',c.relrowsecurity,'forceRls',c.relforcerowsecurity,
  'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,
    'type',format_type(a.atttypid,a.atttypmod),'notNull',a.attnotnull,
    'default',pg_get_expr(d.adbin,d.adrelid),'identity',a.attidentity,'generated',a.attgenerated)
    ORDER BY a.attnum) FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
    WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
  'constraints',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',q.conname,
    'type',q.contype,'definition',pg_get_constraintdef(q.oid),'valid',q.convalidated)
    ORDER BY q.conname) FROM pg_constraint q WHERE q.conrelid=c.oid),'[]'::jsonb),
  'indexes',COALESCE((SELECT jsonb_agg(jsonb_build_object('definition',pg_get_indexdef(i.indexrelid),
    'valid',i.indisvalid) ORDER BY pg_get_indexdef(i.indexrelid)) FROM pg_index i WHERE i.indrelid=c.oid),'[]'::jsonb),
  'triggers',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',t.tgname,
    'definition',pg_get_triggerdef(t.oid),'enabled',t.tgenabled) ORDER BY t.tgname)
    FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal),'[]'::jsonb)) ORDER BY c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='SCHEMA_NAME' AND c.relkind='r'),'[]'::jsonb),
 'routines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
   'signature',p.proname||'('||oidvectortypes(p.proargtypes)||')',
   'definitionMd5',md5(pg_get_functiondef(p.oid)),'acl',p.proacl::text,
   'owner',pg_get_userbyid(p.proowner),'definer',p.prosecdef,'settings',p.proconfig)
   ORDER BY p.proname,oidvectortypes(p.proargtypes)) FROM pg_proc p
   JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='SCHEMA_NAME' AND p.prokind='f'),'[]'::jsonb),
 'schemaAcl',(SELECT nspacl::text FROM pg_namespace WHERE nspname='SCHEMA_NAME')
)::text;"""

# The receipt structure is intentionally confined to a test-only schema. No
# production migration creates this schema, and no deployment consumes it.
BOOTSTRAP = f"""
CREATE SCHEMA {CONTROL};
REVOKE ALL ON SCHEMA {CONTROL} FROM PUBLIC;
CREATE TABLE {CONTROL}.history (
 ordinal integer PRIMARY KEY CHECK (ordinal BETWEEN 3 AND 7),
 filename text NOT NULL UNIQUE,
 file_sha256 text NOT NULL CHECK (file_sha256 ~ '^[a-f0-9]{{64}}$'),
 plan_sha256 text NOT NULL CHECK (plan_sha256 ~ '^[a-f0-9]{{64}}$'),
 before_sha256 text NOT NULL CHECK (before_sha256 ~ '^[a-f0-9]{{64}}$'),
 after_sha256 text NOT NULL CHECK (after_sha256 ~ '^[a-f0-9]{{64}}$'),
 run_id uuid NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
REVOKE ALL ON TABLE {CONTROL}.history FROM PUBLIC;
CREATE FUNCTION {CONTROL}.reject_change() RETURNS trigger LANGUAGE plpgsql
SET search_path TO 'pg_catalog' AS $$ BEGIN RAISE EXCEPTION 'IMMUTABLE_MIGRATION_HISTORY'; END $$;
REVOKE ALL ON FUNCTION {CONTROL}.reject_change() FROM PUBLIC;
CREATE TRIGGER history_no_update_delete BEFORE UPDATE OR DELETE ON {CONTROL}.history
 FOR EACH STATEMENT EXECUTE FUNCTION {CONTROL}.reject_change();
CREATE TRIGGER history_no_truncate BEFORE TRUNCATE ON {CONTROL}.history
 FOR EACH STATEMENT EXECUTE FUNCTION {CONTROL}.reject_change();
"""


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def fingerprint(value):
    return r.digest(canonical(value))


class GateError(Exception):
    pass


class Session:
    """One native psql backend in the owned container; no connection parameter."""
    def __init__(self, lab):
        self.p = subprocess.Popen(lab.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=ENV, bufsize=0)
        self.pending = b''

    def execute(self, sql):
        marker = ('LEDGER_END_' + uuid.uuid4().hex).encode()
        self.p.stdin.write(sql.encode() + b'\nSELECT \'' + marker + b"';\n")
        self.p.stdin.flush()
        deadline = time.monotonic() + 30
        lines = []
        while True:
            while b'\n' in self.pending:
                line, self.pending = self.pending.split(b'\n', 1)
                if line == marker:
                    return b'\n'.join(lines).decode()
                lines.append(line)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.p.stdout], [], [], remaining)[0]:
                raise RuntimeError('LOCAL_PSQL_RESPONSE_TIMEOUT')
            chunk = os.read(self.p.stdout.fileno(), 65536)
            if not chunk:
                self.p.wait(timeout=5)
                raise RuntimeError(self.p.stderr.read().decode()[-3000:])
            self.pending += chunk
            if len(self.pending) + sum(map(len, lines)) > 2_000_000:
                raise RuntimeError('LOCAL_PSQL_RESPONSE_TOO_LARGE')

    def catalog(self, schema='public'):
        r.check(schema in ('public', CONTROL), 'unapproved test schema')
        return json.loads(self.execute(CATALOG.replace('SCHEMA_NAME', schema)))

    def close(self):
        try:
            if self.p.stdin and not self.p.stdin.closed:
                self.p.stdin.close()  # EOF rolls back an unfinished transaction.
            self.p.wait(timeout=10)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.p.terminate()
            self.p.wait(timeout=5)
        finally:
            self.p.stdout.close()
            self.p.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class LabProtocol:
    """Executable protocol specimen, only instantiated by this isolated test."""
    def __init__(self, lab, files, expected, control_contract):
        self.lab, self.files = lab, files
        self.expected, self.control_contract = expected, control_contract
        self.hashes = {k: fingerprint(v) for k, v in expected.items()}
        self.plan_sha = fingerprint({'version': 1, 'files': r.HASHES, 'stages': self.hashes})
        self.names = {int(k[:4]): k for k in files}
        self.locked = set()

    def begin(self):
        s = Session(self.lab)
        try:
            s.execute("BEGIN ISOLATION LEVEL READ COMMITTED; SET LOCAL statement_timeout='5s'; SET LOCAL lock_timeout='250ms';")
            if s.execute(f'SELECT pg_try_advisory_xact_lock({LOCK});') != 't':
                raise GateError('MIGRATION_BUSY')
            self.locked.add(s)
            return s
        except BaseException:
            s.close()
            raise

    def history(self, s):
        exists = s.execute(f"SELECT to_regnamespace('{CONTROL}') IS NOT NULL;") == 't'
        if not exists:
            return False, []
        if s.catalog(CONTROL) != self.control_contract:
            raise GateError('HISTORY_STRUCTURE_OR_PRIVILEGE_DRIFT')
        rows = json.loads(s.execute(f"SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY ordinal),'[]'::jsonb)::text FROM {CONTROL}.history h;"))
        return True, rows

    def validate_rows(self, rows):
        if not isinstance(rows, list) or len(rows) > 5:
            raise GateError('HISTORY_PREFIX_INVALID')
        for ordinal, row in enumerate(rows, 3):
            expected = {'ordinal': ordinal, 'filename': self.names[ordinal],
                        'file_sha256': r.HASHES[self.names[ordinal]], 'plan_sha256': self.plan_sha,
                        'before_sha256': self.hashes[ordinal-1], 'after_sha256': self.hashes[ordinal]}
            if not isinstance(row, dict) or any(row.get(k) != v for k, v in expected.items()):
                raise GateError('HISTORY_PREFIX_OR_CHECKSUM_MISMATCH')
            if set(row) != set(expected) | {'run_id', 'recorded_at'}:
                raise GateError('HISTORY_RECORD_SHAPE_INVALID')
            try:
                uuid.UUID(row['run_id'])
                r.check(bool(row['recorded_at']), 'missing receipt time')
            except (ValueError, TypeError, AssertionError):
                raise GateError('HISTORY_RECORD_SHAPE_INVALID') from None
        return 2 + len(rows)

    def verify(self, s):
        if s not in self.locked or s.execute("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid() AND granted AND classid=110011 AND objid=7 AND objsubid=2) AND current_setting('transaction_isolation')='read committed';") != 't':
            raise GateError('LOCKED_TRANSACTION_REQUIRED')
        exists, rows = self.history(s)
        tip = self.validate_rows(rows)
        if s.catalog() != self.expected[tip]:
            raise GateError('SCHEMA_HISTORY_MISMATCH' if exists else 'HISTORY_ABSENT_SCHEMA_NOT_BASELINE')
        if tip >= 6 and s.execute('SELECT count(*)=1 AND bool_and(NOT enabled) FROM public.marketroute_aws_v0_inference_scopes;') != 't':
            raise GateError('MODEL_ADMISSION_NOT_DISABLED')
        if tip >= 7 and s.execute('SELECT count(*)=1 AND bool_and(NOT enabled) FROM public.marketroute_aws_v0_recovery_control;') != 't':
            raise GateError('RECOVERY_NOT_DISABLED')
        return tip, exists, rows

    def inspect(self):
        s = self.begin()
        try:
            tip, _, rows = self.verify(s)
            s.execute('ROLLBACK;')
            return {'tip': tip, 'next': tip+1 if tip < 7 else None, 'records': rows}
        finally:
            self.locked.discard(s)
            s.close()

    def stage(self, ordinal):
        # Validate original bytes BEFORE a database write. Source files never change.
        if ordinal not in range(3, 8):
            raise GateError('MIGRATION_NOT_IN_PLAN')
        name = self.names[ordinal]
        if r.digest(self.files[name]) != r.HASHES[name]:
            raise GateError('SOURCE_CHECKSUM_MISMATCH')
        s = self.begin()
        try:
            tip, exists, _ = self.verify(s)
            if ordinal <= tip:
                s.execute('ROLLBACK;')
                self.locked.discard(s)
                s.close()
                return None  # ALREADY_APPLIED only after checking the latest state.
            if ordinal != tip+1:
                raise GateError('MIGRATION_PREDECESSOR_MISSING')
            if not exists:
                s.execute(BOOTSTRAP)
                if s.catalog(CONTROL) != self.control_contract:
                    raise GateError('HISTORY_BOOTSTRAP_MISMATCH')
            # Native psql processes whole function bodies. Only the exact pinned
            # outer BEGIN/COMMIT are removed, never a general semicolon split.
            body = re.sub(r'^BEGIN;\s*', '', r.migration_prefix(self.files[name]), count=1, flags=re.M)
            s.execute(body)
            if s.catalog() != self.expected[ordinal]:
                raise GateError('MIGRATION_POSTCONDITION_MISMATCH')
            record = {'ordinal': ordinal, 'filename': name, 'file_sha256': r.HASHES[name],
                      'plan_sha256': self.plan_sha, 'before_sha256': self.hashes[tip],
                      'after_sha256': self.hashes[ordinal], 'run_id': str(uuid.uuid4())}
            encoded = canonical(record).replace("'", "''")
            s.execute(f"INSERT INTO {CONTROL}.history(ordinal,filename,file_sha256,plan_sha256,before_sha256,after_sha256,run_id) "
                      f"SELECT ordinal,filename,file_sha256,plan_sha256,before_sha256,after_sha256,run_id "
                      f"FROM jsonb_populate_record(NULL::{CONTROL}.history, '{encoded}'::jsonb);")
            self.verify(s)  # Receipt + latest catalogue agree before COMMIT.
            return s
        except BaseException:
            self.locked.discard(s)
            s.close()
            raise

    def end(self, s, commit=False):
        try:
            if commit:
                s.execute('COMMIT;')
        finally:
            self.locked.discard(s)
            s.close()

    def apply(self, ordinal):
        s = self.stage(ordinal)
        if s is None:
            return 'ALREADY_APPLIED'
        self.end(s, commit=True)
        return 'APPLIED'


def exercise(lab, files, receipt):
    def passed(name, **details):
        receipt['checks'].append({'name': name, 'status': 'PASS', **details})
        print('PASS', name, flush=True)

    def rejects(fn, code):
        try:
            fn()
        except (GateError, RuntimeError) as exc:
            r.check(code in str(exc), f'expected {code}, received {exc}')
        else:
            raise AssertionError('expected rejection: ' + code)

    receipt['serverVersion'] = lab.value('SHOW server_version;')
    r.check(lab.value('SHOW server_version_num;').startswith('16'), 'PostgreSQL 16 required')
    for name in list(r.HASHES)[:2]:
        lab.sql(files[name])
    r.seed(lab)
    baseline_names, baseline_rows = lab.names(), lab.rows()
    lab.sql(f'CREATE DATABASE {REFERENCE_DB} WITH TEMPLATE {DB};')
    reference = r.Lab(lab.container)
    reference.cmd = [REFERENCE_DB if x == DB else x for x in reference.cmd]
    # Observe a separate reference using ORIGINAL SQL, not protocol-generated DDL.
    with Session(reference) as s:
        expected = {2: s.catalog()}
        for name in list(r.HASHES)[2:]:
            s.execute(files[name])
            expected[int(name[:4])] = s.catalog()
        s.execute(BOOTSTRAP)
        control_contract = s.catalog(CONTROL)
    protocol = LabProtocol(lab, files, expected, control_contract)
    passed('reference stages observed from unchanged SQL in a separate offline database')
    r.check(protocol.inspect()['tip'] == 2, 'expected empty history and baseline')
    passed('baseline without history is recognized, not recorded as a completed migration')
    name = protocol.names[3]
    bad = dict(files, **{name: files[name]+'\n-- changed bytes\n'})
    rejects(lambda: LabProtocol(lab,bad,expected,control_contract).apply(3), 'SOURCE_CHECKSUM_MISMATCH')
    passed('changed migration bytes are rejected before any database write')
    rejects(lambda: protocol.apply(4), 'MIGRATION_PREDECESSOR_MISSING')
    r.check(protocol.inspect()['tip'] == 2, 'out-of-order request changed baseline')
    passed('out-of-order migration is rejected before executing its body')
    wrong_expected = copy.deepcopy(expected)
    wrong_expected[3]['routines'][0]['definitionMd5'] = 'f'*32
    rejects(lambda: LabProtocol(lab,files,wrong_expected,control_contract).apply(3), 'MIGRATION_POSTCONDITION_MISMATCH')
    r.check(protocol.inspect()['tip'] == 2, 'failed postcondition left applied schema')
    passed('failed postcondition rolls back both new schema and ledger bootstrap')

    def state():
        return {'public': lab.state(), 'history': protocol.inspect()}

    for ordinal in range(3, 8):
        before = state()
        for fault in ('statement_error', 'statement_timeout', 'disconnect_before_commit'):
            s = protocol.stage(ordinal)
            try:
                if fault == 'statement_error':
                    rejects(lambda: s.execute('SELECT 1/0;'), 'division by zero')
                elif fault == 'statement_timeout':
                    rejects(lambda: s.execute("SET LOCAL statement_timeout='25ms'; SELECT pg_sleep(1);"), 'statement timeout')
            finally:
                protocol.end(s)
            r.check(state() == before, f'{ordinal} {fault} changed schema, data or history')
            passed(f'{ordinal:04d} {fault}: migration and receipt roll back together')
        s = protocol.stage(ordinal)
        try:
            rejects(protocol.inspect, 'MIGRATION_BUSY')
            rejects(lambda: protocol.apply(ordinal), 'MIGRATION_BUSY')
            passed(f'{ordinal:04d} in-flight commit cannot be mistaken for absent history or raced by another coordinator')
            # Deliberately discard the client's successful commit acknowledgement.
            # This exercises reconciliation from a new connection, NOT a real
            # AWS lost response or a network partition.
            s.execute('COMMIT;')
            rejects(lambda: protocol.verify(s), 'LOCKED_TRANSACTION_REQUIRED')
        finally:
            protocol.end(s)
        fresh = LabProtocol(lab, files, expected, control_contract)
        r.check(fresh.inspect()['tip'] == ordinal, 'committed receipt not recovered')
        r.check(fresh.apply(ordinal) == 'ALREADY_APPLIED', 'committed file executed twice')
        r.check(lab.rows(baseline_names) == baseline_rows, 'baseline rows changed')
        r.check(len(fresh.inspect()['records']) == ordinal-2, 'duplicate history rows')
        passed(f'{ordinal:04d} discarded commit acknowledgement reconciles without re-execution or row changes')

    final = state()
    r.check(protocol.apply(5) == 'ALREADY_APPLIED', 'old repair executed after latest migration')
    r.check(state() == final, 'old repair downgraded recovery guard')
    passed('0005 after 0007 is skipped with the latest catalogue intact, not replayed')
    passed('completed transaction cannot reuse a process-local lock claim; backend lock possession is checked')
    rows = protocol.inspect()['records']
    for label, changed in (
        ('history gap', rows[:1]+rows[2:]),
        ('history reordering', [rows[1],rows[0]]+rows[2:]),
        ('changed file checksum', [dict(rows[0],file_sha256='0'*64)]+rows[1:]),
        ('changed plan fingerprint', [dict(rows[0],plan_sha256='1'*64)]+rows[1:]),
        ('changed predecessor state', [dict(rows[0],before_sha256='2'*64)]+rows[1:]),
        ('changed postcondition', [dict(rows[0],after_sha256='3'*64)]+rows[1:]),
        ('extra unknown migration', rows+[dict(rows[-1],ordinal=8)]),
    ):
        rejects(lambda v=changed: protocol.validate_rows(v), 'HISTORY_PREFIX')
        passed('history validator rejects '+label, scope='IN_MEMORY_PERTURBATION_OF_ACTUAL_DATABASE_RECEIPTS')

    for sql in (f'UPDATE {CONTROL}.history SET filename=filename;',
                f'DELETE FROM {CONTROL}.history;', f'TRUNCATE {CONTROL}.history;'):
        rejects(lambda q=sql: lab.sql(q), 'IMMUTABLE_MIGRATION_HISTORY')
    r.check(state() == final, 'append-only history changed')
    passed('database rejects updates, deletes and truncation of migration history')
    lab.sql('CREATE ROLE build11_ledger_reader;')
    rejects(lambda: lab.sql(f'SET ROLE build11_ledger_reader; SELECT * FROM {CONTROL}.history;'), 'permission denied')
    rejects(lambda: lab.sql(f'SET ROLE build11_ledger_reader; INSERT INTO {CONTROL}.history DEFAULT VALUES;'), 'permission denied')
    lab.sql('DROP ROLE build11_ledger_reader;')
    passed('untrusted database role cannot read or write the private history schema')

    def transaction_fault(sql, code):
        s = protocol.begin()
        try:
            s.execute(sql)
            rejects(lambda: protocol.verify(s), code)
        finally:
            protocol.end(s)
        r.check(state() == final, 'fault probe escaped rollback')

    transaction_fault(re.sub(r'^BEGIN;\s*','',r.migration_prefix(files[protocol.names[5]]),count=1,flags=re.M), 'SCHEMA_HISTORY_MISMATCH')
    passed('history alone cannot hide a downgraded claim routine')
    transaction_fault(f'ALTER TABLE {CONTROL}.history DISABLE TRIGGER history_no_update_delete;', 'HISTORY_STRUCTURE_OR_PRIVILEGE_DRIFT')
    passed('disabled history protection is detected before a resume decision')
    transaction_fault('UPDATE public.marketroute_aws_v0_inference_scopes SET enabled=true;', 'MODEL_ADMISSION_NOT_DISABLED')
    transaction_fault('UPDATE public.marketroute_aws_v0_recovery_control SET enabled=true;', 'RECOVERY_NOT_DISABLED')
    passed('enabled admission or recovery prevents resume even when schema fingerprints match')
    # A different test database with completed schema but no ledger must not be
    # backfilled from table names or from an old process-local success flag.
    reference.sql(f'DROP SCHEMA {CONTROL} CASCADE;')
    rejects(lambda: LabProtocol(reference,files,expected,control_contract).inspect(), 'HISTORY_ABSENT_SCHEMA_NOT_BASELINE')
    passed('schema installed without transaction-coupled history stops for review; no automatic backfill')
    r.check(lab.rows(['marketroute_schema_releases']) == {'marketroute_schema_releases':baseline_rows['marketroute_schema_releases']}, 'original release history was changed')
    r.check(lab.rows(baseline_names) == baseline_rows, 'original public rows changed')
    passed('all 78 baseline table rows and existing schema-release history are preserved')
    receipt.update({'planSha256':protocol.plan_sha,'stageCatalogSha256':protocol.hashes,
                    'committedReceiptCount':len(rows),'baselineTableCount':len(baseline_names),
                    'historySchema':CONTROL,'allBaselineRowsPreserved':True,
                    'inMemoryHistoryNegativeCases':7,'controlsRemainDisabled':True})


def main():
    r.check(len(sys.argv)==1, 'This offline test accepts no arguments or live-database target')
    files = {}
    for name, expected in r.HASHES.items():
        raw = (ROOT/'database/aws'/name).read_bytes()
        r.check(r.digest(raw)==expected, 'source checksum changed: '+name)
        files[name] = raw.decode()
    out = Path(tempfile.mkdtemp(prefix='build11-migration-ledger-'))
    receipt = {'schemaVersion':1,'mode':'DISPOSABLE_NATIVE_POSTGRESQL_PROTOCOL_ONLY',
               'status':'RUNNING','checks':[],'migrationSha256':r.HASHES,
               'liveAwsCalls':0,'liveDatabaseMutations':0,'liveMigrationRunner':'NOT_PROVIDED_OR_TESTED',
               'productionActivation':'BLOCKED','snapshotRestore':'NOT_TESTED',
               'commitResponseTest':'CLIENT_ACK_DISCARDED_AFTER_REAL_LOCAL_COMMIT_NOT_AWS_NETWORK_FAULT'}
    container = None
    try:
        receipt['testedGitCommit'] = r.run(['git','-C',str(ROOT),'rev-parse','HEAD']).stdout.strip()
        container = r.run(['docker','run','--detach','--network','none','--memory','768m',
            '--tmpfs','/var/lib/postgresql/data:rw,size=512m','--label','marketroute.build11.ledger-test=true',
            '-e','POSTGRES_PASSWORD=disposable-ledger-test-only','-e','POSTGRES_DB='+DB,r.IMAGE]).stdout.strip()
        r.check(re.fullmatch(r'[a-f0-9]{64}',container) is not None, 'invalid owned container ID')
        meta = json.loads(r.run(['docker','inspect',container]).stdout)[0]
        r.check(meta['HostConfig']['NetworkMode']=='none' and not meta['HostConfig'].get('PortBindings'), 'test isolation failure')
        receipt.update(networkMode='none', postgresImageId=meta['Image'])
        lab = r.Lab(container)
        for _ in range(40):
            process = r.run(['docker','exec',container,'cat','/proc/1/comm'],must_succeed=False)
            if process.returncode==0 and process.stdout.strip()=='postgres':
                ready = lab.sql('SELECT current_database();',ok=False)
                if ready.returncode==0 and ready.stdout.strip()==DB:
                    break
            time.sleep(0.5)
        else:
            raise RuntimeError('disposable PostgreSQL failed to start')
        exercise(lab, files, receipt)
        receipt['status'] = 'PASS'
    except BaseException as exc:
        receipt['status'], receipt['failure'] = 'FAIL', str(exc)
        raise
    finally:
        if container and re.fullmatch(r'[a-f0-9]{64}',container):
            receipt['ownedContainerRemoved'] = r.run(['docker','rm','--force',container],must_succeed=False).returncode==0
        receipt['assertionGroups'] = len(receipt['checks'])
        path = out/'receipt.json'
        path.write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
        (out/'SHA256SUMS').write_text(r.digest(path.read_bytes())+'  receipt.json\n')
        print('Ledger protocol receipt:',path,flush=True)
        print(f"{len(receipt['checks'])} ledger protocol groups; status={receipt['status']}; no live execution",flush=True)


if __name__=='__main__':
    main()
