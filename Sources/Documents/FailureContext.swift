// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Preserve the syscall's error number before evaluating a path or doing cleanup. Call with
/// `FileOperationFailure(errno, operation: ..., path: ...)`, with errno as the first argument.
struct FileOperationFailure: LocalizedError, CustomNSError {
    let errorNumber: Int32
    let operation: String
    let path: String
    init(_ errorNumber: Int32, operation: String, path: String) {
        self.errorNumber = errorNumber == 0 ? EIO : errorNumber
        self.operation = operation
        self.path = path
    }
    static var errorDomain: String { NSPOSIXErrorDomain }
    var errorCode: Int { Int(errorNumber) }
    var errorDescription: String? {
        "Could not \(operation) “\(path)”: \(String(cString: strerror(errorNumber)))."
    }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "", NSFilePathErrorKey: path,
         NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)]
    }
}

extension Error {
    var isFileNotFound: Bool {
        let error = self as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            || (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue)
    }
    var posixCode: POSIXErrorCode? {
        let error = self as NSError
        return error.domain == NSPOSIXErrorDomain ? POSIXErrorCode(rawValue: Int32(clamping: error.code)) : nil
    }
}

/// A JSON editor needs the field path, not the decoder's generic Cocoa wording. The underlying
/// error remains available to diagnostics; neither a failed decode nor this wrapper writes data.
struct JSONInputFailure: LocalizedError {
    let message: String
    let underlying: Error
    var errorDescription: String? { message }
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data, context: String) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch let error as DecodingError {
            let message: String
            func path(_ keys: [CodingKey]) -> String {
                keys.reduce(context) { text, key in
                    if let index = key.intValue { return text + "[\(index)]" }
                    return text + "." + key.stringValue
                }
            }
            switch error {
            case .keyNotFound(let key, let detail):
                message = "A required value is missing at \(path(detail.codingPath + [key])). The saved data was not changed."
            case .typeMismatch(_, let detail):
                message = "The value at \(path(detail.codingPath)) has the wrong JSON type. The saved data was not changed."
            case .valueNotFound(_, let detail):
                message = "The value at \(path(detail.codingPath)) cannot be null. The saved data was not changed."
            case .dataCorrupted(let detail):
                message = detail.codingPath.isEmpty
                    ? "The JSON is not valid. Check its punctuation and quoted text. The saved data was not changed."
                    : "The value at \(path(detail.codingPath)) is not valid. The saved data was not changed."
            @unknown default:
                message = "The JSON could not be read. The saved data was not changed."
            }
            throw Self(message: message, underlying: error)
        }
    }
}

/// Named Swift errors retain the existing bridged domain/codes for callers that display them
/// through Cocoa. Code numbers are compatibility metadata, never behavior selectors.
enum DocumentActionError: LocalizedError, CustomNSError {
    case diskChanged, notSaved, unsavedChanges, unsafeDiskPath(URL, underlying: Error)
    case multipleSelections, selectionTooLarge, changeRejected, replacementRejected, lineEndingsRejected
    static var errorDomain: String { "TextTank" }
    var errorCode: Int {
        switch self {
        case .diskChanged: return 1
        case .notSaved: return 2
        case .unsavedChanges: return 3
        case .multipleSelections: return 4
        case .unsafeDiskPath, .selectionTooLarge: return 5
        case .changeRejected: return 6
        case .replacementRejected: return 7
        case .lineEndingsRejected: return 8
        }
    }
    var errorDescription: String? {
        switch self {
        case .diskChanged:
            return "The file changed outside TextTank. Use Save As to preserve your edits, or revert to inspect the disk version."
        case .notSaved: return "Save the document before reloading its disk bytes."
        case .unsavedChanges: return "Reload would discard unsaved changes."
        case .unsafeDiskPath(let url, _):
            return "“\(url.path)” is now a symbolic link or its folder was replaced, so TextTank will not read or overwrite it in place. Your editor contents are preserved; use Save As to keep them."
        case .multipleSelections:
            return "This command works on a single selection. Collapse multiple selections and try again."
        case .selectionTooLarge: return "Select at most 16 MiB for this command."
        case .changeRejected: return "The document could not be changed."
        case .replacementRejected: return "The replacement text could not be written. Nothing was changed."
        case .lineEndingsRejected: return "Line endings could not be converted. Nothing was changed."
        }
    }
    var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? ""]
        if case .unsafeDiskPath(_, let error) = self { info[NSUnderlyingErrorKey] = error }
        return info
    }
}
