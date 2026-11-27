// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import TextTankCore

/// Test-only parser. No production tokenization, diff, patch or merge helpers.
enum MergePatchOracle {
    static func records(_ bytes: Data) -> [Data] {
        var result: [Data] = [], start = 0
        for i in bytes.indices where bytes[i] == 10 {
            result.append(bytes.subdata(in: start..<(i + 1)))
            start = i + 1
        }
        if start < bytes.count { result.append(bytes.subdata(in: start..<bytes.count)) }
        return result
    }
    static func apply(_ patch: Data, to original: Data) throws -> Data {
        if patch.isEmpty { return original }
        let rows = records(patch), old = records(original)
        func require(_ condition: Bool) throws { if !condition { throw ReviewRejection.invalidText } }
        try require(
            rows.count >= 3 && rows[0].starts(with: Data("--- a/".utf8)) && rows[1].starts(with: Data("+++ b/".utf8)))
        let regex = try NSRegularExpression(pattern: "^@@ -(\\d+),(\\d+) \\+(\\d+),(\\d+) @@\\n$")
        var i = 2, oldIndex = 0, newIndex = 0, output = Data(), oldEnded = false, newEnded = false
        while i < rows.count {
            let text = String(decoding: rows[i], as: UTF8.self), ns = text as NSString
            guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
                throw ReviewRejection.invalidText
            }
            let v = (1...4).map { Int(ns.substring(with: m.range(at: $0)))! }
            try require(v[1] > 0 || v[3] > 0)
            let oldStart = v[1] == 0 ? v[0] : v[0] - 1, newStart = v[3] == 0 ? v[2] : v[2] - 1
            try require(oldStart >= oldIndex && oldStart <= old.count && !(oldEnded && oldStart > oldIndex))
            for n in oldIndex..<oldStart {
                output.append(old[n])
                newIndex += 1
            }
            oldIndex = oldStart
            try require(newIndex == newStart)
            i += 1
            var consumed = 0, produced = 0
            while i < rows.count && !rows[i].starts(with: Data("@@ ".utf8)) {
                let row = rows[i]
                guard let prefix = row.first, [UInt8(32), 43, 45].contains(prefix), row.last == 10 else {
                    throw ReviewRejection.invalidText
                }
                var payload = Data(row.dropFirst())
                i += 1
                let noLF = i < rows.count && rows[i] == Data("\\ No newline at end of file\n".utf8)
                if noLF {
                    payload.removeLast()
                    try require(!payload.isEmpty)
                    i += 1
                }
                if prefix != 43 {
                    try require(!oldEnded && oldIndex < old.count && old[oldIndex] == payload)
                    oldIndex += 1
                    consumed += 1
                    oldEnded = noLF
                }
                if prefix != 45 {
                    try require(!newEnded)
                    output.append(payload)
                    newIndex += 1
                    produced += 1
                    newEnded = noLF
                }
            }
            try require(consumed == v[1] && produced == v[3])
        }
        try require(!oldEnded || oldIndex == old.count)
        try require(!newEnded || oldIndex == old.count)
        for n in oldIndex..<old.count { output.append(old[n]) }
        return output
    }
}

@main struct MergeChecks {
    struct Pair: Decodable { let name: String, before: String, after: String }
    static func snapshot(_ text: String, document: Bool = true) throws -> TextSnapshot {
        let bytes = Data(text.utf8), id = DocumentID()
        return try TextSnapshot(
            bytes: bytes, source: document ? .document(id) : .freeText(UUID()), label: "owned.txt",
            document: document
                ? .init(
                    documentID: id, revision: 1, byteLength: bytes.count,
                    selections: [.init(anchorByte: 0, caretByte: 0)]) : nil,
            format: .init())
    }
    /// Independent descending splice, not the planner/coalescer/projected output.
    static func oracle(
        _ changes: ReviewChangeSet, _ a: TextSnapshot, _ b: TextSnapshot, _ side: CompareSide, _ selected: [Int]
    ) -> Data {
        var result = side == .original ? a.bytes : b.bytes
        for i in selected.sorted(by: >) {
            let block = changes.blocks[i], range = side == .original ? block.original : block.modified
            let source = side == .original ? b : a, from = side == .original ? block.modified : block.original
            result.replaceSubrange(range.lower..<range.upper, with: source.bytes.subdata(in: from.lower..<from.upper))
        }
        return result
    }
    static func interop(_ patch: Data, before: Data, after: Data, name: String) throws {
        let root = TestPaths.repoRoot.deletingLastPathComponent().appendingPathComponent(
            "tmp/cap-D2-interop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.txt"), diff = root.appendingPathComponent("change.patch")
        try before.write(to: file)
        try patch.write(to: diff)
        func run(_ args: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + args
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
        }
        let initialized = try run(["init", "-q"])
        try require(initialized.0 == 0, "D2 owned patch fixture Git init")
        if patch.isEmpty {
            check(before == after, "D2 empty patch interop no-op")
            return
        }
        let result = try run(["apply", "--verbose", "--whitespace=nowarn", diff.path])
        check(
            result.0 == 0 && !result.1.lowercased().contains("offset") && !result.1.lowercased().contains("fuzz"),
            "D2 standard Git patch accepts exact \(name): \(result.1)")
        check((try? Data(contentsOf: file)) ?? Data() == after, "D2 standard tool byte reconstruction \(name)")
    }
    static func main() async {
        func runCases() async throws {
            for separator in ["\n", "\r", "\r\n", "\r\n\n"] {
                let original = try snapshot("same" + separator + "before" + separator)
                let modified = try snapshot("same" + separator + "after" + separator)
                let result = await ReviewDiffEngine.compare(original, modified)
                check(
                    (result.lfFramedStrategy == .myers) == (separator == "\n"),
                    "LF framing follows actual source splits")
                let untagged = ReviewChangeSet(
                    original: result.original, modified: result.modified, blocks: result.blocks,
                    completeness: result.completeness, metrics: result.metrics)
                for (changes, strategy) in [(result, ReviewDiffStrategy.myers), (result, .anchored), (untagged, .myers)]
                {
                    // The delivery hook belongs to the LF solver. A separate token records it
                    // without cancelling the export or bypassing its normal byte checks.
                    let solverCompleted = ReviewCancellation()
                    let patch = try await UnifiedPatch.write(
                        original: original, modified: modified, changes: changes, strategy: strategy,
                        hooks: .init(checkpoint: { phase, _ in
                            if phase == .delivery { solverCompleted.cancel() }
                        }))
                    let expectedReuse = separator == "\n" && strategy == .myers && changes.lfFramedStrategy == .myers
                    check(
                        solverCompleted.isCancelled != expectedReuse, "LF export respects solver, strategy and framing")
                    let reconstructed = try MergePatchOracle.apply(patch, to: original.bytes)
                    check(reconstructed == modified.bytes, "LF export reconstructs complete input for each framing")
                }
            }
            var pairs = try JSONDecoder().decode(
                [Pair].self, from: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("review/corpus.json")))
            pairs += [
                .init(
                    name: "huge-line", before: String(repeating: "x", count: 2 * 1024 * 1024),
                    after: String(repeating: "x", count: 1024 * 1024) + "y"
                        + String(repeating: "x", count: 1024 * 1024 - 1)),
                .init(
                    name: "huge-prefix-suffix",
                    before: String(repeating: "p", count: 2 * 1024 * 1024) + "\na\n"
                        + String(repeating: "s", count: 2 * 1024 * 1024),
                    after: String(repeating: "p", count: 2 * 1024 * 1024) + "\nb\n"
                        + String(repeating: "s", count: 2 * 1024 * 1024))
            ]
            for n in 0..<48 {
                pairs.append(
                    .init(
                        name: "generated-\(n)", before: (0..<24).map { "\(($0 * 7 + n) % 11)\n" }.joined(),
                        after: (0..<27).map { "\(($0 * 3 + n) % 13)\n" }.joined()))
            }
            let unique = (0..<250).map { "line-\($0)\n" }
            let anchored = "new\n" + unique.dropFirst().joined() + "end\n"
            pairs.append(Pair(name: "unique-anchors", before: unique.joined(), after: anchored))
            pairs.append(Pair(name: "reverse-unique", before: unique.joined(), after: unique.reversed().joined()))
            let distantBefore = (0..<40).map { "row\($0)\n" }.joined()
            let distantAfter = (0..<40).map { $0 == 2 || $0 == 35 ? "changed\($0)\n" : "row\($0)\n" }.joined()
            pairs.append(Pair(name: "distant-context", before: distantBefore, after: distantAfter))
            var evaluated = 0
            let tool = Process(), versionPipe = Pipe()
            tool.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            tool.arguments = ["--version"]
            tool.standardOutput = versionPipe
            try tool.run()
            let toolVersion = versionPipe.fileHandleForReading.readDataToEndOfFile()
            tool.waitUntilExit()
            print("D2_PATCH_TOOL " + String(decoding: toolVersion, as: UTF8.self))
            for strategy in ReviewDiffStrategy.allCases {
                for pair in pairs {
                    let a = try snapshot(pair.before), b = try snapshot(pair.after)
                    let changes = await ReviewDiffEngine.compare(a, b, strategy: strategy, policy: .correctness)
                    try require(changes.completeness == .complete, "D2 corpus complete \(pair.name) \(strategy)")
                    let patch = try await UnifiedPatch.write(
                        original: a, modified: b, changes: changes, strategy: strategy, policy: .correctness)
                    check(
                        try MergePatchOracle.apply(patch, to: a.bytes) == b.bytes,
                        "D2 independent patch \(pair.name) \(strategy)")
                    check(patch.isEmpty == (a.bytes == b.bytes), "D2 empty patch exactly identical")
                    if strategy == .myers
                        && (pairs.prefix(9).contains { $0.name == pair.name } || pair.name == "distant-context")
                    {
                        try interop(patch, before: a.bytes, after: b.bytes, name: pair.name)
                    }
                    for side in [CompareSide.original, .modified] {
                        let destination = side == .original ? a : b, source = side == .original ? b : a
                        let count = changes.blocks.count, all = Array(0..<count)
                        var sets: [[Int]] = [all, [], all.filter { $0 % 2 == 0 }]
                        sets += all.map { [$0] }
                        if count <= 10 {
                            sets += (0..<(1 << count)).map { mask in all.filter { mask & (1 << $0) != 0 } }
                        } else {
                            for seed in 0..<16 { sets.append(all.filter { ($0 * 17 + seed * 31) % 7 < 3 }) }
                        }
                        var seenSelections = Set<[Int]>()
                        for selected in sets where seenSelections.insert(selected).inserted {
                            let plan = try await MergeCore.plan(
                                original: a, modified: b, changes: changes, destination: side, parent: destination,
                                slice: nil, selected: selected, policy: .correctness)
                            check(
                                plan.projectedParent == oracle(changes, a, b, side, selected),
                                "D2 independent subset \(pair.name) \(strategy) \(side)")
                            if selected == all {
                                check(plan.projectedParent == source.bytes, "D2 all reconstructs opposite")
                            }
                            try plan.preflight(current: destination.bytes, target: destination.document!)
                            evaluated += 1
                        }
                        var current = destination
                        for step in 0...count + 2 {
                            let next = await ReviewDiffEngine.compare(
                                current, source, strategy: strategy, policy: .correctness)
                            try require(next.completeness == .complete, "D2 sequence complete")
                            if next.blocks.isEmpty { break }
                            try require(step <= count + 1, "D2 sequence converges")
                            let plan = try await MergeCore.plan(
                                original: current, modified: source, changes: next, destination: .original,
                                parent: current, slice: nil, selected: [0], policy: .correctness)
                            current = try snapshot(String(decoding: plan.projectedParent, as: UTF8.self))
                        }
                        check(current.bytes == source.bytes, "D2 sequence exact \(pair.name) \(side)")
                    }
                }
            }
            let a = try snapshot("keep\n"), b = try snapshot("A\nB\nC\nkeep\n")
            let blocks = (0..<3).map { i in
                ReviewChangeBlock(
                    original: .init(snapshot: a.id, lower: 0, upper: 0),
                    modified: .init(snapshot: b.id, lower: i * 2, upper: i * 2 + 2), kind: .insert,
                    inline: .unrefined(.notAttempted))
            }
            let synthetic = ReviewChangeSet(
                original: a.id, modified: b.id, blocks: blocks, completeness: .complete, metrics: .init())
            for side in [CompareSide.original, .modified] {
                let dest = side == .original ? a : b
                let plan = try await MergeCore.plan(
                    original: a, modified: b, changes: synthetic, destination: side, parent: dest, slice: nil,
                    selected: [2, 0])
                check(
                    plan.projectedParent == oracle(synthetic, a, b, side, [0, 2]),
                    "D2 same-anchor first+third and reverse")
                check(side != .original || plan.proposal.edits.count == 1, "D2 minimal ambiguous coalescing")
                try plan.preflight(current: dest.bytes, target: dest.document!)
            }
            let copied = try TextSnapshot(
                bytes: a.bytes, source: a.source, label: a.label, document: a.document, format: a.format)
            let copiedChanges = await ReviewDiffEngine.compare(copied, b)
            let copiedPlan = try await MergeCore.plan(
                original: copied, modified: b, changes: copiedChanges, destination: .original, parent: a, slice: nil,
                selected: Array(copiedChanges.blocks.indices))
            check(
                copied.id != a.id && copiedPlan.projectedParent == b.bytes && copiedPlan.proposal.snapshot == a.id,
                "D2 copied comparison binds original parent stamp and exact bytes")
            let manyCount = 10_001, manySource = try snapshot(String(repeating: "x\n", count: manyCount) + "keep\n")
            let manyBlocks = (0..<manyCount).map { i in
                ReviewChangeBlock(
                    original: .init(snapshot: a.id, lower: 0, upper: 0),
                    modified: .init(snapshot: manySource.id, lower: i * 2, upper: i * 2 + 2), kind: .insert,
                    inline: .unrefined(.notAttempted))
            }
            let manyChanges = ReviewChangeSet(
                original: a.id, modified: manySource.id, blocks: manyBlocks, completeness: .complete, metrics: .init())
            let many = try await MergeCore.plan(
                original: a, modified: manySource, changes: manyChanges, destination: .original, parent: a, slice: nil,
                selected: Array(0..<manyCount))
            check(
                many.proposal.edits.count == 1 && many.projectedParent == manySource.bytes,
                "D2 10001 same-anchor blocks one admitted edit without quadratic COW")
            let parent = try snapshot("prefix\nold\nsuffix\n"), slice = try snapshot("old\n", document: false),
                value = try snapshot("NEW\r\n", document: false)
            let change = await ReviewDiffEngine.compare(slice, value)
            let translated = try await MergeCore.plan(
                original: slice, modified: value, changes: change, destination: .original, parent: parent,
                slice: 7..<11, selected: [0])
            check(
                translated.projectedParent == Data("prefix\nNEW\r\nsuffix\n".utf8),
                "D2 selection exact parent translation")
            check(translated.mergedSliceLength == 5, "D2 selection new extent")
            try translated.preflight(current: parent.bytes, target: parent.document!)
            var corrupted = parent.bytes
            corrupted[7] = 88
            do {
                try translated.preflight(current: corrupted, target: parent.document!)
                check(false, "D2 changed expected rejection")
            } catch let e as MergeFailure {
                check(e.block == 0 && e.reason == .bytesChanged, "D2 exact failing block diagnostic")
            }
            let cancelled = ReviewCancellation()
            cancelled.cancel()
            do {
                _ = try await MergeCore.plan(
                    original: a, modified: b, changes: synthetic, destination: .original, parent: a, slice: nil,
                    selected: [0], token: cancelled)
                check(false, "D2 cancellation")
            } catch { check(true, "D2 cancelled refuses") }
            for selected in [[-1], [3], [0, 0]] {
                do {
                    _ = try await MergeCore.plan(
                        original: a, modified: b, changes: synthetic, destination: .original, parent: a, slice: nil,
                        selected: selected)
                    check(false, "D2 malformed selected ordinals")
                } catch { check(true, "D2 malformed selection refuses") }
            }
            let incomplete = ReviewChangeSet(
                original: a.id, modified: b.id, blocks: [], completeness: .cancelled, metrics: .init())
            do {
                _ = try await UnifiedPatch.write(original: a, modified: b, changes: incomplete)
                check(false, "D2 incomplete export")
            } catch { check(true, "D2 incomplete refuses") }
            let evil = try TextSnapshot(
                bytes: a.bytes, source: .freeText(UUID()), label: "/private/location/unsafe\tname\n+++ injected")
            let c = await ReviewDiffEngine.compare(evil, b)
            let safe = try await UnifiedPatch.write(original: evil, modified: b, changes: c)
            let header = String(decoding: MergePatchOracle.records(safe)[0], as: UTF8.self)
            check(
                !header.contains("/private/") && !header.contains("\t") && !header.contains("+++ injected"),
                "D2 private header sanitized")
            let traversal = try TextSnapshot(bytes: a.bytes, source: .freeText(UUID()), label: "../../..")
            let traversalDiff = await ReviewDiffEngine.compare(traversal, b)
            let traversalPatch = try await UnifiedPatch.write(original: traversal, modified: b, changes: traversalDiff)
            check(
                String(decoding: MergePatchOracle.records(traversalPatch)[0], as: UTF8.self).contains("\\x2E\\x2E"),
                "D2 dot-only display labels cannot form traversal paths")
            let positive = Data("--- a/owned.txt\n+++ b/owned.txt\n@@ -1,1 +1,1 @@\n-a\n+b\n".utf8)
            check(
                try MergePatchOracle.apply(positive, to: Data("a\n".utf8)) == Data("b\n".utf8),
                "D2 independent parser positive control")
            for bad in [
                Data(positive.dropLast()),
                Data(String(decoding: positive, as: UTF8.self).replacingOccurrences(of: "-1,1", with: "-1,2").utf8),
                positive + Data("junk\n".utf8),
                Data(String(decoding: positive, as: UTF8.self).replacingOccurrences(of: "-a", with: "-x").utf8)
            ] {
                do {
                    _ = try MergePatchOracle.apply(bad, to: Data("a\n".utf8))
                    check(false, "D2 parser negative")
                } catch { check(true, "D2 malformed patch rejected") }
            }
            print(
                "D2_CORPUS pairs=\(pairs.count) strategies=2 directions=2 subset_plans=\(evaluated) profile=512m30s finalF0caps=unchanged"
            )
        }
        await Checks.run("MergeChecks") { try await runCases() }
    }
}
