// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct LanguageChecks {
 static func main() throws {
  var checks=0
  func check(_ value:Bool,_ name:String){precondition(value,name);checks+=1;print("PASS \(name)")}
  func rejects(_ name:String,_ work:()throws->Void){do{try work();fatalError("Expected rejection \(name)")}catch{checks+=1}}
  let catalog=try LanguageCatalog.decode(Data(contentsOf:URL(fileURLWithPath:"Resources/LanguageProfiles.json")))
  check(catalog.profiles.count==96,"all 96 source definitions retained")
  check(catalog.sourceCommit=="61246e5741fd7c59352f3feb5ccc7e33e4594d15","reference source pinned")
  check(try LanguageCatalog.decode(catalog.encoded())==catalog,"catalog roundtrip")
  check(catalog.detect(filename:"HELLO.PY",text:"")=="python","case-insensitive extension detection")
  check(catalog.detect(filename:"CMakeLists.txt",text:"")=="cmake","special filename beats txt extension")
  check(catalog.detect(filename:"script",text:"#!/usr/bin/env python3\n")=="python","bounded shebang detection")
  check(catalog.detect(filename:"unknown.zzzz",text:"")==nil,"unknown file remains explicit choice")
  let python=catalog.profiles.first{$0.id=="python"}!
  check(python.completions.contains("def"),"source keywords supply completion")
  let symbols=try LanguageFunctions.symbols(text:"# café\r\nclass Example:\r\n    def work(self):\r\n        return 1\r\n",profile:python)
  check(symbols.map(\.name)==["Example","work"] && symbols.map(\.line)==[2,3],"function navigation Unicode CRLF line offsets")
  check(try LanguageFunctions.symbols(text:"# def fake():\nvalue = 'def fake()'",profile:python).isEmpty,"basic anchored parser avoids inline false positives")
  var invalid=python; invalid.functionPattern="["; rejects("malformed function pattern"){try invalid.validate()}
  invalid=python;invalid.functionPattern="def";rejects("missing symbol capture"){try invalid.validate()}
  invalid=python;invalid.keywordLists=["32":"bad"];rejects("out-of-range keyword index"){try invalid.validate()}
  invalid=python;invalid.properties=["bad\0":"value"];rejects("NUL lexer property"){try invalid.validate()}
  invalid=python;invalid.functionPattern="(a+)+$"
  let start=ProcessInfo.processInfo.systemUptime
  rejects("pathological custom function pattern"){_ = try LanguageFunctions.symbols(text:String(repeating:"a",count:32)+"!",profile:invalid,timeLimit:0.05)}
  check(ProcessInfo.processInfo.systemUptime-start<1,"function parser time bound")
  var duplicate=catalog;duplicate.profiles.append(python);rejects("duplicate profile id"){try duplicate.validate()}
  let udl=Data("""
  <?xml version="1.0"?><NotepadPlus><UserLang name="Custom Test" ext="sample" udlVersion="2.1"><Settings><Global caseIgnored="yes" forcePureLC="0" decimalSeparator="0"/><Prefix Keywords1="no"/></Settings><KeywordLists><Keywords name="Keywords1">hello world</Keywords><Keywords name="Comments">00// 01 02 03/* 04*/</Keywords><Keywords name="Delimiters">00&quot; 01\\ 02&quot; 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23</Keywords></KeywordLists><Styles><WordsStyle name="KEYWORDS1" fgColor="0000FF" fontStyle="1" nesting="0"/></Styles></UserLang></NotepadPlus>
  """.utf8)
  let definitions=try UserDefinedLanguage.decode(udl),profile=try definitions[0].profile()
  check(profile.lexer=="user" && profile.keywordLists["7"]=="hello world" && profile.properties["userDefine.isCaseIgnored"]=="1","UDL maps keyword slot7 and case settings")
  check(try UserDefinedLanguage.decode(definitions[0].encodedXML())[0].profile()==profile,"UDL export reimport preserves native profile")
  check(try UserDefinedLanguage.words("\"else if\" 'end if'")=="else\u{b}if end\u{8}if","UDL quoted multipart keyword encoding")
  rejects("UDL external entity rejection"){_ = try UserDefinedLanguage.decode(Data("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><NotepadPlus/>".utf8))}
  rejects("UDL malformed XML"){_ = try UserDefinedLanguage.decode(Data("<NotepadPlus>".utf8))}
  rejects("UDL unbalanced keyword quotes"){_ = try UserDefinedLanguage.words("\"open")}
  print("PASS LanguageChecks: \(checks) assertions; data/navigation core, not complete lexer semantics")
 }
}
