#!/usr/bin/env python3
"""Build/verify an isolated, deterministic Node.js 22 Lambda ZIP. Never deploys.

Requires Node 22, npm, Python 3.10+. npm ci verifies the committed lock's integrity;
no lifecycle scripts, development packages, native modules or symlinks are allowed.
A checked manifest binds runtime source, the lock, build script and ZIP bytes.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'runtime/research-worker'
OUTPUT = ROOT / 'artifacts'
ZIP_NAME = 'research-worker.zip'
MANIFEST_NAME = 'research-worker.manifest.json'
RUNTIME_FILES = ('admission-ledger.mjs', 'admitted-executor.mjs', 'executor.mjs',
                 'index.mjs', 'prepared-provider.mjs', 'request-contract.mjs',
                 'package.json', 'package-lock.json')
SDK_PINS = {'@aws-sdk/client-bedrock-runtime': '3.1111.0',
            '@aws-sdk/client-rds-data': '3.1114.0'}
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
MAX_BYTES = 48 * 1024 * 1024  # Deliberately tighter than Lambda's unzipped limit.


def fail(message):
    raise ValueError('MARKETROUTE_BUILD11_PACKAGE_' + message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def serial(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def input_snapshot():
    actual = {p.name for p in SOURCE.iterdir() if p.is_file()}
    # A new runtime module must be explicitly added to the package allowlist.
    if actual != set(RUNTIME_FILES):
        fail('SOURCE_ALLOWLIST_MISMATCH:' + ','.join(sorted(actual ^ set(RUNTIME_FILES))))
    paths = [SOURCE / name for name in RUNTIME_FILES] + [Path(__file__).resolve()]
    if any(p.is_symlink() for p in paths):
        fail('SYMLINK_INPUT')
    return {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(paths)}


def check_lock():
    package = json.loads((SOURCE / 'package.json').read_text())
    lock = json.loads((SOURCE / 'package-lock.json').read_text())
    if package.get('dependencies') != SDK_PINS or package.get('engines') != {'node': '22.x'}:
        fail('DIRECT_DEPENDENCY_OR_RUNTIME_DRIFT')
    if package.get('scripts') or package.get('devDependencies') or package.get('optionalDependencies'):
        fail('UNEXPECTED_PACKAGE_OPTIONS')
    if lock.get('lockfileVersion') != 3 or lock['packages'][''].get('dependencies') != SDK_PINS:
        fail('LOCK_ROOT_MISMATCH')
    for name, version in SDK_PINS.items():
        if lock['packages'].get('node_modules/' + name, {}).get('version') != version:
            fail('SDK_LOCK_VERSION')
    for path, entry in lock['packages'].items():
        if not path:
            continue
        if (not path.startswith('node_modules/') or '..' in PurePosixPath(path).parts
                or not re.fullmatch(r'\d+\.\d+\.\d+', entry.get('version', ''))
                or not entry.get('resolved', '').startswith('https://registry.npmjs.org/')
                or not entry.get('integrity', '').startswith('sha512-')
                or any(entry.get(k) for k in ('dev', 'link', 'hasInstallScript', 'os', 'cpu'))):
            fail('UNSAFE_LOCK_ENTRY:' + path)
    return lock


def validate_path(name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or str(path) != name:
        fail('ARCHIVE_PATH')
    if name not in RUNTIME_FILES and not name.startswith('node_modules/'):
        fail('ARCHIVE_ALLOWLIST:' + name)
    if path.name in ('.env', '.npmrc', '.DS_Store') or path.name.startswith('.env.'):
        fail('SECRET_OR_LOCAL_FILE')
    if path.suffix.lower() in ('.node', '.so', '.dll', '.dylib', '.exe', '.wasm'):
        fail('NATIVE_OR_BINARY_DEPENDENCY:' + name)


def build():
    lock = check_lock()
    inputs = input_snapshot()
    node = subprocess.check_output(['node', '--version'], text=True).strip()
    if not node.startswith('v22.'):
        fail('NODE22_REQUIRED')
    OUTPUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='marketroute-build11-package-') as temporary:
        stage = Path(temporary) / 'task'
        stage.mkdir()
        for name in RUNTIME_FILES:
            shutil.copyfile(SOURCE / name, stage / name)
        before_lock = (stage / 'package-lock.json').read_bytes()
        # Install in isolation: nothing in the application's node_modules can leak in.
        env = dict(os.environ, npm_config_update_notifier='false', npm_config_fund='false',
                   npm_config_audit='false', npm_config_ignore_scripts='true')
        subprocess.run(['npm', 'ci', '--omit=dev', '--ignore-scripts', '--no-bin-links',
                        '--no-audit', '--no-fund'], cwd=stage, env=env, check=True, timeout=180)
        if (stage / 'package-lock.json').read_bytes() != before_lock:
            fail('NPM_MUTATED_LOCK')
        (stage / 'node_modules/.package-lock.json').unlink(missing_ok=True)
        # Reject any installation not matching the committed package graph.
        installed = {str(p.parent.relative_to(stage)) for p in stage.glob('node_modules/**/package.json')
                     if re.search(r'(?:^|/)node_modules/(?:@[^/]+/)?[^/]+/package\.json$',
                                  str(p.relative_to(stage)))}
        expected = set(lock['packages']) - {''}
        if installed != expected:
            fail('INSTALLED_GRAPH_MISMATCH')
        for path in sorted(expected):
            p = json.loads((stage / path / 'package.json').read_text())
            if p.get('version') != lock['packages'][path]['version']:
                fail('INSTALLED_VERSION:' + path)
        files = {}
        with zipfile.ZipFile(OUTPUT / (ZIP_NAME + '.tmp'), 'w', compression=zipfile.ZIP_STORED) as archive:
            # Sort archive names, not Path components (foo.js must precede foo/bar.js).
            for path in sorted(stage.rglob('*'), key=lambda p: p.relative_to(stage).as_posix()):
                if path.is_symlink():
                    fail('SYMLINK_DEPENDENCY')
                if path.is_dir():
                    continue
                if not path.is_file():
                    fail('NON_REGULAR_FILE')
                name = path.relative_to(stage).as_posix()
                validate_path(name)
                data = path.read_bytes()
                files[name] = {'sha256': digest(data), 'bytes': len(data)}
                info = zipfile.ZipInfo(name, FIXED_TIME)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, data)
        archive_path = OUTPUT / (ZIP_NAME + '.tmp')
        if archive_path.stat().st_size > MAX_BYTES:
            fail('SIZE_LIMIT')
        if input_snapshot() != inputs:
            fail('SOURCE_CHANGED_DURING_BUILD')
        manifest = {'schemaVersion': 1, 'handler': 'index.handler', 'runtime': 'nodejs22.x',
                    'targetArchitecture': 'arm64', 'archiveFormat': 'ZIP_STORED_FIXED_METADATA',
                    'dependencies': SDK_PINS, 'inputs': inputs,
                    'inputSha256': digest(serial(inputs)),
                    'archiveSha256': digest(archive_path.read_bytes()),
                    'archiveBytes': archive_path.stat().st_size, 'files': files}
        archive_path.replace(OUTPUT / ZIP_NAME)
        (OUTPUT / MANIFEST_NAME).write_bytes(serial(manifest))
    return verify()


def verify():
    lock = check_lock()
    path = OUTPUT / ZIP_NAME
    manifest_path = OUTPUT / MANIFEST_NAME
    if not path.is_file() or not manifest_path.is_file():
        fail('MISSING_RUN_PACKAGE_RESEARCH')
    if path.is_symlink() or manifest_path.is_symlink():
        fail('SYMLINK_ARTIFACT')
    manifest = json.loads(manifest_path.read_text())
    inputs = input_snapshot()
    if manifest.get('inputs') != inputs or manifest.get('inputSha256') != digest(serial(inputs)):
        fail('STALE_SOURCE_OR_LOCK')
    for key, value in {'schemaVersion': 1, 'handler': 'index.handler', 'runtime': 'nodejs22.x',
                       'targetArchitecture': 'arm64', 'dependencies': SDK_PINS,
                       'archiveFormat': 'ZIP_STORED_FIXED_METADATA'}.items():
        if manifest.get(key) != value:
            fail('MANIFEST_CONTRACT:' + key)
    data = path.read_bytes()
    if len(data) > MAX_BYTES or len(data) != manifest.get('archiveBytes') or digest(data) != manifest.get('archiveSha256'):
        fail('ARCHIVE_DIGEST_OR_SIZE')
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [i.filename for i in infos]
        if names != sorted(set(names)) or set(names) != set(manifest['files']):
            fail('ARCHIVE_INVENTORY')
        if not set(RUNTIME_FILES).issubset(names):
            fail('MISSING_HANDLER_OR_SOURCE')
        if sum(i.file_size for i in infos) > MAX_BYTES:
            fail('UNCOMPRESSED_SIZE_LIMIT')
        for i in infos:
            validate_path(i.filename)
            if (i.date_time != FIXED_TIME or i.compress_type != zipfile.ZIP_STORED
                    or i.external_attr >> 16 != (stat.S_IFREG | 0o644) or i.extra or i.comment):
                fail('NONDETERMINISTIC_OR_UNSAFE_ENTRY')
            body = archive.read(i.filename)
            if manifest['files'][i.filename] != {'bytes': len(body), 'sha256': digest(body)}:
                fail('FILE_DIGEST:' + i.filename)
            if i.filename in RUNTIME_FILES and digest(body) != inputs['runtime/research-worker/' + i.filename]:
                fail('PACKAGED_SOURCE_MISMATCH')
        for package_path, entry in lock['packages'].items():
            if package_path and json.loads(archive.read(package_path + '/package.json'))['version'] != entry['version']:
                fail('PACKAGED_DEPENDENCY_VERSION')
    return {'archive': str(path), 'archiveSha256': manifest['archiveSha256'],
            'inputSha256': manifest['inputSha256'], 'files': len(manifest['files']),
            'archiveBytes': len(data)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['build', 'verify'])
    args = parser.parse_args()
    try:
        print(json.dumps(build() if args.mode == 'build' else verify(), sort_keys=True))
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
