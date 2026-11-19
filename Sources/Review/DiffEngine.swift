// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Every public computation is detached from MainActor; workers receive values only.
package enum ReviewDiffEngine {
    package static func compare(_ original: TextSnapshot, _ modified: TextSnapshot,
        strategy: ReviewDiffStrategy = .myers, policy: ReviewDiffPolicy = .default,
        token: ReviewCancellation = ReviewCancellation(), hooks: ReviewDiffHooks = .init()) async -> ReviewChangeSet {
        await Task.detached {
            compute(original,modified,strategy: strategy,policy: policy,token: token,hooks: hooks)
        }.value
    }
    private static func compute(_ original: TextSnapshot, _ modified: TextSnapshot,
        strategy: ReviewDiffStrategy, policy: ReviewDiffPolicy, token: ReviewCancellation,
        hooks: ReviewDiffHooks) -> ReviewChangeSet {
        let meter = ReviewMeter(policy,token: token,hooks: hooks)
        var blocks: [ReviewChangeBlock] = []
        var completeness: ReviewCompleteness = .complete
        do {
            guard !Thread.isMainThread else { throw ReviewHalt.budget(.mainThread) }
            try meter.poll()
            let a = try ReviewLines(original,meter: meter), b = try ReviewLines(modified,meter: meter)
            let solver = ReviewLineSolver(a,b,meter: meter)
            let ranges = try solver.solve(strategy: strategy)
            try meter.enter(.output)
            for r in ranges {
                try meter.spend();try meter.result(blocks.count+1)
                let ar = ReviewByteRange(snapshot: original.id,lower: a.offset(r.a),upper: a.offset(r.endA))
                let br = ReviewByteRange(snapshot: modified.id,lower: b.offset(r.b),upper: b.offset(r.endB))
                blocks.append(.init(original: ar,modified: br,
                    kind: ar.lower == ar.upper ? .insert : br.lower == br.upper ? .delete : .modify,
                    inline: .unrefined(.work)))
            }
            try solver.validate(blocks)
            try meter.poll()
            // Inline has one aggregate, independent meter; line result stays exact on degradation.
            blocks = try ReviewInline.refine(blocks,original,modified,lineMeter: meter)
            if token.isCancelled { throw ReviewHalt.cancelled }
        } catch ReviewHalt.cancelled { completeness = .cancelled;blocks = [] }
        catch ReviewHalt.budget(let reason) { completeness = .budgetStopped(reason);blocks = [] }
        catch { completeness = .budgetStopped(.invalidInput);blocks = [] }
        meter.metrics.seconds = max(0,hooks.clock()-meter.started)
        return .init(original: original.id,modified: modified.id,blocks: blocks,completeness: completeness,metrics: meter.metrics)
    }
}
struct ReviewLineRange { var a: Int, endA: Int, b: Int, endB: Int }
private final class ReviewLineSolver {
    let a: ReviewLines, b: ReviewLines, meter: ReviewMeter
    init(_ a: ReviewLines,_ b: ReviewLines,meter: ReviewMeter) { self.a = a;self.b = b;self.meter = meter }
    func equal(_ x: Int,_ y: Int) throws -> Bool {
        try meter.spend()
        let ar = a.ranges[x], br = b.ranges[y]
        guard ar.hash == br.hash, ar.upper-ar.lower == br.upper-br.lower else { return false }
        return try equalBytes(ar.lower,br.lower,ar.upper-ar.lower)
    }
    func equalBytes(_ x: Int,_ y: Int,_ count: Int) throws -> Bool {
        try a.snapshot.bytes.withUnsafeBytes { (aa: UnsafeRawBufferPointer) in
            try b.snapshot.bytes.withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
                var i = 0
                while i < count {
                    let end = min(count,i+1024);try meter.spend(end-i)
                    if !aa[(x+i)..<(x+end)].elementsEqual(bb[(y+i)..<(y+end)]) { return false };i = end
                }
                return true
            }
        }
    }
    func solve(strategy: ReviewDiffStrategy) throws -> [ReviewLineRange] {
        var jobs: [ReviewLineRange]
        if strategy == .anchored { jobs = try anchoredJobs() }
        else { jobs = [.init(a: 0,endA: a.ranges.count,b: 0,endB: b.ranges.count)] }
        var changes: [ReviewLineRange] = []
        // The work stack and changes are separately pre-admitted at their maximum live counts.
        try meter.reserve((a.ranges.count+b.ranges.count+1)*64)
        while var r = jobs.popLast() {
            try meter.enter(.trim)
            while r.a < r.endA && r.b < r.endB && (try equal(r.a,r.b)) { r.a += 1;r.b += 1 }
            while r.a < r.endA && r.b < r.endB && (try equal(r.endA-1,r.endB-1)) { r.endA -= 1;r.endB -= 1 }
            let n = r.endA-r.a, m = r.endB-r.b
            if n == 0 && m == 0 { continue }
            if n == 0 || m == 0 { try append(r,to: &changes);continue }
            if n == 1 {
                var match: Int?
                for y in r.b..<r.endB { if try equal(r.a,y) { match = y;break } }
                if let y = match {
                    if r.b < y { try append(.init(a: r.a,endA: r.a,b: r.b,endB: y),to: &changes) }
                    if y+1 < r.endB { try append(.init(a: r.endA,endA: r.endA,b: y+1,endB: r.endB),to: &changes) }
                } else { try append(r,to: &changes) };continue
            }
            if m == 1 {
                var match: Int?
                for x in r.a..<r.endA { if try equal(x,r.b) { match = x;break } }
                if let x = match {
                    if r.a < x { try append(.init(a: r.a,endA: x,b: r.b,endB: r.b),to: &changes) }
                    if x+1 < r.endA { try append(.init(a: x+1,endA: r.endA,b: r.endB,endB: r.endB),to: &changes) }
                } else { try append(r,to: &changes) };continue
            }
            let split = try bisect(r)
            guard split.0 >= r.a, split.0 <= r.endA, split.1 >= r.b, split.1 <= r.endB,
                !(split.0 == r.a && split.1 == r.b), !(split.0 == r.endA && split.1 == r.endB) else {
                throw ReviewHalt.budget(.invalidInput)
            }
            jobs.append(.init(a: split.0,endA: r.endA,b: split.1,endB: r.endB))
            jobs.append(.init(a: r.a,endA: split.0,b: r.b,endB: split.1))
        }
        return changes
    }
    func append(_ r: ReviewLineRange,to output: inout [ReviewLineRange]) throws {
        try meter.spend()
        if let last = output.last, last.endA == r.a, last.endB == r.b {
            output[output.count-1].endA = r.endA;output[output.count-1].endB = r.endB
        } else { try meter.result(output.count+1);output.append(r) }
    }
    /// Myers bidirectional middle split. Only two linear frontiers are retained; no quadratic trace.
    func bisect(_ r: ReviewLineRange) throws -> (Int,Int) {
        try meter.enter(.bisect)
        let n = r.endA-r.a, m = r.endB-r.b, maxD = (n+m+1)/2, offset = maxD+1, length = 2*maxD+3
        let storage = length*MemoryLayout<Int>.stride*2
        try meter.reserve(storage);defer { meter.release(storage) }
        var forward = [Int](repeating: -1,count: length), reverse = forward
        forward[offset+1] = 0;reverse[offset+1] = 0
        let delta = n-m, odd = delta % 2 != 0
        for d in 0...maxD {
            for k in stride(from: -d,through: d,by: 2) {
                try meter.spend()
                let at = offset+k
                var x = (k == -d || (k != d && forward[at-1] < forward[at+1])) ? forward[at+1] : forward[at-1]+1
                var y = x-k
                while x >= 0 && y >= 0 && x < n && y < m && (try equal(r.a+x,r.b+y)) { x += 1;y += 1 }
                forward[at] = x
                let other = offset+delta-k
                if odd, other >= 0, other < length, reverse[other] >= 0, x >= n-reverse[other] {
                    return (r.a+x,r.b+y)
                }
            }
            for k in stride(from: -d,through: d,by: 2) {
                try meter.spend()
                let at = offset+k
                var x = (k == -d || (k != d && reverse[at-1] < reverse[at+1])) ? reverse[at+1] : reverse[at-1]+1
                var y = x-k
                while x >= 0 && y >= 0 && x < n && y < m && (try equal(r.endA-x-1,r.endB-y-1)) { x += 1;y += 1 }
                reverse[at] = x
                let other = offset+delta-k
                if !odd, other >= 0, other < length, forward[other] >= 0, forward[other] >= n-x {
                    let fx = forward[other], fy = fx-(delta-k)
                    return (r.a+fx,r.b+fy)
                }
            }
        }
        throw ReviewHalt.budget(.invalidInput)
    }
    func anchoredJobs() throws -> [ReviewLineRange] {
        try meter.enter(.anchors)
        let estimate = (a.ranges.count+b.ranges.count)*256
        try meter.reserve(estimate);defer { meter.release(estimate) }
        var ac: [UInt64:(count: Int,index: Int)] = [:], bc: [UInt64:(count: Int,index: Int)] = [:]
        for (i,line) in a.ranges.enumerated() { try meter.spend();let old = ac[line.hash];ac[line.hash] = ((old?.count ?? 0)+1,i) }
        for (i,line) in b.ranges.enumerated() { try meter.spend();let old = bc[line.hash];bc[line.hash] = ((old?.count ?? 0)+1,i) }
        var candidates: [(Int,Int)] = []
        for (i,line) in a.ranges.enumerated() {
            try meter.spend()
            if ac[line.hash]?.count == 1, let other = bc[line.hash], other.count == 1, try equal(i,other.index) {
                candidates.append((i,other.index))
            }
        }
        // Candidates arrive sorted by original line, eliminating a sort and its cancellation gap.
        var tails: [Int] = [], previous = [Int](repeating: -1,count: candidates.count)
        for i in candidates.indices {
            var lo = 0, hi = tails.count
            while lo < hi { try meter.spend();let mid = (lo+hi)/2
                if candidates[tails[mid]].1 < candidates[i].1 { lo = mid+1 } else { hi = mid }
            }
            previous[i] = lo == 0 ? -1 : tails[lo-1]
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        try meter.enter(.backtrack)
        var anchors: [(Int,Int)] = [], index = tails.last ?? -1
        while index >= 0 { try meter.spend();anchors.append(candidates[index]);index = previous[index] }
        anchors.reverse();meter.metrics.anchors = anchors.count
        var jobs: [ReviewLineRange] = [], x = 0, y = 0
        for (ax,by) in anchors {
            try meter.spend();jobs.append(.init(a: x,endA: ax,b: y,endB: by));x = ax+1;y = by+1
        }
        jobs.append(.init(a: x,endA: a.ranges.count,b: y,endB: b.ranges.count))
        return jobs.reversed()
    }
    func validate(_ blocks: [ReviewChangeBlock]) throws {
        var x = 0, y = 0
        for block in blocks {
            try meter.spend()
            let dx = block.original.lower-x, dy = block.modified.lower-y
            guard dx >= 0, dx == dy, try equalBytes(x,y,dx) else { throw ReviewHalt.budget(.invalidInput) }
            x = block.original.upper;y = block.modified.upper
        }
        let rest = a.snapshot.bytes.count-x
        guard rest == b.snapshot.bytes.count-y, try equalBytes(x,y,rest) else { throw ReviewHalt.budget(.invalidInput) }
    }
}
