/// A `Record<string, string>` with JavaScript object semantics, for trees and renames.
///
/// A Swift `[String: String]` cannot stand in for it: its keys use canonical equivalence, so an NFC
/// and an NFD spelling of one name would collapse into one entry, and GitHub can hold both (spike S1).
/// Here keys are compared byte for byte and `keys` keeps insertion order (the `Object.keys` order the
/// reference iterates in). Setting an existing key replaces the value and keeps its position.
public struct PathMap: Sendable, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [ExactKey: String] = [:]

    public init() {}

    public init<S: Sequence>(_ pairs: S) where S.Element == (String, String) {
        for (key, value) in pairs { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    public var count: Int { keys.count }

    public func has(_ key: String) -> Bool { storage[ExactKey(key)] != nil }

    public subscript(key: String) -> String? {
        get { storage[ExactKey(key)] }
        set {
            let k = ExactKey(key)
            if let newValue {
                if storage.updateValue(newValue, forKey: k) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: k) != nil {
                keys.removeAll { exactEqual($0, key) }
            }
        }
    }
}
