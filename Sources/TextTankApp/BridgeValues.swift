import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

extension LineEnding {
    var nativeMode: TTLineEndingMode {
        switch self {
        case .lf: return .lf
        case .crlf: return .crlf
        case .cr: return .cr
        }
    }
}

extension TTLineEndingMode {
    var lineEnding: LineEnding {
        switch self {
        case .crlf: return .crlf
        case .cr: return .cr
        default: return .lf
        }
    }
}

extension EditorCommand {
    var nativeIdentifier: TTEditorCommandIdentifier { TTEditorCommandIdentifier(rawValue: rawValue) }
}
