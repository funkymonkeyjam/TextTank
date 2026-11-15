// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded diagnostic; never executes a configured command or connector.
import Foundation
@main struct Probe {
 static func main() throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("TextTankAudit-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:directory)}
  let command=ConfiguredRun(name:"Never executed audit fixture",executable:"/usr/bin/printf",arguments:[String(repeating:"a",count:600000),String(repeating:"b",count:600000)])
  try ConfiguredRun.validateLibrary([command])
  let bytes=try JSONEncoder().encode([command])
  let url=directory.appendingPathComponent("RunCommands.json")
  try WorkspaceStore.writePrivate(bytes,to:url)
  print("Run validation and production writer accepted encoded bytes:",bytes.count)
  do {_ = try WorkspaceStore.readRegularFile(url,maximumBytes:1024*1024);fatalError("unexpected read success")}
  catch {print("Production startup read rejected:",error)}
  var workflow=AutomationDefinition.example
  workflow.steps=Array(repeating:.init(kind:.replaceLiteral,find:"a",replacement:"aa"),count:20)
  try workflow.validate()
  let result=try workflow.transform("a")
  print("Validated ordinary transform expanded 1 byte into:",result.utf8.count)
  do {_ = try workflow.testSample("a");fatalError("expected preview limit")}
  catch {print("Same workflow sample rejects:",error.localizedDescription)}
 }
}
