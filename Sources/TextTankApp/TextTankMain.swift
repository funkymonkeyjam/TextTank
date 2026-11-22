import TextTankRuntime

@main struct TextTankMain {
    @MainActor static func main() { TextTankApplication.run() }
}

import AppIntents
import Foundation
import TextTankCore

struct OpenTextTankFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Open a Text File in TextTank" }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "File", supportedTypeIdentifiers: ["public.text", "public.plain-text"])
    var file: IntentFile

    @MainActor func perform() async throws -> some IntentResult {
        guard let url = file.fileURL, !file.removedOnCompletion else {
            throw AutomationError.invalid("Choose an existing local text file to open in TextTank.")
        }
        try TextTankApplication.openSuppliedTextFile(url)
        return .result()
    }
}

struct TextTankAutomationNames: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let library = try AutomationLibrary.forSuppliedText()
        return library.workflows.compactMap { workflow in
            guard (try? library.namedForSuppliedText(workflow.name)) != nil else { return nil }
            return workflow.name
        }
    }
}

struct RunTextTankAutomationIntent: AppIntent {
    static var title: LocalizedStringResource { "Run a TextTank Automation on Text" }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Automation", optionsProvider: TextTankAutomationNames()) var name: String
    @Parameter(title: "Text") var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let workflow = try AutomationLibrary.forSuppliedText().namedForSuppliedText(name)
        let control = AutomationRunControl()
        let output = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try workflow.transform(text, control: control)
        } onCancel: {
            control.cancel()
        }
        return .result(value: output)
    }
}

struct TextTankUtilityNames: DynamicOptionsProvider {
    func results() async throws -> [String] { TextUtility.allCases.map(\.title) }
}

struct RunTextTankUtilityIntent: AppIntent {
    static var title: LocalizedStringResource { "Apply a TextTank Text Utility" }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Utility", optionsProvider: TextTankUtilityNames()) var utility: String
    @Parameter(title: "Text") var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let operation = TextUtility.allCases.first(where: { $0.title == utility }) else {
            throw AutomationError.invalid("Choose a TextTank text utility.")
        }
        try Task.checkCancellation()
        return .result(value: try operation.apply(text))
    }
}
