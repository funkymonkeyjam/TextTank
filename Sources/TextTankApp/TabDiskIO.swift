import Foundation
import CryptoKit
import Darwin
import TextTankCore

/// A descriptor is transferred exactly once. Eviction closes queued captures only;
/// a running worker owns and closes its local descriptor, never a reused number.
final class TabDiskCapture: @unchecked Sendable {
    let signature: FileSignature
    private let lock = NSLock()
    private var queued: Int32?
    init(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw WorkspaceError.unsafeLocation
        }
        signature = FileSignature(info)
        queued = fd
    }
    func take() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        let result = queued
        queued = nil
        return result
    }
    func cancelQueued() { if let fd = take() { Darwin.close(fd) } }
    deinit { cancelQueued() }
}
struct TabDiskRead: Sendable {
    let data: Data
    let digest: String
    let signature: FileSignature
    let modificationDate: Date
    let writable: Bool
}
/// Serial I/O bounds concurrent fingerprint memory to one chunk buffer. History
/// eviction cancels queued descriptors; no task captures an editor or document.
actor TabDiskIO {
    static let shared = TabDiskIO()
    func fingerprint(_ capture: TabDiskCapture) -> String? {
        try? scan(capture, collecting: false).digest
    }
    func read(_ url: URL) throws -> TabDiskRead {
        let capture = try TabDiskCapture(url)
        let result = try scan(capture, collecting: true)
        let s = capture.signature
        return TabDiskRead(
            data: result.data, digest: result.digest, signature: s,
            modificationDate: Date(
                timeIntervalSinceReferenceDate: Double(s.modifiedSeconds) - Date.timeIntervalBetween1970AndReferenceDate
                    + Double(s.modifiedNanoseconds) / 1_000_000_000),
            writable: FileManager.default.isWritableFile(atPath: url.path))
    }
    private func scan(_ capture: TabDiskCapture, collecting: Bool) throws -> (digest: String, data: Data) {
        guard let fd = capture.take() else { throw CancellationError() }
        defer { Darwin.close(fd) }
        try Task.checkCancellation()
        var before = stat()
        guard fstat(fd, &before) == 0, FileSignature(before) == capture.signature else {
            throw WorkspaceError.invalid("The file changed while it was being read. Try again.")
        }
        var hash = SHA256(), data = Data(), total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= capture.signature.size else {
                throw WorkspaceError.invalid("The file changed while it was being read. Try again.")
            }
            buffer.withUnsafeBytes { bytes in
                let chunk = UnsafeRawBufferPointer(rebasing: bytes[0..<count])
                hash.update(bufferPointer: chunk)
                if collecting { data.append(contentsOf: chunk) }
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, FileSignature(after) == capture.signature, total == capture.signature.size else {
            throw WorkspaceError.invalid("The file changed while it was being read. Try again.")
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), data)
    }
}
