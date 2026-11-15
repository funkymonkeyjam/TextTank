#!/usr/bin/env python3
"""Bind the full acceptance entry point's actual exit status to its source tree."""
import datetime,hashlib,json,os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parent.parent
manifest=root/'harness/logs/test-source-manifest.json'
source=json.loads(manifest.read_text()) if manifest.exists() else {}
def git(*args):return subprocess.check_output(['git',*args],cwd=root,text=True).strip()
stable=bool(source) and not source.get('dirty',True) and source.get('source_tree')==git('rev-parse','HEAD^{tree}') and not git('status','--porcelain') and all((root/p).is_file() and hashlib.sha256((root/p).read_bytes()).hexdigest()==digest for p,digest in source.get('sha256',{}).items())
record={'source_stable':stable,'schema_version':1,'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_commit':git('rev-parse','HEAD'),'source_tree':git('rev-parse','HEAD^{tree}'),'dirty':bool(git('status','--porcelain')),'local_acceptance':{'command':'scripts/test.sh','exit_code':int(os.environ['TEXTTANK_TEST_EXIT']),'log':'harness/logs/full-acceptance.log'},'source_manifest':source,'limitations':['Screenless native test processes skip window geometry assertions. Read test logs for environment skips.','No live Reminders fault, VoiceOver, Intel or macOS14 runtime certification.']}
log=root/'harness/logs/full-acceptance.log'
record['local_acceptance']['log_sha256']=hashlib.sha256(log.read_bytes()).hexdigest() if log.exists() else None
record['local_acceptance']['observed_skips']=[line for line in log.read_text(errors='replace').splitlines() if line.startswith('SKIP ')] if log.exists() else []
(root/'harness/logs/candidate-validation.json').write_text(json.dumps(record,indent=2)+'\n')
