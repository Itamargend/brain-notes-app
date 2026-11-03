import BrainMerge
import Foundation
import Testing

/// The two vector files from spec/merge, unchanged. Every field each vector's `expect` lists must
/// match exactly (strings byte for byte, arrays in order).
@Suite("Spec vectors (spec/merge)")
struct VectorTests {
    @Test("vectors.json: mergeFile", arguments: Fixtures.mergeVectors)
    func mergeVector(_ v: MergeVector) throws {
        let result = try mergeFile(base: v.base, mine: v.mine, theirs: v.theirs, options: v.options)
        for problem in expectMismatches(expect: v.expect, actual: json(result)) {
            Issue.record("\(v.id) \(problem)")
        }
    }

    @Test("plan-vectors.json: planCommit", arguments: Fixtures.planVectors)
    func planVector(_ v: PlanVector) throws {
        let output = try planCommit(v.input)
        for problem in expectMismatches(expect: v.expect, actual: json(output)) {
            Issue.record("\(v.id) \(problem)")
        }
    }

    @Test("All 100 vectors pass (53 merge + 47 plan)")
    func passCount() {
        var mergePass = 0
        for v in Fixtures.mergeVectors {
            if let r = try? mergeFile(base: v.base, mine: v.mine, theirs: v.theirs, options: v.options),
               expectMismatches(expect: v.expect, actual: json(r)).isEmpty { mergePass += 1 }
        }
        var planPass = 0
        for v in Fixtures.planVectors {
            if let o = try? planCommit(v.input), expectMismatches(expect: v.expect, actual: json(o)).isEmpty { planPass += 1 }
        }
        print("VECTORS merge \(mergePass)/\(Fixtures.mergeVectors.count) plan \(planPass)/\(Fixtures.planVectors.count) total \(mergePass + planPass)/\(Fixtures.mergeVectors.count + Fixtures.planVectors.count)")
        #expect(Fixtures.mergeVectors.count == 53)
        #expect(Fixtures.planVectors.count == 47)
        #expect(mergePass == Fixtures.mergeVectors.count)
        #expect(planPass == Fixtures.planVectors.count)
    }

    @Test("Bundled vector files are byte-identical to spec/merge")
    func bundledCopiesMatchSpec() throws {
        // #filePath is .../Tests/BrainMergeTests/VectorTests.swift; the repo root is three levels up.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["vectors", "plan-vectors"] {
            let original = try Data(contentsOf: root.appending(path: "spec/merge/\(name).json"))
            #expect(Fixtures.data(name) == original, "Tests/BrainMergeTests/Resources/\(name).json differs from spec/merge/\(name).json")
        }
    }
}
