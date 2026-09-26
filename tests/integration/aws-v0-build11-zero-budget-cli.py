#!/usr/bin/env python3
"""Real AWS CLI parsing against loopback only; no AWS endpoint or credentials.

Cloud validates its ordinary pinned request before this test adapter replaces the
endpoint with its newly owned HTTP server. This is not live Lambda/IAM proof.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('canary', ROOT/'infrastructure/aws-v0/worker-db-canary/canary.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def main():
    aws = shutil.which('aws')
    if not aws:
        raise RuntimeError('REAL_AWS_CLI_REQUIRED: this test must not silently skip')
    with tempfile.TemporaryDirectory(prefix='mr-canary-real-cli-') as tmp:
        folder = Path(tmp)
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': tmp,
               'LANG': 'C.UTF-8', 'AWS_PAGER': '', 'AWS_CLI_AUTO_PROMPT': 'off',
               'AWS_EC2_METADATA_DISABLED': 'true', 'AWS_MAX_ATTEMPTS': '1',
               'AWS_RETRY_MODE': 'standard', 'AWS_IGNORE_CONFIGURED_ENDPOINT_URLS': 'true',
               'AWS_CONFIG_FILE': str(folder/'no-config'),
               'AWS_SHARED_CREDENTIALS_FILE': str(folder/'no-credentials'),
               'NO_PROXY': '127.0.0.1,localhost'}
        version = subprocess.run([aws, '--version'], env=env, capture_output=True,
                                 text=True, timeout=15, check=True).stdout.strip()
        assert version.startswith('aws-cli/2.'), version
        f = c.fixture()
        payload = c.canonical({'Records': [{'messageId': f['messageId'], 'body': c.canonical(f['envelope'])}]})
        request = {'FunctionName': c.FUNCTION, 'Qualifier': '1', 'InvocationType': 'RequestResponse',
                   'LogType': 'Tail', 'Payload': payload}
        expected_response = {'batchItemFailures': [{'itemIdentifier': f['messageId']}]}
        received = []
        mode = ['success']

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                n = int(self.headers.get('Content-Length', '0'))
                assert 0 < n < 65536
                body = self.rfile.read(n)
                received.append({'path': self.path, 'body': body, 'headers': dict(self.headers)})
                if mode[0] == 'http-error':
                    data = json.dumps({'Type': 'User', 'message': 'synthetic request rejection'}).encode()
                    self.send_response(400)
                    self.send_header('x-amzn-ErrorType', 'InvalidRequestContentException')
                else:
                    data = json.dumps(expected_response if mode[0] == 'success' else
                                      {'errorMessage': 'synthetic handler failure'}).encode()
                    self.send_response(200)
                    self.send_header('X-Amz-Executed-Version', '1')
                    if mode[0] == 'function-error':
                        self.send_header('X-Amz-Function-Error', 'Handled')
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        server = HTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = f'http://127.0.0.1:{server.server_port}'
        checks = []
        try:
            legacy = folder/'legacy.json'
            legacy.write_text(c.canonical(request))
            old = subprocess.run([aws, 'lambda', 'invoke', '--cli-input-json', 'file://'+str(legacy),
                                  '--region', c.REGION, '--endpoint-url', endpoint, '--no-sign-request',
                                  '--cli-binary-format', 'raw-in-base64-out', str(folder/'old-response.json')],
                                 env=env, capture_output=True, text=True, timeout=35, check=False)
            assert old.returncode != 0, 'unsupported invocation arguments were accepted'
            assert not received, 'legacy reproduction unexpectedly reached HTTP transport'
            checks.append('legacy cli-input-json invocation rejected by real CLI before HTTP')

            def local_run(command, **kw):
                assert command[1:3] == ['lambda', 'invoke']
                assert command[command.index('--endpoint-url')+1] == 'https://lambda.eu-west-2.amazonaws.com'
                assert kw['env']['AWS_MAX_ATTEMPTS'] == '1'
                assert '--cli-input-json' not in command
                adapted = list(command)
                adapted[0] = aws
                adapted[adapted.index('--endpoint-url')+1] = endpoint
                adapted += ['--no-sign-request']
                return subprocess.run(adapted, env=env, capture_output=True, text=True,
                                      timeout=35, check=False)

            for name in ('success', 'http-error', 'function-error'):
                target = folder/name
                target.mkdir()
                cloud = c.Cloud(f, target, run=local_run)
                mode[0] = name
                before = len(received)
                if name == 'http-error':
                    try:
                        cloud.call('lambda', 'invoke', request, target/'handler-response.json')
                    except c.Stop:
                        pass
                    else:
                        raise AssertionError('HTTP error was accepted')
                    assert len(received) == before+1, 'request was retried'
                    checks.append('HTTP rejection remains failure with no automatic retry')
                    continue
                meta = cloud.call('lambda', 'invoke', request, target/'handler-response.json')
                assert len(received) == before+1
                actual = received[-1]
                parsed = urlparse(actual['path'])
                assert unquote(parsed.path) == '/2015-03-31/functions/'+c.FUNCTION+'/invocations'
                assert parse_qs(parsed.query) == {'Qualifier': ['1']}
                assert actual['body'] == payload.encode('utf-8')
                headers = {k.lower(): v for k, v in actual['headers'].items()}
                assert 'authorization' not in headers and 'x-amz-security-token' not in headers
                assert headers['x-amz-invocation-type'] == 'RequestResponse' and headers['x-amz-log-type'] == 'Tail'
                assert meta['StatusCode'] == 200 and meta['ExecutedVersion'] == '1'
                body = json.loads((target/'handler-response.json').read_text())
                if name == 'success':
                    assert body == expected_response and 'FunctionError' not in meta
                    checks.append('explicit flags and fileb bytes traverse real CLI and streaming response writer')
                else:
                    assert meta.get('FunctionError') == 'Handled'
                    assert body != expected_response
                    checks.append('HTTP 200 function error is retained for caller rejection')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        assert len(checks) == 4
        receipt = {'status': 'PASS', 'awsCliVersion': version, 'assertionGroups': len(checks),
                   'checks': checks, 'awsRequests': 0, 'credentialsUsed': False,
                   'transport': 'REAL_CLI_UNSIGNED_LOOPBACK_HTTP',
                   'limits': 'No live Lambda, database, IAM or saved-fixture recovery proof.'}
        print(json.dumps(receipt, indent=2))
        out = Path(tempfile.mkdtemp(prefix='build11-zero-budget-cli-proof-'))/'receipt.json'
        out.write_text(json.dumps(receipt, indent=2)+'\n')
        print('CLI receipt:', out)


if __name__ == '__main__':
    main()
