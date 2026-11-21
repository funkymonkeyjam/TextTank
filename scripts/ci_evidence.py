"""Emit strict native acceptance evidence and authenticate it for a review package."""
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

REPOSITORY = 'funkymonkeyjam/TextTank'
WORKFLOW = 'Native Mac checks'
WORKFLOW_PATH = '.github/workflows/native.yml'
RUNNER = 'xcode-27'
XCODE = '27.2'
FILE = 'strict-native.json'
ROOT = Path(__file__).resolve().parents[1]


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def sha(value, length=40):
    require(isinstance(value, str) and re.fullmatch('[0-9a-f]{%d}' % length, value),
            'Invalid Git object or digest.')
    return value


def number(value):
    require(re.fullmatch(r'[1-9][0-9]*', str(value)), 'Expected a positive run, attempt or artifact identifier.')
    return int(value)


def native_summary(log):
    section = log.rsplit('\nSuite summary\n', 1)
    require(len(section) == 2, 'Native suite summary missing.')
    lines = section[1].strip('\n').splitlines()
    require(len(lines) >= 3 and lines[-2] == '', 'Incomplete native suite summary.')
    suites = []
    for line in lines[:-2]:
        row = re.fullmatch(r'  PASS +([a-zA-Z0-9_-]+) +(.+)', line)
        require(row, 'Unexpected or unsuccessful native suite result.')
        suites.append(row[1])
    require(len(set(suites)) == len(suites) and lines[-1] == f'{len(suites)} passed, 0 not passed',
            'Native suite count or completion line did not match.')
    require('bundle-smoke' in suites and 'bridge-checks' in suites, 'Required native suite results missing.')
    return {'passed': len(suites), 'failed': 0}


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def generate():
    # Hosted artifacts summarize the strict check. The run conclusion is verified after GitHub finishes it.
    from package_review import verify_validation
    env = os.environ
    commit = sha(command('git', 'rev-parse', 'HEAD'))
    tree = sha(command('git', 'rev-parse', 'HEAD^{tree}'))
    event = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())
    pr = event.get('pull_request')
    tested = pr['head']['sha'] if pr else env['GITHUB_SHA']
    require(env['GITHUB_REPOSITORY'] == REPOSITORY and env['GITHUB_WORKFLOW'] == WORKFLOW
            and tested == env['CANDIDATE_SHA'] == commit
            and env['TEXTTANK_WARNINGS_AS_ERRORS'] == '1', 'Unexpected workflow, checkout or warning mode.')
    require(env['GITHUB_EVENT_NAME'] in ('push', 'workflow_dispatch', 'pull_request')
            and (env['GITHUB_EVENT_NAME'] == 'pull_request') == bool(pr), 'Unexpected checkout event.')
    validation = verify_validation(ROOT, tree)
    require(validation.get('source_commit') == commit and validation['source_start'].get('source_commit') == commit,
            'Native acceptance ran on a different checkout.')
    raw = (ROOT / 'harness/logs/full-acceptance.log').read_bytes()
    summary = native_summary(raw.decode('utf-8', errors='replace'))
    summary['log_sha256'] = hashlib.sha256(raw).hexdigest()
    require(validation['local_acceptance']['log_sha256'] == summary['log_sha256'], 'Acceptance log changed.')
    toolchain = command('xcodebuild', '-version')
    require(toolchain.splitlines()[0] == 'Xcode ' + XCODE and command('uname', '-m') == 'arm64',
            'Unexpected strict runner toolchain.')
    evidence = {'schema_version': 1, 'repository': REPOSITORY, 'workflow': WORKFLOW,
                'run_id': number(env['GITHUB_RUN_ID']), 'run_attempt': number(env['GITHUB_RUN_ATTEMPT']),
                'event': env['GITHUB_EVENT_NAME'], 'pr_number': pr['number'] if pr else None,
                'checkout_commit': commit, 'source_tree': tree, 'native_conclusion': 'success',
                'runner': RUNNER, 'macos_build': command('sw_vers', '-buildVersion'),
                'image_os': env.get('ImageOS', ''), 'image_version': env.get('ImageVersion', ''),
                'architecture': 'arm64', 'xcode': toolchain, 'native': summary}
    (ROOT / 'harness/logs' / FILE).write_text(json.dumps(evidence, indent=2) + '\n')


def github(path):
    # Read only the canonical GitHub repository. Authentication stays with gh.
    env = dict(os.environ)
    env.pop('GH_DEBUG', None)
    args = ['gh', 'api', '--hostname', 'github.com']
    if re.fullmatch(r'actions/(?:artifacts/[0-9]+/zip|jobs/[0-9]+/logs)', path):
        # Some gh versions require explicit consent for control bytes even when stdout is a pipe.
        help_text = subprocess.check_output(['gh', 'api', '--help'], env=env, timeout=40)
        if b'--allow-escape-sequences' in help_text:
            args.append('--allow-escape-sequences')
    return subprocess.check_output([*args, f'repos/{REPOSITORY}/{path}'], env=env, timeout=40)


def select(items, name):
    found = [item for item in items if item['name'] == name]
    require(len(found) == 1, f'Expected one hosted {name} record.')
    return found[0]


def successful(item):
    return item.get('status') == 'completed' and item.get('conclusion') == 'success'


def instant(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))


def runner_image(job_log):
    # The hosted worker prints these setup records before any repository action executes.
    setup = job_log[:65536].decode('utf-8-sig', errors='replace').split('##[group]GITHUB_TOKEN Permissions', 1)
    require(len(setup) == 2, 'Missing hosted runner setup records.')
    lines = [line.partition(' ')[2] for line in setup[0].splitlines()]
    require('##[group]Runner Image' in lines, 'Missing hosted runner image.')
    index = lines.index('##[group]Runner Image')
    details = lines[index + 1:lines.index('##[endgroup]', index)]
    fields = dict(line.split(': ', 1) for line in details if ': ' in line)
    require(re.fullmatch(r'[a-zA-Z0-9_.-]{1,128}', fields.get('Image', ''))
            and re.fullmatch(r'[a-zA-Z0-9_.-]{1,128}', fields.get('Version', '')), 'Invalid hosted runner image.')
    return {'name': fields['Image'], 'version': fields['Version']}


def hosted_native_count(job_log, acceptance):
    # The API rounds step times to whole seconds. Exclude later advisory performance results.
    start, end = instant(acceptance['started_at']), instant(acceptance['completed_at'])
    counts = []
    for time, passed in re.findall(rb'^([0-9T:.Z-]+) ([1-9][0-9]*) passed, 0 not passed\r?$', job_log, re.MULTILINE):
        second = time.decode().split('.', 1)[0].rstrip('Z') + 'Z'
        if start <= instant(second) <= end:
            counts.append(int(passed))
    require(counts, 'No terminal native completion within the successful acceptance step.')
    return counts[-1]


def authenticate(commit, tree, run_id=None, attempt=None, fetch=github):
    sha(commit)
    sha(tree)

    def get(path):
        return json.loads(fetch(path))

    if not run_id:
        require(not attempt, 'A selected attempt also needs a run ID.')
        runs = get(f'actions/workflows/native.yml/runs?head_sha={commit}&status=success&per_page=1')['workflow_runs']
        require(runs, 'No successful native run on this commit. Select an exact-tree run using TEXTTANK_CI_RUN_ID.')
        run_id = runs[0]['id']
    run_id = number(run_id)
    base = f'actions/runs/{run_id}'
    run = get(f'{base}/attempts/{number(attempt)}' if attempt else base)
    attempt = number(attempt or run['run_attempt'])
    canonical = get('actions/workflows/native.yml')
    require(run['repository']['full_name'] == REPOSITORY and run['id'] == run_id
            and run['run_attempt'] == attempt and run['path'] == WORKFLOW_PATH and run['name'] == WORKFLOW
            and run['workflow_id'] == canonical['id'] and canonical['path'] == WORKFLOW_PATH
            and successful(run), 'Run is not the successful canonical native workflow attempt.')
    head = sha(run['head_sha'])
    require(get(f'git/commits/{head}')['tree']['sha'] == tree, 'Hosted checkout differs from the package tree.')
    event = run['event']
    require(event in ('pull_request', 'push', 'workflow_dispatch'), 'Unsupported hosted checkout event.')
    jobs = get(f'{base}/attempts/{attempt}/jobs?per_page=100')['jobs']
    job = select(jobs, 'native')
    require(successful(job) and job['run_id'] == run_id and job['run_attempt'] == attempt
            and job['head_sha'] == head and RUNNER in job['labels']
            and instant(run['run_started_at']) <= instant(job['started_at']), 'Strict job failed or was carried forward.')
    for step in ('Run acceptance checks', 'Write strict native evidence', 'Upload strict native evidence'):
        record = select(job['steps'], step)
        require(successful(record) and record['completed_at'], f'Hosted step did not finish successfully: {step}')
    name = f'strict-native-{run_id}-{attempt}'
    artifact = select(get(f'{base}/artifacts?name={name}&per_page=100')['artifacts'], name)
    owner = artifact['workflow_run']
    require(artifact['expired'] is False and owner['id'] == run_id and owner['head_sha'] == head
            and owner['repository_id'] == run['repository']['id'] and 0 < artifact['size_in_bytes'] <= 65536,
            'Hosted receipt is expired, oversized or associated with a different checkout.')
    artifact_id = number(artifact['id'])
    blob = fetch(f'actions/artifacts/{artifact_id}/zip')
    digest = hashlib.sha256(blob).hexdigest()
    require(len(blob) == artifact['size_in_bytes'] and artifact['digest'] == 'sha256:' + digest,
            'GitHub artifact integrity check failed.')
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        require(archive.namelist() == [FILE] and archive.getinfo(FILE).file_size <= 32768,
                'Unexpected hosted receipt archive contents.')
        receipt = json.loads(archive.read(FILE))
    expected = {'schema_version': 1, 'repository': REPOSITORY, 'workflow': WORKFLOW, 'run_id': run_id,
                'run_attempt': attempt, 'event': event, 'checkout_commit': head, 'source_tree': tree,
                'native_conclusion': 'success', 'runner': RUNNER, 'architecture': 'arm64'}
    require(all(receipt.get(k) == v for k, v in expected.items()), 'Hosted receipt disagrees with Actions.')
    pr = receipt['pr_number']
    if event == 'pull_request':
        require(any(p['number'] == number(pr) and p['head']['sha'] == head for p in run['pull_requests']),
                'Test checkout does not match the pull request head recorded for this run.')
    else:
        require(pr is None, 'Unexpected pull request for this checkout.')
    xcode = receipt['xcode']
    build = receipt['macos_build']
    require(re.fullmatch(r'Xcode ' + re.escape(XCODE) + r'\nBuild version [a-zA-Z0-9.]+', xcode)
            and re.fullmatch(r'[A-Za-z0-9.]+', build), 'Missing strict Xcode or macOS build.')
    images = {k: receipt[k] for k in ('image_os', 'image_version')}
    require(all(isinstance(v, str) and re.fullmatch(r'[a-zA-Z0-9_.-]{0,128}', v) for v in images.values()),
            'Invalid runner image fields.')
    result = receipt['native']
    require(type(result['passed']) is int and result['passed'] > 0 and type(result['failed']) is int
            and result['failed'] == 0, 'Missing successful native completion.')
    job_id = number(job['id'])
    job_log = fetch(f'actions/jobs/{job_id}/logs')
    acceptance = select(job['steps'], 'Run acceptance checks')
    require(hosted_native_count(job_log, acceptance) == result['passed'],
            'Hosted native completion differs from the uploaded acceptance receipt.')
    image = runner_image(job_log)
    url = f'https://github.com/{REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}'
    # Only these curated fields enter the public package.
    return {**expected, **images, 'pr_number': pr, 'xcode': xcode, 'macos_build': build,
            'native': {'passed': result['passed'], 'failed': 0, 'log_sha256': sha(result['log_sha256'], 64)},
            'job_id': job_id, 'acceptance_completed_at': acceptance['completed_at'], 'hosted_image': image, 'artifact_id': artifact_id, 'artifact_sha256': digest,
            'url': url, 'conclusion': run['conclusion']}


if __name__ == '__main__':
    generate()
