#!/usr/bin/env python3
"""Regenerate static inventory from an explicitly supplied frozen source checkout.
Usage: python3 docs/parity/build_inventory.py SOURCE_CHECKOUT SEED_JSON
Does not mark any behavior implemented or verified. Output lives beside this script.
"""
import sys,json,re,hashlib, pathlib,xml.etree.ElementTree as ET
src=pathlib.Path(sys.argv[1]);seed=json.loads(pathlib.Path(sys.argv[2]).read_text());out=pathlib.Path(__file__).parent
pin='61246e5741fd7c59352f3feb5ccc7e33e4594d15';base=f'https://github.com/notepad-plus-plus/notepad-plus-plus/blob/{pin}/'
def write(n,d): (out/n).write_text(json.dumps(d,indent=2,ensure_ascii=False)+'\n')
def source(p,line=None): return {'path':p,'url':base+p+(f'#L{line}' if line else ''),'sha256':hashlib.sha256((src/p).read_bytes()).hexdigest()}
rows=[]
def row(id,family,behavior,p,expected=None,mac=None,classification='standard-required',symbols=None,line=None,known=None):
 r={'id':id,'family':family,'behavior':behavior,'classification':classification,'classification_basis':'Pinned source surface plus full-capability product contract; exact parameter semantics require acceptance refinement.','reference':{'commit':pin,'distribution_profile':'source-standard-profile; binary artifact unresolved','seed_symbols':symbols or [],'sources':[source(p,line)],'evidence_type':'ordinary static source','windows_runtime_observed':False},'expected_behavior':expected or behavior,'mac_behavior':mac or 'Expose equivalent behavior using the shared command dispatcher and native Mac interaction; exact adaptation remains to be implemented and reviewed.','owner':family,'implementation_paths':[],'implementation_state':'unassessed','verification_state':'not-run','acceptance_cases':[],'candidate_commit':None,'known_differences':known or ['Native behavior not verified; source-level expectation needs focused acceptance cases.'],'review':{'disposition':'not-reviewed'}};rows.append(r);return id
# Dispositions explicitly preserve non-command markers; numeric ranges are not feature rows.
groups=set('IDM_FILE IDM_EDIT IDM_SEARCH IDM_MISC IDM_VIEW IDM_FORMAT IDM_LANG IDM_SETTING IDM_TOOL IDM_SYSTRAYPOPUP IDM_VIEW_FOLD IDM_VIEW_UNFOLD IDM_FORMAT_ENCODE IDM_LANG_EXTERNAL'.split())
markers=set('IDM_FILEMENU_LASTONE IDM_FILEMENU_EXISTCMDPOSITION IDM_FORMAT_ENCODE_END IDM_LANG_EXTERNAL_LIMIT IDM_LANG_USER_LIMIT IDM_WINDOW_MRU_LIMIT IDM_DROPLIST_MRU_FIRST'.split())
disp=[];seen={}
for d in seed['definitions']:
 s=d['symbol']; expression=d['expression'];family=s.split('_')[1].lower(); targets=[]
 if s in groups or s in markers:
  kind='alias/group';reason='Group/range/menu-position metadata; dynamic behavior tracked separately.'
 elif expression in seen:
  kind='alias';targets=[seen[expression]];reason='Identical expression in same source seed; alias requires shared behavior.'
 else:
  kind='required-command-surface';reason='Command surface is required; not a claim that the label fully defines all behaviors.'
  id='command.'+s[4:].lower().replace('_','.');seen[expression]=id
  labels=list(dict.fromkeys(x['label'].replace('&','').replace('...','…') for x in d['menu_occurrences']))
  behavior=labels[0] if labels else s[4:].replace('_',' ').title()
  cls='platform-equivalent-required' if s in ['IDM_FILE_OPEN_CMD','IDM_FILE_OPEN_POWERSHELL','IDM_FILE_OPEN_FOLDER','IDM_SETTING_TRAYICON','IDM_SETTING_PLUGINADM'] else 'standard-required'
  targets=[row(id,family,behavior,d['source_path'],symbols=[s],line=d['source_line'],classification=cls)]
 disp.append({'symbol':s,'expression':expression,'source_line':d['source_line'],'disposition':kind,'capability_ids':targets,'reason':reason})
# Important behavior interactions absent from the menu seed; no inferred pass from engine API.
extra={
'files':('PowerEditor/src/NppIO.cpp',[
('dirty.clone-close','Close one dirty clone, then last view; Cancel preserves shared bytes and dirty state.'),('dirty.clone-quit','Quit visits each unique dirty document exactly once; Save/Discard/Cancel and save failure are respected.'),('save.atomic-failure','Interrupted/denied save leaves original bytes and recoverable unsaved edits intact.'),('save.external-conflict','External modification between read and save requires explicit conflict resolution.'),('recovery.untitled','Forced crash recovers untitled modified bytes without silently discarding them.'),('recovery.named','Forced crash restores pending named-document edits without overwriting changed originals.'),('recovery.corrupt','Corrupt/partial/stale recovery snapshots are rejected or offered safely; originals preserved.'),('encoding.byte-roundtrip','Untouched UTF-8, UTF-16 LE/BE, BOM and mixed-EOL fixtures round-trip exact bytes.'),('encoding.legacy','Required legacy encodings retain bytes; explicit conversion rejects unrepresentable text without replacement.'),('encoding.invalid','Invalid byte sequences require explicit interpretation; no silent lossy decode.'),('clone.shared-undo','Edits through either clone share bytes and one undo history; per-view selections remain independent.'),('reload.dirty','Reload asks before discarding edits and preserves document after canceled or failed reload.'),('metadata','Saving preserves applicable file metadata and reports unsupported cases.'),('session.inert','Restoring sessions cannot run shell commands or load executable extensions.')]),
'search':('PowerEditor/src/ScintillaComponent/FindReplaceDlg.cpp',[
('mode.literal','Literal metacharacters are matched without regex interpretation.'),('mode.extended','Extended escapes follow frozen reference semantics.'),('mode.regex','Boost-compatible captures, Unicode, multiline and replacement syntax match frozen reference.'),('regex.zero-width','Forward/backward/replace-all zero-width matches terminate and match reference behavior.'),('scope.selection','Selection-only search and replace never changes text outside captured selection.'),('scope.open-documents','Find/replace all open documents handles dirty, read-only and encoding failures explicitly.'),('scope.folders','Recursive folder filters, hidden/excluded files and errors are visible and cancellable.'),('scope.projects','Project search respects project membership and reference filters.'),('results.navigation','Results retain file/line identity and navigate safely after intervening edits.'),('cancel.revision','Cancel or intervening editor changes cannot cause stale asynchronous replacements.'),('macro.parameters','Recorded find/replace replays mode, scope, replacement, flags and direction, not current dialog values.')]),
'editing':('scintilla/src/Editor.cxx',[
('unicode.positions','UTF-8 bytes, UTF-16 accessibility positions and Swift indices preserve emoji and combining sequences.'),('input.ime','Marked text, commit/cancel, dead keys and composed characters work in focused native editor.'),('selection.rectangular','Rectangular selections preserve column, tabs, virtual-space and multiple-caret behavior.'),('selection.multiple','Multiple discontiguous selections edit and Undo consistently.'),('accessibility','VoiceOver can discover/read/navigate/edit text; inherited NSView alone is insufficient evidence.'),('undo.group','Each configured editor transform is one Undo step, preserving selection/document scope.'),('ordinary.paste','Ordinary paste stays unchanged when no automation is explicitly invoked.')]),
'languages':('PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp',[
('udl.definition','Create/edit/import/export user definitions, styles and keyword sets.'),('udl.lexing','Port audited LexUser behavior including nested and delimiter settings.'),('completion','Language keyword/API completion and call tips preserve insertion semantics.'),('function-list','Language parsers identify symbols and navigate to source; configuration persists.'),('associations','File extensions and user overrides select language predictably.')]),
'workspace':('PowerEditor/src/NppBigSwitch.cpp',[
('monitor.append','Monitoring shows appended bytes without losing view position policy.'),('monitor.truncate','Monitoring handles truncation/replacement and dirty conflicts explicitly.'),('printing','Native printing/PDF preserves pagination, selected scope, headers and settings.'),('projects.persistence','Project folders/files and workspace state survive restart.'),('preferences.persistence','Preferences, shortcut collisions and context-menu customization survive restart.'),('commands.inert','Document open, folder open and workflow import never run configured processes.'),('commands.arguments','Executable and argv preserve spaces, quotes and metacharacters as data; shell mode explicit.'),('extensions.contract','Native extension command/menu/notification contract has executable sample and tests; no Windows DLL compatibility claim.')])}
for family,(p,items) in extra.items():
 if not (src/p).exists(): raise RuntimeError(p)
 for suffix,behavior in items: row(f'{family}.{suffix}',family,behavior,p,expected=behavior)
# Bundled utility requirements established by official installer descriptions, not excluded as third party.
for mode in ['Base64','Quoted-printable','URL','SAML']:
 for action in ['encode','decode']:row(f'bundled.mime.{mode.lower()}.{action}','bundled',f'{action.title()} selected text using {mode}; exact invalid-input semantics remain to audit.','PowerEditor/installer/nppSetup.nsi',line=421)
for radix in ['binary','octal','hexadecimal','decimal']:
 row(f'bundled.converter.{radix}','bundled',f'ASCII conversion to {radix} string; bidirectional/options require plugin source or package audit.','PowerEditor/installer/nppSetup.nsi',line=422)
for fmt in ['html','rtf']:
 for dest in ['clipboard','file']:row(f'bundled.export.{fmt}.{dest}','bundled',f'Export syntax-highlighted text as {fmt.upper()} to {dest}.','PowerEditor/installer/nppSetup.nsi',line=420)
# Inventory default shortcuts by unique command, not key count; platform bindings require audit.
k='scintilla/src/KeyMap.cxx';matches={}
for i,line in enumerate((src/k).read_text().splitlines(),1):
 m=re.search(r'Message::(\w+)',line)
 if m:matches.setdefault(m[1],[]).append({'line':i,'binding':line.strip()})
for msg,bindings in matches.items():
 r=row('shortcut.'+msg.lower(),'editing','Default editor keyboard command '+msg,k,line=bindings[0]['line']);rows[-1]['reference']['bindings']=bindings;rows[-1]['known_differences']=['Keyboard surface may overlap menu command; semantic cross-link/dedup still required. Windows/Mac conditional bindings need runtime assessment.']
# Language/configuration data are a concrete frozen source profile, not evidence of shipped binary identity.
langp='PowerEditor/src/langs.model.xml';languages=[]
for e in ET.parse(src/langp).getroot().findall('./Languages/Language'):
 languages.append({'name':e.get('name'),'extensions':e.get('ext',''),'comment_line':e.get('commentLine'),'comment_start':e.get('commentStart'),'comment_end':e.get('commentEnd'),'keyword_sets':[x.get('name') for x in e.findall('Keywords')]})
profilepaths=['PowerEditor/src/langs.model.xml','PowerEditor/src/stylers.model.xml','PowerEditor/installer/packageAll.bat','PowerEditor/installer/msi/defaultPlugins.wxs','PowerEditor/installer/nppSetup.nsi']
for folder in ['PowerEditor/installer/nativeLang','PowerEditor/installer/APIs','PowerEditor/installer/functionList','PowerEditor/installer/themes']:
 profilepaths += [str(p.relative_to(src)) for p in sorted((src/folder).glob('*.xml'))]
profile={'source_commit':pin,'source_version':'8.9.8.1','profile':'official source standard portable/installer package recipes','artifact_version':None,'artifact_url':None,'artifact_sha256':None,'artifact_state':'unresolved; official distribution has not been downloaded/verified','source_url':base+'PowerEditor/installer/packageAll.bat','standard_bundled_utilities':['mimeTools','NppConverter','NppExport'],'configurations':[source(p) for p in profilepaths],'languages':languages,'limits':['Source packaging recipes establish intended files, not actual released archive contents or exact plugin binary versions.','All language styles/keywords, per-language settings, APIs, localizations and function-list parsers remain required; data presence is not implementation.']}
write('reference-profile.json',profile)
write('seed-dispositions.json',{'source_commit':pin,'definition_count':len(disp),'definitions':disp,'range_expansion_state':'incomplete; dynamic per-document/menu, user languages and extension commands need detailed runtime-instance contracts'})
write('capabilities.json',{'schema_version':1,'source_commit':pin,'inventory_state':'expanded working inventory; NOT a complete deduplicated behavioral denominator','completion_claim':False,'required_semantic_dedup_remaining':['menu vs default keyboard commands','dialog options/preferences combinations','dynamic menu instances and language registrations','bundled utility version-specific behavior'],'capabilities':rows})
print(f'{len(disp)} seed dispositions; {len(rows)} working rows; {len(languages)} languages; {len(profilepaths)} hashed profile inputs. No verified rows.')
