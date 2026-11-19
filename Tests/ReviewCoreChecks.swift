// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
@testable import TextTankCore

@main struct ReviewCoreChecks {
    struct Pair: Decodable { let name: String, before: String, after: String }
    static func snapshot(_ bytes: Data) throws -> TextSnapshot {
        try TextSnapshot(bytes: bytes, source: .freeText(UUID()), label: "owned fixture")
    }
    static func snapshot(_ text: String) throws -> TextSnapshot { try snapshot(Data(text.utf8)) }
    // Independent splice oracle: does not call a production replay helper.
    static func replay(_ changes: ReviewChangeSet, _ a: TextSnapshot, _ b: TextSnapshot) -> Data? {
        guard changes.completeness == .complete else { return nil }
        var output = Data(), cursor = 0, modifiedCursor = 0
        for block in changes.blocks {
            guard block.original.snapshot == a.id, block.modified.snapshot == b.id,
                block.original.lower >= cursor, block.modified.lower >= modifiedCursor,
                block.original.upper <= a.bytes.count, block.modified.upper <= b.bytes.count
            else { return nil }
            output.append(a.bytes.subdata(in: cursor..<block.original.lower))
            output.append(b.bytes.subdata(in: block.modified.lower..<block.modified.upper))
            cursor = block.original.upper
            modifiedCursor = block.modified.upper
        }
        output.append(a.bytes.subdata(in: cursor..<a.bytes.count))
        return output
    }
    static func main() async {
        await Checks.run("ReviewCoreChecks") {
            let doc = DocumentID()
            let target = DocumentTarget(
                documentID: doc, revision: 7, loadEpoch: 2, byteLength: 6,
                selections: [.init(anchorByte: 0, caretByte: 0)])
            let a = try TextSnapshot(
                bytes: Data("aé\nbc".utf8), source: .document(doc), label: "same", document: target)
            let clone = try TextSnapshot(bytes: a.bytes, source: .document(doc), label: "same", document: target)
            check(a.source == clone.source && a.id != clone.id, "F0 shared source, exact capture coordinates")
            for bytes in [Data([0xff]), Data([0xc0, 0x80]), Data([0xed, 0xa0, 0x80]), Data([0xe2, 0x82])] {
                rejects("F0 strict invalid UTF8") { _ = try snapshot(bytes) }
            }
            for text in ["", "\n", "\r", "\r\n", "a\n\n", "a\rb\r\nc\nlast", "\u{feff}\0é"] {
                let s = try snapshot(text), lines = try ReviewLineTable(snapshot: s)
                let joined = lines.ranges.reduce(into: Data()) { $0.append(s.bytes.subdata(in: $1.lower..<$1.upper)) }
                check(joined == s.bytes, "F0 exact line join \(text.debugDescription)")
                check(lines.ranges.isEmpty == text.isEmpty, "F0 empty has zero lines only")
            }
            let fixtures = TestPaths.fixtures.appendingPathComponent("review/corpus.json")
            var pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: fixtures))
            pairs += [
                Pair(
                    name: "huge-line", before: String(repeating: "x", count: 2 * 1024 * 1024),
                    after: String(repeating: "x", count: 1024 * 1024) + "y"
                        + String(repeating: "x", count: 1024 * 1024 - 1)),
                Pair(
                    name: "huge-prefix-suffix",
                    before: String(repeating: "p", count: 2 * 1024 * 1024) + "\na\n"
                        + String(repeating: "s", count: 2 * 1024 * 1024),
                    after: String(repeating: "p", count: 2 * 1024 * 1024) + "\nb\n"
                        + String(repeating: "s", count: 2 * 1024 * 1024))
            ]
            // Generated corpus fixed before measurements; no random seed hidden in the engine.
            for n in 0..<48 {
                let x = (0..<24).map { "\(($0*7+n)%11)\n" }.joined()
                let y = (0..<27).map { "\(($0*3+n)%13)\n" }.joined()
                pairs.append(Pair(name: "generated-\(n)", before: x, after: y))
            }
            let unique = (0..<250).map { "line-\($0)\n" }
            pairs.append(
                Pair(
                    name: "unique-anchors", before: unique.joined(),
                    after: (["new\n"] + unique.dropFirst() + ["end\n"]).joined()))
            var records: [[String: Any]] = []
            func record(
                _ result: ReviewChangeSet, _ x: TextSnapshot, _ y: TextSnapshot, _ strategy: ReviewDiffStrategy,
                _ name: String, _ profile: String, _ reverse: Bool
            ) throws {
                let blocks: [[String: Any]] = result.blocks.map { block in
                    let refinement: [[Int]]
                    if case .refined(let spans) = block.inline {
                        refinement = spans.map {
                            [$0.original.lower, $0.original.upper, $0.modified.lower, $0.modified.upper]
                        }
                    } else {
                        refinement = []
                    }
                    return [
                        "original": [block.original.lower, block.original.upper],
                        "modified": [block.modified.lower, block.modified.upper], "kind": block.kind.rawValue,
                        "inline": refinement
                    ]
                }
                records.append([
                    "case": name, "reverse": reverse, "strategy": strategy.rawValue, "profile": profile,
                    "repetition": 1, "before_bytes": x.bytes.count, "after_bytes": y.bytes.count,
                    "before_sha256": SHA256.hash(data: x.bytes).map { String(format: "%02x", $0) }.joined(),
                    "after_sha256": SHA256.hash(data: y.bytes).map { String(format: "%02x", $0) }.joined(),
                    "wall_seconds": result.metrics.seconds, "line_work": result.metrics.work,
                    "inline_work": result.metrics.inlineWork,
                    "peak_workspace_estimate_bytes": result.metrics.peakWorkspaceBytes,
                    "peak_inline_workspace_estimate_bytes": result.metrics.peakInlineWorkspaceBytes,
                    "result_blocks": result.blocks.count,
                    "result_json_bytes": try JSONSerialization.data(withJSONObject: blocks, options: [.sortedKeys])
                        .count,
                    "anchors": result.metrics.anchors, "completeness": String(describing: result.completeness),
                    "exact_replay": replay(result, x, y) == y.bytes
                ])
            }
            pairs.append(Pair(name: "reverse-unique", before: unique.joined(), after: unique.reversed().joined()))
            for strategy in ReviewDiffStrategy.allCases {
                for pair in pairs {
                    for reverse in [false, true] {
                        let x = try snapshot(reverse ? pair.after : pair.before)
                        let y = try snapshot(reverse ? pair.before : pair.after)
                        let result = await ReviewDiffEngine.compare(x, y, strategy: strategy, policy: .correctness)
                        try record(result, x, y, strategy, pair.name, "correctness512m30s", reverse)
                        if !reverse {
                            let normal = await ReviewDiffEngine.compare(x, y, strategy: strategy, policy: .default)
                            try record(normal, x, y, strategy, pair.name, "default128m2s", false)
                            check(
                                normal.completeness == .complete ? replay(normal, x, y) == y.bytes : !normal.identical,
                                "F0 separately declared default policy outcome")
                        }
                        check(
                            result.completeness == .complete,
                            "F0 required complete \(strategy) \(pair.name) reverse=\(reverse)")
                        check(replay(result, x, y) == y.bytes, "F0 independent exact replay \(strategy) \(pair.name)")
                        check(result.identical == (x.bytes == y.bytes), "F0 exact identical flag")
                        if strategy == .anchored && pair.name == "unique-anchors" {
                            check(result.metrics.anchors > 0, "F0 distinct anchor/LIS strategy exercised")
                        }
                    }
                }
            }
            let evidence: [String: Any] = [
                "schema": 1, "generated_seed": "fixed formulas n=0..<48 and unique0..<250",
                "repetitions_per_declared_profile_pair": 1,
                "machine": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": "arm64",
                "environment_scale": ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"] ?? "1",
                "memory_estimate_method":
                    "Conservative explicit capacity accounting before allocation: line capacity64B, dictionary/anchor256B per line, linear frontier16B per slot, stack64B per admitted entry. Input, codec/capture, native Undo and process RSS excluded; inline estimate separate.",
                "result_size_method":
                    "Sorted-key UTF8 JSON of original/modified byte ranges, kinds and inline span ranges; UUIDs/metrics excluded.",
                "rss": "Not measured; explicit estimates are not total process peak memory.", "records": records
            ]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(
                to: TestPaths.repoRoot.appendingPathComponent("harness/logs/review-algorithm-comparison.json"))
            let left = try snapshot("a\nb\nc\n"), right = try snapshot("c\nb\na\n")
            let collisions = await ReviewDiffEngine.compare(
                left, right, strategy: .anchored,
                policy: .correctness, hooks: .init(hashByte: { _, _ in 0 }))
            check(replay(collisions, left, right) == right.bytes, "F0 hash collisions do not invent equality")
            for field in ["bytes", "lines", "work", "workspace", "blocks", "output", "time"] {
                var policy = ReviewDiffPolicy.default
                switch field {
                case "bytes": policy.maximumInputBytes = 1
                case "lines": policy.maximumLines = 1
                case "work": policy.maximumWork = 1
                case "workspace": policy.maximumWorkspaceBytes = 1
                case "blocks": policy.maximumBlocks = 0
                case "output": policy.maximumOutputBytes = 0
                default: policy.seconds = 0
                }
                let result = await ReviewDiffEngine.compare(left, right, policy: policy)
                check(
                    result.completeness != .complete && !result.identical,
                    "F0 \(field) budget incomplete never identical")
            }
            let phaseLeft = try snapshot("a\nb\nc\nd\n"), phaseRight = try snapshot("d\nc\nb\na\n")
            for phase in ReviewDiffPhase.allCases {
                let cancellation = ReviewCancellation()
                let r = await ReviewDiffEngine.compare(
                    phaseLeft, phaseRight,
                    strategy: (phase == .anchors || phase == .backtrack) ? .anchored : .myers, token: cancellation,
                    hooks: .init(checkpoint: { p, _ in if p == phase { cancellation.cancel() } }))
                check(r.metrics.phases.contains(phase), "F0 deliberate phase reached \(phase)")
                check(r.completeness == .cancelled && !r.identical, "F0 deliberate phase cancellation \(phase)")
            }
            let cancelled = ReviewCancellation()
            cancelled.cancel()
            let stop = await ReviewDiffEngine.compare(left, left, token: cancelled)
            check(stop.completeness == .cancelled && !stop.identical, "F0 cancelled equal input never identical")
            for (x, y) in [("a👩🏽‍💻é\r\n", "a👨‍👩‍👧é\r\n"), ("🇺🇸", "🇨🇦"), ("\u{feff}\0x", "\u{feff}\0y")] {
                let s = try snapshot(x), t = try snapshot(y)
                let result = await ReviewDiffEngine.compare(s, t)
                check(result.completeness == .complete, "F0 inline line result complete")
                for block in result.blocks {
                    if case .refined(let spans) = block.inline {
                        func boundaries(_ text: String) -> Set<Int> {
                            var n = 0, set: Set<Int> = [0]
                            for c in text {
                                n += String(c).utf8.count
                                set.insert(n)
                            }
                            return set
                        }
                        for span in spans {
                            check(
                                boundaries(x).contains(span.original.lower)
                                    && boundaries(x).contains(span.original.upper)
                                    && boundaries(y).contains(span.modified.lower)
                                    && boundaries(y).contains(span.modified.upper), "F0 inline full grapheme boundaries"
                            )
                        }
                    } else {
                        check(false, "F0 small graphemes refine")
                    }
                }
            }
            var inline = ReviewDiffPolicy.default
            inline.inline.maximumWork = 0
            let unrefined = await ReviewDiffEngine.compare(left, right, policy: inline)
            check(
                unrefined.completeness == .complete
                    && unrefined.blocks.allSatisfy {
                        if case .unrefined = $0.inline { return true }
                        return false
                    }, "F0 inline budget independently degrades")
            let huge = try snapshot("a" + String(repeating: "\u{301}", count: 50000))
            let hugeResult = await ReviewDiffEngine.compare(huge, try snapshot("b"), policy: .correctness)
            check(
                hugeResult.completeness == .complete
                    && hugeResult.blocks.allSatisfy {
                        if case .unrefined = $0.inline { return true }
                        return false
                    }, "F0 huge cluster not segmented")
            func edit(_ lo: Int, _ hi: Int, _ expected: Data, _ replacement: Data) -> ReviewEdit {
                .init(range: .init(snapshot: a.id, lower: lo, upper: hi), expected: expected, replacement: replacement)
            }
            let good = edit(0, 1, Data("a".utf8), Data("A".utf8))
            func validate(
                _ edits: [ReviewEdit], current: Data? = nil, stamp: DocumentTarget? = nil,
                policy: ReviewApplyPolicy = .default
            ) -> Result<[ReviewEdit], ReviewRejection> {
                ReviewPreflight.validate(
                    .init(target: target, snapshot: a.id, edits: edits), current: current ?? a.bytes,
                    target: stamp ?? target, policy: policy)
            }
            check(try validate([good]).get() == [good], "F0 exact pure preflight")
            check(try validate([good]).get() == [good], "F0 pure preflight repeatable")
            let no = edit(0, 1, Data("a".utf8), Data("a".utf8))
            check(try validate([no]).get().isEmpty, "F0 no-op validated then filtered")
            check(try validate([]).get().isEmpty, "F0 empty preflight no native work")
            for bad in [
                edit(-1, 0, Data(), Data()), edit(1, 2, Data([0xc3]), Data()),
                edit(0, Int.max, Data(), Data()), edit(3, 2, Data(), Data()), edit(0, 1, Data("z".utf8), Data()),
                edit(0, 1, Data("a".utf8), Data([0xff]))
            ] {
                if case .failure = validate([bad]) {
                    check(true, "F0 invalid pure proposal rejects")
                } else {
                    check(false, "F0 invalid pure proposal rejects")
                }
                if case .failure = validate([good, bad]) {
                    check(true, "F0 bad late edit rejects all")
                } else {
                    check(false, "F0 bad late edit rejects all")
                }
            }
            for edits in [
                [good, good], [edit(0, 0, Data(), Data("x".utf8)), good],
                [good, edit(1, 1, Data(), Data("x".utf8))], [edit(3, 3, Data(), Data()), edit(3, 3, Data(), Data())]
            ] {
                check(validate(edits) == .failure(.invalidRange), "F0 ambiguous ordering rejects")
            }
            check(
                try validate([good, edit(1, 3, Data("é".utf8), Data())]).get().count == 2,
                "F0 positive adjacent edits valid")
            check(
                try validate([edit(6, 6, Data(), Data("!".utf8))]).get().count == 1, "F0 isolated EOF insertion valid")
            let wrong = DocumentTarget(
                documentID: DocumentID(), revision: 7, loadEpoch: 2, byteLength: 6, selections: target.selections)
            check(validate([good], stamp: wrong) == .failure(.closed), "F0 no different-document relocation")
            let reload = DocumentTarget(
                documentID: doc, revision: 7, loadEpoch: 3, byteLength: 6, selections: target.selections)
            check(validate([good], stamp: reload) == .failure(.reloaded), "F0 identical reload stale")
            var limits = ReviewApplyPolicy.default
            limits.maximumEdits = 0
            check(validate([good], policy: limits) == .failure(.budgetExceeded), "F0 admission count before conversion")
            limits = .default
            limits.maximumWork = 0
            check(validate([good], policy: limits) == .failure(.budgetExceeded), "F0 validation work admission")
            check(
                ReviewUTF8.text(Data("\u{feff}\0".utf8)).map { Data($0.utf8) } == Data("\u{feff}\0".utf8),
                "F0 replacement conversion preserves FEFF/NUL")
        }
    }
}
