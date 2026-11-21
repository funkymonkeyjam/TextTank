import AppKit
import ObjectiveC
@testable import TextTankCore
@testable import TextTankRuntime

@main struct ModuleContractChecks {
    @MainActor static func main() {
        Checks.run("ModuleContractChecks") {
            let isolated = try IsolatedSupportDirectory("TextTankModuleContracts")
            defer { isolated.restore() }
            // Loading the actual Runtime must register NSDocumentClass without creating
            // NSApplication or invoking the normal product bootstrap.
            check(NSApp == nil, "module loading leaves NSApplication unconstructed")
            let registered: AnyClass = try requireValue(
                NSClassFromString("TextDocument"), "Runtime document class registration")
            check(
                ObjectIdentifier(registered) == ObjectIdentifier(TextDocument.self),
                "stable Objective-C TextDocument registration survives framework linking")
            let dependencies = DocumentDependencies()
            check(
                dependencies.automaticRecoveryDelay == 0.5 && dependencies.maximumRecoveryDelay == 5,
                "actual Runtime production recovery delays are 0.5 and 5 seconds")
            check(
                dependencies.afterWrite == nil && dependencies.duringWrite == nil
                    && dependencies.recoveryFailureNotice == nil,
                "actual Runtime production write and notice effects default to nil")
            check(
                RuntimeDependencies().windowAnimation == .some(.none),
                "actual Runtime production document transitions disable window animation")
            let manifestPath = try requireValue(
                ProcessInfo.processInfo.environment["TEXTTANK_ARTIFACT_MANIFEST"], "owned artifact manifest")
            let manifest = try requireValue(
                try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
                    as? [String: Any], "artifact record")
            let app = URL(fileURLWithPath: try requireValue(manifest["app"] as? String, "actual built application"))
            let plist = try requireValue(
                try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), options: [], format: nil)
                    as? [String: Any],
                "actual application Info.plist")
            let types = try requireValue(plist["CFBundleDocumentTypes"] as? [[String: Any]], "actual document types")
            check(
                !types.isEmpty && types.allSatisfy { $0["NSDocumentClass"] as? String == "TextDocument" },
                "actual application document types resolve the stable Runtime class")
            check(NSApp == nil, "class and production-default checks never launch or bootstrap the product")
        }
    }
}
