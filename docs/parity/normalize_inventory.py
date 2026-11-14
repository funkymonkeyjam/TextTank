#!/usr/bin/env python3
"""Expand the frozen source inventory without converting source evidence into passes.
Usage: python3 docs/parity/normalize_inventory.py FROZEN_SOURCE
Output is deterministic; existing implementation/evidence fields are retained.
"""
import hashlib,json,pathlib,re,subprocess,sys,xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parent
src=pathlib.Path(sys.argv[1])
pin='61246e5741fd7c59352f3feb5ccc7e33e4594d15'
assert subprocess.check_output(['git','-C',str(src),'rev-parse','HEAD'],text=True).strip()==pin
base=f'https://github.com/notepad-plus-plus/notepad-plus-plus/blob/{pin}/'
path=root/'capabilities.json'; data=json.loads(path.read_text()); rows=data['capabilities']; byid={r['id']:r for r in rows}
def source(p,line):
 return {'path':p,'url':base+p+f'#L{line}','sha256':hashlib.sha256((src/p).read_bytes()).hexdigest()}
def add(id,family,behavior,p,line,parameters,acceptance):
 if id in byid:return
 r={'id':id,'family':family,'behavior':behavior,'classification':'standard-required','classification_basis':'Frozen source control/configuration plus full-capability contract; control presence does not prove implementation.', 'reference':{'commit':pin,'sources':[source(p,line)],'evidence_type':'ordinary static source','windows_runtime_observed':False},'expected_behavior':behavior,'mac_behavior':'Native control or documented equivalent; behavioral details require implementation and focused source review.','owner':family,'implementation_paths':[],'implementation_state':'unassessed','verification_state':'not-run','acceptance_cases':acceptance,'candidate_commit':None,'known_differences':['Source requirements only; runtime and complete interaction combinations not verified.'],'review':{'disposition':'not-reviewed'},'parameters':parameters}
 rows.append(r);byid[id]=r
# Include interactive dialog controls; retain their parent dialog to avoid collisions
# between reused Win32 IDs. Static labels/group boxes are evidence, not capabilities.
controls=[]
for f in sorted((src/'PowerEditor/src').rglob('*.rc')):
 p=str(f.relative_to(src));dialog=None
 for n,line in enumerate(f.read_text(errors='strict').splitlines(),1):
  m=re.match(r'\s*(\w+)\s+DIALOG(?:EX)?\s',line)
  if m:dialog=m[1]
  if not dialog:continue
  m=re.match(r'\s*(CONTROL|EDITTEXT|COMBOBOX|LISTBOX|PUSHBUTTON|DEFPUSHBUTTON|CHECKBOX|AUTOCHECKBOX|RADIOBUTTON)\s+(.*)',line)
  if not m:continue
  kind,rest=m.groups(); label=None
  if rest.startswith('"'):
   v=re.match(r'"((?:[^"\\]|\\.)*)"\s*,\s*(\w+)',rest)
   if not v:continue
   label,symbol=v.groups()
  else:
   v=re.match(r'(\w+)\s*,',rest)
   if not v:continue
   symbol=v[1]
  if symbol=='IDC_STATIC':continue
  # Generic CONTROL may be a passive static image or frame.
  if kind=='CONTROL' and ('"Static"' in rest or 'SS_BITMAP' in rest or 'SS_ICON' in rest):continue
  family='preferences' if '/Preference/' in p else 'dialogs'
  id=f'{family}.{dialog.lower()}.{symbol.lower()}'
  controls.append({'id':id,'dialog':dialog,'control':symbol,'kind':kind,'label':label,'source':source(p,n)})
  label=(label or symbol).replace('&','')
  acceptance=[{'id':id+'.effect','given':f'Open {dialog} with a synthetic Unicode document and the reference-dependent preconditions.','when':f'Invoke or change {label}; compare the owning reference handler.','then':'Observe the text/selection/view/settings effect and enabled-state dependencies; source label alone is insufficient.','state':'needs-handler-specific-fixture'}]
  if family=='preferences':acceptance.append({'id':id+'.restart','given':'Save a non-default valid preference value.','when':'Close/reopen the app, then reset the preference.','then':'The value survives restart; reset restores the default without editing document text.','state':'not-run'})
  add(id,family,f'{dialog}: {label}',p,n,{'control_id':symbol,'control_kind':kind},acceptance)
# Per-language behavior requirements; a lexer menu entry is never a pass.
p='PowerEditor/src/langs.model.xml';text=(src/p).read_text()
for e in ET.fromstring(text).findall('./Languages/Language'):
 name=e.get('name');n=next(i for i,l in enumerate(text.splitlines(),1) if f'name="{name}"' in l)
 id='language.profile.'+name
 add(id,'languages',f'Language {name}: default associations, keywords, comments and styles',p,n,dict(e.attrib),[{'id':id+'.fixture','given':f'A {name} fixture with Unicode identifiers, valid syntax, comments, strings and incomplete syntax.','when':'Open by associated extension; explicitly select the language; edit and Undo; inspect lexing and folding.','then':'Compare style spans, keyword classes, comment commands and fold levels with the pinned language data/lexer. Selection must not change file identity or document text.','state':'not-run'}])
# Only source-confirmed equivalent core actions are aliases. Menu commands with
# conditional behavior (cut/copy, indent, Unicode case) remain separate surfaces.
aliases={'shortcut.redo':('command.edit.redo',486),'shortcut.selectall':('command.edit.selectall',2057)}
for id,(target,line) in aliases.items():
 if id in byid and target in byid:
  byid[id]['canonical_behavior_id']=target
  byid[id]['alias_evidence']={'source':source('PowerEditor/src/NppCommands.cpp',line),'scope':'Editor-focused core action; native menu routing still requires its own invocation evidence.'}
# Every retained surface receives an explicit command contract and acceptance gate.
for r in rows:
 r.setdefault('canonical_behavior_id',r['id'])
 r.setdefault('command_contract',{'identifier':r['id'],'parameters':'See row parameters and reference handler; unresolved values must not be guessed.','availability':'Native equivalent and source preconditions must be reviewed.','recording_policy':'Not approved for recording until text/view/external-effect classification is reviewed; external effects require explicit invocation.'})
 if not r.get('acceptance_cases'):
  r['acceptance_cases']=[{'id':r['id']+'.reference-effect','given':'Synthetic fixture satisfying the linked reference handler preconditions, including Unicode and empty/boundary inputs.','when':r['expected_behavior'],'then':'Verify the exact text/selection/view/output effect through the actual native command; verify Undo for edits and no dirty change for view-only actions.','state':'needs-handler-specific-fixture'},{'id':r['id']+'.unavailable-or-cancel','given':'Unavailable, read-only, invalid-parameter or canceled state appropriate to this command.','when':'Invoke through every implemented surface.','then':'No silent text loss, stale mutation or external side effect; availability and errors are visible.','state':'needs-handler-specific-fixture'}]
data['inventory_state']='expanded source surfaces with explicit acceptance gates; NOT a complete normalized behavioral denominator'
data['required_semantic_dedup_remaining']=['Nontrivial menu/keyboard contextual semantics','Dialog handlers and option interaction fixtures','Dynamic language/style/UDL configurations','Bundled utility version-specific behavior and actual distribution reconciliation']
path.write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n')
(root/'dialog-surfaces.json').write_text(json.dumps({'source_commit':pin,'evidence':'Static interactive resource controls; no implementation or runtime claim','controls':controls},indent=2,ensure_ascii=False)+'\n')
print(f'{len(rows)} retained capability surfaces; {len(controls)} interactive resource occurrences; {len(aliases)} explicit core aliases')
