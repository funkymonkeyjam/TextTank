// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Conservative grapheme prefix/suffix refinement: a single exact interior span per changed block.
/// Opaque Character segmentation is admitted only for a bounded64KiB combined span.
enum ReviewInline {
    static func refine(_ blocks: [ReviewChangeBlock], _ a: TextSnapshot, _ b: TextSnapshot,
        lineMeter: ReviewMeter) throws -> [ReviewChangeBlock] {
        let limits = lineMeter.policy.inline
        var policy = ReviewDiffPolicy()
        policy.maximumWork = min(250_000,limits.maximumWork)
        policy.seconds = min(0.250,limits.seconds)
        policy.maximumWorkspaceBytes = min(16*1024*1024,limits.maximumWorkspaceBytes)
        let meter = ReviewMeter(policy,token: lineMeter.token,hooks: lineMeter.hooks)
        lineMeter.metrics.phases.insert(.inline)
        var tokens = 0, spans = 0, output: [ReviewChangeBlock] = [], exhausted: ReviewBudgetReason?
        for block in blocks {
            var state: ReviewInlineState = .unrefined(exhausted ?? .span)
            if exhausted == nil {
                do {
                    try meter.enter(.inline)
                    let na = block.original.upper-block.original.lower, nb = block.modified.upper-block.modified.lower
                    guard na+nb <= min(64*1024,limits.maximumSpanBytes) else { throw ReviewHalt.budget(.span) }
                    // Include String storage, token ranges, and conservative temporary capacity.
                    let storage = (na+nb+1)*96
                    try meter.reserve(storage);defer { meter.release(storage) }
                    let aa = ReviewUTF8.slice(a.bytes,block.original.lower,block.original.upper)
                    let bb = ReviewUTF8.slice(b.bytes,block.modified.lower,block.modified.upper)
                    try meter.spend(na+nb)
                    func boundaries(_ bytes: Data) throws -> [Int] {
                        var values = [0], offset = 0
                        for character in String(decoding: bytes,as: UTF8.self) {
                            try meter.poll()
                            guard tokens < min(32_000,limits.maximumTokens) else { throw ReviewHalt.budget(.tokens) }
                            tokens += 1
                            let size = String(character).utf8.count
                            try meter.spend(size+1);offset += size;values.append(offset)
                        }
                        return values
                    }
                    let ar = try boundaries(aa), br = try boundaries(bb)
                    func equal(_ x: Int,_ y: Int) throws -> Bool {
                        let n = ar[x+1]-ar[x], m = br[y+1]-br[y]
                        guard n == m else { try meter.spend();return false }
                        return try aa.withUnsafeBytes { (ab: UnsafeRawBufferPointer) in
                            try bb.withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
                                var i = 0
                                while i < n {
                                    let end = min(n,i+1024);try meter.spend(end-i)
                                    if !ab[(ar[x]+i)..<(ar[x]+end)].elementsEqual(bb[(br[y]+i)..<(br[y]+end)]) { return false };i = end
                                };return true
                            }
                        }
                    }
                    var start = 0, endA = ar.count-1, endB = br.count-1
                    while start < endA && start < endB && (try equal(start,start)) { start += 1 }
                    while endA > start && endB > start && (try equal(endA-1,endB-1)) { endA -= 1;endB -= 1 }
                    guard spans < min(32_000,limits.maximumSpans), (spans+1)*256 <= min(8*1024*1024,limits.maximumOutputBytes) else {
                        throw ReviewHalt.budget(.output)
                    }
                    try meter.poll();spans += 1
                    state = .refined([.init(
                        original: .init(snapshot: a.id,lower: block.original.lower+ar[start],upper: block.original.lower+ar[endA]),
                        modified: .init(snapshot: b.id,lower: block.modified.lower+br[start],upper: block.modified.lower+br[endB]))])
                } catch ReviewHalt.cancelled { throw ReviewHalt.cancelled }
                catch ReviewHalt.budget(let reason) {
                    state = .unrefined(reason)
                    // Span admission is per block; all aggregate exhaustion sticks for later blocks.
                    if reason != .span { exhausted = reason }
                }
            }
            output.append(.init(original: block.original,modified: block.modified,kind: block.kind,inline: state))
        }
        lineMeter.metrics.inlineWork = meter.metrics.work
        lineMeter.metrics.peakInlineWorkspaceBytes = meter.metrics.peakWorkspaceBytes
        lineMeter.metrics.resultBytes += spans*256
        return output
    }
}
