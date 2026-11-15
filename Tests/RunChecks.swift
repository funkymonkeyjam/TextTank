import Foundation
@main struct RunChecks {
 static func main() {
  Checks.run("RunChecks") {
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
  check(timeout.cancelled && Date().timeIntervalSince(start)<10,"timeout terminates child promptly")
  rejects("missing executable surfaces launch error"){_ = try RunExecution().execute(ConfiguredRun(name:"Missing",executable:"/no/such/executable",arguments:[]))}
  let noisy=try RunExecution().execute(ConfiguredRun(name:"Bounded output",executable:"/usr/bin/yes",arguments:[]),timeout:2)
  check(noisy.truncated && noisy.stdout.count+noisy.stderr.count<=4*1024*1024,"output flood bounded and process stopped")
  let descendant=ConfiguredRun(name:"Descendant",executable:"/bin/zsh",arguments:["-c","/bin/sleep 10 & exit 0"],shellMode:true)
  // The 0.5 s descendant grace must end the run long before the 10 s timeout or the 10 s sleep.
  let began=Date();let orphan=try RunExecution().execute(descendant,timeout:10)
  check(orphan.truncated && !orphan.cancelled && Date().timeIntervalSince(began)<5,"inherited descendant pipes cannot retain worker indefinitely")
  let config=ConfiguredRun.uppercaseSample
  rejects("duplicate identities rejected before configuration save"){try ConfiguredRun.validateLibrary([config,config])}
  let encoded=try JSONEncoder().encode(config)
  check(try JSONDecoder().decode(ConfiguredRun.self,from:encoded)==config,"configuration roundtrip preserves extension identity without execution")
  var boundary=ConfiguredRun(name:"Boundary",executable:"/usr/bin/printf",arguments:[""])
  let overhead=try ConfiguredRun.encodeLibrary([boundary]).count
  boundary.arguments=[String(repeating:"x",count:ConfiguredRun.maximumLibraryBytes-overhead)]
  let boundaryData=try ConfiguredRun.encodeLibrary([boundary])
  check(boundaryData.count==ConfiguredRun.maximumLibraryBytes,"exact aggregate JSON byte boundary accepted")
  check(try ConfiguredRun.decodeLibrary(boundaryData)==[boundary],"exact-boundary library restart roundtrip")
  boundary.arguments[0]+="x"
  rejects("one byte over aggregate boundary rejected"){_ = try ConfiguredRun.encodeLibrary([boundary])}
  let escaped=ConfiguredRun(name:"Escaped",executable:"/usr/bin/printf",arguments:[String(repeating:"\"\n",count:300000)])
  rejects("JSON escaping counted in aggregate ceiling"){_ = try ConfiguredRun.encodeLibrary([escaped])}
  let large=ConfiguredRun(name:"Large",executable:"/usr/bin/printf",arguments:[String(repeating:"x",count:600000),String(repeating:"y",count:600000)])
  rejects("valid individual arguments cannot exceed aggregate ceiling"){_ = try ConfiguredRun.encodeLibrary([large])}
  var second=large;second.id=UUID();second.arguments.removeLast();var first=large;first.arguments.removeLast()
  rejects("aggregate ceiling spans multiple commands"){_ = try ConfiguredRun.encodeLibrary([first,second])}
  rejects("restart rejects oversized bytes before JSON decoding"){_ = try ConfiguredRun.decodeLibrary(Data(repeating:32,count:ConfiguredRun.maximumLibraryBytes+1))}
  Checks.summary { "PASS RunChecks: \(Checks.count) assertions" }
  }
 }
}
