import Darwin
import Dispatch
import Foundation
import TextTankCore

/// Owns at most one local vnode subscription. The queue serializes descriptor ownership,
/// replacement and cancellation. Callers receive only a generation on the main queue.
final class ExternalFileWatch: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "TextTank.external-file-watch", qos: .utility)
    private let deliver: @MainActor @Sendable (UInt) -> Void
    private var url: URL?
    private var generation: UInt = 0
    private var source: DispatchSourceFileSystemObject?
    private var sourceID = UUID()
    private var pending: DispatchWorkItem?

    init(deliver: @escaping @MainActor @Sendable (UInt) -> Void) { self.deliver = deliver }

    deinit { source?.cancel() }

    func follow(_ next: URL?, generation: UInt) {
        Self.queue.async { [self] in
            if next != url || generation != self.generation {
                cancelSource()
                pending?.cancel()
                pending = nil
                url = next
                self.generation = generation
            }
            if source == nil, let next, attach(next) { notify() }
        }
    }
    private func cancelSource() {
        sourceID = UUID()
        source?.cancel()
        source = nil
    }
    private func notify() {
        let generation = generation, deliver = deliver
        DispatchQueue.main.async { deliver(generation) }
    }
    private func event(for id: UUID) {
        guard id == sourceID, let source else { return }
        if !source.data.isDisjoint(with: [.rename, .delete, .revoke]) { cancelSource() }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let target = self.url else { return }
            self.pending = nil
            if self.source == nil { _ = self.attach(target) }
            self.notify()
        }
        pending = work
        Self.queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: work)
    }
    private func attach(_ target: URL) -> Bool {
        guard Self.isLocalMount(target), Self.hasDescriptorRoom(),
            let opened = try? PrivateFileStore.openRegularFile(target, maximumBytes: Int.max)
        else { return false }
        let fd = opened.descriptor
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            close(fd)
            return false
        }
        let subscription = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke, .link],
            queue: Self.queue)
        let id = UUID()
        sourceID = id
        source = subscription
        subscription.setEventHandler { [weak self] in self?.event(for: id) }
        subscription.setCancelHandler { close(fd) }
        subscription.resume()
        return true
    }
    /// Inspect the kernel's mounted-filesystem table without refreshing a network server.
    /// Descriptor inspection then verifies the volume actually opened, including firmlinks.
    private static func isLocalMount(_ url: URL) -> Bool {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return false }
        defer { free(entries) }
        var longest = 0, local = false
        let path = url.path
        for entry in UnsafeBufferPointer(start: entries, count: Int(count)) {
            let mount = withUnsafeBytes(of: entry.f_mntonname) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard mount.utf8.count > longest,
                mount == "/" || path == mount || path.hasPrefix(mount + "/")
            else { continue }
            longest = mount.utf8.count
            local = entry.f_flags & UInt32(MNT_LOCAL) != 0
        }
        return local
    }
    private static func hasDescriptorRoom() -> Bool {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return false }
        // proc_pidinfo's buffer estimate includes spare entries. Keep them available to
        // editors, file saves and activation checks when the process approaches its soft limit.
        let estimated = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        return estimated > 0 && UInt64(estimated / Int32(MemoryLayout<proc_fdinfo>.stride) + 8) < limit.rlim_cur
    }
}
