"""Closed Build 11 migration contract. Not a general SQL execution interface."""
import hashlib
import json
import re
from pathlib import Path

ACCOUNT = '801132668416'
REGION = 'eu-west-2'
DATABASE = 'marketroute'
DB_ROLE = 'marketroute_admin'
CLUSTER = f'arn:aws:rds:{REGION}:{ACCOUNT}:cluster:marketroute-aws-v0'
HISTORY = 'marketroute_migration_control'
LOCK_NAMESPACE, LOCK_KEY = 110011, 7
FORMAT = 'MR-BUILD11-MIGRATION-PLAN-1'
HASHES = {
    '0003_marketroute_aws_build9_research_execution.sql': '5008514cc7a2caa4d07221a067ef4251fec5c89802c048955330c4bf05133800',
    '0004_marketroute_aws_build10_research_orchestration.sql': 'ab060054228bc056b79cb857817bc84e61d185b595d968611e28b556b4aa58cb',
    '0005_marketroute_aws_build11_terminal_replay.sql': '32f3e11b0cc1171bc0e068fbfe24f70f39fe7cbf98b37131283542f530e32ed2',
    '0006_marketroute_aws_build11_inference_admission.sql': '3f11ea6dc909dd0896e5aca703e6033b8ac1e4e65af61e27dce42fc1100ef7f3',
    '0007_marketroute_aws_build11_recovery.sql': 'ca2b19022dd4cfa1866802c4fd88fdb97a48e8f6f0265312c231163719258b8c',
}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def sha(value):
    return hashlib.sha256(value if isinstance(value, bytes) else value.encode()).hexdigest()


def fingerprint(value):
    return sha(canonical(value))


class GateError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise GateError(code)


def split_sql(text):
    """Build-time lexical segmentation; execution separately requires pinned bytes.

    Semicolons inside quoted strings, identifiers, dollar bodies and comments are
    not separators. This is not a PostgreSQL grammar validator or a security parser.
    PostgreSQL independently parses every resulting statement during CI rehearsal.
    """
    require(isinstance(text, str) and '\x00' not in text, 'SQL_TEXT_INVALID')
    out = []; start = i = 0; state = None; depth = 0; tag = None; escaped = False
    while i < len(text):
        c = text[i]; nxt = text[i:i+2]
        if state == 'line':
            if c == '\n': state = None
        elif state == 'block':
            if nxt == '/*': depth += 1; i += 1
            elif nxt == '*/':
                depth -= 1; i += 1
                if depth == 0: state = None
        elif state in ('single', 'double'):
            quote = "'" if state == 'single' else '"'
            if state == 'single' and escaped and c == '\\': i += 1
            elif c == quote:
                if i+1 < len(text) and text[i+1] == quote: i += 1
                else: state = None
        elif state == 'dollar':
            if text.startswith(tag, i): i += len(tag)-1; state = None
        elif nxt == '--': state = 'line'; i += 1
        elif nxt == '/*': state = 'block'; depth = 1; i += 1
        elif c in ("'", '"'):
            escaped = c == "'" and i > 0 and text[i-1] in 'Ee' and (i < 2 or not (text[i-2].isalnum() or text[i-2] == '_'))
            state = 'single' if c == "'" else 'double'
        elif c == '$':
            match = re.match(r'\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$', text[i:])
            if match: tag = match.group(0); state = 'dollar'; i += len(tag)-1
        elif c == ';':
            out.append(text[start:i+1]); start = i+1
        i += 1
    require(state in (None, 'line'), 'SQL_UNTERMINATED_TOKEN')
    # Hash-pinned files end in COMMIT; no trailing executable content is allowed.
    require(not text[start:].strip(), 'SQL_TRAILING_CONTENT')
    return out


def leading_sql(stmt):
    s = stmt.lstrip()
    while s.startswith('--') or s.startswith('/*'):
        if s.startswith('--'):
            end = s.find('\n'); require(end >= 0, 'SQL_COMMENT_ONLY'); s = s[end+1:].lstrip()
        else:
            depth = 1; i = 2
            while depth and i < len(s):
                if s[i:i+2] == '/*': depth += 1; i += 2
                elif s[i:i+2] == '*/': depth -= 1; i += 2
                else: i += 1
            require(depth == 0, 'SQL_UNTERMINATED_COMMENT'); s = s[i:].lstrip()
    return s


def pinned_body(name, raw):
    require(name in HASHES and isinstance(raw, bytes) and sha(raw) == HASHES[name], 'MIGRATION_SOURCE_HASH_MISMATCH')
    text = raw.decode('utf-8'); parts = split_sql(text)
    require(len(parts) >= 3 and leading_sql(parts[0]) == 'BEGIN;' and leading_sql(parts[-1]) == 'COMMIT;', 'MIGRATION_BOUNDARY_MISMATCH')
    body = parts[1:-1]
    for stmt in body:
        require(len(stmt.encode()) < 60_000, 'MIGRATION_STATEMENT_TOO_LARGE')
        word = leading_sql(stmt).split(None, 1)[0].upper().rstrip(';')
        require(word in ('CREATE', 'ALTER', 'REVOKE', 'GRANT', 'INSERT', 'COMMENT', 'DO'), 'MIGRATION_STATEMENT_NOT_REVIEWED')
    return body


# Each result is small (one catalogue object fingerprint). This avoids returning
# the entire catalogue as one oversized Data API field. Object names and hashes
# are metadata, never customer row contents. Owners/ACLs remain part of the hash.
CATALOG_TEMPLATE = """WITH objects AS (
 SELECT 'table:'||c.relname AS object_key, jsonb_build_object(
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
    FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal),'[]'::jsonb)) AS value
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='SCHEMA_NAME' AND c.relkind='r'
 UNION ALL
 SELECT 'function:'||p.proname||'('||oidvectortypes(p.proargtypes)||')',
  jsonb_build_object('definitionMd5',md5(pg_get_functiondef(p.oid)),'acl',p.proacl::text,
    'owner',pg_get_userbyid(p.proowner),'definer',p.prosecdef,'settings',p.proconfig)
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='SCHEMA_NAME' AND p.prokind='f'
 UNION ALL
 SELECT 'namespace:SCHEMA_NAME',jsonb_build_object('owner',pg_get_userbyid(nspowner),'acl',nspacl::text)
 FROM pg_namespace WHERE nspname='SCHEMA_NAME'
) SELECT object_key,md5(value::text) AS object_md5 FROM objects ORDER BY object_key"""

BOOTSTRAP = [
    f'CREATE SCHEMA {HISTORY} AUTHORIZATION {DB_ROLE}',
    f'REVOKE ALL ON SCHEMA {HISTORY} FROM PUBLIC',
    f"""CREATE TABLE {HISTORY}.history (
 ordinal integer PRIMARY KEY CHECK (ordinal BETWEEN 3 AND 7),
 filename text NOT NULL UNIQUE,
 file_sha256 text NOT NULL CHECK (file_sha256 ~ '^[a-f0-9]{{64}}$'),
 plan_sha256 text NOT NULL CHECK (plan_sha256 ~ '^[a-f0-9]{{64}}$'),
 before_sha256 text NOT NULL CHECK (before_sha256 ~ '^[a-f0-9]{{64}}$'),
 after_sha256 text NOT NULL CHECK (after_sha256 ~ '^[a-f0-9]{{64}}$'),
 run_id uuid NOT NULL,
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
)""",
    f'REVOKE ALL ON TABLE {HISTORY}.history FROM PUBLIC',
    f"""CREATE FUNCTION {HISTORY}.reject_change() RETURNS trigger LANGUAGE plpgsql
SET search_path TO 'pg_catalog' AS $$ BEGIN RAISE EXCEPTION 'IMMUTABLE_MIGRATION_HISTORY'; END $$""",
    f'REVOKE ALL ON FUNCTION {HISTORY}.reject_change() FROM PUBLIC',
    f'CREATE TRIGGER history_no_update_delete BEFORE UPDATE OR DELETE ON {HISTORY}.history FOR EACH STATEMENT EXECUTE FUNCTION {HISTORY}.reject_change()',
    f'CREATE TRIGGER history_no_truncate BEFORE TRUNCATE ON {HISTORY}.history FOR EACH STATEMENT EXECUTE FUNCTION {HISTORY}.reject_change()',
]

SQL = {
    'isolation': 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED',
    'readOnly': 'SET TRANSACTION READ ONLY',
    'timeout': "SET LOCAL statement_timeout = '20s'",
    'lockTimeout': "SET LOCAL lock_timeout = '2s'",
    'identity': "SELECT current_database() AS database,current_user AS role,session_user AS session_role,current_setting('server_version') AS version,current_setting('transaction_isolation') AS isolation,current_setting('transaction_read_only') AS read_only",
    'lock': f'SELECT pg_try_advisory_xact_lock({LOCK_NAMESPACE},{LOCK_KEY}) AS acquired',
    'lockHeld': f"SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND pid=pg_backend_pid() AND granted AND classid={LOCK_NAMESPACE} AND objid={LOCK_KEY} AND objsubid=2) AS held",
    'catalog': CATALOG_TEMPLATE.replace('SCHEMA_NAME','public'),
    'historyCatalog': CATALOG_TEMPLATE.replace('SCHEMA_NAME',HISTORY),
    'history': f'SELECT ordinal,filename,file_sha256,plan_sha256,before_sha256,after_sha256,run_id::text,recorded_at::text FROM {HISTORY}.history ORDER BY ordinal',
    'insertReceipt': f"""INSERT INTO {HISTORY}.history(ordinal,filename,file_sha256,plan_sha256,before_sha256,after_sha256,run_id)
SELECT ordinal,filename,file_sha256,plan_sha256,before_sha256,after_sha256,run_id
FROM jsonb_populate_record(NULL::{HISTORY}.history,CAST(:receipt AS jsonb))""",
    'modelOff': 'SELECT count(*)=1 AND bool_and(NOT enabled) AS disabled FROM public.marketroute_aws_v0_inference_scopes',
    'recoveryOff': 'SELECT count(*)=1 AND bool_and(NOT enabled) AS disabled FROM public.marketroute_aws_v0_recovery_control',
    'busy': "SELECT EXISTS(SELECT 1 FROM public.background_jobs WHERE status IN ('RUNNING','RESERVED')) OR EXISTS(SELECT 1 FROM public.scheduler_leases WHERE expires_at > clock_timestamp()) AS busy",
    'maintenanceLock': 'LOCK TABLE public.background_jobs,public.scheduler_leases,public.research_work_units,public.research_budget_policies IN SHARE MODE NOWAIT',
    'ready': 'SELECT 1 AS ready',
}


def object_map(rows):
    require(isinstance(rows, list) and len(rows) < 2000, 'CATALOG_RESPONSE_INVALID')
    result = {}
    for row in rows:
        require(isinstance(row, dict) and set(row)=={'object_key','object_md5'}, 'CATALOG_ROW_INVALID')
        key, value = row['object_key'], row['object_md5']
        require(isinstance(key,str) and key not in result and isinstance(value,str) and re.fullmatch('[a-f0-9]{32}',value), 'CATALOG_ROW_INVALID')
        result[key] = value
    return result


class Package:
    def __init__(self, root):
        self.root = Path(root)
        self.bodies = {int(n[:4]): pinned_body(n,(self.root/'migrations'/n).read_bytes()) for n in HASHES}
        self.names = {int(n[:4]):n for n in HASHES}
        reference = json.loads((self.root/'reference.json').read_text())
        require(reference.get('format')==FORMAT and reference.get('migrationSha256')==HASHES, 'REFERENCE_IDENTITY_MISMATCH')
        self.expected = reference['stages']; self.history_contract = reference['historyContract']
        require(set(self.expected)==set(map(str,range(2,8))), 'REFERENCE_STAGES_INVALID')
        require(all(isinstance(v,dict) and len(v)>78 for v in self.expected.values()), 'REFERENCE_CATALOG_INVALID')
        self.hashes = {k:fingerprint(v) for k,v in self.expected.items()}
        self.plan_sha = fingerprint({'format':FORMAT,'files':HASHES,'stages':self.hashes,'historyContract':self.history_contract})
        require(reference.get('planSha256')==self.plan_sha, 'REFERENCE_PLAN_HASH_MISMATCH')
        self.allowed_sql = set(SQL.values()) | set(BOOTSTRAP) | {s for group in self.bodies.values() for s in group}
