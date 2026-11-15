import Foundation
@main struct RunChecks {
 static func main()throws {
  var count=0
  func check(_ value:Bool,_ label:String){guard value else{fatalError(label)};count+=1;print("PASS "+label)}
  let dangerous="space ; $(printf wrong) `touch /no` ' \""
  let c=ConfiguredRun(name:"Arguments",executable:"/usr/bin/printf",arguments:["%s","{selection}"])
  let resolved=try c.resolved(file:nil,selection:dangerous)
  let result=try RunExecution().execute(resolved)
  check(String(data:result.stdout,encoding:.utf8)==dangerous && result.status==0,"argv preserves spaces quotes and shell metacharacters without interpretation")
  let sample=try RunExecution().execute(.uppercaseSample,input:Data("hello world α".utf8))
  check(String(data:sample.stdout,encoding:.utf8)=="HELLO WORLD α","sample extension actual stdin stdout protocol")
  let fail=ConfiguredRun(name:"Fail",executable:"/bin/zsh",arguments:["-c","printf problem >&2; exit 7"],shellMode:true)
  let failed=try RunExecution().execute(fail)
  check(failed.status==7 && String(data:failed.stderr,encoding:.utf8)=="problem","explicit shell reports stderr and exit status")
  let cancelled=RunExecution();cancelled.cancel();let stopped=try cancelled.execute(c)
  check(stopped.cancelled,"cancel before launch prevents execution")
  let sleeper=ConfiguredRun(name:"Timeout",executable:"/bin/sleep",arguments:["10"])
  let start=Date();let timeout=try RunExecution().execute(sleeper,timeout:0.1)
  check(timeout.cancelled && Date().timeIntervalSince(start)<2,"timeout terminates child promptly")
  do{_ = try RunExecution().execute(ConfiguredRun(name:"Missing",executable:"/no/such/executable",arguments:[]));fatalError("accepted missing")}catch{count+=1;print("PASS missing executable surfaces launch error")}
  let noisy=try RunExecution().execute(ConfiguredRun(name:"Bounded output",executable:"/usr/bin/yes",arguments:[]),timeout:2)
  check(noisy.truncated && noisy.stdout.count+noisy.stderr.count<=4*1024*1024,"output flood bounded and process stopped")
  let descendant=ConfiguredRun(name:"Descendant",executable:"/bin/zsh",arguments:["-c","/bin/sleep 10 & exit 0"],shellMode:true)
  let began=Date();let orphan=try RunExecution().execute(descendant,timeout:2)
  check(orphan.truncated && Date().timeIntervalSince(began)<2,"inherited descendant pipes cannot retain worker indefinitely")
  let config=ConfiguredRun.uppercaseSample
  do{try ConfiguredRun.validateLibrary([config,config]);fatalError("duplicate ids accepted")}catch{count+=1;print("PASS duplicate identities rejected before configuration save")}
  let encoded=try JSONEncoder().encode(config)
  check(try JSONDecoder().decode(ConfiguredRun.self,from:encoded)==config,"configuration roundtrip preserves extension identity without execution")
  var boundary=ConfiguredRun(name:"Boundary",executable:"/usr/bin/printf",arguments:[""])
  let overhead=try ConfiguredRun.encodeLibrary([boundary]).count
  boundary.arguments=[String(repeating:"x",count:ConfiguredRun.maximumLibraryBytes-overhead)]
  let boundaryData=try ConfiguredRun.encodeLibrary([boundary])
  check(boundaryData.count==ConfiguredRun.maximumLibraryBytes,"exact aggregate JSON byte boundary accepted")
  check(try ConfiguredRun.decodeLibrary(boundaryData)==[boundary],"exact-boundary library restart roundtrip")
  boundary.arguments[0]+="x"
  do{_ = try ConfiguredRun.encodeLibrary([boundary]);fatalError("over boundary accepted")}catch{check(true,"one byte over aggregate boundary rejected")}
  let escaped=ConfiguredRun(name:"Escaped",executable:"/usr/bin/printf",arguments:[String(repeating:"\"\n",count:300000)])
  do{_ = try ConfiguredRun.encodeLibrary([escaped]);fatalError("escaped aggregate accepted")}catch{check(true,"JSON escaping counted in aggregate ceiling")}
  let large=ConfiguredRun(name:"Large",executable:"/usr/bin/printf",arguments:[String(repeating:"x",count:600000),String(repeating:"y",count:600000)])
  do{_ = try ConfiguredRun.encodeLibrary([large]);fatalError("oversized aggregate accepted")}catch{check(true,"valid individual arguments cannot exceed aggregate ceiling")}
  var second=large;second.id=UUID();second.arguments.removeLast();var first=large;first.arguments.removeLast()
  do{_ = try ConfiguredRun.encodeLibrary([first,second]);fatalError("multi-command aggregate accepted")}catch{check(true,"aggregate ceiling spans multiple commands")}
  do{_ = try ConfiguredRun.decodeLibrary(Data(repeating:32,count:ConfiguredRun.maximumLibraryBytes+1));fatalError("oversized decode accepted")}catch{check(true,"restart rejects oversized bytes before JSON decoding")}
  print("PASS RunChecks: \(count) assertions")
 }
}
