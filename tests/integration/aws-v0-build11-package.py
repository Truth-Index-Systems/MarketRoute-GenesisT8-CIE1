"""Verify reproducibility/tamper rejection; run the exact extracted ZIP in isolation.

The child uses real pinned AWS SDKs and replaces only their HTTP handler. It cannot
reach an AWS endpoint. A disposable PostgreSQL service is used when CI provides it.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
IAC = ROOT / 'infrastructure/aws-v0'
BUILDER = IAC / 'scripts/package-research-worker.py'
ARTIFACTS = IAC / 'artifacts'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-rebuild', action='store_true', help='Verify a retained artifact on another architecture')
args = parser.parse_args()


def run(command, **kw):
    return subprocess.run(command, check=True, timeout=240, **kw)


def snapshot():
    return {name: hashlib.sha256((ARTIFACTS / name).read_bytes()).hexdigest()
            for name in ('research-worker.zip', 'research-worker.manifest.json')}


if not args.skip_rebuild:
    run(['python3', str(BUILDER), 'build'])
    first = snapshot()
    run(['python3', str(BUILDER), 'build'])
    assert snapshot() == first, 'Separate clean npm installs must produce identical ZIP and manifest bytes'
    print('PASS two clean dependency installations produce byte-identical ZIP and manifest', flush=True)
run(['python3', str(BUILDER), 'verify'])
manifest = json.loads((ARTIFACTS / 'research-worker.manifest.json').read_text())
count = 0


def passed(name):
    global count
    count += 1
    print('PASS', name, flush=True)


with tempfile.TemporaryDirectory(prefix='build11-package-proof-') as tmp:
    temp = Path(tmp)
    isolated_iac = temp / 'isolated-infrastructure'
    (isolated_iac / 'scripts').mkdir(parents=True)
    shutil.copyfile(BUILDER, isolated_iac / 'scripts' / BUILDER.name)
    shutil.copytree(IAC / 'runtime/research-worker', isolated_iac / 'runtime/research-worker')
    shutil.copytree(ARTIFACTS, isolated_iac / 'artifacts')
    verify_command = ['python3', str(isolated_iac / 'scripts' / BUILDER.name), 'verify']
    run(verify_command, stdout=subprocess.DEVNULL)
    passed('artifact verifies independently of repository location')

    def reject_change(path, content, expected):
        original = path.read_bytes()
        try:
            path.write_bytes(content)
            p = subprocess.run(verify_command, capture_output=True, text=True, timeout=30)
            assert p.returncode != 0 and expected in p.stderr, (p.stdout, p.stderr)
        finally:
            path.write_bytes(original)

    entry = isolated_iac / 'runtime/research-worker/index.mjs'
    reject_change(entry, entry.read_bytes() + b'\n// unbuilt change\n', 'STALE_SOURCE_OR_LOCK')
    passed('stale runtime source is rejected')
    lock = isolated_iac / 'runtime/research-worker/package-lock.json'
    reject_change(lock, lock.read_bytes() + b'\n', 'STALE_SOURCE_OR_LOCK')
    passed('stale lockfile is rejected')
    archive = isolated_iac / 'artifacts/research-worker.zip'
    reject_change(archive, archive.read_bytes()[:-1] + bytes([archive.read_bytes()[-1] ^ 1]), 'ARCHIVE_DIGEST_OR_SIZE')
    passed('altered deployment ZIP is rejected')
    archive.rename(archive.with_suffix('.hidden'))
    try:
        p = subprocess.run(verify_command, capture_output=True, text=True, timeout=30)
        assert p.returncode != 0 and 'MISSING_RUN_PACKAGE_RESEARCH' in p.stderr
    finally:
        archive.with_suffix('.hidden').rename(archive)
    passed('missing artifact cannot fall back to source-only packaging')

    task = temp / 'lambda-task'
    with zipfile.ZipFile(ARTIFACTS / 'research-worker.zip') as z:
        assert 'index.mjs' in z.namelist() and 'node_modules/@aws-sdk/client-bedrock-runtime/package.json' in z.namelist()
        assert not any(n.startswith(('app/', 'tests/', '.git/', '.env')) for n in z.namelist())
        z.extractall(task)  # Paths and entry types were validated above.
    passed('isolated task contains handler and locked SDKs, but no app/test/secret files')
    env = {k: os.environ[k] for k in ('PATH', 'BUILD11_POSTGRES_CONTAINER') if k in os.environ}
    env.update({'HOME': str(temp), 'BUILD11_TASK_DIR': str(task), 'NODE_PATH': '',
                'AWS_EC2_METADATA_DISABLED': 'true', 'AWS_CONFIG_FILE': '/dev/null',
                'AWS_SHARED_CREDENTIALS_FILE': '/dev/null'})
    p = subprocess.run(['node', str(ROOT / 'tests/integration/aws-v0-build11-package-wire.mjs')],
                       cwd=temp, env=env, check=False, capture_output=True, text=True, timeout=180)
    print(p.stdout, end='', flush=True)
    if p.stderr:
        print(p.stderr, end='', flush=True)
    p.check_returncode()  # Preserve the wire assertion output when a test fails.
    report_line = next(line for line in p.stdout.splitlines() if line.startswith('PACKAGE_PROOF_JSON='))
    wire = json.loads(report_line.split('=', 1)[1])
    assert wire['archiveSourceVerified'] and wire['liveAwsCalls'] == 0

receipt = {'schemaVersion': 1, 'archiveSha256': manifest['archiveSha256'],
           'inputSha256': manifest['inputSha256'], 'machine': platform.machine(),
           'testedCommit': os.environ.get('GITHUB_SHA'), 'packagingAssertionGroups': count,
           'cleanDoubleBuild': not args.skip_rebuild, **wire}
(ARTIFACTS / ('research-worker.proof-' + wire['architecture'] + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
print(f'{count}/{count} artifact integrity groups passed; source/lock changes require a rebuild', flush=True)
