#!/usr/bin/env python3
import hashlib,json,pathlib,tarfile,urllib.request
root=pathlib.Path(__file__).resolve().parent.parent
for dep in json.loads((root/'Dependencies.lock.json').read_text())['dependencies']:
 name=dep['file']; folder='scintilla' if name.startswith('scintilla') else 'lexilla'
 # Verify pinned source tree on every build, rather than trust an arbitrary cache.
 manifest=root/'scripts'/f'{folder}-source-hashes.json'
 if (root/'Vendor'/folder).exists() and manifest.exists():
  for rel,digest in json.loads(manifest.read_text()).items():
   p=root/'Vendor'/folder/rel
   if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest: raise SystemExit(f'Pinned source mismatch: {folder}/{rel}')
  continue
 cache=root/'build/downloads';cache.mkdir(parents=True,exist_ok=True);archive=cache/name
 if not archive.exists(): urllib.request.urlretrieve(dep['url'],archive)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=dep['sha256']: raise SystemExit('Archive checksum mismatch')
 with tarfile.open(archive) as t:
  if any(pathlib.PurePosixPath(m.name).is_absolute() or '..' in pathlib.PurePosixPath(m.name).parts or m.name.split('/')[0]!=folder or m.issym() or m.islnk() for m in t): raise SystemExit('Unsafe archive')
  t.extractall(root/'Vendor')
