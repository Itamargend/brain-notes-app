import BrainMerge
import Foundation
import Testing

/// Swift against the TypeScript reference, field for field, on differential.json
/// (Tools/differential/gen.ts: the 73 spec inputs plus seeded random and adversarial cases).
/// Unlike the vector test, every output field is compared, including ones `expect` leaves out.
@Suite("Differential: Swift port vs TypeScript reference")
struct DifferentialTests {
    @Test("splitBlocks")
    func blocks() {
        compare("splitBlocks") { c in json(splitBlocks(c["text"]?.string ?? "")) }
    }

    @Test("matchLines, including the 4,000,000-cell limit")
    func match() {
        compare("matchLines") { c in JSON.array(try matchLines(lines(c["a"]), lines(c["b"])).map { JSON.number(Double($0)) }) }
    }

    @Test("diff3")
    func threeWay() {
        compare("diff3") { c in
            json(try diff3(lines(c["o"]), lines(c["a"]), lines(c["b"]), unionInsertions: c["union"]?.bool ?? true))
        }
    }

    @Test("mergeFile: 73-vector inputs with every output field, plus random cases")
    func merge() {
        compare("merge") { c in
            json(try mergeFile(base: c["base"]?.string, mine: c["mine"]?.string, theirs: c["theirs"]?.string, options: mergeOptions(c["options"])))
        }
    }

    @Test("nfc, foldKey and checkPath")
    func paths() {
        compareWith("paths", expected: { c in
            JSON.object([("nfc", c["nfc"] ?? JSON.null), ("fold", c["fold"] ?? JSON.null), ("check", c["check"] ?? JSON.null)])
        }, actual: { c in
            let p = c["path"]?.string ?? ""
            let check: JSON = checkPath(p).map { JSON.string($0.rawValue) } ?? JSON.null
            return JSON.object([("nfc", JSON.string(nfc(p))), ("fold", JSON.string(foldKey(p))), ("check", check)])
        })
    }

    @Test("checkPath size limit counts UTF-8 bytes")
    func pathContent() {
        compareWith("pathContent", expected: { c in c["check"] ?? JSON.null }, actual: { c in
            let block = checkPath(c["path"]?.string ?? "", content: content(c["content"]))
            return block.map { JSON.string($0.rawValue) } ?? JSON.null
        })
    }

    @Test("freePath")
    func free() {
        compare("freePath") { c in
            JSON.string(freePath(c["path"]?.string ?? "", PathIndex((c["existing"]?.array ?? []).map { $0.string ?? "" })))
        }
    }

    @Test("yamlStr (JSON.stringify)")
    func yaml() {
        compare("yaml") { c in JSON.string(yamlStr(c["in"]?.string ?? "")) }
    }

    @Test("copyStamp")
    func stamp() {
        compare("stamp") { c in JSON.string(try copyStamp(c["in"]?.string ?? "")) }
    }

    @Test("planCommit: 24 plan-vector inputs plus random, sort-order and final-guard cases")
    func plan() {
        compare("plan") { c in json(try planCommit(planInput(c["input"] ?? .null))) }
    }
}

/// Compares against the case's "out" (or its "error", for copyStamp).
private func compare(_ category: String, _ actual: (JSON) throws -> JSON) {
    compareWith(category, expected: { c in c["out"] ?? JSON.object([("error", c["error"] ?? JSON.null)]) }, actual: actual)
}

/// Runs every case of one category; an error thrown by Swift counts as `{"error": message}`,
/// which is how the generator records an error thrown by the reference.
private func compareWith(_ category: String, expected: (JSON) -> JSON, actual: (JSON) throws -> JSON) {
    let cases = Fixtures.differential[category]?.array ?? []
    var failures = 0
    for (n, c) in cases.enumerated() {
        let want = expected(c)
        let got: JSON
        do {
            got = try actual(c)
        } catch {
            got = errorJSON(error)
        }
        if !jsonEqual(want, got) {
            failures += 1
            if failures <= 5 {
                Issue.record("\(category) case \(c["id"]?.string ?? String(n)): \(describeDifference(expected: want, actual: got))")
            }
        }
    }
    print("DIFFERENTIAL \(category) \(cases.count - failures)/\(cases.count)")
    #expect(!cases.isEmpty, "differential.json has no \(category) cases")
    #expect(failures == 0, "\(failures) of \(cases.count) \(category) cases differ from the TypeScript reference")
}
