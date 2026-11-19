// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import TextTankCore

@main struct CompareChecks {
    struct Pair: Decodable { let name: String, before: String, after: String }
    static func snapshot(_ text: String) throws -> TextSnapshot {
        try TextSnapshot(bytes: Data(text.utf8), source: .freeText(UUID()), label: "Owned comparison")
    }
    static func reconstructed(_ projection: CompareProjection, _ side: CompareSide, unified: Bool) -> Data {
        let s = projection.snapshot(side), lines = projection.lines(side)
        var bytes = Data()
        let indices: [Int]
        if unified {
            indices = projection.unified.compactMap { row in
                row.side == side ? row.line : row.counterpart
            }
        } else {
            indices = projection.rows.compactMap { side == .original ? $0.original : $0.modified }
        }
        for i in indices {
            let r = lines[i].range
            bytes.append(s.bytes.subdata(in: r.lower..<r.upper))
        }
        return bytes
    }
    static func main() async {
        await Checks.run("CompareChecks") {
            let corpus = try JSONDecoder().decode(
                [Pair].self,
                from: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("review/corpus.json")))
            var extra = [
                Pair(name: "empty", before: "", after: ""), Pair(name: "leading", before: "b\n", after: "a\nb\n"),
                Pair(name: "EOF", before: "old", after: "new\n"),
                Pair(name: "FEFF/NUL", before: "\u{feff}\0x\r", after: "\u{feff}\0y\n"),
                Pair(name: "clusters", before: "a👩🏽‍💻 e\u{301}\r\n", after: "b👩🏽‍💻 e\u{300}\n")
            ]
            extra += [
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
            for n in 0..<48 {
                extra.append(
                    Pair(
                        name: "generated-\(n)", before: (0..<24).map { "\(($0*7+n)%11)\n" }.joined(),
                        after: (0..<27).map { "\(($0*3+n)%13)\n" }.joined()))
            }
            let unique = (0..<250).map { "line-\($0)\n" }
            extra.append(
                Pair(
                    name: "unique-anchors", before: unique.joined(),
                    after: (["new\n"] + unique.dropFirst() + ["end\n"]).joined()))
            extra.append(Pair(name: "reverse-unique", before: unique.joined(), after: unique.reversed().joined()))
            for pair in corpus + extra {
                for strategy in ReviewDiffStrategy.allCases {
                    for reverse in [false, true] {
                        let a = try snapshot(reverse ? pair.after : pair.before)
                        let b = try snapshot(reverse ? pair.before : pair.after)
                        let changes = await FirstPartyReviewDiff(strategy: strategy).compare(
                            a, b,
                            policy: .correctness, token: ReviewCancellation(), hooks: .init())
                        // Explicit correctness-only projection for the inherited multi-MiB corpus.
                        // Runtime always retains the unchanged 2s/32m default.
                        var projectionPolicy = ComparePolicy.default
                        if pair.name.hasPrefix("huge-") {
                            projectionPolicy.seconds = 30
                            projectionPolicy.maximumWork = 256_000_000
                        }
                        let projection = try await CompareProjection.build(
                            original: a, modified: b, changes: changes, policy: projectionPolicy)
                        for side in [CompareSide.original, .modified] {
                            check(
                                reconstructed(projection, side, unified: false) == projection.snapshot(side).bytes,
                                "D1 side reconstruction \(pair.name) \(strategy) \(reverse)")
                            check(
                                reconstructed(projection, side, unified: true) == projection.snapshot(side).bytes,
                                "D1 unified reconstruction \(pair.name) \(strategy) \(reverse)")
                        }
                        for side in [CompareSide.original, .modified] {
                            var joined = Data()
                            for segment in projection.segments {
                                let row = projection.unified[segment.unifiedRow]
                                let range = row.side == side ? segment.range : segment.counterpart
                                if let range {
                                    joined.append(
                                        projection.snapshot(side).bytes.subdata(in: range.lower..<range.upper))
                                }
                            }
                            check(
                                joined == projection.snapshot(side).bytes,
                                "D1 bounded unified cells reconstruct exact bytes")
                        }
                        check(
                            projection.originalToRow.count == projection.originalLines.count
                                && projection.modifiedToRow.count == projection.modifiedLines.count,
                            "D1 source map totals")
                        for fold in projection.folds {
                            check(
                                projection.rows[fold.rows].allSatisfy { $0.change == nil },
                                "D1 folds never hide a change")
                        }
                    }
                }
            }
            var n = CompareNavigation(count: 3)
            check(
                n.move(next: true) == 0 && n.move(next: true) == 1 && n.move(next: true) == 2 && !n.hasNext,
                "D1 Next reaches every change without wrapping")
            check(n.move(next: false) == 1 && n.move(next: false) == 0 && !n.hasPrevious, "D1 Previous stops at first")
            n = CompareNavigation(count: 3)
            check(n.move(next: false) == 2, "D1 initial Previous goes last")
            check(
                !CompareNavigation(count: 0).hasNext && !CompareNavigation(count: 0).hasPrevious,
                "D1 empty disables both")
            let a = try snapshot((0..<20).map { "\($0)\n" }.joined()),
                b = try snapshot((0..<20).map { $0 == 10 ? "changed\n" : "\($0)\n" }.joined())
            let changes = await FirstPartyReviewDiff().compare(
                a, b, policy: .default, token: ReviewCancellation(), hooks: .init())
            let p = try await CompareProjection.build(original: a, modified: b, changes: changes)
            check(p.folds.map(\.rows) == [1..<7, 14..<20], "D1 three context lines at prefix/suffix")
            for limit in [0, 1] {
                var policy = ComparePolicy.default
                policy.maximumWork = limit
                do {
                    _ = try await CompareProjection.build(original: a, modified: b, changes: changes, policy: policy)
                    check(false, "D1 work refused")
                } catch { check(error as? CompareFailure == .budget(.work), "D1 work budget typed") }
            }
            var policy = ComparePolicy.default
            policy.maximumOutputBytes = 0
            do {
                _ = try await CompareProjection.build(original: a, modified: b, changes: changes, policy: policy)
                check(false, "D1 output refused")
            } catch { check(error as? CompareFailure == .budget(.output), "D1 output pre-admission") }
            for dimension in 0..<3 {
                var limited = ComparePolicy.default
                if dimension == 0 { limited.maximumWorkspaceBytes = 0 }
                if dimension == 1 { limited.maximumRows = 0 }
                if dimension == 2 { limited.seconds = 0 }
                do {
                    _ = try await CompareProjection.build(original: a, modified: b, changes: changes, policy: limited)
                    check(false, "D1 projection resource guard refuses")
                } catch {
                    check(
                        error as? CompareFailure
                            == .budget(dimension == 0 ? .workspace : dimension == 1 ? .output : .time),
                        "D1 separate projection guard reason")
                }
            }
            for phase in [ReviewDiffPhase.lines, .output] {
                let cancelled = ReviewCancellation()
                do {
                    _ = try await CompareProjection.build(
                        original: a, modified: b, changes: changes, token: cancelled,
                        hooks: .init(checkpoint: { at, _ in if at == phase { cancelled.cancel() } }))
                    check(false, "D1 phase cancellation")
                } catch { check(error as? CompareFailure == .cancelled, "D1 cancellation during indexing/output") }
            }
            let token = ReviewCancellation()
            token.cancel()
            do {
                _ = try await CompareProjection.build(original: a, modified: b, changes: changes, token: token)
                check(false, "D1 cancellation")
            } catch { check(error as? CompareFailure == .cancelled, "D1 cancellation typed") }
            let invalid = ReviewChangeSet(
                original: SnapshotID(), modified: b.id, blocks: changes.blocks, completeness: .complete,
                metrics: .init())
            do {
                _ = try await CompareProjection.build(original: a, modified: b, changes: invalid)
                check(false, "D1 foreign IDs")
            } catch { check(error as? CompareFailure == .invalid, "D1 foreign IDs rejected") }
            let incomplete = ReviewChangeSet(
                original: a.id, modified: b.id, blocks: [], completeness: .budgetStopped(.time), metrics: .init())
            do {
                _ = try await CompareProjection.build(original: a, modified: b, changes: incomplete)
                check(false, "D1 incomplete")
            } catch {
                check(error as? CompareFailure == .incomplete && !incomplete.identical, "D1 incomplete never identical")
            }
            let broken = ReviewChangeBlock(
                original: .init(snapshot: a.id, lower: 1, upper: 2),
                modified: .init(snapshot: b.id, lower: 0, upper: 2), kind: .modify, inline: .unrefined(.notAttempted))
            let bad = ReviewChangeSet(
                original: a.id, modified: b.id, blocks: [broken], completeness: .complete, metrics: .init())
            do {
                _ = try await CompareProjection.build(original: a, modified: b, changes: bad)
                check(false, "D1 bad line bounds")
            } catch { check(error as? CompareFailure == .invalid, "D1 non-line-aligned metadata rejected") }
        }
    }
}
