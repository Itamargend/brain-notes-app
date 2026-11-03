import BrainMerge
import Foundation
import Testing

/// The bundled test resources, parsed once.
enum Fixtures {
    static let mergeVectors: [MergeVector] = vectors("vectors").map(MergeVector.init)
    static let planVectors: [PlanVector] = vectors("plan-vectors").map(PlanVector.init)
    static let differential: JSON = load("differential")

    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { fatalError("test resource \(name).json is missing from the bundle") }
        return data
    }

    static func load(_ name: String) -> JSON {
        do {
            return try JSONParser.parse(data(name))
        } catch {
            fatalError("\(name).json: \(error)")
        }
    }

    private static func vectors(_ name: String) -> [JSON] {
        load(name)["vectors"]?.array ?? []
    }
}

struct MergeVector: Sendable, CustomTestStringConvertible {
    let id: String
    let title: String
    let base: String?
    let mine: String?
    let theirs: String?
    let options: MergeOptions
    let expect: JSON

    init(_ j: JSON) {
        id = j["id"]?.string ?? "?"
        title = j["title"]?.string ?? ""
        base = j["base"]?.string
        mine = j["mine"]?.string
        theirs = j["theirs"]?.string
        options = mergeOptions(j["options"])
        expect = j["expect"] ?? .null
    }

    var testDescription: String { "\(id) \(title)" }
}

struct PlanVector: Sendable, CustomTestStringConvertible {
    let id: String
    let title: String
    let input: PlanInput
    let expect: JSON

    init(_ j: JSON) {
        id = j["id"]?.string ?? "?"
        title = j["title"]?.string ?? ""
        input = planInput(j)
        expect = j["expect"] ?? .null
    }

    var testDescription: String { "\(id) \(title)" }
}

// MARK: - JSON -> library input

func mergeOptions(_ j: JSON?) -> MergeOptions {
    MergeOptions(unionInsertions: j?["unionInsertions"]?.bool ?? true)
}

/// A content field: a string, or `{"$repeat": [s, n]}` meaning s repeated n times.
func content(_ j: JSON?) -> String {
    if let s = j?.string { return s }
    if let rep = j?["$repeat"]?.array, rep.count == 2, let s = rep[0].string, let n = rep[1].int {
        return String(repeating: s, count: n)
    }
    return ""
}

/// `{"$lines": [prefix, n]}` means the lines "<prefix>0\n" ... "<prefix>(n-1)\n".
func lines(_ j: JSON?) -> [String] {
    if let a = j?.array { return a.map { $0.string ?? "" } }
    if let spec = j?["$lines"]?.array, spec.count == 2, let p = spec[0].string, let n = spec[1].int {
        return (0..<n).map { "\(p)\($0)\n" }
    }
    return []
}

func pathMap(_ j: JSON?) -> PathMap? {
    guard let members = j?.members else { return nil }
    return PathMap(members.map { ($0.key, $0.value.string ?? "") })
}

func planInput(_ j: JSON) -> PlanInput {
    let ops: [Op] = (j["ops"]?.array ?? []).map { o in
        let path = o["path"]?.string ?? ""
        switch o["kind"]?.string ?? "" {
        case "edit": return .edit(path: path, content: content(o["content"]))
        case "create": return .create(path: path, content: content(o["content"]))
        default: return .delete(path: path)
        }
    }
    return PlanInput(
        baseTree: pathMap(j["baseTree"]) ?? PathMap(),
        theirsTree: pathMap(j["theirsTree"]) ?? PathMap(),
        ops: ops,
        renames: pathMap(j["renames"]),
        device: j["device"]?.string ?? "",
        time: j["time"]?.string ?? ""
    )
}

// MARK: - library output -> JSON (same shape as the reference's objects; absent fields are left out)

func json(_ r: MergeResult) -> JSON {
    var m: [(key: String, value: JSON)] = [
        ("kind", .string(r.kind.rawValue)),
        ("content", r.content.map(JSON.string) ?? .null),
        ("copy", r.copy.map(JSON.string) ?? .null),
    ]
    if let reason = r.reason { m.append(("reason", .string(reason.rawValue))) }
    if let clashes = r.clashes { m.append(("clashes", .array(clashes.map(JSON.string)))) }
    if let unions = r.unions { m.append(("unions", .number(Double(unions)))) }
    return .object(m)
}

func json(_ o: PlanOutput) -> JSON {
    let entries: [JSON] = o.entries.map { e -> JSON in
        switch e {
        case let .write(path, content): return .object([("path", .string(path)), ("content", .string(content))])
        case let .delete(path): return .object([("path", .string(path)), ("delete", .bool(true))])
        }
    }
    let attention: [JSON] = o.attention.map { a -> JSON in
        var m: [(key: String, value: JSON)] = [("path", .string(a.path)), ("reason", .string(a.reason.rawValue))]
        if let copy = a.copy { m.append(("copy", .string(copy))) }
        if let detail = a.detail { m.append(("detail", .string(detail))) }
        return .object(m)
    }
    return .object([
        ("entries", .array(entries)),
        ("attention", .array(attention)),
        ("kept", .array(o.kept.map { JSON.number(Double($0)) })),
        ("noops", .array(o.noops.map { JSON.number(Double($0)) })),
    ])
}

func json(_ blocks: [Block]) -> JSON {
    JSON.array(blocks.map { b in JSON.object([("key", JSON.string(b.key)), ("lines", JSON.array(b.lines.map(JSON.string)))]) })
}

func json(_ d: Diff3Result) -> JSON {
    switch d {
    case let .clean(lines, unions):
        return .object([("clean", .bool(true)), ("lines", .array(lines.map(JSON.string))), ("unions", .number(Double(unions)))])
    case let .conflict(conflicts):
        return .object([("clean", .bool(false)), ("conflicts", .number(Double(conflicts)))])
    }
}

/// What the reference returns for a thrown error.
func errorJSON(_ error: any Error) -> JSON {
    .object([("error", .string(String(describing: error)))])
}

// MARK: - comparing

/// Mismatches between an `expect` object and an output, checking only the fields `expect` lists.
/// This is how the reference's own test passes all 78 vectors: 10 merge vectors leave out
/// `unions`, which the reference returns as 0 (see RESULTS.md). The differential test checks every field.
func expectMismatches(expect: JSON, actual: JSON) -> [String] {
    guard let fields = expect.members else { return ["expect is not an object"] }
    var problems: [String] = []
    for field in fields {
        let got = actual[field.key]
        if got == nil || !jsonEqual(field.value, got!) {
            problems.append("\(field.key): " + describeDifference(expected: field.value, actual: got))
        }
    }
    return problems
}
