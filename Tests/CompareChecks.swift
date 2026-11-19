// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import TextTankCore

@main struct CompareChecks {
    struct Pair: Decodable { let name: String, before: String, after: String }
    static func snapshot(_ text: String) throws -> TextSnapshot {
        try TextSnapshot(bytes:Data(text.utf8),source:.freeText(UUID()),label:"Owned comparison")
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
        for i in indices { let r = lines[i].range; bytes.append(s.bytes.subdata(in:r.lower..<r.upper)) }
        return bytes
    }
    static func main() async {
        await Checks.run("CompareChecks") {
            let corpus = try JSONDecoder().decode([Pair].self,
                from:Data(contentsOf:TestPaths.fixtures.appendingPathComponent("review/corpus.json")))
            let extra = [Pair(name:"empty",before:"",after:""),Pair(name:"leading",before:"b\n",after:"a\nb\n"),
                Pair(name:"EOF",before:"old",after:"new\n"),Pair(name:"FEFF/NUL",before:"\u{feff}\0x\r",after:"\u{feff}\0y\n"),
                Pair(name:"clusters",before:"a👩🏽‍💻 e\u{301}\r\n",after:"b👩🏽‍💻 e\u{300}\n")]
            for pair in corpus+extra {
                for strategy in ReviewDiffStrategy.allCases {
                    for reverse in [false,true] {
                        let a = try snapshot(reverse ? pair.after : pair.before)
                        let b = try snapshot(reverse ? pair.before : pair.after)
                        let changes = await FirstPartyReviewDiff(strategy:strategy).compare(original:a,modified:b,
                            policy:.correctness,token:ReviewCancellation(),hooks:.init())
                        let projection = try await CompareProjection.build(original:a,modified:b,changes:changes)
                        for side in [CompareSide.original,.modified] {
                            check(reconstructed(projection,side,unified:false) == projection.snapshot(side).bytes,
                                "D1 side reconstruction \(pair.name) \(strategy) \(reverse)")
                            check(reconstructed(projection,side,unified:true) == projection.snapshot(side).bytes,
                                "D1 unified reconstruction \(pair.name) \(strategy) \(reverse)")
                        }
                        check(projection.originalToRow.count == projection.originalLines.count
                            && projection.modifiedToRow.count == projection.modifiedLines.count,"D1 source map totals")
                        for fold in projection.folds {
                            check(projection.rows[fold.rows].allSatisfy { $0.change == nil },"D1 folds never hide a change")
                        }
                    }
                }
            }
            var n = CompareNavigation(count:3)
            check(n.move(next:true) == 0 && n.move(next:true) == 1 && n.move(next:true) == 2 && !n.hasNext,
                "D1 Next reaches every change without wrapping")
            check(n.move(next:false) == 1 && n.move(next:false) == 0 && !n.hasPrevious,"D1 Previous stops at first")
            n = CompareNavigation(count:3)
            check(n.move(next:false) == 2,"D1 initial Previous goes last")
            check(!CompareNavigation(count:0).hasNext && !CompareNavigation(count:0).hasPrevious,"D1 empty disables both")
            let a = try snapshot((0..<20).map { "\($0)\n" }.joined()), b = try snapshot((0..<20).map { $0 == 10 ? "changed\n" : "\($0)\n" }.joined())
            let changes = await FirstPartyReviewDiff().compare(original:a,modified:b,policy:.default,token:ReviewCancellation(),hooks:.init())
            let p = try await CompareProjection.build(original:a,modified:b,changes:changes)
            check(p.folds.map(\.rows) == [0..<7,14..<20],"D1 three context lines at prefix/suffix")
            for limit in [0,1] {
                var policy = ComparePolicy.default; policy.maximumWork = limit
                do { _ = try await CompareProjection.build(original:a,modified:b,changes:changes,policy:policy); check(false,"D1 work refused") }
                catch { check(error as? CompareFailure == .budget(.work),"D1 work budget typed") }
            }
            var policy = ComparePolicy.default; policy.maximumOutputBytes = 0
            do { _ = try await CompareProjection.build(original:a,modified:b,changes:changes,policy:policy); check(false,"D1 output refused") }
            catch { check(error as? CompareFailure == .budget(.output),"D1 output pre-admission") }
            let token = ReviewCancellation(); token.cancel()
            do { _ = try await CompareProjection.build(original:a,modified:b,changes:changes,token:token); check(false,"D1 cancellation") }
            catch { check(error as? CompareFailure == .cancelled,"D1 cancellation typed") }
            let invalid = ReviewChangeSet(original:SnapshotID(),modified:b.id,blocks:changes.blocks,completeness:.complete,metrics:.init())
            do { _ = try await CompareProjection.build(original:a,modified:b,changes:invalid); check(false,"D1 foreign IDs") }
            catch { check(error as? CompareFailure == .invalid,"D1 foreign IDs rejected") }
            let incomplete = ReviewChangeSet(original:a.id,modified:b.id,blocks:[],completeness:.budgetStopped(.time),metrics:.init())
            do { _ = try await CompareProjection.build(original:a,modified:b,changes:incomplete); check(false,"D1 incomplete") }
            catch { check(error as? CompareFailure == .incomplete && !incomplete.identical,"D1 incomplete never identical") }
            let broken = ReviewChangeBlock(original:.init(snapshot:a.id,lower:1,upper:2),modified:.init(snapshot:b.id,lower:0,upper:2),kind:.modify,inline:.unrefined(.notAttempted))
            let bad = ReviewChangeSet(original:a.id,modified:b.id,blocks:[broken],completeness:.complete,metrics:.init())
            do { _ = try await CompareProjection.build(original:a,modified:b,changes:bad); check(false,"D1 bad line bounds") }
            catch { check(error as? CompareFailure == .invalid,"D1 non-line-aligned metadata rejected") }
        }
    }
}
