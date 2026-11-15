#!/usr/bin/env python3
"""Import data only from the frozen official Notepad++ source. GPL-3.0-or-later."""
import hashlib,json,pathlib,re,sys,xml.etree.ElementTree as ET
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
paths=['PowerEditor/src/langs.model.xml','PowerEditor/src/stylers.model.xml','PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp']
source=(root/paths[2]).read_text()
mapping={m[0]:(m[1],m[2]) for m in re.findall(r'\{L"([^"]+)",\s*L"([^"]+)",\s*L"[^"]+",\s*\w+,\s*"([^"]+)"\}',source)}
styles={e.get('name'):e for e in ET.parse(root/paths[1]).findall('.//LexerType')}
classes=['instre1','instre2','type1','type2','type3','type4','type5','type6','type7']
profiles=[]
for lang in ET.parse(root/paths[0]).findall('.//Language'):
 name=lang.get('name'); title,lexer=mapping.get(name,(name,'null'))
 raw={k.get('name'):' '.join((k.text or '').split()) for k in lang.findall('Keywords')}
 keywords={str(i):raw.get(k,'') for i,k in enumerate(classes)}
 if lexer=='cpp': keywords={'0':raw.get('instre1',''),'1':raw.get('type1',''),'2':'','3':raw.get('instre2','')}
 props={'fold':'1','fold.compact':'0','fold.comment':'1'}
 if lexer=='cpp':props.update({'lexer.cpp.track.preprocessor':'0','fold.preprocessor':'1'})
 if name=='go':props['lexer.cpp.backquoted.strings']='1'
 if name=='json5': props.update({'lexer.json.allow.comments':'1','lexer.json.escape.sequence':'1'})
 style=styles.get(name); rows=[]
 if style is not None:
  for e in style.findall('WordsStyle'):
   rows.append({'id':int(e.get('styleID','0')),'name':e.get('name',''),'foreground':e.get('fgColor','000000'),'fontStyle':int(e.get('fontStyle','0') or '0')})
 # Upstream numbers this language's styles for JavaScript embedded in HTML (the hypertext lexer).
 # Here it runs the cpp lexer, so each style moves to the cpp style with the same meaning. The
 # embedded identifier style (46) and the server-side template style (68) have no cpp counterpart.
 if name=='javascript' and lexer=='cpp':
  moved={41:11,42:1,43:2,44:3,45:4,47:5,48:6,49:7,50:10,52:14,53:20,**{200+i:128+i for i in range(8)}}
  rows=[{**r,'id':moved[r['id']]} for r in rows if r['id'] in moved]
 # These three share a lexer with another language and have no styles of their own for its style
 # numbers. The editor no longer colours unstyled numbers with C defaults, so they borrow them.
 shared=styles.get({'asp':'html','jsp':'html','json5':'json'}.get(name,''))
 if shared is not None:
  have={r['id'] for r in rows}
  for e in shared.findall('WordsStyle'):
   if int(e.get('styleID','0')) not in have: rows.append({'id':int(e.get('styleID','0')),'name':e.get('name',''),'foreground':e.get('fgColor','000000'),'fontStyle':int(e.get('fontStyle','0') or '0')})
 profiles.append({'id':name,'title':title,'lexer':lexer,'extensions':lang.get('ext','').split(),'keywordLists':keywords,'referenceKeywordClasses':raw,'properties':props,'styles':rows,'functionPattern':None,'comments':{'line':lang.get('commentLine'),'blockOpen':lang.get('commentStart'),'blockClose':lang.get('commentEnd')}})
# Native basic symbol navigation patterns are explicitly separate from upstream functionList parser semantics.
patterns={'python':r'(?m)^[ \t]*(?:async[ \t]+)?(?:def|class)[ \t]+([\p{L}_][\p{L}\p{N}_]*)','swift':r'(?m)^[ \t]*(?:(?:public|private|internal|fileprivate|open|final|static|class|override|mutating)[ \t]+)*(?:func|class|struct|enum|protocol)[ \t]+([\p{L}_][\p{L}\p{N}_]*)','javascript.js':r'(?m)^[ \t]*(?:export[ \t]+)?(?:async[ \t]+)?(?:function|class)[ \t]+([\p{L}_$][\p{L}\p{N}_$]*)','rust':r'(?m)^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?(?:fn|struct|enum|trait|mod)[ \t]+([\p{L}_][\p{L}\p{N}_]*)','ruby':r'(?m)^[ \t]*(?:def|class|module)[ \t]+([\p{L}_][\p{L}\p{N}_?.!]*)'}
for p in profiles:p['functionPattern']=patterns.get(p['id'])
result={'version':1,'sourceCommit':'61246e5741fd7c59352f3feb5ccc7e33e4594d15','sourceHashes':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in paths},'limitations':['Imported data and lexer mapping are source evidence, not full language verification.','Complex embedded lexer properties, substyles and reference function-list XML semantics remain unverified.','LexUser UDL requires the Notepad++ engine delta; generic profiles are not UDL compatibility.'],'profiles':profiles}
out.write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n')
print(len(profiles),'profiles imported')
