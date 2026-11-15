#!/bin/bash
# Package a clean committed candidate with its corresponding source and pinned dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'Commit the curated candidate before packaging; the working tree must be clean.' >&2
  exit 1
fi
candidate_sha="$(git rev-parse HEAD)"
# Rebuild the exact committed source; do not attach an arbitrary older app to this SHA.
./scripts/build.sh
if [[ "$(git rev-parse HEAD)" != "$candidate_sha" || -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'Source changed during build. Packaging stopped.' >&2
  exit 1
fi
TEXTTANK_PACKAGE_SHA="$candidate_sha" python3 - <<'PY'
import datetime,hashlib,json,os,pathlib,shutil,subprocess,tarfile,tempfile,urllib.request
root=pathlib.Path.cwd();sha=os.environ['TEXTTANK_PACKAGE_SHA']
output=root/'output';output.mkdir(exist_ok=True)
stage=pathlib.Path(tempfile.mkdtemp(prefix='TextTank-review-package-'))
package=stage/'TextTank-review';package.mkdir();sources=package/'Source';sources.mkdir()
app=root/'build/DerivedData/Build/Products/Debug/TextTank.app'
if not app.is_dir():raise SystemExit('Built application is missing')
subprocess.run(['ditto','--norsrc','--noextattr','--noqtn',str(app),str(package/'TextTank.app')],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(package/'TextTank.app')],check=True)
source_tar=sources/'TextTank-source.tar.gz'
# gzip -n omits transient filename/timestamp headers. git archive contains tracked files only.
archive=subprocess.Popen(['git','archive','--format=tar','--prefix=TextTank-source/',sha],stdout=subprocess.PIPE)
with source_tar.open('wb') as target:
    gzip=subprocess.run(['gzip','-n'],stdin=archive.stdout,stdout=target,check=True)
archive.stdout.close()
if archive.wait()!=0:raise SystemExit('git archive failed')
validation_path=root/'harness/logs/candidate-validation.json'
if not validation_path.exists():raise SystemExit('Run scripts/test.sh on this clean candidate before packaging; validation evidence missing.')
validation=json.loads(validation_path.read_text())
source_tree=subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip()
if not validation.get('source_stable') or validation.get('source_tree')!=source_tree or validation.get('dirty') or validation.get('local_acceptance',{}).get('exit_code')!=0:
    raise SystemExit('Current clean candidate requires a successful exact-tree full acceptance record.')
# Verify source-file hashes too: never inherit tests from an earlier working tree.
for relative,digest in validation.get('source_manifest',{}).get('sha256',{}).items():
    if hashlib.sha256((root/relative).read_bytes()).hexdigest()!=digest:raise SystemExit('Test source changed: '+relative)
ci_path=root/'harness/logs/candidate-ci.json'
validation['ci']={'status':'not_observed','source_tree':source_tree}
if ci_path.exists():
    ci=json.loads(ci_path.read_text())
    if ci.get('source_tree')==source_tree:validation['ci']=ci
validation['packaged_source_commit']=sha
log=root/'harness/logs/full-acceptance.log'
if not log.is_file():raise SystemExit('Full acceptance log missing')
if hashlib.sha256(log.read_bytes()).hexdigest()!=validation.get('local_acceptance',{}).get('log_sha256'):raise SystemExit('Acceptance log changed after validation')
evidence=package/'Evidence';evidence.mkdir()
shutil.copyfile(log,evidence/'full-acceptance.log')
validation['local_acceptance']['log']='Evidence/full-acceptance.log'
validation['local_acceptance']['log_sha256']=hashlib.sha256(log.read_bytes()).hexdigest()
validation['local_acceptance']['observed_skips']=[line for line in log.read_text(errors='replace').splitlines() if line.startswith('SKIP ')]
(package/'validation.json').write_text(json.dumps(validation,indent=2)+'\n')
lock=json.loads((root/'Dependencies.lock.json').read_text())
cache=root/'build/downloads';cache.mkdir(parents=True,exist_ok=True)
for dependency in lock['dependencies']:
    name=dependency['file']
    if pathlib.PurePath(name).name!=name:raise SystemExit('Unsafe dependency filename')
    cached=cache/name
    if not cached.exists():
        # Optional pre-provisioned archive directory supports an offline source package.
        provided=os.environ.get('TEXTTANK_SOURCE_ARCHIVES')
        if provided and (pathlib.Path(provided)/name).is_file():shutil.copyfile(pathlib.Path(provided)/name,cached)
        else:urllib.request.urlretrieve(dependency['url'],cached)
    if hashlib.sha256(cached.read_bytes()).hexdigest()!=dependency['sha256']:raise SystemExit('Pinned dependency archive mismatch: '+name)
    shutil.copyfile(cached,sources/name)
for name in ['README.md','LICENSE','THIRD_PARTY_NOTICES.md','Dependencies.lock.json']:
    shutil.copyfile(root/name,package/name)
# Preserve relative links using only curated tracked documentation/reviews.
for raw in subprocess.check_output(['git','ls-files','-z','--','docs','harness/reviews']).split(b'\0'):
    if not raw:continue
    relative=pathlib.Path(os.fsdecode(raw));target=package/relative
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(root/relative,target)
shutil.copyfile(root/'scripts/launch-review.sh',package/'Launch-TextTank.command')
(package/'Launch-TextTank.command').chmod(0o755)
review=(root/'docs/REVIEW-ME.md').read_text().replace('](parity/','](docs/parity/').replace('](../harness/','](harness/')
(package/'REVIEW-ME.md').write_text(review)
licenses=package/'Licenses';licenses.mkdir()
for path in [root/'Resources/scintilla-License.txt',root/'Resources/lexilla-License.txt',root/'Resources/boost-License.txt',root/'Resources/Brand/Inter-OFL.txt',root/'Resources/Brand/SpaceGrotesk-OFL.txt']:
    shutil.copyfile(path,licenses/path.name)
def tree_hash(directory):
    digest=hashlib.sha256()
    for path in sorted(directory.rglob('*'),key=lambda p:p.relative_to(directory).as_posix()):
        relative=path.relative_to(directory).as_posix().encode()
        if path.is_symlink():kind=b'L';value=os.readlink(path).encode()
        elif path.is_file():kind=b'F';value=hashlib.sha256(path.read_bytes()).digest()
        else:continue
        digest.update(kind+b'\0'+relative+b'\0'+value+b'\0')
    return digest.hexdigest()
def capture(*args):return subprocess.check_output(args,text=True).strip()
manifest={'schema_version':1,'status':'INCOMPLETE PREVIEW','source_commit':sha,'source_tree':source_tree,'built_from_clean_commit':True,'created_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'app_tree_sha256':tree_hash(package/'TextTank.app'),'app_tree_hash_algorithm':'Sorted relative paths: SHA256 of type byte F/L, NUL, UTF8 path, NUL, raw SHA256 file bytes or UTF8 symlink target, NUL; directories/xattrs excluded.','architecture':capture('lipo','-archs',str(package/'TextTank.app/Contents/MacOS/TextTank')),'host_macos':capture('sw_vers','-productVersion'),'xcode':capture('xcodebuild','-version'),'deployment_target':lock['deploymentTarget'],'signing':'local ad-hoc; codesign deep/strict verification passed; not notarized','dependencies':lock['dependencies'],'files':{str(p.relative_to(package)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources.iterdir())},'ci_status':'Not inferred by packaging. Consult the exact source-commit CI result.','limitations':'Not full Notepad++ parity; see REVIEW-ME.md. No Intel/older-macOS runtime claim; live EventKit happy path is user-confirmed, remaining live failure/retry cases are unverified.'}
validation['app_tree_sha256']=manifest['app_tree_sha256']
(package/'validation.json').write_text(json.dumps(validation,indent=2)+'\n')
(package/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
zipfile=stage/'TextTank-review.zip'
subprocess.run(['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(package),str(zipfile)],check=True)
zip_hash=hashlib.sha256(zipfile.read_bytes()).hexdigest()
if capture('git','rev-parse','HEAD') != sha or capture('git','status','--porcelain','--untracked-files=normal'):
    raise SystemExit('Source changed during packaging; staged files were not delivered')
# Keep previous generated deliveries intact, rather than overlay potentially stale bundle files.
destination=output/'review'
if destination.exists() or destination.is_symlink():
    if destination.is_symlink():raise SystemExit('Refusing to replace a symlink at output/review')
    previous=output/('review-previous-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    destination.rename(previous)
package.rename(destination)
zipfile.rename(destination/'TextTank-review.zip')
manifest['zip_sha256']=zip_hash
(destination/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
checks=[f'{zip_hash}  TextTank-review.zip']+[f'{digest}  {name}' for name,digest in manifest['files'].items()]
(destination/'SHA256SUMS').write_text('\n'.join(checks)+'\n')
shutil.rmtree(stage)
print('Packaged output/review/TextTank.app and output/review/TextTank-review.zip')
print('Source commit: '+sha)
print('ZIP SHA256: '+zip_hash)
print('App tree SHA256: '+manifest['app_tree_sha256'])
PY
