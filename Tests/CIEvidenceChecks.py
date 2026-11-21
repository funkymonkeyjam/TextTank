"""Faithful hosted run fixtures for the package verifier, without network or credentials."""
import hashlib
import io
import json
import unittest
from pathlib import Path
import tempfile
import os
from unittest.mock import patch
import zipfile

import ci_evidence as ci


class CIEvidenceChecks(unittest.TestCase):
    tree = 'c' * 40
    commit = 'a' * 40
    merge = 'b' * 40
    start = '2026-11-20T12:00:00Z'
    terminal = {'status': 'completed', 'conclusion': 'success'}
    setup = b'2026-11-20T12:00:00Z ##[group]Runner Image\n2026-11-20T12:00:01Z Image: xcode-27-arm64\n2026-11-20T12:00:02Z Version: 20261104.0337.1\n2026-11-20T12:00:03Z ##[endgroup]\n2026-11-20T12:00:04Z ##[group]GITHUB_TOKEN Permissions\n2026-11-20T12:00:05.9981234Z 61 passed, 0 not passed\n2026-11-20T12:05:36Z 1 passed, 0 not passed\n'

    def setUp(self):
        self.run = {**self.terminal, 'id': 44, 'run_attempt': 2, 'repository': {'id': 10, 'full_name': ci.REPOSITORY},
                    'path': ci.WORKFLOW_PATH, 'name': ci.WORKFLOW, 'head_sha': self.commit, 'event': 'pull_request',
                    'workflow_id': 12, 'run_started_at': self.start, 'pull_requests': [{'number': 9, 'head': {'sha': self.commit}}]}
        self.job = {**self.terminal, 'id': 55, 'run_id': 44, 'run_attempt': 2, 'head_sha': self.commit,
                    'started_at': self.start, 'name': 'native', 'labels': [ci.RUNNER], 'steps': [
                        {**self.terminal, 'name': n, 'started_at': self.start, 'completed_at': '2026-11-20T12:00:05Z'} for n in
                        ('Run acceptance checks', 'Write strict native evidence', 'Upload strict native evidence')]}
        self.receipt = {'schema_version': 1, 'repository': ci.REPOSITORY, 'workflow': ci.WORKFLOW, 'run_id': 44,
                        'run_attempt': 2, 'event': 'pull_request', 'pr_number': 9, 'checkout_commit': self.commit,
                        'source_tree': self.tree, 'native_conclusion': 'success', 'runner': ci.RUNNER, 'architecture': 'arm64',
                        'macos_build': '26A434', 'xcode': 'Xcode 27.2\nBuild version 12345', 'image_os': '',
                        'image_version': '', 'native': {'passed': 61, 'failed': 0, 'log_sha256': 'e' * 64}}
        self.artifact = {'name': 'strict-native-44-2', 'id': 66, 'workflow_run': {
            'id': 44, 'head_sha': self.commit, 'repository_id': 10}, 'expired': False}
        self.archive()
        self.responses = {
            f'actions/workflows/native.yml/runs?head_sha={self.commit}&status=success&per_page=1': {'workflow_runs': [self.run]},
            'actions/workflows/native.yml': {'id': 12, 'path': ci.WORKFLOW_PATH},
            'actions/runs/44': self.run, 'actions/runs/44/attempts/2': self.run,
            'actions/runs/44/attempts/2/jobs?per_page=100': {'jobs': [self.job]},
            f'git/commits/{self.commit}': {'tree': {'sha': self.tree}},
            'actions/runs/44/artifacts?name=strict-native-44-2&per_page=100': {'artifacts': [self.artifact]}}

    def archive(self, filename=ci.FILE):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr(filename, json.dumps(self.receipt))
        self.blob = buffer.getvalue()
        self.artifact.update(digest='sha256:' + hashlib.sha256(self.blob).hexdigest(), size_in_bytes=len(self.blob))

    def fetch(self, path):
        if path == 'actions/artifacts/66/zip':
            return self.blob
        if path == 'actions/jobs/55/logs':
            return self.setup
        return json.dumps(self.responses[path]).encode()

    def verify(self):
        return ci.authenticate(self.merge, self.tree, '44', '2', self.fetch)

    def test_same_tree_with_another_commit_and_exact_default(self):
        for value in [self.verify(), ci.authenticate(self.commit, self.tree, fetch=self.fetch)]:
            self.assertEqual(value['checkout_commit'], self.commit)
            self.assertEqual(value['artifact_sha256'], self.artifact['digest'][7:])
            self.assertEqual(value['hosted_image']['version'], '20261104.0337.1')
            self.assertEqual(value['native']['passed'], 61)
        self.run.update(event='push', pull_requests=[])
        self.receipt.update(event='push', pr_number=None)
        self.archive()
        self.assertIsNone(self.verify()['pr_number'])

    def test_provider_and_attempt_negatives(self):
        changes = [
            (self.run, 'status', 'in_progress'), (self.run, 'conclusion', 'failure'), (self.run, 'path', 'other.yml'),
            (self.run, 'name', 'other'), (self.run, 'workflow_id', 11), (self.run['repository'], 'full_name', 'fork/repo'),
            (self.run, 'run_attempt', 1), (self.run, 'pull_requests', []),
            (self.responses[f'git/commits/{self.commit}']['tree'], 'sha', self.commit),
            (self.job, 'name', 'native-advisory-16.4'), (self.job, 'labels', ['macos-15']),
            (self.job, 'started_at', '2026-11-19T12:00:00Z'), (self.job['steps'][0], 'conclusion', 'skipped'),
            (self.job, 'conclusion', 'failure'), (self.artifact, 'expired', True), (self.artifact, 'digest', 'sha256:'+'f'*64),
            (self.artifact['workflow_run'], 'id', 77), (self.artifact, 'size_in_bytes', 65537)]
        for target, key, bad in changes:
            with self.subTest(key=key, bad=bad), patch.dict(target, {key: bad}), self.assertRaises(ValueError):
                self.verify()

    def test_receipt_and_archive_negatives(self):
        for key, bad in [('source_tree', self.commit), ('checkout_commit', self.merge), ('run_attempt', 1),
                         ('xcode', 'Xcode 16.4\nBuild version abc'), ('native_conclusion', 'failure'),
                         ('native', {'passed': 0, 'failed': 0}), ('image_version', 'x\nextra'),
                         ('pr_number', 20), ('event', 'push')]:
            with self.subTest(key=key), patch.dict(self.receipt, {key: bad}), self.assertRaises(ValueError):
                self.archive()
                self.verify()
        with patch.dict(self.receipt['native'], {'passed': 1}), self.assertRaisesRegex(ValueError, 'completion differs'):
            self.archive()
            self.verify()
        self.archive('../receipt.json')
        with self.assertRaises(ValueError):
            self.verify()
        self.archive()
        self.setup = b'absent setup group'
        with self.assertRaises(ValueError):
            self.verify()

    def test_generate_from_native_acceptance_and_private_environment(self):
        log = b'Start\nSuite summary\n  PASS  bundle-smoke  PASS bound\n  PASS  bridge-checks  PASS native\n\n2 passed, 0 not passed\n'
        def command(*args):
            if args[0] == 'git':
                return self.commit if args[-1] == 'HEAD' else self.tree
            return {'sw_vers': '26A434', 'uname': 'arm64', 'xcodebuild': self.receipt['xcode']}[args[0]]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            logs = root / 'harness/logs'
            logs.mkdir(parents=True)
            (logs / 'full-acceptance.log').write_bytes(log)
            event = root / 'event.json'
            event.write_text(json.dumps({'pull_request': {'number': 9, 'head': {'sha': self.commit}}}))
            valid = {'source_stable': True, 'source_start': {'source_commit': self.commit}, 'source_commit': self.commit,
                     'source_tree': self.tree, 'dirty': False, 'local_acceptance': {'exit_code': 0, 'log_sha256': hashlib.sha256(log).hexdigest()}}
            (logs / 'candidate-validation.json').write_text(json.dumps(valid))
            env = {'GITHUB_EVENT_PATH': str(event), 'GITHUB_RUN_ID': '44', 'GITHUB_RUN_ATTEMPT': '2',
                   'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_REPOSITORY': ci.REPOSITORY, 'GITHUB_WORKFLOW': ci.WORKFLOW,
                   'CANDIDATE_SHA': self.commit, 'TEXTTANK_WARNINGS_AS_ERRORS': '1', 'GH_TOKEN': 'fixture-private-value'}
            with patch.object(ci, 'ROOT', root), patch.object(ci, 'command', command), patch.dict(os.environ, env, clear=True):
                ci.generate()
                text = (logs / ci.FILE).read_text()
                self.assertNotIn(env['GH_TOKEN'], text)
                self.assertEqual(json.loads(text)['native']['passed'], 2)
                (logs / 'full-acceptance.log').write_bytes(log + b'changed')
                with self.assertRaises(ValueError):
                    ci.generate()
        for damaged in [log.replace(b'2 passed', b'1 passed'), log.replace(b'bridge-checks', b'bundle-smoke'),
                        log.replace(b'0 not passed', b'1 not passed'), b'0 passed, 0 not passed']:
            with self.assertRaises(ValueError):
                ci.native_summary(damaged.decode())
